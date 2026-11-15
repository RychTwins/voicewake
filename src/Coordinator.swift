import AppKit

/// Veille -> déclenchement -> pause pendant la conversation -> veille.
final class Coordinator {
    private let config: Config
    private let router: Router
    private let detector: WakeWordDetector
    private let trigger = ShortcutTrigger()
    private var lastWake = Date.distantPast
    private var pauseTimer: Timer?

    init(config: Config) throws {
        self.config = config
        self.router = Router(config: config)
        self.detector = try WakeWordDetector(config: config, hints: router.hints)
        detector.onText = { [weak self] text, isFinal in self?.handle(text, isFinal: isFinal) }
        Feedback.configure(config)
        trigger.onReadingFinished = { [weak self] target, window in
            self?.continueConversation(target, in: window)
        }
    }

    /// Bundle IDs des apps et éditeurs pilotés.
    private var managedBundleIDs: Set<String> {
        Set(config.targets.compactMap(\.bundleID) + (config.editors ?? []).flatMap(\.bundleIDs))
    }

    /// Prépare l'arbre d'accessibilité des apps pilotées dès qu'elles tournent : sinon, juste après
    /// un redémarrage du Mac ou de l'app, le premier « Dis Claude » ne trouve pas le bouton micro.
    private func warmUpAccessibility() {
        let ids = managedBundleIDs
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier.map(ids.contains) == true {
            AXButtonPresser.enableAccessibility(app)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier.map(self.managedBundleIDs.contains) == true else { return }
            // Laisser l'app ouvrir sa fenêtre, puis demander l'arbre.
            for delay in [2.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { AXButtonPresser.enableAccessibility(app) }
            }
        }
    }

    func start() {
        _ = ShortcutTrigger.checkAccessibility(prompt: true)
        warmUpAccessibility()
        detector.requestPermissions { [weak self] granted in
            guard granted, let self else { exit(1) }
            self.detector.start()
            let names = self.config.targets.map(\.id).joined(separator: ", ")
            log("VoiceWake prêt. Cibles : \(names).")
        }
    }

    /// Cible en cours de dictée, quand l'envoi vocal est actif.
    private var active: Target?
    private var pendingSend: DispatchWorkItem?
    private var sendEnabled: Bool { !(config.sendPhrases ?? []).isEmpty }

    private func externalDictation(for target: Target) -> ExternalDictation? {
        target.id.contains("@") ? nil : config.externalDictation
    }

    /// Le texte transcrit (tes paroles) n'est écrit dans le log qu'en mode debug.
    private func said(_ text: String) -> String { config.debug ? " (« \(text) »)" : "" }

