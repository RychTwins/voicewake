import Foundation

/// Interpréteur IA (optionnel, désactivé par défaut) : « Jarvis, <phrase libre> » que VoiceWake ne comprend pas
/// est envoyée à Claude, qui la reformule en UNE commande VoiceWake connue (ou rien). La commande reformulée passe
/// ensuite par le traitement normal : mêmes vérifications, mêmes confirmations pour les actions sensibles.
/// Seule la phrase dite après le nom d'appel (et le nom de l'app au premier plan) part chez Anthropic.
struct InterpreterSettings: Codable {
    var enabled: Bool?
    /// Modèle (défaut claude-haiku-5-5 : rapide et économique).
    var model: String?
    /// Fichier contenant la ligne ANTHROPIC_API_KEY=… (défaut ~/.config/voicewake/anthropic.env).
    /// La clé n'est jamais écrite dans la configuration.
    var keyFile: String?
    /// Délai maximal de la requête (défaut 8 s).
    var timeoutSeconds: Double?
}

enum Interpreter {
    static let defaultModel = "claude-haiku-5-5"

    static func apiKey(_ s: InterpreterSettings) -> String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        let path = (s.keyFile ?? "~/.config/voicewake/anthropic.env") as NSString
        guard let content = try? String(contentsOfFile: path.expandingTildeInPath, encoding: .utf8) else { return nil }
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].replacingOccurrences(of: "export ", with: "") == "ANTHROPIC_API_KEY" else { continue }
            let key = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return key.isEmpty ? nil : key
        }
        return nil
    }

    /// Commandes que le modèle peut produire (formes exactes reconnues par VoiceWake).
    static let catalog = """
    Applications : « ouvre <app> », « bascule sur <app> », « ferme <app> », « cache <app> », « minimise la fenêtre », \
    « plein écran », « ferme la fenêtre ».
    Son et écran : « monte le son », « baisse le son », « coupe le son », « remets le son », « volume <0-100> », \
    « augmente la luminosité », « baisse la luminosité », « capture d'écran ».
    Musique : « morceau suivant », « morceau précédent », « pause », « lecture », « cherche <titre> sur spotify », \
    « cherche <titre> sur youtube », « joue <titre> dans musique », « quelle est cette chanson », « lecture aléatoire ».
    Navigateur : « va sur <site> », « cherche <requête> sur google », « nouvel onglet », « ferme l'onglet », \
    « onglet suivant », « onglet précédent », « recharge la page », « page précédente », « page suivante », \
    « zoom avant », « zoom arrière », « descends », « remonte », « tout en haut », « tout en bas », \
    « cherche dans la page <texte> », « ajoute aux favoris », « navigation privée ».
    Finder : « va dans <dossier> », « copie dans <dossier> », « déplace dans <dossier> », « mets à la corbeille », \
    « vide la corbeille », « renomme en <nom> », « nouveau dossier <nom> ».
    Réglages : « ouvre les réglages du <volet> » (son, wifi, bluetooth, écran, clavier, batterie, notifications…), \
    « active le wifi », « coupe le wifi », « mode sombre », « mode clair ».
    Menus et boutons de l'app devant : « menu <nom> », « clique sur <libellé> ».
    Saisie : « écris <texte> ».
    """

    static func system(front: String?, extra: [String]) -> String {
        var s = """
        Tu traduis une phrase dite à voix haute (en français, transcrite par reconnaissance vocale, avec de possibles \
        fautes) en UNE commande de l'assistant vocal VoiceWake sur macOS. Réponds avec la commande exacte, en français, \
        dans l'une des formes ci-dessous, en remplaçant <…> par la valeur dite. Si la phrase ne correspond clairement à \
        aucune commande, ou demande plusieurs actions, réponds une commande vide. N'invente jamais d'action.

        \(catalog)
        """
        if !extra.isEmpty { s += "\nAutres phrases reconnues : " + extra.prefix(60).map { "« \($0) »" }.joined(separator: ", ") + "." }
        if let front { s += "\nApplication au premier plan : \(front)." }
        return s
    }

    static func body(text: String, model: String, front: String?, extra: [String]) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 1024,
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": ["command": ["type": "string"]],
                        "required": ["command"],
                        "additionalProperties": false,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "system": system(front: front, extra: extra),
            "messages": [["role": "user", "content": text]],
        ]
    }

    /// Commande renvoyée par l'API (vide = rien), sinon nil si la réponse est inexploitable.
    static func parse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["stop_reason"] as? String) == "end_turn",
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let command = inner["command"] as? String else { return nil }
        return command.trimmingCharacters(in: CharacterSet(charactersIn: " .!?«»\"\n"))
    }

    /// Appel hors fil principal ; `done(commande, détail)` sur le fil principal.
    static func interpret(_ text: String, settings s: InterpreterSettings, front: String?, extra: [String],
                          done: @escaping (String?, String) -> Void) {
        func finish(_ c: String?, _ d: String) { DispatchQueue.main.async { done(c, d) } }
        guard let key = apiKey(s) else { return finish(nil, "clé ANTHROPIC_API_KEY introuvable") }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let payload = try? JSONSerialization.data(withJSONObject: body(text: text, model: s.model ?? defaultModel,
                                                                              front: front, extra: extra)) else {
            return finish(nil, "requête invalide")
        }
        var req = URLRequest(url: url, timeoutInterval: s.timeoutSeconds ?? 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = payload
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return finish(nil, "réseau : \(err.localizedDescription)") }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else { return finish(nil, "HTTP \(status)") }
            guard let c = parse(data) else { return finish(nil, "réponse inexploitable") }
            finish(c, "ok")
        }.resume()
    }
}
