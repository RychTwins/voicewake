import AppKit
import AVFoundation
import Speech

/// Transcrit le micro en local et transmet le texte partiel à `onText`.
final class WakeWordDetector {
    struct AudioActivity {
        let lastBuffer: TimeInterval
        let lastSpeech: TimeInterval
    }

    /// (texte, définitif) : `true` quand le moteur a fini de corriger l'énoncé.
    var onText: ((String, Bool) -> Void)?

    private let config: Config
    /// Indices pour le moteur (phrases d'activation, commandes, noms de projets) : pris en compte à la
    /// prochaine tâche de reconnaissance (après chaque pause ou commande).
    var hints: [String]
    private let recognizer: SFSpeechRecognizer
    private let audio = AudioListener()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var activity: AudioActivity?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var rotateTimer: Timer?
    private var wanted = false
    private var observersInstalled = false
    private var waitedForModel = 0

    var audioActivity: AudioActivity? {
        lock.lock()
        defer { lock.unlock() }
        return activity
    }

    init(config: Config, hints: [String]) throws {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: config.locale)) else {
            throw ConfigError("Langue non supportée : \(config.locale)")
        }
        self.config = config
        self.hints = hints
        self.recognizer = r
        audio.echoCancellation = config.echoCancellation ?? false
        audio.debugLevels = config.debug
    }

    func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                log("Reconnaissance vocale refusée (Réglages > Confidentialité > Reconnaissance vocale).")
                DispatchQueue.main.async { done(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { log("Micro refusé (Réglages > Confidentialité > Micro).") }
                DispatchQueue.main.async { done(granted) }
            }
        }
    }

    func start() {
        if !recognizer.supportsOnDeviceRecognition {
            if config.requireOnDevice {
                // Juste après le démarrage du Mac, le modèle local n'est pas toujours chargé : on réessaie.
                waitedForModel += 1
                if waitedForModel <= 24 {
                    if waitedForModel == 1 { log("Modèle vocal \(config.locale) pas encore prêt, nouvel essai toutes les 5 s.") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
                    return
                }
                log("Reconnaissance locale indisponible pour \(config.locale). Mettre \"requireOnDevice\": false pour passer par les serveurs d'Apple.")
                exit(1)
            }
            log("Reconnaissance locale indisponible pour \(config.locale) : serveurs d'Apple.")
        }
        installObserversOnce()
        wanted = true
        restartAudio()
    }

    /// Coupe l'écoute et libère le micro.
    func stop() {
        wanted = false
        rotateTimer?.invalidate()
        generation += 1
        lock.lock(); let r = request; request = nil; activity = nil; lock.unlock()
        r?.endAudio()
        task?.cancel()
        task = nil
        audio.stop()
    }

    /// Vide la transcription en cours (après une détection).
    func reset() {
        guard wanted else { return }
        startTask()
    }

    private func installObserversOnce() {
        guard !observersInstalled else { return }
        observersInstalled = true
        audio.onBuffer = { [weak self] buffer in
            guard let self else { return }
            let level = self.config.continuousConversation == true ? Self.hasSpeechEnergy(buffer) : nil
            self.lock.lock()
            let r = self.request
            if r != nil, let level {
                let now = ProcessInfo.processInfo.systemUptime
                self.activity = AudioActivity(lastBuffer: now, lastSpeech: level ? now : self.activity?.lastSpeech ?? 0)
            }
            self.lock.unlock()
            r?.append(buffer)
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.wanted else { return }
            log("Périphérique audio modifié, redémarrage.")
            self.restartAudio()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.wanted else { return }
            log("Sortie de veille, redémarrage.")
            self.restartAudio()
        }
    }

    private func restartAudio() {
        guard wanted else { return }
        lock.lock(); activity = nil; lock.unlock()
        do {
            try audio.start()
        } catch {
            log("Erreur audio : \(error.localizedDescription). Nouvel essai dans 5 s.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.restartAudio() }
            return
        }
        startTask()
        log("En écoute (\(config.locale)).")
    }

    /// Énergie RMS d'un tampon micro. Un bruit persistant retarde l'envoi.
    private static func hasSpeechEnergy(_ buffer: AVAudioPCMBuffer) -> Bool? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        var energy: Float = 0
        for index in 0..<frames {
            let sample = samples[index * buffer.stride]
            energy += sample * sample
        }
        return energy / Float(frames) >= 0.000063 // environ -42 dBFS
    }

    // Une tâche de reconnaissance est limitée dans le temps : rotation toutes les 50 s.
    private func startTask() {
        generation += 1
        let gen = generation

        lock.lock(); let old = request; request = nil; lock.unlock()
        old?.endAudio()
        task?.cancel()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.contextualStrings = hints
        req.taskHint = .search
        lock.lock(); request = req; lock.unlock()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    if self.config.debug {
                        log("… \(text)")
                        let alts = (result?.transcriptions ?? []).dropFirst().prefix(4).map(\.formattedString)
                        let segs = (result?.bestTranscription.segments ?? []).map {
                            "\($0.substring)[\(String(format: "%.2f", $0.confidence)): \($0.alternativeSubstrings.prefix(4).joined(separator: ","))]"
                        }
                        if !alts.isEmpty || segs.contains(where: { $0.contains(",") || !$0.contains("[0.00") }) {
                            log("   alt: \(alts.joined(separator: " / ")) | \(segs.joined(separator: " "))")
                        }
                    }
                    self.onText?(text, result?.isFinal == true)
                    if gen != self.generation { return } // reset() ou stop() appelé
                }
                if error != nil || result?.isFinal == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if gen == self.generation, self.wanted { self.startTask() }
                    }
                }
            }
        }

        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self, self.wanted else { return }
            self.startTask()
        }
    }
}