    private func handle(_ text: String, isFinal: Bool = false) {
        // Pas de garde « un assistant parle » ici : Claude garde une sortie audio ouverte pendant sa dictée.
        // Relecture après « ok arrête » / « garde le brouillon » (micro coupé) : une commande de veille
        // (« lis à partir de… », « fais la lecture », « dis Claude »…) abandonne l'attente de « ok envoie ».
        if active != nil, !recording, !stopping, reviewUntil != nil,
           !router.isSendCommand(text), wakeKey(text) != nil {
            // « Où on en est ? » : on répond sans abandonner le brouillon.
            if AppCommand.match(text, router: router, config: config) == .status {
                announceStatus()
                return
            }
            log("Attente de « ok envoie » abandonnée : nouvelle commande.")
            endPause()
            // Pas de return : la même phrase est traitée tout de suite par la veille, ci-dessous.
        }
        if let t = active {
            if !router.endsWithStopPhrase(text), let other = switchTarget(text, from: t) {
                switchDictation(from: t, to: other)
                return
            }
            checkSend(text, t, isFinal: isFinal)
            return
        }
        // Lecture à voix haute d'une app en cours : on la suit à l'oreille pour afficher le mot en cours.
        if (config.showReadingProgress ?? false) || (config.highlightReadingInApp ?? false),
           let r = currentReader(), let app = ShortcutTrigger.runningApp(for: r) {
            follower.selectInApp = config.highlightReadingInApp ?? false
            if config.debug, follower.onProgress == nil { follower.onProgress = { log("Suivi de lecture : mot \($0) sur \($1).") } }
            if config.debug, follower.onHighlight == nil { follower.onHighlight = { log("Surlignage : bloc \($0), cadre \($1.map { NSStringFromRect($0) } ?? "introuvable").") } }
            follower.follow(text, target: r, app: app)
        }
        // Le moteur corrige souvent sa première hypothèse (« Salut Claude » → « Salut Codex ») :
        // on attend que la transcription se stabilise avant d'agir.
        // Le moteur corrige souvent sa première hypothèse (« Salut Claude » → « Salut Codex ») :
        // on agit sur son résultat définitif, ou au plus tard `wakeMaxWaitSeconds` après la première
        // détection (un flux continu, comme la voix de lecture, ne bloque donc pas les commandes).
        latestWakeText = text
        guard wakeKey(text) != nil || pendingWake != nil else { return }
        let fire = { [weak self] in
            guard let self else { return }
            self.pendingWake?.cancel()
            self.pendingWake = nil
            guard self.active == nil else { return }
            self.handleWake(self.latestWakeText)
        }
        if isFinal { return fire() }
        guard pendingWake == nil else { return }
        let work = DispatchWorkItem(block: fire)
        pendingWake = work
        // « Lis à partir de … » : laisser le temps de dire la citation.
        // « Ouvre … » / « Nouvelle session dans … » : laisser le temps de dire le nom.
        var wait = config.wakeMaxWaitSeconds ?? 1.8
        if router.containsAny(text, config.readFromPhrases) { wait = 6 }
        else if case .open? = NavCommands.match(text, target: nil, config: config) { wait = 3 }
        else if case .newSessionIn? = NavCommands.match(text, target: nil, config: config) { wait = 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private let announcer = Announcer()
    private var lastStatus = Date.distantPast

    /// « Où on en est ? » : dit l'état de VoiceWake avec une voix du Mac. Le texte ne contient aucune
    /// phrase de commande, pour que VoiceWake ne réagisse pas à sa propre annonce.
    private func announceStatus() {
        guard !announcer.isSpeaking, Date().timeIntervalSince(lastStatus) >= 4 else { return }
        lastStatus = Date()
        let name = { (t: Target) in t.appName ?? t.id.capitalized }
        let message: String
        if let t = active, let until = reviewUntil {
            message = "Brouillon gardé pour \(name(t)), en attente d'envoi encore \(max(0, Int(until.timeIntervalSinceNow))) secondes."
        } else if let t = active {
            message = "Dictée en cours vers \(name(t))."
        } else if reader.isActive {
            message = reader.isPaused ? "Lecteur intégré en pause." : "Lecteur intégré en cours."
        } else if let t = trigger.readingTarget() {
            message = "Lecture à voix haute de \(name(t)) en cours."
        } else if let t = trigger.pausedTarget() {
            message = "Lecture de \(name(t)) en pause."
        } else if let t = router.frontmostTarget(), let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) {
            message = "En veille, prêt. \(name(t)) est au premier plan."
        } else {
            message = "En veille, prêt."
        }
        log("État : \(message)")
        announcer.say(message, locale: config.locale, voice: config.readerVoice) { [weak self] in
            self?.detector.reset() // oublier ce que le micro a entendu de l'annonce
        }
    }

    private let reader = Reader()
    private let follower = ReadingFollower()
    private var detectedReader: (target: Target?, at: Date) = (nil, .distantPast)

    /// L'assistant qui lit à voix haute : lecture lancée par VoiceWake, sinon lecture lancée à la main
    /// (bouton de pause visible dans l'app au premier plan ; vérifié au plus toutes les 2 s).
    private func currentReader() -> Target? {
        if let r = trigger.readingTarget() { return r }
        if Date().timeIntervalSince(detectedReader.at) < 2 { return detectedReader.target }
        var found: Target?
        // L'app au premier plan seulement si c'est une cible (pas de recherche dans les éditeurs ici).
        if let front = NSWorkspace.shared.frontmostApplication,
           let t = config.targets.first(where: { ShortcutTrigger.matches(front, $0) }),
           // Même processus que celui que VoiceWake pilotera ensuite pour cette cible.
           let app = ShortcutTrigger.runningApp(for: t), app.processIdentifier == front.processIdentifier,
           let pause = t.pauseReadShortcut?.buttons, !pause.isEmpty,
           !AXButtonPresser.all(pause, in: app).isEmpty { found = t }
        detectedReader = (found, Date())
        return found
    }
    private var readerTarget: Target?

    /// « Lis à partir de … » : cherche le passage dans le texte affiché par l'assistant et le lit depuis là.
    private func readFrom(_ query: [String]) {
        guard let target = trigger.pausedTarget() ?? trigger.readingTarget() ?? router.frontmostTarget(),
              let app = ShortcutTrigger.runningApp(for: target) else { Feedback.play(.failed); return log("Lecture : aucun assistant ouvert.") }
        let tokens = PassageFinder.tokens(in: app, target: target)
        let start = PassageFinder.find(query, in: tokens)
        guard let start else { Feedback.play(.failed); return log("Lecture : passage introuvable\(said(query.joined(separator: " "))).") }
        if trigger.readingTarget() != nil { trigger.pauseReading(target) }
        readerTarget = target
        reader.voiceName = config.readerVoice
        reader.onFinish = { log("Lecteur intégré : lecture terminée.") }
        let words = PassageFinder.passage(tokens, from: start)
        guard !words.isEmpty else { Feedback.play(.failed); return log("Lecture : passage vide.") }
        Feedback.play(.understood)
        let passage = words.joined(separator: " ")
        log("Lecteur intégré → \(target.id), à partir du mot \(start), \(words.count) mots jusqu'à la fin de la réponse\(said(words.prefix(4).joined(separator: " "))).")
        reader.speak(passage, config: config)
    }

    /// Le micro entend aussi le lecteur intégré : une commande présente dans ce qu'il lit en ce moment est ignorée.
    private func spokenByOwnReader(_ text: String) -> Bool {
        let phrases = (config.readPausePhrases ?? []) + (config.interruptPhrases ?? []) + (config.readResumePhrases ?? [])
            + ReaderNav.allPhrases(config)
        return VoiceFilter.spokenByReader(text, phrases: phrases, spokenNow: reader.spokenNow, router: router)
    }

    private var insistence = Insistence()

    /// Commande attribuée à la voix de lecture mais redite par l'utilisateur (voir `Insistence`).
    private func insisted(_ text: String, phrases: [String]?, spokenNow: String) -> Bool {
        guard let phrase = router.lastMatch(text, phrases)?.phrase else { return false }
        return insistence.accept(phrase, spokenNow: spokenNow)
    }

    private var readCommandPhrases: [String] { (config.readPausePhrases ?? []) + (config.interruptPhrases ?? []) }

    private func spokenByReader(_ text: String, _ reader: Target) -> Bool {
        let phrases = (config.readPausePhrases ?? []) + (config.interruptPhrases ?? [])
        guard let hit = router.lastMatch(text, phrases), let app = ShortcutTrigger.runningApp(for: reader) else { return false }
        let shown = " " + normalize(AXButtonPresser.windowTexts(in: app).joined(separator: " ")) + " "
        guard shown.contains(" " + hit.phrase + " ") else { return false }
        guard let previous = hit.previous else { return true }
        return shown.contains(" " + previous + " " + hit.phrase + " ")
    }

    private var pendingWake: DispatchWorkItem?
    private var latestWakeText = ""

    /// Ce que la phrase déclencherait (cible ou commande de lecture), ou nil.
    private func wakeKey(_ text: String) -> String? {
        if router.readFromQuery(text) != nil || router.containsAny(text, config.readFromPhrases) { return "#readfrom" }
        if router.containsInterruptPhrase(text) { return "#interrupt" }
        if router.containsAny(text, config.readPausePhrases) { return "#pause" }
        if router.containsAny(text, config.readResumePhrases) { return "#resume" }
        if router.containsReadAloudPhrase(text) { return "#readaloud" }
        if reader.isActive, let nav = ReaderNav.match(text, config: config) { return "#" + nav.rawValue }
        if NavCommands.match(text, target: nil, config: config) != nil { return "#nav" }
        if let command = AppCommand.match(text, router: router, config: config) { return "#" + command.rawValue }
        return router.route(text)?.id
    }

    private func handleWake(_ text: String) {
        let interrupt = router.containsInterruptPhrase(text)
        let pauseRead = router.containsAny(text, config.readPausePhrases)
        let resumeRead = router.containsAny(text, config.readResumePhrases)
        let routed = router.route(text)
        let readAloud = router.containsReadAloudPhrase(text)
        if let query = router.readFromQuery(text) {
            detector.reset()
            // Le lecteur intégré ne doit pas se relancer lui-même en lisant « à partir de … ».
            if reader.isActive, !reader.isPaused,
               router.containsAny(reader.spokenNow, config.readFromPhrases),
               !insisted(text, phrases: config.readFromPhrases, spokenNow: reader.spokenNow) {
                Feedback.play(.ignored)
                return log("Commande ignorée : prononcée par le lecteur intégré.")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            if config.dryRun == true { return log("[essai] → lecture à partir d'un passage\(said(text))") }
            readFrom(query)
            return
        }
        // Lecteur intégré en cours : pause, reprise, écoute.
        if reader.isActive {
            defer { detector.reset() }
            if spokenByOwnReader(text), !insisted(text, phrases: readCommandPhrases + (config.readResumePhrases ?? []) + ReaderNav.allPhrases(config), spokenNow: reader.spokenNow) { Feedback.play(.ignored); return log("Commande ignorée : prononcée par le lecteur intégré.") }
            if interrupt, let t = readerTarget {
                reader.stop()
                lastWake = Date()
                log("Écoute → \(t.id) (micro).")
                detector.stop()
                trigger.fire(t, external: config.externalDictation) { [weak self] started in self?.didTrigger(t, started: started) }
            } else if pauseRead {
                reader.pause(); Feedback.play(.understood); log("Lecteur intégré : pause.")
            } else if resumeRead {
                reader.resume(); Feedback.play(.understood); log("Lecteur intégré : reprise.")
            } else if let nav = ReaderNav.match(text, config: config) {
                let ok: Bool
                switch nav {
                case .faster, .slower:
                    let r = reader.changeRate(faster: nav == .faster)
                    ok = r != nil
                    log(r.map { "Lecteur intégré : vitesse × \(String(format: "%.2f", $0))." } ?? "Lecteur intégré : vitesse déjà à la limite.")
                case .repeatSentence, .nextSentence:
                    ok = reader.skipSentence(forward: nav == .nextSentence)
                    log(ok ? "Lecteur intégré : \(nav == .nextSentence ? "phrase suivante" : "phrase reprise")." : "Lecteur intégré : pas d'autre phrase.")
                }
                Feedback.play(ok ? .understood : .failed)
            }
            return
        }
        // Navigation dans l'app au premier plan : menus, barre latérale, « ouvre <projet> ».
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil,
           let front = router.frontmostTarget(), let request = NavCommands.match(text, target: front, config: config) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            if config.dryRun == true { return log("[essai] → navigation \(request) sur \(front.id)") }
            NavCommands.run(request, target: front) { ok, detail in
                Feedback.play(ok ? .understood : .failed)
                log("Navigation → \(front.id) : \(ok ? "faite" : "impossible") (\(detail)).")
            }
            return
        }
        // Gestion de l'assistant : efface le brouillon, nouvelle conversation, copie, état.
        if !interrupt, !pauseRead, !resumeRead, !readAloud,
           let command = AppCommand.match(text, router: router, config: config) {
            detector.reset()
            if command == .status { return announceStatus() }
            // Pendant une lecture à voix haute, la voix pourrait dire la phrase : on n'agit pas.
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            guard let t = router.frontmostTarget() else { Feedback.play(.failed); return log("Commande : aucun assistant ouvert.") }
            if config.dryRun == true { return log("[essai] → \(command.rawValue) sur \(t.id)") }
            AppActions.run(command, target: t) { ok, detail in
                Feedback.play(ok ? .understood : .failed)
                log("Commande \(command.rawValue) → \(t.id) : \(ok ? "faite" : "impossible") (\(detail)).")
            }
            return
        }
        guard interrupt || pauseRead || resumeRead || readAloud || routed != nil else { return }
        // Lecture en pause : « reprends la lecture » la relance, « écoute » ouvre le micro.
        if trigger.readingTarget() == nil, let paused = trigger.pausedTarget(), resumeRead || interrupt {
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { detector.reset(); return }
            lastWake = Date()
            detector.reset()
            if resumeRead {
                Feedback.play(.understood)
                log("Reprise de la lecture → \(paused.id).")
                trigger.resumeReading(paused)
            } else {
                log("Écoute → \(paused.id) (micro).")
                detector.stop()
                trigger.fire(paused, external: config.externalDictation) { [weak self] started in
                    self?.didTrigger(paused, started: started)
                }
            }
            return
        }
        // Lecture à voix haute lancée par VoiceWake et encore en cours : seule une phrase
        // d'interruption compte, pour ne pas se déclencher sur la voix de l'assistant.
        // (Une app peut garder sa sortie audio ouverte sans rien lire : on ne bloque que nos lectures.)
        // La lecture reste « en cours » jusqu'à 3 s de silence continu (voir startReading).
        if let reader = currentReader() {
            if (pauseRead || interrupt), spokenByReader(text, reader),
               !insisted(text, phrases: readCommandPhrases, spokenNow: "") {
                Feedback.play(.ignored)
                log("Commande ignorée : prononcée par la voix de lecture de \(reader.id).")
                detector.reset()
                return
            }
            if pauseRead && !interrupt {
                Feedback.play(.understood)
                log("Lecture mise en pause → \(reader.id).")
                detector.reset()
                trigger.pauseReading(reader)
            } else if interrupt {
                let t = reader
                lastWake = Date()
                log("Interruption de la lecture → \(t.id)\(said(text)).")
                detector.stop()
                trigger.interruptAndDictate(t, external: config.externalDictation) { [weak self] started in
                    self?.didTrigger(t, started: started)
                }
            } else {
                log("Phrase ignorée : lecture à voix haute de \(reader.id) en cours\(said(text)).")
                detector.reset()
            }
            return
        }
        // « Fais la lecture » (ou « reprends la lecture » sans lecture en pause) : lire la dernière réponse.
        if readAloud || resumeRead {
            detector.reset()
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            guard let t = router.frontmostTarget() else { Feedback.play(.failed); return log("Lecture : aucun assistant ouvert.") }
            if config.dryRun == true { return log("[essai] → lecture de la dernière réponse de \(t.id)") }
            log("Lecture demandée → \(t.id).")
            trigger.readAloudNow(t) { ok in
                Feedback.play(ok ? .understood : .failed)
                log(ok ? "\(t.id) : lecture à voix haute lancée." : "\(t.id) : bouton de lecture introuvable.")
            }
            return
        }
        guard let routedTarget = routed else { detector.reset(); return }
        // Éditeur de code au premier plan avec cet assistant intégré : on vise l'éditeur.
        let target = config.externalDictation == nil ? (router.inEditor(routedTarget) ?? routedTarget) : routedTarget
        let now = Date()
        guard now.timeIntervalSince(lastWake) >= config.cooldownSeconds else {
            detector.reset()
            return
        }
        if config.dryRun == true {
            // Essai à blanc : on montre ce qui serait déclenché, sans rien ouvrir.
            log("[essai] → \(target.id)\(said(text))")
            detector.reset()
            return
        }
        lastWake = now
        log("Phrase détectée → \(target.id)\(said(text)).")

        // On libère le micro avant d'appuyer sur le raccourci.
        detector.stop()
        let external = externalDictation(for: target)
        trigger.fire(target, external: external) { [weak self] started in
            self?.didTrigger(target, started: started)
        }
    }

    private var dictatedContent = DictatedContent.empty
    private var lastAutoSendPause: TimeInterval = 0

    /// Conversation continue : la lecture de la réponse est finie, on rouvre le micro du même assistant.
    private func continueConversation(_ t: Target, in window: ShortcutTrigger.DictationWindow) {
        guard config.continuousConversation == true, externalDictation(for: t) == nil, config.dryRun != true,
              active == nil, pendingWake == nil, !reader.isActive else { return }
        // Seulement si l'assistant est resté devant : on ne reprend pas la main sur une autre app.
        guard window.isFocused else {
            return log("Conversation continue : fenêtre de \(t.id) changée, veille.")
        }
        lastWake = Date()
        log("Conversation continue → \(t.id) (micro).")
        detector.stop()
        trigger.reopenDictation(t, in: window) { [weak self] started in
            guard let self else { return }
            if started { self.pauseUntilConversationEnds(t, reopenedIn: window) }
            else { self.detector.start() }
        }
    }

    private func endSilentContinuation(_ t: Target) {
        guard active?.id == t.id, recording, !stopping else { return }
        stopping = true
        dictatedContent = .held
        trigger.stopDictation(t, in: dictationWindow, external: nil) { [weak self] stopped in
            guard let self, self.active?.id == t.id else { return }
            self.stopping = false
            if stopped {
                self.endPause()
                Feedback.play(.micClosed)
                log("Conversation continue : rien entendu, micro refermé.")
                self.detector.reset()
            } else {
                log("Conversation continue : fermeture du micro non confirmée.")
            }
        }
    }

    /// Micro de l'app encore ouvert (false après « ok arrête »).
    private var recording = false
    private var stopping = false
    private var dictationWindow: ShortcutTrigger.DictationWindow?
    /// Après « ok arrête » : attente de « ok envoie » jusqu'à cette date.
    private var reviewUntil: Date?

    /// Phrase en fin de transcription, puis silence :
    ///   « ok envoie » → coupe le micro de l'app si besoin et envoie ;
    ///   « ok arrête » → coupe seulement le micro, pour relire.
    /// Transcriptions récentes (date, texte normalisé), pour mesurer la pause avant « ok envoie ».
    private var history: [(at: Date, text: String)] = []

    /// Ce qui a été dit après la dernière pause d'au moins `minPause` secondes (texte normalisé), sinon nil.
    private func spokenAfterPause(_ n: String, minPause: Double) -> String? {
        guard history.count >= 2 else { return nil }
        for i in stride(from: history.count - 2, through: 0, by: -1) {
            let h = history[i].text
            guard !h.isEmpty, n.hasPrefix(h + " ") else { continue }
            if history[i + 1].at.timeIntervalSince(history[i].at) >= minPause { return String(n.dropFirst(h.count + 1)) }
        }
        return nil
    }

    /// « OK tu peux envoyer », « vas-y envoie »… : courte phrase après une pause, terminée par le verbe d'envoi.
    /// Pendant une dictée : « Salut Codex », dit seul après une pause, vise un autre assistant.
    private func switchTarget(_ text: String, from current: Target) -> Target? {
        guard !stopping else { return nil }
        let n = normalize(text)
        // Une vraie pause, puis la phrase d'activation dite seule : « dis à Codex » cité au fil
        // d'une dictée ne doit pas changer d'assistant.
        let candidate = spokenAfterPause(n, minPause: max(config.sendPauseBeforeSeconds ?? 0.6, 1.2)) ?? n
        guard router.isWakePhrase(candidate), let routed = router.route(candidate) else { return nil }
        let next = router.inEditor(routed) ?? routed
        return next.id == current.id ? nil : next
    }

    /// Arrête la dictée en cours (sans envoyer) puis ouvre le micro de l'autre assistant.
    private func switchDictation(from current: Target, to next: Target) {
        guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
        lastWake = Date()
        log("Changement d'assistant : \(current.id) → \(next.id).")
        let window = dictationWindow
        pendingSend?.cancel()
        pendingSend = nil
        let open = { [weak self] in
            guard let self else { return }
            self.endPause()
            self.detector.stop()
            self.trigger.fire(next, external: self.externalDictation(for: next)) { [weak self] started in
                self?.didTrigger(next, started: started)
            }
        }
        guard recording else { return open() }
        stopping = true
        trigger.stopDictation(current, in: window, external: externalDictation(for: current)) { [weak self] stopped in
            guard let self, self.active?.id == current.id else { return }
            if stopped { open() }
            else {
                self.stopping = false
                log("Changement annulé : l'arrêt du micro de \(current.id) n'a pas été confirmé.")
                self.detector.reset()
            }
        }
    }

    private func checkSend(_ text: String, _ t: Target, isFinal: Bool) {
        guard !stopping else { return }
        let normalized = normalize(text)
        if history.last?.text == normalized, !isFinal { return }
        pendingSend?.cancel()
        pendingSend = nil
        if history.last?.text != normalized {
            history.append((Date(), normalized))
        }
        if history.count > 60 { history.removeFirst(history.count - 60) }
        let external = externalDictation(for: t)
        let isolated = spokenAfterPause(normalized, minPause: config.sendPauseBeforeSeconds ?? 0.6) ?? normalized
        let stop = recording && (router.isStandaloneStop(text) || router.isStandaloneStop(isolated))
        let pause = !stop && recording && external == nil &&
            (router.isThoughtPause(text) || router.isThoughtPause(isolated))
        let send = !stop && !pause && sendEnabled && external == nil &&
            (router.isSendCommand(text) || router.isSendCommand(isolated))
        guard send || stop || pause else {
            if !normalized.isEmpty { dictatedContent.heardContent() }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active?.id == t.id else { return }
            self.pendingSend = nil
            if pause {
                self.dictatedContent = .paused
                self.lastAutoSendPause = ProcessInfo.processInfo.systemUptime
                self.history.removeAll()
                self.detector.reset()
                log("Envoi automatique suspendu jusqu'à la reprise de la dictée.")
                return
            }
            if stop {
                self.dictatedContent = .held
                log("Phrase d'arrêt détectée → \(t.id)\(self.said(text)).")
                self.stopping = true
                self.trigger.stopDictation(t, in: self.dictationWindow, external: external) { [weak self] stopped in
                    guard let self, self.active?.id == t.id else { return }
                    self.stopping = false
                    if stopped {
                        if external != nil || !self.sendEnabled {
                            self.endPause()
                            Feedback.play(.micClosed)
                            log("Dictée arrêtée. Reprise de la veille.")
                            self.detector.reset()
                            return
                        }
                        self.recording = false
                        self.reviewUntil = Date().addingTimeInterval(self.config.reviewSeconds ?? 180)
                        Feedback.play(.micClosed)
                        log("Dictée arrêtée. En attente de « ok envoie ».")
                    } else {
                        Feedback.play(.failed)
                        log("Arrêt de la dictée non effectué.")
                    }
                    self.detector.reset()
                }
                return
            }
            log("Phrase d'envoi détectée → \(t.id)\(self.said(text)).")
            self.submitNow(t)
        }
        if isFinal { work.perform() }
        else {
            pendingSend = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (config.sendSilenceSeconds ?? 1.2), execute: work)
        }
    }

