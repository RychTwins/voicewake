import AppKit
import AVFoundation

extension Coordinator {
    // MARK: Nom d'appel

    /// Phrase libre après le nom d'appel : attendre qu'elle soit finie (2 s stable ou résultat définitif),
    /// puis demander à Claude la commande correspondante et la traiter comme si elle avait été dite.
    func scheduleInterpret(_ text: String, isFinal: Bool) {
        pendingInterpret?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingInterpret = nil
            guard self.active == nil, !self.interpreting, self.currentReader() == nil, !self.reader.isActive,
                  Date().timeIntervalSince(self.lastWake) >= self.config.cooldownSeconds else { return }
            let gate = self.voiceGate()
            if gate == false { self.detector.reset(); return }
            self.detector.reset()
            if self.config.dryRun == true { return log("[essai] → interpréteur\(said(text))") }
            self.interpreting = true
            self.lastWake = Date()
            let extra = AppCommand.allCases.flatMap { $0.phrases(self.config) }
                + (self.config.routines ?? []).flatMap { $0.phrases ?? [] }
            log("Interpréteur : demande envoyée\(self.config.debug ? said(text) : "").")
            Interpreter.interpret(text, front: Universal.frontApp()?.localizedName, jarvis: self.config.jarvisEnabled, extra: extra) { [weak self] command, detail in
                guard let self else { return }
                self.interpreting = false
                guard let command, !command.isEmpty else {
                    Feedback.play(.failed)
                    Bilan.record(.command, command == nil ? "interpréteur : \(detail)" : "interpréteur : rien compris")
                    return log("Interpréteur : \(command == nil ? detail : "aucune commande ne correspond").")
                }
                // Seules les commandes que VoiceWake reconnaît sont exécutées, par le chemin habituel.
                guard self.wakeKey(command) != nil, self.active == nil else {
                    Feedback.play(.failed)
                    Bilan.record(.command, "interpréteur : commande inconnue")
                    return log("Interpréteur : réponse non reconnue\(self.config.debug ? said(command) : "").")
                }
                log("Interpréteur → \(self.wakeKey(command) ?? "")\(self.config.debug ? said(command) : "").")
                let run = { [weak self] in
                    guard let self else { return }
                    self.lastWake = .distantPast
                    self.handleWake(command, fromVoice: false, verified: gate == true)
                }
                if Interpreter.needsConfirmation(command) {
                    log("Confirmation demandée → commande interprétée.")
                    return self.askConfirmation(command, run: run)
                }
                run()
            }
        }
        pendingInterpret = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isFinal ? 0.1 : 2), execute: work)
    }

    func afterWakeName(_ text: String) -> String? {
        guard config.jarvisEnabled else { return nil }
        return WakeName.command(after: text, names: config.wakeNames ?? WakeName.defaults)
    }

    /// Pendant une dictée : « Jarvis, <commande> » coupe le micro puis exécute la commande (stable 1,5 s).
    func checkWakeNameDuringDictation(_ text: String, _ t: Target) -> Bool {
        guard recording, !stopping, let command = afterWakeName(text), wakeKey(command) != nil else {
            pendingWakeName?.cancel() // la phrase a continué : ce n'était pas (ou plus) une commande
            pendingWakeName = nil
            return false
        }
        pendingWakeName?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active?.id == t.id, self.recording, !self.stopping else { return }
            self.pendingWakeName = nil
            let gate = self.voiceGate()
            if gate == false { return } // voix non reconnue : la dictée continue
            self.pendingSend?.cancel()
            self.stopping = true
            log("Nom d'appel pendant la dictée → \(t.id) : micro coupé, commande exécutée.")
            self.trigger.stopDictation(t, in: self.dictationWindow, external: self.externalDictation(for: t)) { [weak self] _ in
                guard let self else { return }
                self.stopping = false
                self.endPause()
                self.detector.reset()
                self.lastWake = .distantPast
                self.handleWake(command, fromVoice: false, verified: gate == true)
            }
        }
        pendingWakeName = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        return true
    }

    // MARK: Couper la parole

    func startBargeInWatch() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkBargeIn() }
        RunLoop.main.add(timer, forMode: .common)
        bargeTimer = timer
    }

    func checkBargeIn() {
        guard let settings = config.voiceFilter, settings.enabled == true, settings.bargeIn ?? true,
              let print = VoicePrint.shared, print.profile != nil, !bargeChecking, active == nil,
              currentReader() != nil || (reader.isActive && !reader.isPaused),
              Date().timeIntervalSince(lastBargeIn) > 3 else { return }
        let threshold = Float(settings.bargeInThreshold ?? (settings.threshold ?? 0.45) + 0.1)
        bargeChecking = true
        bargeQueue.async { [weak self] in
            // Au moins 0,5 s de parole dans la dernière 1,2 s, puis une seule empreinte (~35 ms).
            let score = print.speechSeconds(last: 1.2) >= 0.5 ? print.score(lastSeconds: 1.2, split: false) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.bargeChecking = false
                guard let score, score >= threshold, self.active == nil,
                      self.currentReader() != nil || (self.reader.isActive && !self.reader.isPaused) else { return }
                self.lastBargeIn = Date()
                let shown = String(format: "%.2f", score)
                guard settings.block == true else {
                    return log("Filtre de voix (observation) : ta voix pendant la lecture (score \(shown)) → aurait coupé la lecture.")
                }
                log("Ta voix pendant la lecture (score \(shown)) : lecture coupée, micro ouvert.")
                self.lastWake = .distantPast
                self.handleWake(self.config.interruptPhrases?.first ?? "écoute", fromVoice: false, verified: true)
            }
        }
    }

    // MARK: Filtre « ma voix uniquement »

    /// nil : filtre inactif ou en observation (rien ne change) ; true : voix reconnue ; false : commande bloquée.
    func voiceDecision(_ text: String) -> Bool? {
        guard wakeKey(text) != nil else { return nil }
        return voiceGate()
    }

    /// Même décision, sur la parole entendue à l'instant (aussi pour les phrases que l'interpréteur IA ou le nom
    /// d'appel transformeront en commande : la vérification se fait sur la voix d'origine).
    func voiceGate() -> Bool? {
        guard let settings = config.voiceFilter, settings.enabled == true, let print = VoicePrint.shared,
              print.profile != nil else { return nil }
        let threshold = Float(settings.threshold ?? 0.45)
        let score = print.score(lastSeconds: settings.windowSeconds ?? 4)
        let ok = score.map { $0 >= threshold } ?? false
        let shown = score.map { String(format: "%.2f", $0) } ?? "aucune parole"
        guard settings.block == true else {
            log("Filtre de voix (observation) : score \(shown), seuil \(String(format: "%.2f", threshold)) → \(ok ? "ta voix" : "aurait été bloquée").")
            return nil
        }
        if ok { if config.debug { log("Filtre de voix : score \(shown) → ta voix.") }; return true }
        Feedback.play(.ignored)
        log("Commande ignorée : voix non reconnue (score \(shown)).")
        return false
    }

}
