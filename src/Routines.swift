import Foundation

/// Routine vocale : une phrase dite seule enchaîne des commandes vocales existantes (« ouvre voxtv »,
/// « menu afficher le terminal »…), exécutées une à une comme si elles avaient été dites.
struct Routine: Codable {
    /// Nom affiché dans le journal et reconnu par « routine <nom> ».
    var name: String?
    /// Phrases qui lancent la routine, dites seules (ex. « prépare voxtv »).
    var phrases: [String]?
    /// Commandes vocales, dans l'ordre (10 au plus).
    var steps: [String]
    /// Attente entre deux étapes (défaut 1,5 s, entre 0,5 et 10 s).
    var delaySeconds: Double?
}

enum Routines {
    static let maxSteps = 10
    static let defaultDelay = 1.5

    static func delay(_ r: Routine) -> Double { min(10, max(0.5, r.delaySeconds ?? defaultDelay)) }

    static func label(_ r: Routine) -> String { r.name ?? r.phrases?.first ?? "sans nom" }

    /// Routine dont une phrase (ou « routine <nom> ») est toute la phrase dite. Dite seule : une phrase
    /// prononcée au milieu d'un texte (voix de lecture, dictée) ne lance rien.
    static func match(_ text: String, config: Config) -> Routine? {
        let said = normalize(text)
        guard !said.isEmpty else { return nil }
        return (config.routines ?? []).first { r in
            var phrases = r.phrases ?? []
            if let name = r.name { phrases += ["routine \(name)", "lance la routine \(name)"] }
            return phrases.contains { normalize($0) == said }
        }
    }

    /// Erreurs de configuration (vérifiées au chargement).
    static func problems(_ routines: [Routine]) -> [String] {
        var out: [String] = []
        for r in routines {
            let name = label(r)
            if (r.phrases ?? []).allSatisfy({ normalize($0).isEmpty }) && r.name.map({ normalize($0).isEmpty }) ?? true {
                out.append("routine \(name) : ni phrase ni nom.")
            }
            if r.steps.isEmpty { out.append("routine \(name) : aucune étape.") }
            if r.steps.count > maxSteps { out.append("routine \(name) : \(maxSteps) étapes au plus.") }
            if r.steps.contains(where: { normalize($0).isEmpty }) { out.append("routine \(name) : étape vide.") }
        }
        return out
    }
}
