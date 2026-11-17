import AppKit
import AVFoundation

extension Coordinator {
    // MARK: Veille : phrases dites et commandes

    /// Ce que la phrase déclencherait (cible ou commande de lecture), ou nil.
    func wakeKey(_ text: String) -> String? {
        if router.readFromQuery(text) != nil || router.containsAny(text, config.readFromPhrases) { return "#readfrom" }
        if router.containsInterruptPhrase(text) { return "#interrupt" }
        if router.containsAny(text, config.readPausePhrases) { return "#pause" }
        if router.containsAny(text, config.readResumePhrases) { return "#resume" }
        if router.containsReadAloudPhrase(text) { return "#readaloud" }
        if reader.isActive, let nav = ReaderNav.match(text, config: config) { return "#" + nav.rawValue }
        if Routines.match(text, config: config) != nil { return "#routine" }
        if let card = currentCard, QuestionAnswer.match(text, card: card.card) != nil { return "#answer" }
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

    func handleWake(_ text: String, fromVoice: Bool = true, verified: Bool = false) {
        voiceVerified = verified
        if fromVoice, let accepted = voiceDecision(text) {
            guard accepted else { detector.reset(); return }
            voiceVerified = true
        }
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
            if !router.isStrongInterrupt(text, notIn: reader.spokenNow), spokenByOwnReader(text), !insisted(text, phrases: readCommandPhrases + (config.readResumePhrases ?? []) + ReaderNav.allPhrases(config), spokenNow: reader.spokenNow) { Feedback.play(.ignored); return log("Commande ignorée : prononcée par le lecteur intégré.") }
            if interrupt, let t = readerTarget {
                reader.stop()
                lastWake = Date()
                log("Écoute → \(t.id) (micro).")
                detector.stop()
                trigger.fire(t, external: externalDictation(for: t)) { [weak self] started in self?.didTrigger(t, started: started) }
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
            if !voiceVerified, let r = currentReader() {
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
        // Question affichée par l'assistant : option, rang, « passe », « réponds … ».
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil,
           let card = currentCard, let reply = QuestionAnswer.match(text, card: card.card) {
            detector.reset()
            if !voiceVerified, let r = currentReader() {
                Feedback.play(.ignored)
                return log("Réponse ignorée : lecture à voix haute de \(r.id) en cours.")
            }
            guard Date().timeIntervalSince(lastWake) >= config.cooldownSeconds else { return }
            lastWake = Date()
            if config.dryRun == true { return log("[essai] → réponse à la question : \(reply)") }
            let app = card.app
            let answer = { [weak self] in
            DispatchQueue.global().async { [weak self] in
                let ok = QuestionAnswer.perform(reply, expected: card.card, in: app)
                DispatchQueue.main.async {
                    Feedback.play(ok ? .understood : .failed)
                    if !ok { Bilan.record(.command, "reponse a une question") }
                    let what: String
                    switch reply {
                    case let .option(i): what = "option \(i + 1)"
                    case .skip: what = "passer"
                    case .free: what = "réponse libre envoyée"
                    }
                    log("Question → \(what) : \(ok ? "fait" : "carte changée ou introuvable").")
                    self?.currentCard = nil
                }
            }
            }
            // Option sensible (supprimer, publier, envoyer…) : « je confirme » d'abord, comme pour les boutons.
            if case let .option(i) = reply, i < card.card.options.count, Universal.isDangerous(card.card.options[i], path: "") {
                log("Confirmation demandée → réponse à la question.")
                return askConfirmation(card.card.options[i], run: answer)
            }
            answer()
            return
        }
        // Touches et palettes de commandes, dans une app autorisée au premier plan.
        let keySpec = Palette.key(text, paletteOpen: paletteOpen)
        let palette = keySpec == nil ? Palette.request(text, config: config) : nil
        if !interrupt, !pauseRead, !resumeRead, !readAloud, routed == nil, keySpec != nil || palette != nil {
            detector.reset()
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
            if !voiceVerified, let r = currentReader() {
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
                trigger.fire(paused, external: externalDictation(for: paused)) { [weak self] started in
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
            if (pauseRead || interrupt), !strongInterrupt(text, reader), spokenByReader(text, reader),
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
}
