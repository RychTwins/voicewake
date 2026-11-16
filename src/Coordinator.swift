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
        Bilan.configure(config)
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
            self.startHintRefresh()
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
        if pendingConfirmation != nil, handleConfirmation(text, isFinal: isFinal) { return }
        // VoiceWake parle (état, aide, confirmation) : ce que le micro entend est sa propre voix.
        if announcer.isSpeaking { return }
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
        if let t = active, checkWakeNameDuringDictation(text, t) { return }
        // En veille, le nom d'appel est facultatif : « Jarvis, monte le son » = « monte le son ».
        let text = active == nil ? (afterWakeName(text).flatMap { $0.isEmpty ? nil : $0 } ?? text) : text
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
        if router.containsAny(text, config.readFromPhrases) || WriteCommand.request(text, config: config) != nil { wait = 6 }
        else if Universal.match(text, config: config) != nil || SkillCatalog.request(text, config: config) != nil
                    || Palette.request(text, config: config) != nil { wait = 3 }
        else if case .open? = NavCommands.match(text, target: nil, config: config) { wait = 3 }
        else if case .newSessionIn? = NavCommands.match(text, target: nil, config: config) { wait = 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    // MARK: Commandes universelles

    /// Libellé lu dans l'app : journalisé seulement en mode debug (un bouton peut porter un titre de conversation).
    private func label(_ title: String) -> String { config.debug ? " « \(title) »" : "" }

    private func runUniversal(_ kind: Universal.Kind, _ query: [String], in app: NSRunningApplication) {
        let name = app.localizedName ?? "app"
        DispatchQueue.global().async { [weak self] in
            let action = Universal.find(kind, query, in: app)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let action else {
                    Feedback.play(.failed)
                    Bilan.record(.universal, (kind == .menu ? "menu " : "clique sur ") + (self.config.debug ? query.joined(separator: " ") : "rien ne correspond"))
                    return log("Commande universelle → \(name) : rien ne correspond\(self.config.debug ? " à « \(query.joined(separator: " ")) »" : "").")
                }
                if self.config.dryRun == true { return log("[essai] → \(kind == .menu ? "menu" : "bouton")\(self.label(action.title)) dans \(name)") }
                if action.dangerous { return self.askConfirmation(action, in: name) }
                self.performUniversal(action, in: name)
            }
        }
    }

    /// Dernière commande tapée dans une palette sans être validée : « valide » seul est accepté pendant 20 s.
    private var lastPaletteAt = Date.distantPast
    private var paletteOpen: Bool { Date().timeIntervalSince(lastPaletteAt) < Palette.paletteWindow }

    // MARK: « Écris … »

    private func writeText(_ typed: String) {
        guard !typed.isEmpty else { Feedback.play(.failed); return log("Écris : texte vide.") }
        guard let app = Universal.frontApp(), let bid = app.bundleIdentifier, Universal.allowedApps(config).contains(bid) else {
            Feedback.play(.failed)
            Bilan.record(.write, "app non autorisée")
            return log("Écris : app au premier plan non autorisée (ajouter son identifiant à universalApps).")
        }
        let name = app.localizedName ?? bid
        if config.dryRun == true { return log("[essai] → écris dans \(name)\(said(typed))") }
        DispatchQueue.global().async { [weak self] in
            // Seulement le champ qui a déjà le focus : le texte ne part jamais dans un autre champ.
            var ok = false
            if let field = AXButtonPresser.focusedTextField(in: app) {
                ok = TextTyper.type(typed, to: app.processIdentifier, while: {
                    AXButtonPresser.isFrontmost(app) && AXButtonPresser.focusedTextField(in: app).map { CFEqual($0, field) } == true
                })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                Feedback.play(ok ? .understood : .failed)
                if !ok { Bilan.record(.write, "aucun champ de saisie actif") }
                log("Écris → \(name) : \(ok ? "\(typed.count) caractères tapés" : "aucun champ de saisie actif")\(self.said(typed)).")
            }
        }
    }

    // MARK: Commandes du Mac

    private func systemCommand(_ text: String) -> SystemCommand? {
        guard config.systemCommands ?? true else { return nil }
        return SystemCommands.match(text, apps: SystemCommands.installedApps(), running: SystemCommands.runningApps() + SystemCommands.targetApps(config),
                                    front: Universal.frontApp()?.bundleIdentifier)
    }

    private func runSystem(_ sys: SystemCommand) {
        let what: String
        switch sys {
        case let .launch(p), let .activate(p): what = "ouvrir \(SystemCommands.appName(p))"
        case let .quit(id): what = "quitter \(SystemCommands.appName(id))"
        case let .hide(id): what = "cacher \(SystemCommands.appName(id))"
        default: what = "\(sys)"
        }
        if config.dryRun == true { return log("[essai] → Mac : \(what)") }
        let run = {
            let ok = SystemCommands.perform(sys)
            Feedback.play(ok ? .understood : .failed)
            if !ok { Bilan.record(.system, "\(sys)".split(separator: "(").first.map(String.init) ?? "mac") }
            log("Mac : \(what) \(ok ? "fait" : "impossible").")
        }
        if sys.dangerous {
            log("Confirmation demandée → Mac : \(what).")
            return askConfirmation(what, run: run)
        }
        run()
    }

    // MARK: Finder et Réglages Système

    private enum MacCommand { case finder(FinderCommand), settings(SettingsCommand) }

    private func macCommand(_ text: String) -> MacCommand? {
        guard config.systemCommands ?? true else { return nil }
        if let s = SettingsCommands.match(text) { return .settings(s) }
        guard let f = FinderCommands.match(text) else { return nil }
        // Sélection du Finder : seulement Finder au premier plan (« supprime » ailleurs ne vise jamais un fichier).
        if f.needsFinderFront, Universal.frontApp()?.bundleIdentifier != "com.apple.finder" { return nil }
        return .finder(f)
    }

    private func runMac(_ mac: MacCommand) {
        let title: String, dangerous: Bool
        switch mac {
        case let .finder(f): (title, dangerous) = (f.title, f.dangerous)
        case let .settings(c): (title, dangerous) = (c.title, c.dangerous)
        }
        if config.dryRun == true { return log("[essai] → \(title)") }
        let config = self.config
        let run = { [weak self] in
            DispatchQueue.global().async {
                let result: (ok: Bool, detail: String)
                switch mac {
                case let .finder(f): result = FinderCommands.perform(f, config: config)
                case let .settings(c): let ok = SettingsCommands.perform(c); result = (ok, ok ? "fait" : "impossible")
                }
                DispatchQueue.main.async {
                    Feedback.play(result.ok ? .understood : .failed)
                    if !result.ok { Bilan.record(.system, "\(title) \(result.detail)") }
                    log("Mac : \(title) → \(result.detail).")
                    _ = self
                }
            }
        }
        if dangerous {
            log("Confirmation demandée → \(title).")
            return askConfirmation(title, run: run)
        }
        run()
    }

    // MARK: Nom d'appel

    private var pendingWakeName: DispatchWorkItem?

    private func afterWakeName(_ text: String) -> String? {
        WakeName.command(after: text, names: config.wakeNames ?? WakeName.defaults)
    }

    /// Pendant une dictée : « Jarvis, <commande> » coupe le micro puis exécute la commande (stable 1,5 s).
    private func checkWakeNameDuringDictation(_ text: String, _ t: Target) -> Bool {
        guard recording, !stopping, let command = afterWakeName(text), wakeKey(command) != nil else {
            pendingWakeName?.cancel() // la phrase a continué : ce n'était pas (ou plus) une commande
            pendingWakeName = nil
            return false
        }
        pendingWakeName?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active?.id == t.id, self.recording, !self.stopping else { return }
            self.pendingWakeName = nil
            self.pendingSend?.cancel()
            self.stopping = true
            log("Nom d'appel pendant la dictée → \(t.id) : micro coupé, commande exécutée.")
            self.trigger.stopDictation(t, in: self.dictationWindow, external: self.externalDictation(for: t)) { [weak self] _ in
                guard let self else { return }
                self.stopping = false
                self.endPause()
                self.detector.reset()
                self.lastWake = .distantPast
                self.handleWake(command)
            }
        }
        pendingWakeName = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        return true
    }

    // MARK: Routines

    private var routineWork: DispatchWorkItem?

    /// Exécute l'étape `i` comme une phrase dite, puis la suivante après le délai de la routine. Arrêt si une
    /// dictée s'ouvre, une confirmation est demandée, une lecture commence ou une étape n'est pas reconnue.
    private func runRoutine(_ r: Routine, step i: Int) {
        routineWork = nil
        let steps = Array(r.steps.prefix(Routines.maxSteps))
        let name = Routines.label(r)
        guard i < steps.count else { return log("Routine « \(name) » terminée.") }
        // VoiceWake parle (« où on en est ? ») : on attend la fin de l'annonce.
        if announcer.isSpeaking { return scheduleRoutine(r, step: i, after: 0.5) }
        if i > 0, active != nil || pendingConfirmation != nil || reader.isActive || currentReader() != nil {
            Bilan.record(.routine, "routine \(name) étape \(i + 1)")
            return log("Routine « \(name) » arrêtée avant l'étape \(i + 1) : dictée, confirmation ou lecture en cours.")
        }
        let step = steps[i]
        guard Routines.match(step, config: config) == nil, wakeKey(step) != nil else {
            Feedback.play(.failed)
            Bilan.record(.routine, "routine \(name) étape \(i + 1)")
            return log("Routine « \(name) » : étape \(i + 1) non reconnue, arrêt\(config.debug ? " (« \(step) »)" : "").")
        }
        if config.debug { log("Routine « \(name) » : étape \(i + 1) (« \(step) »).") }
        lastWake = .distantPast // pas de délai entre deux commandes pour les étapes d'une routine
        handleWake(step)
        scheduleRoutine(r, step: i + 1, after: Routines.delay(r))
    }

    private func scheduleRoutine(_ r: Routine, step i: Int, after delay: Double) {
        let work = DispatchWorkItem { [weak self] in self?.runRoutine(r, step: i) }
        routineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Skills

    /// Tape « /skill arguments » dans la zone de saisie de l'assistant au premier plan, puis attend « ok envoie »
    /// (comme après « garde le brouillon »). « … et envoie » à la fin : envoi immédiat.
    private func runSkill(_ query: [String], said text: String) {
        guard let t = router.frontmostTarget(), let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) else {
            Feedback.play(.failed); Bilan.record(.skill, "aucun assistant au premier plan"); return log("Skill : aucun assistant au premier plan.")
        }
        var q = query
        let sendNow = q.count >= 2 && ["envoie", "envoyer"].contains(q.last!) && ["et", "puis"].contains(q[q.count - 2])
        if sendNow { q.removeLast(2) }
        DispatchQueue.global().async { [weak self] in
            let entries = SkillCatalog.entries(for: t)
            let hit = SkillCatalog.match(q, in: entries)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let hit else {
                    Feedback.play(.failed)
                    Bilan.record(.skill, self.config.debug ? q.joined(separator: " ") : "aucun skill ne correspond")
                    return log("Skill → \(t.id) : aucun skill ne correspond (\(entries.count) connus)\(self.config.debug ? " à « \(q.joined(separator: " ")) »" : "").")
                }
                // Arguments : texte d'origine après la phrase et le nom du skill.
                let phraseWords = normalize(text).split(separator: " ").count - query.count
                let args = SkillCatalog.originalSlice(text, skippingWords: phraseWords + hit.consumed, droppingLastWords: sendNow ? 2 : 0)
                let typed = args.isEmpty ? hit.entry.text + " " : hit.entry.text + " " + args
                if self.config.dryRun == true { return log("[essai] → skill \(hit.entry.text) dans \(t.id)") }
                self.typeSkill(typed, skill: hit.entry.text, target: t, app: app, sendNow: sendNow)
            }
        }
    }

    private func typeSkill(_ typed: String, skill: String, target t: Target, app: NSRunningApplication, sendNow: Bool) {
        DispatchQueue.global().async { [weak self] in
            var ok = false
            // Seulement si le champ visé a bien reçu le focus : le texte ne part jamais ailleurs.
            if let field = AXButtonPresser.composerField(in: app), AXButtonPresser.focusVerified(field, in: app) {
                ok = TextTyper.type(typed, to: app.processIdentifier, while: { AXButtonPresser.isFrontmost(app) })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else {
                    Feedback.play(.failed)
                    Bilan.record(.skill, "zone de saisie introuvable")
                    return log("Skill → \(t.id) : zone de saisie introuvable ou app passée en arrière-plan.")
                }
                Feedback.play(.understood)
                log("Skill → \(t.id) : \(skill) tapé\(sendNow ? ", envoi" : ", en attente de « ok envoie »").")
                // Envoi immédiat seulement si l'envoi vocal est activé (sinon : texte laissé dans la zone de saisie).
                if sendNow, self.sendEnabled, self.config.dryRun != true { self.submitNow(t) } else { self.holdForSend(t) }
            }
        }
    }

    /// Texte prêt dans la zone de saisie : « ok envoie » l'envoie (même attente qu'après « garde le brouillon »).
    private func holdForSend(_ t: Target) {
        guard config.dryRun != true, sendEnabled else { return }
        pauseTimer?.invalidate()
        active = t
        dictationWindow = ShortcutTrigger.dictationWindow(for: t)
        recording = false
        stopping = false
        dictatedContent = .held
        let until = Date().addingTimeInterval(config.reviewSeconds ?? 180)
        reviewUntil = until
        detector.reset()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.active?.id == t.id, self.reviewUntil != nil, !self.recording else { timer.invalidate(); return }
            if Date() >= until {
                self.endPause()
                log("Reprise de la veille (pas de « ok envoie » après le skill).")
                self.detector.reset()
            }
        }
    }

    // MARK: Confirmation vocale

    private var pendingConfirmation: (title: String, run: () -> Void, expires: Date)?
    private var confirmWork: DispatchWorkItem?

    /// Action sensible : « Confirmer … ? », puis « oui » ou « non » dit seul dans les 8 s.
    private func askConfirmation(_ action: Universal.Action, in name: String) {
        log("Confirmation demandée → \(name)\(label(action.title)).")
        askConfirmation(action.title) { [weak self] in self?.performUniversal(action, in: name, confirmed: true) }
    }

    /// Demande « Confirmer … ? » et n'exécute `run` que sur « je confirme » dit seul.
    private func askConfirmation(_ title: String, run: @escaping () -> Void) {
        pendingConfirmation = (title, run, Date().addingTimeInterval(Universal.confirmSeconds + 3))
        speak(Universal.confirmationPrompt(title, config: config)) { [weak self] in
            self?.pendingConfirmation?.expires = Date().addingTimeInterval(Universal.confirmSeconds)
        }
    }

    /// true si la transcription a été prise comme réponse (ou ignorée pendant l'annonce).
    private func handleConfirmation(_ text: String, isFinal: Bool) -> Bool {
        guard let pending = pendingConfirmation else { return false }
        if Date() > pending.expires {
            pendingConfirmation = nil
            confirmWork?.cancel()
            Feedback.play(.micClosed)
            log("Confirmation expirée : rien n'a été fait.")
            return false
        }
        if announcer.isSpeaking { return true } // c'est la question qu'on entend
        confirmWork?.cancel()
        guard let answer = Universal.answer(text, config: config) else { return false }
        // Pendant une lecture à voix haute, la réponse pourrait venir de la voix : jamais de confirmation.
        if answer == .confirm, reader.isActive || currentReader() != nil {
            Feedback.play(.ignored)
            log("Confirmation ignorée : lecture à voix haute en cours.")
            return true
        }
        // Confirmer : résultat définitif du moteur seulement. Annuler : dès que la réponse est stable (0,9 s).
        if answer == .confirm, !isFinal { return true }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pendingConfirmation else { return }
            self.pendingConfirmation = nil
            self.detector.reset()
            switch answer {
            case .confirm:
                log("Confirmé.")
                p.run()
            case .cancel:
                Feedback.play(.micClosed)
                log("Annulé : rien n'a été fait.")
            }
        }
        confirmWork = work
        if isFinal { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work) }
        return true
    }

    private func performUniversal(_ action: Universal.Action, in name: String, confirmed: Bool = false) {
        DispatchQueue.global().async { [weak self] in
            let ok = action.perform(confirmed: confirmed)
            DispatchQueue.main.async {
                Feedback.play(ok ? .understood : .failed)
                if !ok { Bilan.record(.universal, action.kind == .menu ? "menu non exécuté" : "bouton non exécuté") }
                log("Commande universelle → \(name) : \(action.kind == .menu ? "menu" : "bouton")\(self?.label(action.title) ?? "") \(ok ? "exécuté" : "non exécuté").")
            }
        }
    }

    // MARK: Indices de reconnaissance

    /// Au plus ce nombre d'indices (au-delà, le moteur d'Apple en tire moins de profit).
    static let maxHints = 100
    private var hintTimer: Timer?

    /// Met à jour les indices toutes les 60 s : noms de projets et de conversations de l'app au premier plan
    /// (« ouvre VoxTV » est alors bien mieux compris), puis phrases d'activation et commandes.
    private func startHintRefresh() {
        _ = SystemCommands.installedApps() // liste des apps prête avant la première commande
        refreshHints()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshHints() }
        RunLoop.main.add(timer, forMode: .common)
        hintTimer = timer
    }

    private func refreshHints() {
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
        (config.wakeNames ?? WakeName.defaults).forEach(add)
        for n in names.prefix(30) where n.count <= 60 { add("ouvre \(n)"); add(n) }
        let commands = target.map(NavCommands.commands(for:)) ?? []
        (commands.flatMap(\.phrases) + AppCommand.allCases.flatMap { $0.phrases(config) }
            + (config.readPausePhrases ?? []) + (config.readResumePhrases ?? []) + (config.readFromPhrases ?? [])
            + (config.sendPhrases ?? []) + (config.routines ?? []).flatMap { $0.phrases ?? [] }).forEach(add)
        return out
    }

    /// « Quelles commandes ? » : ce qu'on peut dire dans l'app au premier plan, à voix haute (sans jamais
    /// commencer une phrase par une commande ; tout ce que le micro entend pendant l'annonce est ignoré).
    private func announceHelp() {
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

    private let announcer = Announcer()

    /// Annonce parlée : le micro est coupé pendant toute l'annonce (VoiceWake ne peut pas s'entendre lui-même),
    /// puis relancé avec une transcription vide.
    private func speak(_ message: String, then: (() -> Void)? = nil) {
        detector.stop()
        announcer.say(message, locale: config.locale, voice: config.readerVoice) { [weak self] in
            self?.detector.start()
            then?()
        }
    }
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
        speak(message)
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
        guard let start else { Feedback.play(.failed); Bilan.record(.read, config.debug ? query.joined(separator: " ") : "passage introuvable"); return log("Lecture : passage introuvable\(said(query.joined(separator: " "))).") }
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
        if Routines.match(text, config: config) != nil { return "#routine" }
        if Palette.key(text, paletteOpen: paletteOpen) != nil { return "#key" }
        if Palette.request(text, config: config) != nil { return "#palette" }
        if SkillCatalog.request(text, config: config) != nil { return "#skill" }
        if WriteCommand.request(text, config: config) != nil { return "#write" }
        if Universal.match(text, config: config) != nil { return "#universal" }
        if macCommand(text) != nil { return "#mac" }
        if systemCommand(text) != nil { return "#system" }
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
        // Routines : une phrase dite seule enchaîne plusieurs commandes.
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, let routine = Routines.match(text, config: config) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard routineWork == nil else { return log("Routine déjà en cours.") }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            Feedback.play(.understood)
            log("Routine « \(Routines.label(routine)) » : \(min(routine.steps.count, Routines.maxSteps)) étapes.")
            runRoutine(routine, step: 0)
            return
        }
        // Touches et palettes de commandes, dans une app autorisée au premier plan.
        let keySpec = Palette.key(text, paletteOpen: paletteOpen)
        let palette = keySpec == nil ? Palette.request(text, config: config) : nil
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, keySpec != nil || palette != nil {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            // Flèches : répétables vite (1,5 s) ; tout le reste : délai normal entre deux commandes.
            let repeatable = keySpec == "up" || keySpec == "down"
            guard Date().timeIntervalSince(lastWake) >= (repeatable ? 1.5 : config.cooldownSeconds) else { return }
            lastWake = Date()
            guard let app = Universal.frontApp(), let bid = app.bundleIdentifier, Universal.allowedApps(config).contains(bid) else {
                Feedback.play(.failed); Bilan.record(.palette, "app non autorisée"); return log("Touche ou palette : app au premier plan non autorisée.")
            }
            let name = app.localizedName ?? bid
            if config.dryRun == true { return log("[essai] → \(keySpec.map { "touche \($0)" } ?? "palette") dans \(name)") }
            if let keySpec {
                if keySpec == "return" { lastPaletteAt = .distantPast }
                DispatchQueue.global().async {
                    let ok = Palette.pressKey(keySpec, in: app)
                    DispatchQueue.main.async { Feedback.play(ok ? .understood : .failed); if !ok { Bilan.record(.palette, "touche \(keySpec)") }; log("Touche \(keySpec) → \(name) : \(ok ? "envoyée" : "non envoyée").") }
                }
                return
            }
            guard let palette, let spec = Palette.shortcut(for: bid, config: config) else {
                Feedback.play(.failed); Bilan.record(.palette, "pas de palette pour \(bid)"); return log("Palette : pas de palette connue pour \(name) (paletteShortcuts).")
            }
            // Texte d'origine de la commande, découpé sur les mêmes mots que la phrase reconnue.
            let command = SkillCatalog.originalSlice(text, skippingWords: palette.phraseWords, droppingLastWords: palette.validate ? 2 : 0)
            guard !command.isEmpty else { Feedback.play(.failed); return log("Palette : commande vide.") }
            lastPaletteAt = palette.validate ? .distantPast : Date()
            DispatchQueue.global().async { [weak self] in
                let ok = Palette.run(command, validate: palette.validate, shortcut: spec, in: app)
                DispatchQueue.main.async {
                    Feedback.play(ok ? .understood : .failed)
                    if !ok { Bilan.record(.palette, "palette \(name)") }
                    log("Palette → \(name) : \(ok ? (palette.validate ? "commande lancée" : "commande tapée, « valide » pour l'exécuter") : "échec")\(self?.config.debug == true ? " (« \(command) »)" : "").")
                }
            }
            return
        }
        // Skills et commandes slash : « lance le skill code review sur ce fichier ».
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, let q = SkillCatalog.request(text, config: config) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            runSkill(q, said: text)
            return
        }
        // « Écris … » : texte tapé dans le champ qui a le focus.
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, let n = WriteCommand.request(text, config: config) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            writeText(WriteCommand.text(text, phraseWords: n))
            return
        }
        // Commandes universelles : « menu <libellé> », « clique sur <libellé> », dans l'app au premier plan.
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, let u = Universal.match(text, config: config) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            guard let app = Universal.frontApp(), let bid = app.bundleIdentifier, Universal.allowedApps(config).contains(bid) else {
                Feedback.play(.failed)
                Bilan.record(.universal, "app non autorisée")
                return log("Commande universelle : app au premier plan non autorisée (ajouter son identifiant à universalApps).")
            }
            runUniversal(u.kind, u.query, in: app)
            return
        }
        // Finder et Réglages Système.
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, let mac = macCommand(text) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            runMac(mac)
            return
        }
        // Commandes du Mac : apps, fenêtres, son, musique, capture d'écran.
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, let sys = systemCommand(text) {
            detector.reset()
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            // Son, luminosité, musique : répétables vite (1,5 s).
            let repeatable = [.volumeUp, .volumeDown, .brightnessUp, .brightnessDown, .nextTrack, .previousTrack].contains(sys)
            guard Date().timeIntervalSince(lastWake) >= (repeatable ? 1.5 : config.cooldownSeconds) else { return }
            lastWake = Date()
            runSystem(sys)
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
            // Noms de projets et titres de sessions : journalisés seulement en mode debug (données privées).
            if config.dryRun == true { return log("[essai] → navigation sur \(front.id)\(config.debug ? " : \(request)" : "")") }
            NavCommands.run(request, target: front) { [weak self] ok, detail in
                Feedback.play(ok ? .understood : .failed)
                if !ok { Bilan.record(.nav, self?.config.debug == true ? text : "navigation impossible") }
                log("Navigation → \(front.id) : \(ok ? "faite" : "impossible")\(self?.config.debug == true ? " (\(detail))" : "").")
            }
            return
        }
        // Gestion de l'assistant : efface le brouillon, nouvelle conversation, copie, état.
        if !interrupt, !pauseRead, !resumeRead, !readAloud,
           let command = AppCommand.match(text, router: router, config: config) {
            detector.reset()
            if command == .status { return announceStatus() }
            if command == .help { return announceHelp() }
            // Pendant une lecture à voix haute, la voix pourrait dire la phrase : on n'agit pas.
            if let r = currentReader() {
                Feedback.play(.ignored)
                return log("Commande ignorée : lecture à voix haute de \(r.id) en cours (mettre en pause d'abord).")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            guard let t = router.frontmostTarget() else { Feedback.play(.failed); Bilan.record(.command, command.rawValue); return log("Commande : aucun assistant ouvert.") }
            if config.dryRun == true { return log("[essai] → \(command.rawValue) sur \(t.id)") }
            AppActions.run(command, target: t) { ok, detail in
                Feedback.play(ok ? .understood : .failed)
                if !ok { Bilan.record(.command, command.rawValue) }
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
        guard window.isSameConversation else {
            return log("Conversation continue : chat de \(t.id) changé ou non identifié, veille.")
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
        guard dictationWindow?.isSameConversation == true else { return false }
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
            dictationWindow = window ?? (external == nil ? trigger.nativeDictationWindow : trigger.externalDictationWindow)
            if natural, dictationWindow?.conversation == nil {
                log("\(target.id) : chat non identifié, envoi automatique désactivé pour ce tour.")
            }
            recording = true
            reviewUntil = nil
            detector.start()
        }

        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: natural ? 0.2 : 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard !self.stopping else { return }
            if natural, self.active?.id == target.id {
                if let origin = self.dictationWindow,
                   !origin.isFocused || (origin.conversation != nil && !origin.isSameConversation) {
                    self.endPause()
                    Feedback.play(.failed)
                    log("\(target.id) : envoi automatique annulé, chat ou fenêtre changé.")
                    self.detector.reset()
                    return
                }
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
