import AppKit

/// Veille -> déclenchement -> pause pendant la conversation -> veille.
final class Coordinator {
    let config: Config
    let router: Router
    let detector: WakeWordDetector
    let trigger = ShortcutTrigger()
    var lastWake = Date.distantPast
    var pauseTimer: Timer?

    init(config: Config) throws {
        self.config = config
        self.router = Router(config: config)
        self.detector = try WakeWordDetector(config: config, hints: router.hints)
        detector.onText = { [weak self] text, isFinal in self?.handle(text, isFinal: isFinal) }
        detector.isIdle = { [weak self] in
            guard let self else { return true }
            return self.active == nil && !self.reader.isActive && self.currentReader() == nil
        }
        Feedback.configure(config)
        Bilan.configure(config)
        if config.interpreter?.enabled ?? true {
            if Interpreter.isAvailable { DispatchQueue.global().async { Interpreter.prewarm() } }
            else { log("Interpréteur local : \(Interpreter.unavailableReason).") }
        }
        if config.voiceFilter?.enabled == true {
            let path = VoicePrint.defaultPath(config.voiceFilter)
            let modelPath = VoicePrint.defaultModelPath(config.voiceFilter)
            if !FileManager.default.fileExists(atPath: modelPath) {
                log("Filtre de voix : modèle introuvable (\(modelPath)).")
            } else if let profile = VoicePrint.loadProfile(path) {
                VoicePrint.profileToUse = profile
                DispatchQueue.main.async { VoicePrint.loadModel(modelPath) } // premier calcul ~3 s, au démarrage
                log("Filtre de voix actif (\(config.voiceFilter?.block == true ? "blocage" : "observation")).")
            } else {
                log("Filtre de voix : aucune empreinte (voicewake voix apprends).")
            }
        }
        trigger.onReadingFinished = { [weak self] target, window in
            self?.continueConversation(target, in: window)
        }
        trigger.onReadText = { [weak self] target, window, text in
            guard let self, self.active == nil, self.pendingWake == nil, !self.reader.isActive,
                  window.isSameConversation else { return false }
            log("\(target.id) : lecture via le lecteur intégré.")
            self.readerTarget = target
            self.readerWindow = window
            self.reader.voiceName = self.config.readerVoice
            self.reader.onFinish = { [weak self] in
                log("\(target.id) : lecture terminée.")
                self?.readerWindow = nil
                self?.continueConversation(target, in: window)
            }
            self.reader.speak(text, locale: self.config.locale)
            return true
        }
    }

    /// Bundle IDs des apps et éditeurs pilotés.
    var managedBundleIDs: Set<String> {
        Set(config.targets.compactMap(\.bundleID) + (config.editors ?? []).flatMap(\.bundleIDs))
    }

