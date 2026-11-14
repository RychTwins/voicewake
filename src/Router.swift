import AppKit

/// Associe une transcription à une cible.
struct Router {
    let config: Config
    private let targetPhrases: [(phrase: String, id: String)]
    private let frontmostPhrases: [String]

    init(config: Config) {
        self.config = config
        // Les phrases les plus longues d'abord : "salut chatgpt" avant "salut chat".
        self.targetPhrases = config.targets
            .flatMap { t in t.phrases.map { (normalize($0), t.id) } }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        self.frontmostPhrases = config.frontmostPhrases.map(normalize).filter { !$0.isEmpty }
    }

    /// Mots soufflés au moteur pour mieux reconnaître les noms propres.
    var hints: [String] {
        Array(Set(config.targets.flatMap(\.phrases) + config.frontmostPhrases))
    }

    func route(_ text: String) -> Target? {
        let n = normalize(text)
        if let hit = targetPhrases.first(where: { n.contains($0.phrase) }) {
            return config.target(id: hit.id)
        }
        if frontmostPhrases.contains(where: { n.contains($0) }) {
            return frontmostTarget()
        }
        return nil
    }

    /// Vrai si la transcription se termine par une phrase d'envoi.
    func endsWithSendPhrase(_ text: String) -> Bool { endsWith(text, config.sendPhrases) }

    /// Vrai si la transcription se termine par une phrase d'arrêt du micro.
    func endsWithStopPhrase(_ text: String) -> Bool { endsWith(text, config.stopPhrases) }

    /// Vrai si la transcription contient une phrase d'interruption de la lecture.
    func containsInterruptPhrase(_ text: String) -> Bool {
        let n = normalize(text)
        return (config.interruptPhrases ?? []).map(normalize).contains { !$0.isEmpty && n.contains($0) }
    }

    private func endsWith(_ text: String, _ phrases: [String]?) -> Bool { suffix(text, phrases) != nil }

    /// Ce qui précède la phrase finale (texte normalisé), ou nil si la phrase n'y est pas.
    func bodyBeforeCommand(_ text: String) -> String? {
        guard let p = suffix(text, (config.sendPhrases ?? []) + (config.stopPhrases ?? [])) else { return nil }
        return String(normalize(text).dropLast(p.count))
    }

    /// La plus longue phrase normalisée qui termine le texte.
    private func suffix(_ text: String, _ phrases: [String]?) -> String? {
        let n = normalize(text)
        return (phrases ?? []).map(normalize).filter { !$0.isEmpty && n.hasSuffix($0) }.max { $0.count < $1.count }
    }

    func frontmostTarget() -> Target? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let t = config.targets.first(where: { ShortcutTrigger.matches(front, $0) }) {
            return t
        }
        if let d = config.defaultTarget { return config.target(id: d) }
        log("Phrase générale : aucune cible au premier plan et pas de defaultTarget.")
        return nil
    }
}
