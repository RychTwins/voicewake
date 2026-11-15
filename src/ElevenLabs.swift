import AVFoundation
import Foundation

/// Voix ElevenLabs (optionnelle, désactivée par défaut) : remplace la voix du Mac pour le lecteur intégré
///. Le texte à dire est alors envoyé à api.elevenlabs.io.
struct ElevenLabsSettings: Codable {
    var enabled: Bool?
    /// Identifiant de la voix (page « Voices » d'ElevenLabs).
    var voiceID: String
    /// Modèle (défaut eleven_flash_v2_5 : rapide et économique).
    var model: String?
    /// Fichier contenant la ligne ELEVENLABS_API_KEY=… (défaut ~/.config/voicewake/elevenlabs.env).
    /// La clé n'est jamais écrite dans la configuration.
    var keyFile: String?
}

enum ElevenLabs {
    static func apiKey(_ s: ElevenLabsSettings) -> String? {
        if let k = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !k.isEmpty { return k }
        let path = (s.keyFile ?? "~/.config/voicewake/elevenlabs.env") as NSString
        guard let content = try? String(contentsOfFile: path.expandingTildeInPath, encoding: .utf8) else { return nil }
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].replacingOccurrences(of: "export ", with: "") == "ELEVENLABS_API_KEY" else { continue }
            let key = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return key.isEmpty ? nil : key
        }
        return nil
    }

    /// Audio MP3 du texte, ou nil (désactivé, clé absente, erreur réseau). Rappel sur la file principale.
    static func synthesize(_ text: String, config: Config, completion: @escaping (Data?) -> Void) {
        guard let s = config.elevenLabs, s.enabled == true, let key = apiKey(s),
              let id = s.voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)?output_format=mp3_44100_128")
        else { return DispatchQueue.main.async { completion(nil) } }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "model_id": s.model ?? "eleven_flash_v2_5", "language_code": String(config.locale.prefix(2)),
        ])
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if status == 200, let data, !data.isEmpty { return completion(data) }
                log("ElevenLabs indisponible (\(error?.localizedDescription ?? "code \(status)")) : voix du Mac.")
                completion(nil)
            }
        }.resume()
    }

    private static var announcer: AudioClip?

    /// Dit une courte annonce avec la voix ElevenLabs. `completion(false)` : à dire autrement.
    static func say(_ text: String, config: Config, completion: @escaping (Bool) -> Void) {
        synthesize(text, config: config) { data in
            guard let data, let clip = AudioClip(data) else { return completion(false) }
            announcer = clip
            clip.onFinish = { announcer = nil; completion(true) }
            clip.play()
        }
    }
}

/// Lecture d'un extrait audio, avec pause, reprise et progression.
final class AudioClip: NSObject, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?

    init?(_ data: Data) {
        guard let p = try? AVAudioPlayer(data: data) else { return nil }
        player = p
        super.init()
        p.delegate = self
    }

    /// Part de l'extrait déjà lue (0 à 1).
    var progress: Double { player.duration > 0 ? player.currentTime / player.duration : 0 }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}
