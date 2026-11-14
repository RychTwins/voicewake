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

    /// Le texte transcrit (tes paroles) n'est écrit dans le log qu'en mode debug.
    private func said(_ text: String) -> String { config.debug ? " (« \(text) »)" : "" }

    private func handle(_ text: String, isFinal: Bool = false) {
        // Pas de garde « un assistant parle » ici : Claude garde une sortie audio ouverte pendant sa dictée.
        if let t = active {
            if let other = switchTarget(text, from: t) { switchDictation(from: t, to: other); return }
            checkSend(text, t)
            return
        }
        // Lecture à voix haute d'une app en cours : on la suit à l'oreille pour afficher le mot en cours.
        if config.showReadingProgress ?? false, let r = trigger.readingTarget(),
           let app = ShortcutTrigger.runningApp(for: r) {
            if config.debug, follower.onProgress == nil { follower.onProgress = { log("Suivi de lecture : mot \($0) sur \($1).") } }
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
        let wait = router.containsAny(text, config.readFromPhrases) ? 6 : (config.wakeMaxWaitSeconds ?? 1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private let reader = Reader()
    private let follower = ReadingFollower()
    private var readerTarget: Target?

    /// « Lis à partir de … » : cherche le passage dans le texte affiché par l'assistant et le lit depuis là.
    private func readFrom(_ query: [String]) {
        guard let target = trigger.pausedTarget() ?? trigger.readingTarget() ?? router.frontmostTarget(),
              let app = ShortcutTrigger.runningApp(for: target) else { return log("Lecture : aucun assistant ouvert.") }
        let tokens = AXButtonPresser.windowTexts(in: app).joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let start = PassageFinder.find(query, in: tokens)
        guard let start else { return log("Lecture : passage introuvable\(said(query.joined(separator: " "))).") }
        if trigger.readingTarget() != nil { trigger.pauseReading(target) }
        readerTarget = target
        reader.voiceName = config.readerVoice
        reader.onFinish = { log("Lecteur intégré : lecture terminée.") }
        let passage = tokens[start..<min(tokens.count, start + 500)].joined(separator: " ")
        log("Lecteur intégré → \(target.id), à partir du mot \(start) sur \(tokens.count)\(said(tokens[start..<min(tokens.count, start + 4)].joined(separator: " "))).")
        reader.speak(passage, locale: config.locale)
    }

    /// Le micro entend aussi le lecteur intégré : une commande présente dans son texte, précédée du même mot, est ignorée.
    private func spokenByOwnReader(_ text: String) -> Bool {
        let phrases = (config.readPausePhrases ?? []) + (config.interruptPhrases ?? []) + (config.readResumePhrases ?? [])
        guard let hit = router.lastMatch(text, phrases) else { return false }
        let spoken = " " + normalize(reader.spokenNow) + " "
        guard spoken.contains(" " + hit.phrase + " ") else { return false }
        guard let previous = hit.previous else { return true }
        return spoken.contains(" " + previous + " " + hit.phrase + " ")
    }

    /// La commande entendue vient-elle de la voix de lecture ? Oui si le texte affiché par l'app
    /// contient cette phrase précédée du même mot (ou si on n'a pas entendu de mot avant).
    private var lastSuppressedAt = Date.distantPast

    /// Une commande ignorée (attribuée à la voix de lecture) passe si elle est redite dans les 6 s :
    /// l'utilisateur ne peut jamais être bloqué par le contenu lu.
    private func insisted() -> Bool {
        let repeated = Date().timeIntervalSince(lastSuppressedAt) < 6
        lastSuppressedAt = repeated ? .distantPast : Date()
        return repeated
    }

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
        return router.route(text)?.id
    }

    private func handleWake(_ text: String) {
        let interrupt = router.containsInterruptPhrase(text)
        let pauseRead = router.containsAny(text, config.readPausePhrases)
        let resumeRead = router.containsAny(text, config.readResumePhrases)
        let routed = router.route(text)
        if let query = router.readFromQuery(text) {
            detector.reset()
            // Le lecteur intégré ne doit pas se relancer lui-même en lisant « à partir de … ».
            if reader.isActive, !reader.isPaused,
               router.containsAny(reader.spokenNow, config.readFromPhrases) {
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
            if spokenByOwnReader(text), !insisted() { return log("Commande ignorée : prononcée par le lecteur intégré.") }
            if interrupt, let t = readerTarget {
                reader.stop()
                lastWake = Date()
                log("Écoute → \(t.id) (micro).")
                detector.stop()
                trigger.fire(t, external: config.externalDictation) { [weak self] started in self?.didTrigger(t, started: started) }
            } else if pauseRead {
                reader.pause(); log("Lecteur intégré : pause.")
            } else if resumeRead {
                reader.resume(); log("Lecteur intégré : reprise.")
            }
            return
        }
        guard interrupt || pauseRead || resumeRead || routed != nil else { return }
        // Lecture en pause : « reprends la lecture » la relance, « écoute » ouvre le micro.
        if trigger.readingTarget() == nil, let paused = trigger.pausedTarget(), resumeRead || interrupt {
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { detector.reset(); return }
            lastWake = Date()
            detector.reset()
            if resumeRead {
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
        if let reader = trigger.readingTarget() {
            if (pauseRead || interrupt), spokenByReader(text, reader), !insisted() {
                log("Commande ignorée : prononcée par la voix de lecture de \(reader.id).")
                detector.reset()
                return
            }
            if pauseRead && !interrupt {
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
        let external = target.id.contains("@") ? nil : config.externalDictation
        trigger.fire(target, external: external) { [weak self] started in
            self?.didTrigger(target, started: started)
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

    /// Pause (s) entre la fin du texte qui précède la commande et le premier mot de la commande.
    /// nil si on ne peut pas la mesurer (début de transcription, texte corrigé par le moteur).
    private func pauseBeforeCommand(_ text: String) -> Double? {
        guard let body = router.bodyBeforeCommand(text), !body.isEmpty,
              let i = history.lastIndex(where: { $0.text == body }), i + 1 < history.count else { return nil }
        return history[i + 1].at.timeIntervalSince(history[i].at)
    }

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
        let n = normalize(text)
        let candidate = spokenAfterPause(n, minPause: config.sendPauseBeforeSeconds ?? 0.6) ?? n
        guard candidate.split(separator: " ").count <= 4, let routed = router.route(candidate) else { return nil }
        let next = router.inEditor(routed) ?? routed
        return next.id == current.id ? nil : next
    }

    /// Arrête la dictée en cours (sans envoyer) puis ouvre le micro de l'autre assistant.
    private func switchDictation(from current: Target, to next: Target) {
        guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
        lastWake = Date()
        log("Changement d'assistant : \(current.id) → \(next.id).")
        let window = dictationWindow
        let wasRecording = recording
        endPause()
        detector.stop()
        let open = { [weak self] in
            guard let self else { return }
            self.trigger.fire(next, external: self.config.externalDictation) { [weak self] started in
                self?.didTrigger(next, started: started)
            }
        }
        guard wasRecording, let window else { return open() }
        trigger.stopDictation(current, in: window, external: config.externalDictation) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open() }
        }
    }

    private func isFlexibleSend(_ text: String) -> Bool {
        let n = normalize(text)
        let candidate = spokenAfterPause(n, minPause: config.sendPauseBeforeSeconds ?? 0.6) ?? n
        return router.isShortSendCommand(candidate)
    }

    private func checkSend(_ text: String, _ t: Target) {
        guard !stopping else { return }
        pendingSend?.cancel()
        history.append((Date(), normalize(text)))
        if history.count > 60 { history.removeFirst(history.count - 60) }
        let external = config.externalDictation
        let send = external == nil && (router.endsWithSendPhrase(text) || isFlexibleSend(text))
        let stop = !send && recording && router.endsWithStopPhrase(text)
        guard send || stop else { return }
        // « ok envoie » cité en pleine phrase (sans pause avant) : ignoré.
        let minPause = config.sendPauseBeforeSeconds ?? 0
        if minPause > 0, let pause = pauseBeforeCommand(text), pause < minPause {
            if config.debug { log("Commande ignorée : pas de pause avant (\(String(format: "%.2f", pause)) s).") }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active?.id == t.id else { return }
            if stop {
                log("Phrase d'arrêt détectée → \(t.id)\(self.said(text)).")
                self.stopping = true
                self.trigger.stopDictation(t, in: self.dictationWindow, external: external) { [weak self] stopped in
                    guard let self, self.active?.id == t.id else { return }
                    self.stopping = false
                    if stopped {
                        if external != nil {
                            self.endPause()
                            log("Dictée externe arrêtée. Reprise de la veille.")
                            self.detector.reset()
                            return
                        }
                        self.recording = false
                        self.reviewUntil = Date().addingTimeInterval(self.config.reviewSeconds ?? 180)
                        log("Dictée arrêtée. En attente de « ok envoie ».")
                    } else {
                        log("Arrêt de la dictée non effectué.")
                    }
                    self.detector.reset()
                }
                return
            }
            log("Phrase d'envoi détectée → \(t.id)\(self.said(text)).")
            let stopFirst = self.recording
            let window = self.dictationWindow
            self.endPause()
            self.detector.stop()
            self.trigger.submit(t, in: window, stopFirst: stopFirst) { [weak self] submitted in
                log(submitted ? "Reprise de la veille (action d'envoi déclenchée)." : "Reprise de la veille (envoi annulé).")
                self?.detector.start()
                if submitted { self?.trigger.readAloudWhenDone(t) }
            }
        }
        pendingSend = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (config.sendSilenceSeconds ?? 1.2), execute: work)
    }

    private func endPause() {
        history.removeAll()
        pauseTimer?.invalidate()
        pendingSend?.cancel()
        active = nil
        dictationWindow = nil
        recording = false
        stopping = false
        reviewUntil = nil
    }

    private func didTrigger(_ target: Target, started: Bool) {
        if started { pauseUntilConversationEnds(target) } else { detector.start() }
    }

    /// Reste en pause tant qu'une application utilise le micro.
    /// Avec l'envoi vocal, VoiceWake continue d'écouter (micro partagé) pour entendre « ok envoie ».
    private func pauseUntilConversationEnds(_ target: Target) {
        let c = config.conversation
        let started = Date()
        var lastActive = started
        var sawConversation = false
        let external = config.externalDictation
        let listening = external == nil ? sendEnabled : external?.stopShortcut != nil && !(config.stopPhrases ?? []).isEmpty
        let mode = external == nil ? "envoi vocal actif" : "arrêt vocal actif"
        log("Pause pendant la conversation\(listening ? " (\(mode))" : "").")
        if listening {
            active = target
            dictationWindow = external == nil ? ShortcutTrigger.dictationWindow(for: target) : trigger.externalDictationWindow
            recording = true
            reviewUntil = nil
            detector.start()
        }

        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
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
