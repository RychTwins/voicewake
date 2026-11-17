import AVFoundation
import CoreML
import Foundation

/// Filtre « ma voix uniquement » : un modèle de reconnaissance du locuteur (WeSpeaker ResNet34, Core ML, sur le Mac)
/// transforme quelques secondes de parole en une empreinte de 256 nombres. Une commande n'est acceptée que si la
/// parole entendue juste avant ressemble assez à l'empreinte de l'utilisateur (similarité cosinus).
/// Aucun son n'est enregistré ni envoyé : les 8 dernières secondes restent en mémoire, le temps de décider.
/// Modèle : wespeaker_int8 (FluidInference/speaker-diarization-coreml, d'après pyannote/wespeaker-voxceleb-resnet34-LM,
/// CC-BY-4.0), dans ~/.config/voicewake/models/.
struct VoiceFilterSettings: Codable {
    var enabled: Bool?
    /// false (défaut) : mode observation, rien n'est bloqué, le score de chaque commande est noté dans le journal.
    var block: Bool?
    /// Similarité minimale avec l'empreinte pour accepter une commande (défaut 0,45).
    var threshold: Double?
    /// Durée examinée avant la commande, en secondes (défaut 4).
    var windowSeconds: Double?
    /// Empreinte (défaut ~/.config/voicewake/voix.json, créée par `voicewake voix apprends`).
    var profilePath: String?
    /// Modèle Core ML (défaut ~/.config/voicewake/models/wespeaker_int8.mlmodelc).
    var modelPath: String?
    /// Couper la parole : ta voix pendant une lecture l'arrête et rouvre le micro, sans mot-clé (défaut true ;
    /// en mode observation, seulement noté dans le journal).
    var bargeIn: Bool?
    /// Similarité minimale pour couper la lecture (défaut : seuil + 0,1, la voix de lecture se mêlant à la tienne).
    var bargeInThreshold: Double?
}

final class VoicePrint {
    static let rate = 16_000.0
    static let hop = 160                 // 10 ms à 16 kHz
    static let modelSamples = 160_000    // 10 s
    static let maskFrames = 589

    struct Profile: Codable {
        var embedding: [Float]
        /// Similarité moyenne des extraits de l'enregistrement avec l'empreinte (repère pour le seuil).
        var selfScore: Float
        var createdAt: Date
    }

    static var shared: VoicePrint?
    /// Empreinte à utiliser au prochain démarrage du micro (nil : filtre désactivé).
    static var profileToUse: Profile?
    static var model: MLModel?

    let sampleRate: Double
    var profile: Profile?
    private let lock = NSLock()
    private var samples: [Float] = []    // 16 kHz
    private var voiced: [Bool] = []      // un drapeau par tranche de 10 ms
    private var hopBuffer: [Float] = []
    private var position = 0.0           // rééchantillonnage
    private var previous: Float = 0
    private var noiseFloor: Float = -60
    private let keepHops = 800           // 8 s

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    // MARK: Modèle

    static func defaultModelPath(_ s: VoiceFilterSettings?) -> String {
        ((s?.modelPath ?? "~/.config/voicewake/models/wespeaker_int8.mlmodelc") as NSString).expandingTildeInPath
    }

    /// Charge le modèle et fait un premier calcul (le tout premier prend ~3 s).
    @discardableResult
    static func loadModel(_ path: String) -> Bool {
        if model != nil { return true }
        guard FileManager.default.fileExists(atPath: path),
              let m = try? MLModel(contentsOf: URL(fileURLWithPath: path)) else { return false }
        model = m
        _ = embed([[Float](repeating: 0.01, count: 16_000)])
        return true
    }

