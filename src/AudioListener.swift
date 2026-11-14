import AVFoundation

final class AudioListener {
    private var engine = AVAudioEngine()
    private(set) var isRunning = false
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Annulation d'écho de macOS : retire du micro le son joué par le Mac (voix de lecture des assistants).
    var echoCancellation = false

    func start() throws {
        stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Ne pas baisser le son des autres apps (lecture à voix haute, musique).
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                log("Annulation d'écho indisponible : \(error.localizedDescription)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ConfigError("Aucun micro disponible") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Libère réellement le micro, pour que l'assistant l'ait pour lui seul.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