    /// Prépare l'arbre d'accessibilité des apps pilotées dès qu'elles tournent : sinon, juste après
    /// un redémarrage du Mac ou de l'app, le premier « Dis Claude » ne trouve pas le bouton micro.
    func warmUpAccessibility() {
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
            self.startHintRefresh()
            self.startQuestionWatch()
            self.startBargeInWatch()
            self.startRoutineClock()
            // Diagnostic 15 s après le démarrage (le modèle vocal peut mettre un moment à se charger).
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.startupDiagnostic() }
            let names = self.config.targets.map(\.id).joined(separator: ", ")
            log("VoiceWake prêt. Cibles : \(names).")
        }
    }

    /// Cible en cours de dictée, quand l'envoi vocal est actif.
    var active: Target?
    var pendingSend: DispatchWorkItem?
    var sendEnabled: Bool { !(config.sendPhrases ?? []).isEmpty }

    func externalDictation(for target: Target) -> ExternalDictation? {
        if target.typedDictation == true {
            return ExternalDictation(shortcut: target.shortcut, useMacOSDictationMenu: nil, stopShortcut: nil, typedByVoiceWake: true)
        }
        return target.id.contains("@") ? nil : config.externalDictation
    }

    /// Dictée externe au sens strict (outil tiers) : nil pour une dictée tapée par VoiceWake, qui se comporte
    /// comme le micro intégré d'une app (arrêt, envoi vocal, fin de tour).
    func thirdPartyDictation(for target: Target) -> ExternalDictation? {
        target.typedDictation == true ? nil : externalDictation(for: target)
    }

    /// Le texte transcrit (tes paroles) n'est écrit dans le log qu'en mode debug.
    func said(_ text: String) -> String { config.debug ? " (« \(text) »)" : "" }

    func handle(_ heard: String, isFinal: Bool = false) {
        // En veille, erreurs de reconnaissance fréquentes corrigées (« lance le ski » → « lance le skill »).
        let fixed = active == nil ? SpeechFixes.apply(heard) : heard
        if pendingConfirmation != nil, handleConfirmation(fixed, isFinal: isFinal) { return }
        // VoiceWake parle (état, aide, confirmation) : ce que le micro entend est sa propre voix.
        if announcer.isSpeaking { return }
        // Pas de garde « un assistant parle » ici : Claude garde une sortie audio ouverte pendant sa dictée.
        // Relecture après « ok arrête » / « garde le brouillon » (micro coupé) : une commande de veille
        // (« lis à partir de… », « fais la lecture », « dis Claude »…) abandonne l'attente de « ok envoie ».
        if active != nil, !recording, !stopping, reviewUntil != nil,
           !router.isSendCommand(fixed), wakeKey(fixed) != nil {
            // « Où on en est ? » : on répond sans abandonner le brouillon.
            if AppCommand.match(fixed, router: router, config: config) == .status {
                announceStatus()
                return
            }
            log("Attente de « ok envoie » abandonnée : nouvelle commande.")
            endPause()
            // Pas de return : la même phrase est traitée tout de suite par la veille, ci-dessous.
        }
        if let t = active, checkWakeNameDuringDictation(fixed, t) { return }
        // En veille, le nom d'appel est facultatif : « Jarvis, monte le son » = « monte le son ».
        let named = active == nil ? afterWakeName(fixed).flatMap { $0.isEmpty ? nil : $0 } : nil
        let text = named ?? fixed
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
        // « Jarvis, <phrase libre> » sans commande reconnue : interpréteur IA (si activé).
        // Phrase libre adressée à un assistant (« Claude, tu peux me lire sa réponse ? ») ou après « Jarvis » :
        // interpréteur local (modèle d'Apple sur le Mac).
        // « Claude… » (nom seul, en attente) qui continue en demande : la demande l'emporte.
        if active == nil, config.interpreter?.enabled ?? true,
           named != nil || Interpreter.addressed(text), wakeKey(text) == nil {
            pendingWake?.cancel()
            pendingWake = nil
            return scheduleInterpret(text, isFinal: isFinal)
        }
        pendingInterpret?.cancel()
        pendingInterpret = nil
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
        if router.containsAny(text, config.readFromPhrases) || WriteCommand.request(text, config: config) != nil { wait = 6 }
        else if Universal.match(text, config: config) != nil || SkillCatalog.request(text, config: config) != nil
                    || Palette.request(text, config: config) != nil { wait = 3 }
        else if case .open? = NavCommands.match(text, target: nil, config: config) { wait = 3 }
        else if case .newSessionIn? = NavCommands.match(text, target: nil, config: config) { wait = 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    // MARK: Commandes universelles

    /// Dernière commande tapée dans une palette sans être validée : « valide » seul est accepté pendant 20 s.
    var lastPaletteAt = Date.distantPast
    var paletteOpen: Bool { Date().timeIntervalSince(lastPaletteAt) < Palette.paletteWindow }
    // MARK: « Écris … »
    // MARK: Commandes du Mac
    // MARK: Finder et Réglages Système

    enum MacCommand { case finder(FinderCommand), settings(SettingsCommand), media(MediaCommand), browser(BrowserCommand) }
    // MARK: Nom d'appel

    var pendingWakeName: DispatchWorkItem?
    var pendingInterpret: DispatchWorkItem?
    var interpreting = false
    // MARK: Diagnostic et routines à heure fixe

    var routineClock: Timer?
    var lastRoutineMinute = ""
    // MARK: Couper la parole

    /// Pendant une lecture à voix haute, ta voix (reconnue par le filtre de voix) coupe la lecture et rouvre le
    /// micro, comme on interrompt quelqu'un : pas besoin de dire « écoute ». La voix de lecture et les autres
    /// personnes ne déclenchent rien. Vérifié toutes les 0,5 s, hors fil principal.
    var bargeTimer: Timer?
    var bargeChecking = false
    var lastBargeIn = Date.distantPast
    let bargeQueue = DispatchQueue(label: "voicewake.barge-in")
    // MARK: Questions de l'assistant

    /// Carte de question visible dans l'assistant au premier plan (relue toutes les 2 s, hors dictée et lecture).
    var currentCard: (card: QuestionCard, app: NSRunningApplication)?
    var questionTimer: Timer?
    var scanningCard = false
    // MARK: Routines

    var routineWork: DispatchWorkItem?
    // MARK: Skills
    // MARK: Confirmation vocale

    var pendingConfirmation: (title: String, run: () -> Void, expires: Date)?
    var confirmWork: DispatchWorkItem?
    // MARK: Indices de reconnaissance

    /// Au plus ce nombre d'indices (au-delà, le moteur d'Apple en tire moins de profit).
    static let maxHints = 100
    var hintTimer: Timer?

    /// Met à jour les indices toutes les 60 s : noms de projets et de conversations de l'app au premier plan
    /// (« ouvre VoxTV » est alors bien mieux compris), puis phrases d'activation et commandes.
    func startHintRefresh() {
        _ = SystemCommands.installedApps() // liste des apps prête avant la première commande
        refreshHints()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshHints() }
        RunLoop.main.add(timer, forMode: .common)
        hintTimer = timer
    }

    func refreshHints() {
        // Pas pendant une dictée ou une lecture : la lecture de l'arbre d'accessibilité prend un instant.
        guard active == nil, !reader.isActive else { return }
        var names: [String] = []
        if let t = router.frontmostTarget(), let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) {
            let entries = AXButtonPresser.sidebarEntries(in: app)
            names += entries.filter { $0.kind == .project }.map(\.title)
            names += AXButtonPresser.menuBarItems(under: NavCommands.conversationMenus, in: app).map(\.title)
            // Skills personnels : « lance le skill <nom> » mieux compris.
            names += SkillCatalog.entries(for: t).filter { $0.source == .personal }.prefix(15)
                .compactMap { $0.aliases.first?.joined(separator: " ") }.map { "lance le skill \($0)" }
        }
        let hints = Self.hints(base: router.hints, names: names, config: config, target: router.frontmostTarget())
        if hints != detector.hints {
            detector.hints = hints
            if config.debug { log("Indices de reconnaissance : \(hints.count).") }
        }
    }

    /// Ordre de priorité : phrases d'activation, « ouvre <projet> » et noms, puis commandes. Sans doublon.
    static func hints(base: [String], names: [String], config: Config, target: Target?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let key = normalize(s)
            guard !key.isEmpty, out.count < maxHints, seen.insert(key).inserted else { return }
            out.append(s)
        }
        base.forEach(add)
        if config.jarvisEnabled { (config.wakeNames ?? WakeName.defaults).forEach(add) }
        for n in names.prefix(30) where n.count <= 60 { add("ouvre \(n)"); add(n) }
        let commands = target.map(NavCommands.commands(for:)) ?? []
        (commands.flatMap(\.phrases) + AppCommand.allCases.flatMap { $0.phrases(config) }
            + (config.readPausePhrases ?? []) + (config.readResumePhrases ?? []) + (config.readFromPhrases ?? [])
            + (config.sendPhrases ?? []) + (config.routines ?? []).flatMap { $0.phrases ?? [] }).forEach(add)
        return out
    }

    /// « Quelles commandes ? » : ce qu'on peut dire dans l'app au premier plan, à voix haute (sans jamais
    /// commencer une phrase par une commande ; tout ce que le micro entend pendant l'annonce est ignoré).
    func announceHelp() {
        guard !announcer.isSpeaking else { return }
        let app = Universal.frontApp()
        let allowed = app?.bundleIdentifier.map { Universal.allowedApps(config).contains($0) } ?? false
        let target = router.frontmostTarget().flatMap { t in
            ShortcutTrigger.runningApp(for: t).map { AXButtonPresser.isFrontmost($0) ? t : nil } ?? nil
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var parts: [String] = []
            // Nom de l'app : jamais une phrase de commande à voix haute.
            let raw = app?.localizedName ?? ""
            let risky = raw.isEmpty || Universal.match(raw, config: self.config) != nil || Palette.request(raw, config: self.config) != nil
                || SkillCatalog.request(raw, config: self.config) != nil || self.wakeKey(raw) != nil
            let name = risky ? "cette application" : raw
            if let app, allowed {
                let menus = AXButtonPresser.allMenuBarItems(in: app).count
                let buttons = AXButtonPresser.visibleButtons(in: app).count
                parts.append("Dans \(name), on peut choisir l'une des \(menus) options de menu en disant le mot menu puis son nom, ou l'un des \(buttons) boutons visibles avec clique sur.")
                if let bid = app.bundleIdentifier, Palette.shortcut(for: bid, config: self.config) != nil {
                    parts.append("La palette de commandes s'utilise en disant palette puis la commande.")
                }
            } else {
                parts.append("\(name) n'est pas une application pilotée.")
            }
            if let t = target {
                let skills = SkillCatalog.entries(for: t).count
                if skills > 0 { parts.append("\(skills) skills et commandes slash se lancent avec lance le skill puis leur nom.") }
                if let assistant = ShortcutTrigger.runningApp(for: t), !AXButtonPresser.sidebarEntries(in: assistant).isEmpty {
                    parts.append("Un projet de la barre latérale s'ouvre avec ouvre puis son nom.")
                }
            }
            parts.append("La liste complète est dans le fichier lisez-moi.")
            let message = parts.joined(separator: " ")
            DispatchQueue.main.async {
                log("Aide vocale : \(name).")
                self.speak(message)
            }
        }
    }

    let announcer = Announcer()
    var speakGeneration = 0

    /// Annonce parlée : le micro est coupé pendant toute l'annonce (VoiceWake ne peut pas s'entendre lui-même),
    /// puis relancé avec une transcription vide.
    func speak(_ message: String, then: (() -> Void)? = nil) {
        detector.stop()
        // Une annonce qui en remplace une autre : seule la dernière rend le micro, sinon VoiceWake se remettrait
        // à écouter pendant qu'il parle encore.
        speakGeneration += 1
        let mine = speakGeneration
        ElevenLabs.stopAnnouncement()
        let finish = { [weak self] in
            guard let self, mine == self.speakGeneration else { return }
            self.speakGeneration += 1 // une seule fois : le garde-fou ci-dessous ne rend pas le micro deux fois
            self.announcer.external = false
            self.detector.start()
            then?()
        }
        // Voix ElevenLabs si elle est configurée ; la voix du Mac seulement en secours (pas de clé, panne, hors ligne).
        guard config.elevenLabs?.enabled == true, config.elevenLabs?.announcements ?? true else {
            announcer.external = false
            return announcer.say(message, locale: config.locale, voice: config.readerVoice, onFinish: finish)
        }
        announcer.external = true
        // Garde-fou : si l'annonce ne se termine jamais (lecture audio bloquée), le micro est rendu quand même.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, mine == self.speakGeneration else { return }
            log("Annonce ElevenLabs sans fin après 60 s : micro rendu.")
            ElevenLabs.stopAnnouncement()
            finish()
        }
        ElevenLabs.say(message, config: config) { [weak self] said in
            guard let self, mine == self.speakGeneration else { return }
            if said { return finish() }
            self.announcer.external = false
            self.announcer.say(message, locale: self.config.locale, voice: self.config.readerVoice, onFinish: finish)
        }
    }
    var lastStatus = Date.distantPast

    /// « Où on en est ? » : dit l'état de VoiceWake avec une voix du Mac. Le texte ne contient aucune
    /// phrase de commande, pour que VoiceWake ne réagisse pas à sa propre annonce.
    func announceStatus() {
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
        speak(message)
    }

    let reader = Reader()
    let follower = ReadingFollower()
    var detectedReader: (target: Target?, at: Date) = (nil, .distantPast)

    /// L'assistant qui lit à voix haute : lecture lancée par VoiceWake, sinon lecture lancée à la main
    /// (bouton de pause visible dans l'app au premier plan ; vérifié au plus toutes les 2 s).
    func currentReader() -> Target? {
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
    var readerTarget: Target?
    var readerWindow: ShortcutTrigger.DictationWindow?

    /// « Lis à partir de … » : cherche le passage dans le texte affiché par l'assistant et le lit depuis là.
    func readFrom(_ query: [String]) {
        guard let target = trigger.pausedTarget() ?? trigger.readingTarget() ?? router.frontmostTarget(),
              let app = ShortcutTrigger.runningApp(for: target) else { Feedback.play(.failed); return log("Lecture : aucun assistant ouvert.") }
        let tokens = PassageFinder.tokens(in: app, target: target)
        let start = PassageFinder.find(query, in: tokens)
        guard let start else { Feedback.play(.failed); Bilan.record(.read, config.debug ? query.joined(separator: " ") : "passage introuvable"); return log("Lecture : passage introuvable\(said(query.joined(separator: " "))).") }
        if trigger.readingTarget() != nil { trigger.pauseReading(target) }
        readerTarget = target
        readerWindow = nil
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
    func spokenByOwnReader(_ text: String) -> Bool {
        if voiceVerified { return false } // voix reconnue par le filtre : c'est l'utilisateur
        let phrases = (config.readPausePhrases ?? []) + (config.interruptPhrases ?? []) + (config.readResumePhrases ?? [])
            + ReaderNav.allPhrases(config)
        return VoiceFilter.spokenByReader(text, phrases: phrases, spokenNow: reader.spokenNow, router: router)
    }

    var insistence = Insistence()

    /// Commande attribuée à la voix de lecture mais redite par l'utilisateur (voir `Insistence`).
    func insisted(_ text: String, phrases: [String]?, spokenNow: String) -> Bool {
        guard let phrase = router.lastMatch(text, phrases)?.phrase else { return false }
        return insistence.accept(phrase, spokenNow: spokenNow)
    }

    var readCommandPhrases: [String] { (config.readPausePhrases ?? []) + (config.interruptPhrases ?? []) }

    /// « Stop Claude » passe du premier coup, sauf si la réponse affichée contient elle-même la phrase.
    func strongInterrupt(_ text: String, _ reader: Target) -> Bool {
        guard let app = ShortcutTrigger.runningApp(for: reader) else { return false }
        return router.isStrongInterrupt(text, notIn: AXButtonPresser.windowTexts(in: app).joined(separator: " "))
    }

    func spokenByReader(_ text: String, _ reader: Target) -> Bool {
        if voiceVerified { return false } // voix reconnue par le filtre : c'est l'utilisateur
        let phrases = (config.readPausePhrases ?? []) + (config.interruptPhrases ?? [])
        guard let hit = router.lastMatch(text, phrases), let app = ShortcutTrigger.runningApp(for: reader) else { return false }
        let shown = " " + normalize(AXButtonPresser.windowTexts(in: app).joined(separator: " ")) + " "
        guard shown.contains(" " + hit.phrase + " ") else { return false }
        guard let previous = hit.previous else { return true }
        return shown.contains(" " + previous + " " + hit.phrase + " ")
    }

    var pendingWake: DispatchWorkItem?

    // MARK: Filtre « ma voix uniquement »

    /// La commande en cours vient d'une voix reconnue par le filtre (mode blocage) : les protections contre la voix
    /// de lecture, fondées sur le texte affiché, ne s'appliquent pas.
    var voiceVerified = false
    var latestWakeText = ""

    var dictatedContent = DictatedContent.empty
    var lastAutoSendPause: TimeInterval = 0

    /// Micro de l'app encore ouvert (false après « ok arrête »).
    var recording = false
    var stopping = false
    var dictationWindow: ShortcutTrigger.DictationWindow?
    /// Après « ok arrête » : attente de « ok envoie » jusqu'à cette date.
    var reviewUntil: Date?

    /// Phrase en fin de transcription, puis silence :
    ///   « ok envoie » → coupe le micro de l'app si besoin et envoie ;
    ///   « ok arrête » → coupe seulement le micro, pour relire.
    /// Transcriptions récentes (date, texte normalisé), pour mesurer la pause avant « ok envoie ».
    var history: [(at: Date, text: String)] = []
    /// Dictée tapée par VoiceWake : segments définitifs et segment en cours de la transcription.
    var typedDone: [String] = []
    var typedCurrent = ""

    /// Dernière transcription entendue pendant la dictée (pour juger si la phrase est finie).
    var lastDictationText = ""
}
