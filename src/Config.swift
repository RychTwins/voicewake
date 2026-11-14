import CoreGraphics
import Foundation

func log(_ message: String) {
    print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
}

/// "Salut, Chat GPT !" -> "salut chat gpt"
func normalize(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .joined(separator: " ")
}

struct ConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Target: Codable {
    var id: String
    var appName: String?
    var bundleID: String?
    var phrases: [String]
    var shortcut: Shortcut
    /// Mettre l'application au premier plan avant le raccourci (inutile pour un raccourci global).
    var activate: Bool?
    /// Attente après le lancement d'une application fermée.
    var launchDelaySeconds: Double?
    /// Envoi vocal : touche d'envoi (défaut "return").
    var submitShortcut: Shortcut?
    /// Couper le micro de l'app avant l'envoi (défaut true).
    var stopBeforeSubmit: Bool?
    /// Raccourci qui coupe le micro de l'app (défaut : `shortcut`). Ex. "button:Arrêter la dictée".
    var stopShortcut: Shortcut?
    /// Après un envoi vocal : bouton de lecture à cliquer quand la réponse est finie. Ex. "button:Lire à voix haute".
    var readAloudShortcut: Shortcut?
    /// Option à choisir dans le menu ouvert par readAloudShortcut (ex. Gemini : « Autres actions » puis « Écouter »).
    var readAloudMenuItem: String?
    /// Libellés visibles tant que l'assistant répond (ex. "Arrêter"). Optionnel.
    var busyLabels: [String]?
    /// Attente maximale de la fin de la réponse (défaut 600 s).
    var readAloudTimeoutSeconds: Double?
    /// Met la lecture à voix haute en pause (ex. "button:Pause"), avant de rouvrir le micro.
    var pauseReadShortcut: Shortcut?
    /// Attente entre l'arrêt du micro et l'envoi, le temps que le texte s'affiche (défaut 1,5 s).
    var submitDelaySeconds: Double?
}

/// Un assistant intégré à un éditeur (ex. extension Claude Code dans VS Code).
struct EditorAssistant: Codable {
    var shortcut: Shortcut
    var stopShortcut: Shortcut?
    var submitShortcut: Shortcut?
    var readAloudShortcut: Shortcut?
    var busyLabels: [String]?
    var pauseReadShortcut: Shortcut?
}

/// Éditeur de code : s'il est au premier plan, « Dis Claude » vise l'assistant intégré plutôt que l'app de bureau.
struct Editor: Codable {
    var id: String
    var bundleIDs: [String]
    /// Clé = id de la cible (claude, codex, gemini…).
    var assistants: [String: EditorAssistant]
}

struct ConversationSettings: Codable {
    /// Temps laissé à l'assistant pour ouvrir le micro après le déclenchement.
    var startGraceSeconds: Double
    /// Micro libre pendant ce temps = conversation terminée.
    var idleSecondsBeforeResume: Double
    /// Sécurité : reprise forcée après cette durée.
    var maxPauseMinutes: Double
}

struct Config: Codable {
    var locale: String
    var requireOnDevice: Bool
    var cooldownSeconds: Double
    var debug: Bool
    var conversation: ConversationSettings
    /// Phrases qui visent l'application au premier plan.
    var frontmostPhrases: [String]
    /// Cible si l'application au premier plan n'est pas une cible.
    var defaultTarget: String?
    /// Phrases d'envoi dites en fin de dictée (« ok envoie »). Vide ou absent = pas d'envoi vocal.
    var sendPhrases: [String]?
    /// Pause minimale (s) avant « ok envoie » / « ok arrête » : évite l'envoi quand la phrase est citée en pleine phrase. 0 = désactivé.
    var sendPauseBeforeSeconds: Double?
    /// Phrases qui coupent seulement le micro (« ok arrête ») pour relire avant « ok envoie ».
    var stopPhrases: [String]?
    /// Silence après la phrase d'envoi ou d'arrêt avant d'agir (défaut 1,2 s).
    var sendSilenceSeconds: Double?
    /// Pendant la lecture à voix haute d'un assistant : interrompt la lecture et rouvre son micro.
    var interruptPhrases: [String]?
    /// Après « ok arrête », durée d'attente de « ok envoie » (défaut 180 s).
    var reviewSeconds: Double?
    var targets: [Target]
    /// Éditeurs de code avec assistants intégrés (prioritaires quand ils sont au premier plan).
    var editors: [Editor]?

    static func defaultPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/voicewake/config.json")
    }

    static func load(path: String) throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    func validate() throws {
        guard !targets.isEmpty else { throw ConfigError("Aucune cible définie.") }
        var ids = Set<String>()
        for t in targets {
            guard ids.insert(t.id).inserted else { throw ConfigError("Cible en double : \(t.id)") }
            guard t.appName != nil || t.bundleID != nil else {
                throw ConfigError("\(t.id) : appName ou bundleID requis.")
            }
            guard !t.phrases.isEmpty else { throw ConfigError("\(t.id) : aucune phrase.") }
        }
        if let d = defaultTarget, !ids.contains(d) {
            throw ConfigError("defaultTarget inconnue : \(d)")
        }
    }

    func target(id: String) -> Target? { targets.first { $0.id == id } }

    /// Remplace le raccourci d'une cible en gardant le reste du fichier.
    static func saveShortcut(_ shortcut: Shortcut, targetID: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var targets = root["targets"] as? [[String: Any]],
              let i = targets.firstIndex(where: { $0["id"] as? String == targetID })
        else { throw ConfigError("Cible introuvable : \(targetID)") }
        targets[i]["shortcut"] = shortcut.spec
        root["targets"] = targets
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        _ = try load(path: path) // revalide
    }
}