    /// Empreintes normalisées (256 nombres) de 1 à 3 extraits de parole à 16 kHz (10 s max chacun).
    static func embed(_ chunks: [[Float]]) -> [[Float]]? {
        guard let model, !chunks.isEmpty, chunks.count <= 3,
              let wave = try? MLMultiArray(shape: [3, NSNumber(value: modelSamples)], dataType: .float32),
              let mask = try? MLMultiArray(shape: [3, NSNumber(value: maskFrames)], dataType: .float32) else { return nil }
        let w = wave.dataPointer.bindMemory(to: Float.self, capacity: 3 * modelSamples)
        let k = mask.dataPointer.bindMemory(to: Float.self, capacity: 3 * maskFrames)
        w.initialize(repeating: 0, count: 3 * modelSamples)
        k.initialize(repeating: 0, count: 3 * maskFrames)
        for row in 0..<3 {
            let c = chunks[min(row, chunks.count - 1)]   // lignes vides : on répète le dernier extrait
            let n = min(c.count, modelSamples)
            for i in 0..<n { w[row * modelSamples + i] = c[i] }
            let frames = max(1, Int(Double(n) / Double(modelSamples) * Double(maskFrames)))
            for i in 0..<min(frames, maskFrames) { k[row * maskFrames + i] = 1 }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": wave, "mask": mask])),
              let e = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let p = e.dataPointer.bindMemory(to: Float.self, capacity: 3 * 256)
        return (0..<chunks.count).map { row in normalized((0..<256).map { p[row * 256 + $0] }) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    // MARK: Audio (fil audio)

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.format.sampleRate == sampleRate else { return }
        feed(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Rééchantillonne à 16 kHz (interpolation linéaire) et marque chaque tranche de 10 ms parlée ou non.
    func feed(_ input: UnsafeBufferPointer<Float>) {
        guard !input.isEmpty else { return }
        let step = sampleRate / Self.rate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 1)
        while position < Double(input.count) {
            let i = Int(position), f = Float(position - Double(i))
            let a = i == 0 ? previous : input[i - 1], b = input[i]
            out.append(a + (b - a) * f)
            position += step
        }
        position -= Double(input.count)
        previous = input[input.count - 1]
        hopBuffer.append(contentsOf: out)
        var chunks: [([Float], Bool)] = []
        while hopBuffer.count >= Self.hop {
            let h = Array(hopBuffer.prefix(Self.hop))
            hopBuffer.removeFirst(Self.hop)
            let rms = sqrt(h.reduce(0) { $0 + $1 * $1 } / Float(Self.hop))
            let energy = 20 * log10(max(rms, 1e-7))
            noiseFloor = energy < noiseFloor ? energy : noiseFloor + 0.002 * (energy - noiseFloor)
            chunks.append((h, energy > noiseFloor + 12 && energy > -55))
        }
        guard !chunks.isEmpty else { return }
        lock.lock()
        for (h, v) in chunks { samples.append(contentsOf: h); voiced.append(v) }
        if voiced.count > keepHops {
            let drop = voiced.count - keepHops
            voiced.removeFirst(drop); samples.removeFirst(drop * Self.hop)
        }
        lock.unlock()
    }

    /// Parole (tranches parlées, avec 30 ms de marge) des dernières `seconds` secondes, morceaux contigus.
    func speechRuns(lastSeconds seconds: Double) -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        let n = voiced.count
        guard n > 0 else { return [] }
        let from = max(0, n - Int(seconds * 100))
        var runs: [[Float]] = [], current: [Float] = []
        for i in from..<n {
            let near = (max(from, i - 3)...min(n - 1, i + 3)).contains { voiced[$0] }
            if near { current.append(contentsOf: samples[(i * Self.hop)..<((i + 1) * Self.hop)]) }
            else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: Décision (fil principal)

    /// Meilleure similarité avec l'empreinte parmi trois extraits des dernières secondes (toute la parole, la
    /// première moitié, la seconde) : une commande dite par-dessus la voix de lecture ressort dans l'un d'eux.
    /// nil : pas d'empreinte, pas de modèle ou moins de 0,4 s de parole.
    func score(lastSeconds seconds: Double, split: Bool = true) -> Float? {
        guard let user = profile?.embedding else { return nil }
        let speech = Array(speechRuns(lastSeconds: seconds).joined())
        guard speech.count >= 6_400 else { return nil }
        var chunks = [speech]
        if split, speech.count >= 16_000 {
            chunks.append(Array(speech.prefix(speech.count / 2)))
            chunks.append(Array(speech.suffix(speech.count / 2)))
        }
        guard let embeddings = Self.embed(chunks.map { Array($0.suffix(Self.modelSamples)) }) else { return nil }
        return embeddings.map { Self.cosine($0, user) }.max()
    }

    /// Durée de parole (s) entendue dans les dernières secondes.
    func speechSeconds(last seconds: Double) -> Double {
        Double(speechRuns(lastSeconds: seconds).reduce(0) { $0 + $1.count }) / Self.rate
    }

    // MARK: Empreinte

    static func defaultPath(_ s: VoiceFilterSettings?) -> String {
        ((s?.profilePath ?? "~/.config/voicewake/voix.json") as NSString).expandingTildeInPath
    }

    static func loadProfile(_ path: String) -> Profile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(Profile.self, from: data)
    }

    /// Fichier lisible par l'utilisateur seul.
    static func saveProfile(_ p: Profile, to path: String) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let data = try e.encode(p)
        let dir = (path as NSString).deletingLastPathComponent
        let old = umask(077); defer { umask(old) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Empreinte à partir de la parole d'un enregistrement : moyenne des empreintes d'extraits de 3 s.
    static func makeProfile(from speech: [Float]) -> Profile? {
        let size = 48_000
        guard speech.count >= size * 4 else { return nil }
        let chunks = stride(from: 0, to: speech.count - size + 1, by: size).map { Array(speech[$0..<($0 + size)]) }
        var all: [[Float]] = []
        for i in stride(from: 0, to: chunks.count, by: 3) {
            guard let e = embed(Array(chunks[i..<min(i + 3, chunks.count)])) else { return nil }
            all += e
        }
        let mean = normalized((0..<256).map { d in all.reduce(0) { $0 + $1[d] } })
        let selfScore = all.map { cosine($0, mean) }.reduce(0, +) / Float(all.count)
        return Profile(embedding: mean, selfScore: selfScore, createdAt: Date())
    }
}
