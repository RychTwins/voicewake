import Foundation

enum DictatedContent {
    case empty, ready, paused, held

    mutating func heardContent() {
        if self != .held { self = .ready }
    }

    func shouldSend(
        now: TimeInterval, startedAt: TimeInterval, lastBuffer: TimeInterval,
        lastSpeech: TimeInterval, delay: TimeInterval
    ) -> Bool {
        self == .ready && delay > 0 && lastSpeech >= startedAt &&
            now - lastBuffer < 0.5 && now - lastSpeech >= delay
    }
}

/// Fin de tour naturelle : le silence attendu avant l'envoi automatique dépend de la façon dont la phrase se
/// termine. Une question ou une phrase complète part vite ; une phrase en suspens (« … et », « euh », « parce que »)
/// laisse le temps de réfléchir.
enum TurnEnd {
    /// Mots après lesquels la phrase n'est manifestement pas finie.
    static var continuation: Set<String> {
        Set(Lang.list("turnEnd.continuation", [
        "et", "ou", "mais", "donc", "alors", "puis", "ensuite", "car", "parce", "que", "qui", "dont", "si",
        "euh", "heu", "bah", "ben", "genre", "enfin", "bref", "comme", "quand", "pour", "avec", "sans", "dans", "sur",
        "de", "du", "des", "le", "la", "les", "l", "un", "une", "au", "aux", "ce", "cette", "ces", "mon", "ma", "mes",
        "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre", "leur", "leurs", "je", "tu", "il", "elle", "on",
        "nous", "vous", "ils", "elles", "est", "sont", "c", "d", "j", "qu", "s", "n", "m", "t", "à", "a", "en", "par",
    ]))
    }
    static var questionStarts: [String] {
        Lang.list("turnEnd.questionStarts", ["est ce que", "est ce qu", "comment", "pourquoi", "quand", "qui", "quel", "quelle",
                                 "quels", "quelles", "combien", "ou est", "peux tu", "tu peux", "pourrais tu",
                                 "tu pourrais", "c est quoi", "qu est ce"])
    }

    enum Kind: Equatable { case question, complete, unfinished }

    static func kind(of text: String) -> Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = normalize(trimmed)
        guard let last = n.split(separator: " ").last.map(String.init) else { return .unfinished }
        if continuation.contains(last) || trimmed.hasSuffix("…") || trimmed.hasSuffix(",") { return .unfinished }
        // Dernière phrase seulement (« J'ai fini. Tu peux regarder ? »).
        let sentence = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!")).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? trimmed
        let s = normalize(sentence)
        if trimmed.hasSuffix("?") || questionStarts.contains(where: { s.hasPrefix($0 + " ") }) { return .question }
        return .complete
    }

    /// Silence à attendre (s) ; `base` = autoSendSilenceSeconds.
    static func delay(for text: String, base: Double) -> Double {
        switch kind(of: text) {
        case .question: return max(0.8, base * 0.6)
        case .complete: return base
        case .unfinished: return max(3.5, base * 2.3)
        }
    }
}
