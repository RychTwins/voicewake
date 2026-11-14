import AppKit
import AVFoundation
import Speech

/// Transcrit le micro en local et transmet le texte partiel à `onText`.
final class WakeWordDetector {
    var onText: ((String) -> Void)?

    private let config: Config
    private let hints: [String]
    private let recognizer: SFSpeechRecognizer
    private let audio = AudioListener()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var rotateTimer: Timer?
    private var wanted = false
    private var observersInstalled = false

    init(config: Config, hints: [String]) throws {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: config.locale)) else {
            throw ConfigError("Langue non supportée : \(config.locale)")
        }
        self.config = config
        self.hints = hints
        self.recognizer = r
        audio.echoCancellation = config.echoCancellation ?? true
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
            log("Reconnaissance locale indisponible pour \(config.locale).")
            if config.requireOnDevice {
                log("Arrêt : mettre \"requireOnDevice\": false pour passer par les serveurs d'Apple.")
                exit(1)
            }
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
        lock.lock(); let r = request; request = nil; lock.unlock()
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
            self.lock.lock(); let r = self.request; self.lock.unlock()
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
                    if self.config.debug { log("… \(text)") }
                    self.onText?(text)
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
