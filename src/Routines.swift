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
    /// Heure de lancement automatique, « HH:mm » (ex. « 09:00 ») ; sans heure, seulement à la voix.
    var at: String?
    /// Jours de lancement automatique : 1 = lundi … 7 = dimanche (défaut : du lundi au vendredi).
    var days: [Int]?
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
    /// « HH:mm » valide → (heure, minute).
    static func time(_ at: String) -> (Int, Int)? {
        let p = at.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) else { return nil }
        return (p[0], p[1])
    }

    /// Routines prévues à cette minute-là.
    static func due(_ routines: [Routine], at date: Date, calendar: Calendar = .current) -> [Routine] {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let isoDay = ((c.weekday ?? 1) + 5) % 7 + 1 // dimanche = 1 → 7, lundi = 2 → 1
        return routines.filter { r in
            guard let at = r.at, let (h, m) = time(at), h == c.hour, m == c.minute else { return false }
            return (r.days ?? [1, 2, 3, 4, 5]).contains(isoDay)
        }
    }

    static func problems(_ routines: [Routine]) -> [String] {
        var out: [String] = []
        for r in routines {
            let name = label(r)
            if let at = r.at, time(at) == nil { out.append("routine \(name) : heure « \(at) » invalide (HH:mm).") }
            if let d = r.days, d.isEmpty || d.contains(where: { !(1...7).contains($0) }) { out.append("routine \(name) : jours de 1 (lundi) à 7.") }
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
