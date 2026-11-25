import Foundation

/// Erreurs de reconnaissance fréquentes, corrigées avant de chercher une commande (en veille seulement : une
/// dictée n'est jamais modifiée). Relevées en comparant les moteurs de macOS sur les phrases de commande.
enum SpeechFixes {
    static let rules: [(pattern: String, replacement: String)] = [
        ("^ouvrez\\b", "ouvre"),                                              // « Ouvrez Equality Holding »
        ("\\b(lance|lancer|lances|lancez) (le|la|les) (ski|skis|skie|squi|skil)\\b", "$1 le skill"),
        ("\\bnouvelle session (de|des|du|d'un|dans le|dans la)\\b", "nouvelle session dans"),
        ("^(dit|di|dix) (claude|clode|codex|gemini|chatgpt)\\b", "dis $2"),
    ]

    static func apply(_ text: String) -> String {
        var s = text
        for r in Lang.fixes ?? rules {
            guard let re = try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive]) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r.replacement)
        }
        return s
    }
}
