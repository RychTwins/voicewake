import Foundation

/// Distingue la voix de lecture (haut-parleurs) de celle de l'utilisateur (micro), sans état global :
/// testable sans micro (tests/reader.swift).
enum VoiceFilter {
    /// La commande entendue est-elle dans ce que la voix lit en ce moment (`spokenNow`) ?
    /// Pas de vérification du mot précédent : la transcription de la voix est souvent déformée
    /// (« puis arrête » → « suite arrête »). L'utilisateur fait passer la commande en la redisant (`Insistence`).
    static func spokenByReader(_ text: String, phrases: [String], spokenNow: String, router: Router) -> Bool {
        guard let hit = router.lastMatch(text, phrases) else { return false }
        return (" " + normalize(spokenNow) + " ").contains(" " + hit.phrase + " ")
    }
}

/// Une commande attribuée à la voix de lecture passe quand la même phrase est redite dans les 6 s :
/// dès la 2e fois si le texte lu à cet instant ne la répète pas, et toujours à la 3e fois.
/// Le contenu lu ne peut donc jamais bloquer l'utilisateur.
struct Insistence {
    static let window: TimeInterval = 6
    private var suppressed: [String: (count: Int, at: Date)] = [:]

    /// `phrase` normalisée. Renvoie true si la commande doit passer cette fois-ci.
    mutating func accept(_ phrase: String, spokenNow: String, now: Date = Date()) -> Bool {
        let previous = suppressed[phrase].flatMap { now.timeIntervalSince($0.at) < Self.window ? $0.count : nil } ?? 0
        let count = previous + 1
        suppressed[phrase] = (count, now)
        let occurrences = (" " + normalize(spokenNow) + " ").components(separatedBy: " " + phrase + " ").count - 1
        let accepted = count >= 3 || (count == 2 && occurrences < 2)
        if accepted { suppressed[phrase] = nil }
        return accepted
    }
}
