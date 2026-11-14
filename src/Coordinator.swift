import Foundation

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
        detector.onText = { [weak self] text in self?.handle(text) }
    }

    func start() {
        _ = ShortcutTrigger.checkAccessibility(prompt: true)
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

    private func handle(_ text: String) {
        // Pas de garde « un assistant parle » ici : Claude garde une sortie audio ouverte pendant sa dictée.
        if let t = active { checkSend(text, t); return }
        let interrupt = router.containsInterruptPhrase(text)
        let routed = router.route(text)
        guard interrupt || routed != nil else { return }
        // Lecture à voix haute lancée par VoiceWake et encore en cours : seule une phrase
        // d'interruption compte, pour ne pas se déclencher sur la voix de l'assistant.
        // (Une app peut garder sa sortie audio ouverte sans rien lire : on ne bloque que nos lectures.)
        // La lecture reste « en cours » jusqu'à 3 s de silence continu (voir startReading).
        if let reader = trigger.readingTarget() {
            if interrupt {
                let t = reader
                lastWake = Date()
                log("Interruption de la lecture → \(t.id)\(said(text)).")
                detector.stop()
                trigger.interruptAndDictate(t) { [weak self] in self?.pauseUntilConversationEnds(t) }
            } else {
                log("Phrase ignorée : lecture à voix haute de \(reader.id) en cours\(said(text)).")
                detector.reset()
            }
            return
        }
        guard let routedTarget = routed else { detector.reset(); return }
        // Éditeur de code au premier plan avec cet assistant intégré : on vise l'éditeur.
        let target = router.inEditor(routedTarget) ?? routedTarget
        let now = Date()
        guard now.timeIntervalSince(lastWake) >= config.cooldownSeconds else {
            detector.reset()
            return
        }
        lastWake = now
        log("Phrase détectée → \(target.id)\(said(text)).")

        // On libère le micro avant d'appuyer sur le raccourci.
        detector.stop()
        trigger.fire(target) { [weak self] in self?.pauseUntilConversationEnds(target) }
    }

    /// Micro de l'app encore ouvert (false après « ok arrête »).
    private var recording = false
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

    private func checkSend(_ text: String, _ t: Target) {
        pendingSend?.cancel()
        history.append((Date(), normalize(text)))
        if history.count > 60 { history.removeFirst(history.count - 60) }
        let send = router.endsWithSendPhrase(text)
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
                log("Phrase d'arrêt détectée → \(t.id)\(self.said(text)). En attente de « ok envoie ».")
                self.recording = false
                self.reviewUntil = Date().addingTimeInterval(self.config.reviewSeconds ?? 180)
                self.detector.reset()
                self.trigger.stopDictation(t)
                return
            }
            log("Phrase d'envoi détectée → \(t.id)\(self.said(text)).")
            let stopFirst = self.recording
            self.endPause()
            self.detector.stop()
            self.trigger.submit(t, stopFirst: stopFirst) { [weak self] in
                log("Reprise de la veille (message envoyé).")
                self?.detector.start()
                self?.trigger.readAloudWhenDone(t)
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
        recording = false
        reviewUntil = nil
    }

    /// Reste en pause tant qu'une application utilise le micro.
    /// Avec l'envoi vocal, VoiceWake continue d'écouter (micro partagé) pour entendre « ok envoie ».
    private func pauseUntilConversationEnds(_ target: Target) {
        let c = config.conversation
        let started = Date()
        var lastActive = started
        var sawConversation = false
        let listening = sendEnabled
        log("Pause pendant la conversation\(listening ? " (envoi vocal actif)" : "").")
        if listening {
            active = target
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
