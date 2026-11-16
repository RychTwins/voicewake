import Foundation

/// Bilan local des commandes ratées (rien ne correspond, action impossible) : `voicewake bilan` montre les plus
/// fréquentes avec un conseil. Fichier ~/.config/voicewake/bilan.json (lisible par toi seul), jamais envoyé ailleurs.
/// Le texte dicté avec « écris … » n'y est jamais écrit. Désactivable : "failureReport": false.
enum Bilan {
    enum Kind: String, Codable, CaseIterable {
        case universal, skill, nav, command, palette, write, routine, read

        var title: String {
            switch self {
            case .universal: return "menu / bouton"
            case .skill: return "skill"
            case .nav: return "navigation"
            case .command: return "commande"
            case .palette: return "palette / touche"
            case .write: return "écris"
            case .routine: return "routine"
            case .read: return "lis à partir de"
            }
        }

        var advice: String {
            switch self {
            case .universal: return "dire le libellé exact (plus de mots si plusieurs options se ressemblent) ; vérifier avec voicewake trouve <bundle-id> \"menu …\""
            case .skill: return "vérifier le nom avec voicewake skill <cible> \"…\""
            case .nav: return "vérifier les noms avec voicewake barre <cible>"
            case .command: return "mettre l'assistant au premier plan (un message ou un brouillon doit exister)"
            case .palette: return "app autorisée ? raccourci de palette dans paletteShortcuts"
            case .write: return "cliquer d'abord dans un champ de saisie ; app dans universalApps"
            case .routine: return "tester l'étape avec voicewake route \"…\""
            case .read: return "dire 3 ou 4 mots exacts d'un passage visible de la dernière réponse"
            }
        }
    }

    struct Entry: Codable, Equatable {
        var kind: Kind
        var phrase: String
        var count: Int
        var last: Date
    }

    static let maxEntries = 100
    static let maxWords = 8
    static var path = (NSHomeDirectory() as NSString).appendingPathComponent(".config/voicewake/bilan.json")
    static var enabled = true

    static func configure(_ config: Config) { enabled = config.failureReport ?? true }

    /// Phrase gardée : normalisée, 8 mots au plus.
    static func key(_ phrase: String) -> String {
        normalize(phrase).split(separator: " ").prefix(maxWords).joined(separator: " ")
    }

    static func load() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Ajoute un échec (même type et même phrase : le compteur augmente). Au-delà de 100, les plus anciens partent.
    static func record(_ kind: Kind, _ phrase: String, now: Date = Date()) {
        guard enabled else { return }
        let k = key(phrase)
        guard !k.isEmpty else { return }
        var entries = load()
        if let i = entries.firstIndex(where: { $0.kind == kind && $0.phrase == k }) {
            entries[i].count += 1
            entries[i].last = now
        } else {
            entries.append(Entry(kind: kind, phrase: k, count: 1, last: now))
        }
        if entries.count > maxEntries {
            entries = Array(entries.sorted { $0.last > $1.last }.prefix(maxEntries))
        }
        save(entries)
    }

    /// Les plus fréquents d'abord (à égalité : les plus récents).
    static func top(_ entries: [Entry], limit: Int = 15) -> [Entry] {
        Array(entries.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }.prefix(limit))
    }

    static func clear() { try? FileManager.default.removeItem(atPath: path) }
}
