import AppKit
import AVFoundation

extension Coordinator {
    // MARK: Dictée, envoi et conversation continue

    /// Conversation continue : la lecture de la réponse est finie, on rouvre le micro du même assistant.
    func continueConversation(_ t: Target, in window: ShortcutTrigger.DictationWindow) {
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

    func endSilentContinuation(_ t: Target) {
        guard active?.id == t.id, recording, !stopping else { return }
        stopping = true
        dictatedContent = .held
        trigger.stopDictation(t, in: dictationWindow, recoverFocus: false) { [weak self] stopped in
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

    /// Ce qui a été dit après la dernière pause d'au moins `minPause` secondes (texte normalisé), sinon nil.
    func spokenAfterPause(_ n: String, minPause: Double) -> String? {
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
    func switchTarget(_ text: String, from current: Target) -> Target? {
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
    func switchDictation(from current: Target, to next: Target) {
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

    func checkSend(_ text: String, _ t: Target, isFinal: Bool) {
        lastDictationText = text
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

    func sendAfterSilence(_ target: Target, startedAt: TimeInterval) -> Bool {
        let base = config.autoSendSilenceSeconds ?? 5
        let delay = (config.naturalTurnEnd ?? true) ? TurnEnd.delay(for: lastDictationText, base: base) : base
        guard pendingSend == nil, recording, let audio = detector.audioActivity else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard dictatedContent.shouldSend(now: now, startedAt: max(startedAt, lastAutoSendPause), lastBuffer: audio.lastBuffer,
                                         lastSpeech: audio.lastSpeech, delay: delay) else { return false }
        guard dictationWindow?.isSameConversation == true, let shortcut = target.automaticSubmitShortcut else { return false }
        var submission = target
        submission.submitShortcut = shortcut
        log("Silence de \(String(format: "%.1f", delay)) s : envoi → \(target.id).")
        submitNow(submission, automatic: true)
        return true
    }

    func submitNow(_ t: Target, automatic: Bool = false) {
        let stopFirst = recording
        let window = dictationWindow
        let readBaseline = trigger.readAloudBaseline(t, in: window)
        endPause()
        detector.stop()
        trigger.submit(t, in: window, stopFirst: stopFirst, automatic: automatic) { [weak self] submitted in
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

    func endPause() {
        history.removeAll()
        lastDictationText = ""
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

    func didTrigger(_ target: Target, started: Bool) {
        if started { pauseUntilConversationEnds(target) } else { Feedback.play(.failed); detector.start() }
    }

    /// Reste en pause tant qu'une application utilise le micro.
    /// Avec l'envoi vocal, VoiceWake continue d'écouter (micro partagé) pour entendre « ok envoie ».
    func pauseUntilConversationEnds(_ target: Target, reopenedIn window: ShortcutTrigger.DictationWindow? = nil) {
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