    private func sendAfterSilence(_ target: Target, startedAt: TimeInterval) -> Bool {
        let delay = config.autoSendSilenceSeconds ?? 5
        guard pendingSend == nil, recording, let audio = detector.audioActivity else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard dictatedContent.shouldSend(now: now, startedAt: max(startedAt, lastAutoSendPause), lastBuffer: audio.lastBuffer,
                                         lastSpeech: audio.lastSpeech, delay: delay) else { return false }
        var submission = target
        if (submission.submitShortcut?.buttons ?? []).isEmpty, submission.bundleID == "com.anthropic.claudefordesktop" {
            submission.submitShortcut = try? Shortcut(spec: "button:Envoyer|Send|Send message")
        }
        guard !(submission.submitShortcut?.buttons ?? []).isEmpty else { return false }
        log("Silence de \(delay) s : envoi → \(target.id).")
        submitNow(submission)
        return true
    }

    private func submitNow(_ t: Target) {
        let stopFirst = recording
        let window = dictationWindow
        let readBaseline = trigger.readAloudBaseline(t, in: window)
        endPause()
        detector.stop()
        trigger.submit(t, in: window, stopFirst: stopFirst) { [weak self] submitted in
            Feedback.play(submitted ? .sent : .failed)
            log(submitted ? "Reprise de la veille (action d'envoi déclenchée)." : "Reprise de la veille (envoi annulé).")
            self?.detector.start()
            guard submitted, let self else { return }
            if t.readAloudShortcut?.buttons.isEmpty == false {
                self.trigger.readAloudWhenDone(t, in: window, baseline: readBaseline)
            } else if self.config.continuousConversation == true, let window {
                // Pas de lecture à voix haute (extension d'éditeur, ChatGPT) : le micro se rouvre à la fin de la réponse.
                self.trigger.whenAnswerDone(t, in: window) { [weak self] in self?.continueConversation(t, in: window) }
            }
        }
    }

