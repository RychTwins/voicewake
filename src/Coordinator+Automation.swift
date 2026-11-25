import AppKit
import AVFoundation

extension Coordinator {
    // MARK: Diagnostic et routines à heure fixe

    func startupDiagnostic() {
        let checks = Diagnostic.run(config)
        for c in checks where !c.ok { log("Diagnostic : \(c.name) — \(c.fix)") }
        guard config.announceProblems ?? true, let summary = Diagnostic.spokenSummary(checks),
              active == nil, !reader.isActive, currentReader() == nil else { return }
        speak(summary)
    }

    /// Routines avec une heure (`"at": "09:00"`) : lancées à cette heure, si VoiceWake est en veille.
    func startRoutineClock() {
        guard (config.routines ?? []).contains(where: { $0.at != nil }) else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.checkRoutineClock() }
        RunLoop.main.add(timer, forMode: .common)
        routineClock = timer
    }

    func checkRoutineClock(now: Date = Date()) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let minute = f.string(from: now)
        guard minute != lastRoutineMinute else { return }
        lastRoutineMinute = minute
        for r in Routines.due(config.routines ?? [], at: now) {
            guard active == nil, pendingConfirmation == nil, !reader.isActive, currentReader() == nil else {
                log("Routine « \(Routines.label(r)) » de \(r.at ?? "") non lancée : dictée, confirmation ou lecture en cours.")
                continue
            }
            log("Routine « \(Routines.label(r)) » : heure prévue (\(r.at ?? "")).")
            runRoutine(r, step: 0)
            break // une à la fois
        }
    }

    // MARK: Questions de l'assistant

    func startQuestionWatch() {
        guard config.answerQuestions ?? true else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.scanQuestion() }
        RunLoop.main.add(timer, forMode: .common)
        questionTimer = timer
    }

    func scanQuestion() {
        guard !scanningCard else { return }
        guard active == nil, !reader.isActive, let t = router.frontmostTarget(),
              let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) else { currentCard = nil; return }
        scanningCard = true
        DispatchQueue.global().async { [weak self] in
            let found = QuestionAnswer.card(in: app)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanningCard = false
                let had = self.currentCard != nil
                self.currentCard = found.map { ($0.card, app) }
                // Une question vient de s'afficher : petit son, tu peux répondre à la voix.
                if !had, found != nil { Feedback.play(.micOpen) }
                if self.config.debug, had != (found != nil) {
                    log(found.map { "Question affichée : \($0.card.options.count) options." } ?? "Question fermée.")
                }
            }
        }
    }

    // MARK: Routines

    /// Exécute l'étape `i` comme une phrase dite, puis la suivante après le délai de la routine. Arrêt si une
    /// dictée s'ouvre, une confirmation est demandée, une lecture commence ou une étape n'est pas reconnue.
    func runRoutine(_ r: Routine, step i: Int) {
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
        handleWake(step, fromVoice: false)
        scheduleRoutine(r, step: i + 1, after: Routines.delay(r))
    }

    func scheduleRoutine(_ r: Routine, step i: Int, after delay: Double) {
        let work = DispatchWorkItem { [weak self] in self?.runRoutine(r, step: i) }
        routineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Skills

    /// Tape « /skill arguments » dans la zone de saisie de l'assistant au premier plan, puis attend « ok envoie »
    /// (comme après « garde le brouillon »). « … et envoie » à la fin : envoi immédiat.
    func runSkill(_ query: [String], said text: String) {
        guard let t = router.frontmostTarget(), let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) else {
            Feedback.play(.failed); Bilan.record(.skill, "aucun assistant au premier plan"); return log("Skill : aucun assistant au premier plan.")
        }
        var q = query
        let sendNow = q.count >= 2 && Lang.list("skill.send", ["envoie", "envoyer"]).contains(q.last!) && Lang.list("andThen", ["et", "puis"]).contains(q[q.count - 2])
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

    func typeSkill(_ typed: String, skill: String, target t: Target, app: NSRunningApplication, sendNow: Bool) {
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
    func holdForSend(_ t: Target) {
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

    /// Action sensible : « Confirmer … ? », puis « oui » ou « non » dit seul dans les 8 s.
    func askConfirmation(_ action: Universal.Action, in name: String) {
        log("Confirmation demandée → \(name)\(label(action.title)).")
        askConfirmation(action.title) { [weak self] in self?.performUniversal(action, in: name, confirmed: true) }
    }

    /// Demande « Confirmer … ? » et n'exécute `run` que sur « je confirme » dit seul.
    func askConfirmation(_ title: String, run: @escaping () -> Void) {
        pendingConfirmation = (title, run, Date().addingTimeInterval(Universal.confirmSeconds + 3))
        speak(Universal.confirmationPrompt(title, config: config)) { [weak self] in
            self?.pendingConfirmation?.expires = Date().addingTimeInterval(Universal.confirmSeconds)
        }
    }

    /// true si la transcription a été prise comme réponse (ou ignorée pendant l'annonce).
    func handleConfirmation(_ text: String, isFinal: Bool) -> Bool {
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

    func performUniversal(_ action: Universal.Action, in name: String, confirmed: Bool = false) {
        DispatchQueue.global().async { [weak self] in
            let ok = action.perform(confirmed: confirmed)
            DispatchQueue.main.async {
                Feedback.play(ok ? .understood : .failed)
                if !ok { Bilan.record(.universal, action.kind == .menu ? "menu non exécuté" : "bouton non exécuté") }
                log("Commande universelle → \(name) : \(action.kind == .menu ? "menu" : "bouton")\(self?.label(action.title) ?? "") \(ok ? "exécuté" : "non exécuté").")
            }
        }
    }
}
