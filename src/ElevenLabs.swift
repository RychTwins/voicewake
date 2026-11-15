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

    /// Audio synthétisé, avec l'instant où chaque caractère du texte est prononcé.
    struct Speech {
        let audio: Data
        /// Début de prononciation (s) pour chaque unité UTF-16 du texte (indices NSString), ou nil si
        /// ElevenLabs n'a pas renvoyé d'alignement exploitable.
        let timings: [Double]?
    }

    /// Cache en mémoire des derniers extraits (relire un passage ne consomme pas de quota).
    private static var cache: [String: Speech] = [:]
    private static var cacheOrder: [String] = []
    static let cacheLimit = 24

    static func cacheKey(_ text: String, _ s: ElevenLabsSettings, locale: String) -> String {
        [s.voiceID, s.model ?? "eleven_flash_v2_5", String(locale.prefix(2)), text].joined(separator: "\u{1F}")
    }

    static func cached(_ key: String) -> Speech? { cache[key] }

    static func store(_ speech: Speech, key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = speech
        while cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Audio MP3 du texte, ou nil (désactivé, clé absente, erreur réseau). Rappel sur la file principale.
    static func synthesize(_ text: String, config: Config, completion: @escaping (Speech?) -> Void) {
        if let s = config.elevenLabs, s.enabled == true, let hit = cached(cacheKey(text, s, locale: config.locale)) {
            return DispatchQueue.main.async { completion(hit) }
        }
        guard let s = config.elevenLabs, s.enabled == true, let key = apiKey(s),
              let id = s.voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)/with-timestamps?output_format=mp3_44100_128")
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
            let speech = status == 200 ? data.flatMap { parse($0, text: text) } : nil
            DispatchQueue.main.async {
                if let speech {
                    store(speech, key: cacheKey(text, s, locale: config.locale))
                    return completion(speech)
                }
                log("ElevenLabs indisponible (\(error?.localizedDescription ?? "code \(status)")) : voix du Mac.")
                completion(nil)
            }
        }.resume()
    }

    /// Réponse de /with-timestamps : { audio_base64, alignment: { characters, character_start_times_seconds } }.
    static func parse(_ data: Data, text: String) -> Speech? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let b64 = json["audio_base64"] as? String, let audio = Data(base64Encoded: b64), !audio.isEmpty
        else { return nil }
        return Speech(audio: audio, timings: timings(json["alignment"] as? [String: Any], text: text))
    }

    /// Instants par unité UTF-16 du texte ; nil si l'alignement ne correspond pas exactement au texte envoyé.
    static func timings(_ alignment: [String: Any]?, text: String) -> [Double]? {
        guard let chars = alignment?["characters"] as? [String],
              let starts = alignment?["character_start_times_seconds"] as? [NSNumber],
              chars.count == starts.count, !chars.isEmpty else { return nil }
        var out: [Double] = []
        out.reserveCapacity((text as NSString).length)
        for (c, t) in zip(chars, starts) {
            out.append(contentsOf: repeatElement(t.doubleValue, count: (c as NSString).length))
        }
        guard out.count == (text as NSString).length else {
            log("ElevenLabs : alignement inattendu, position estimée.")
            return nil
        }
        return out
    }

    private static var announcer: AudioClip?

    /// Dit une courte annonce avec la voix ElevenLabs. `completion(false)` : à dire autrement.
    static func say(_ text: String, config: Config, completion: @escaping (Bool) -> Void) {
        synthesize(text, config: config) { speech in
            guard let speech, let clip = AudioClip(speech.audio) else { return completion(false) }
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
        p.enableRate = true // « plus vite » / « moins vite »
        p.prepareToPlay()
    }

    /// Part de l'extrait déjà lue (0 à 1).
    var progress: Double { player.duration > 0 ? player.currentTime / player.duration : 0 }
    /// Position de lecture (s).
    var currentTime: Double { player.currentTime }
    var duration: Double { player.duration }
    /// Vitesse (1 = normale, de 0,5 à 2).
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    /// Se place à `time` (s), en lecture comme en pause.
    func seek(to time: Double) { player.currentTime = min(max(0, time), max(0, player.duration - 0.05)) }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}
