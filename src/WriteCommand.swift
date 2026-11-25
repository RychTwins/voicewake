import Foundation

/// « Écris rendez-vous demain à 10 h » : tape le texte dans le champ qui a le focus, dans une app autorisée
/// (cibles, éditeurs, `universalApps`), sans ouvrir le micro d'un assistant.
enum WriteCommand {
    /// « écrit » : le moteur transcrit souvent « écris » ainsi.
    static var defaultPhrases: [String] { Lang.t(["écris", "écrit", "tape le texte"]) }

    /// Nombre de mots normalisés de la phrase d'activation (en début d'énoncé, suivie d'au moins un mot), sinon nil.
    static func request(_ text: String, config: Config) -> Int? {
        let words = normalize(text).split(separator: " ").map(String.init)
        for p in (config.writePhrases ?? defaultPhrases).map(normalize).sorted(by: { $0.count > $1.count }) where !p.isEmpty {
            let pw = p.split(separator: " ").map(String.init)
            if words.count > pw.count, Array(words.prefix(pw.count)) == pw { return pw.count }
        }
        return nil
    }

    /// Texte d'origine à taper (accents, majuscules, ponctuation), sans la phrase d'activation ni « : » en tête.
    static func text(_ said: String, phraseWords: Int) -> String {
        let tail = SkillCatalog.originalSlice(said, skippingWords: phraseWords, droppingLastWords: 0)
        return String(tail.drop(while: { $0 == ":" || $0 == "," || $0 == " " }))
    }
}