    private func endPause() {
        history.removeAll()
        dictatedContent = .empty
        lastAutoSendPause = 0
        pauseTimer?.invalidate()
        pendingSend?.cancel()
        pendingSend = nil
        active = nil
        dictationWindow = nil
        recording = false
        stopping = false
        reviewUntil = nil
    }

    private func didTrigger(_ target: Target, started: Bool) {
        if started { pauseUntilConversationEnds(target) } else { Feedback.play(.failed); detector.start() }
    }

    /// Reste en pause tant qu'une application utilise le micro.
    /// Avec l'envoi vocal, VoiceWake continue d'écouter (micro partagé) pour entendre « ok envoie ».
    private func pauseUntilConversationEnds(_ target: Target, reopenedIn window: ShortcutTrigger.DictationWindow? = nil) {
        let c = config.conversation
        let started = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastActive = started
        var sawConversation = false
        let external = externalDictation(for: target)
        let natural = config.continuousConversation == true && external == nil && config.dryRun != true
        let canStop = (natural || !(config.stopPhrases ?? []).isEmpty) &&
            (external == nil || external?.stopShortcut != nil)
        let canSend = external == nil && sendEnabled
        let listening = canStop || canSend
        let mode = canSend ? "envoi vocal actif" : "arrêt vocal actif"
        log("Pause pendant la conversation\(listening ? " (\(mode))" : "").")
        Feedback.play(.micOpen)
        if listening {
            active = target
            dictationWindow = window ?? (external == nil ? ShortcutTrigger.dictationWindow(for: target) : trigger.externalDictationWindow)
            recording = true
            reviewUntil = nil
            detector.start()
        }

        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: natural ? 0.2 : 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard !self.stopping else { return }
            if natural, self.active?.id == target.id {
                if self.sendAfterSilence(target, startedAt: startedAt) { return }
                let lastSpeech = self.detector.audioActivity?.lastSpeech ?? startedAt
                if window != nil, self.dictatedContent == .empty, self.pendingSend == nil,
                   ProcessInfo.processInfo.systemUptime - max(startedAt, lastSpeech) >= (self.config.continueSilenceSeconds ?? 10) {
                    self.endSilentContinuation(target)
                    return
                }
            }
            let now = Date()
            let elapsed = now.timeIntervalSince(started)

            if listening ? MicMonitor.isInputInUseByOtherProcess() : MicMonitor.isAnyInputInUse() {
                lastActive = now
                if !sawConversation { sawConversation = true; log("Conversation en cours.") }
            }

            let idle = now.timeIntervalSince(lastActive)
            let reason: String?
            if elapsed >= c.maxPauseMinutes * 60 {
                reason = "durée maximale atteinte"
            } else if let until = self.reviewUntil {
                // Relecture après « ok arrête » : on attend « ok envoie ».
                reason = now >= until ? "pas de « ok envoie » après relecture" : nil
            } else if elapsed >= c.startGraceSeconds && idle >= c.idleSecondsBeforeResume {
                reason = sawConversation ? "conversation terminée" : "aucune conversation détectée"
            } else {
                reason = nil
            }
            guard let reason else { return }

            self.endPause()
            log("Reprise de la veille (\(reason)).")
            if listening { self.detector.reset() } else { self.detector.start() }
        }
    }

}
