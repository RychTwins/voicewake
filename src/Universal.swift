import AppKit

/// Commandes universelles : n'importe quelle option de menu ou n'importe quel bouton de l'app au premier plan,
/// trouvés par leur libellé. Aucune liste à tenir à jour : VoiceWake lit l'app (Claude, Codex, Gemini, ChatGPT,
/// VS Code, Zed…) au moment où la phrase est dite.
enum Universal {
    enum Kind { case menu, click }

    static let defaultMenuPhrases = ["choisis le menu", "ouvre le menu", "menu"]
    static let defaultClickPhrases = ["appuie sur le bouton", "clique sur le bouton", "clique sur", "appuie sur", "clique"]
    /// Libellé cité : au plus ce nombre de mots.
    static let maxWords = 8

    /// Mots d'une action irréversible ou sensible : jamais exécutée sans confirmation.
    static let dangerWords: Set<String> = [
        "supprimer", "supprime", "suppression", "effacer", "efface", "vider", "vide", "archiver", "archive",
        "deconnecter", "deconnexion", "quitter", "reinitialiser", "desinstaller", "envoyer", "publier", "partager",
        "delete", "remove", "erase", "clear", "empty", "quit", "logout", "signout", "reset", "uninstall", "send", "publish", "share",
    ]

    /// Phrase universelle en début d'énoncé : (type, mots du libellé), ou nil.
    static func match(_ text: String, config: Config) -> (kind: Kind, query: [String])? {
        let words = normalize(text).split(separator: " ").map(String.init)
        func after(_ phrases: [String]) -> [String]? {
            for p in phrases.map(normalize).sorted(by: { $0.count > $1.count }) where !p.isEmpty {
                let pw = p.split(separator: " ").map(String.init)
                guard words.count > pw.count, Array(words.prefix(pw.count)) == pw else { continue }
                let rest = Array(words.dropFirst(pw.count))
                return rest.count <= maxWords ? rest : nil
            }
            return nil
        }
        if let q = after(config.menuPhrases ?? defaultMenuPhrases) { return (.menu, q) }
        if let q = after(config.clickPhrases ?? defaultClickPhrases) { return (.click, q) }
        return nil
    }

    private static let fillers: Set<String> = ["le", "la", "les", "l", "un", "une", "de", "du", "des", "d", "sur", "bouton", "menu"]

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 3
    }

    /// Meilleur libellé : tous les mots cités y sont (petites différences tolérées), le moins de mots en trop,
    /// puis le premier dans l'ordre de l'app. `nil` si rien ne convient.
    static func best<T>(_ query: [String], in candidates: [(title: String, value: T)]) -> (title: String, value: T)? {
        let q = query.filter { !fillers.contains($0) }
        guard !q.isEmpty else { return nil }
        var found: (title: String, value: T, extra: Int)?
        for c in candidates {
            let words = normalize(c.title).split(separator: " ").map(String.init)
            guard q.allSatisfy({ w in words.contains(where: { same($0, w) }) }) || words.joined() == q.joined() else { continue }
            let extra = words.count - q.count
            if found == nil || extra < found!.extra { found = (c.title, c.value, extra) }
        }
        return found.map { ($0.title, $0.value) }
    }

    static func isDangerous(_ title: String) -> Bool {
        let words = normalize(title).split(separator: " ").map(String.init)
        // « Se déconnecter » → « se deconnecter » ; « Sign out » → « signout ».
        let joined = zip(words, words.dropFirst()).map { $0 + $1 }
        return !Set(words + joined).isDisjoint(with: dangerWords)
    }

    /// Action trouvée, prête à être exécutée (après confirmation si `dangerous`).
    struct Action {
        let kind: Kind
        let title: String
        let app: NSRunningApplication
        let element: AXUIElement
        var dangerous: Bool { Universal.isDangerous(title) }

        func perform() -> Bool {
            switch kind {
            case .menu: return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            case .click: return AXButtonPresser.activate(element, in: app)
            }
        }
    }

    /// Cherche l'option ou le bouton dans l'app au premier plan (hors VoiceWake). Appel hors de la file principale.
    static func find(_ kind: Kind, _ query: [String], in app: NSRunningApplication) -> Action? {
        switch kind {
        case .menu:
            let items = AXButtonPresser.allMenuBarItems(in: app).map { (title: $0.title, value: $0.element) }
            return best(query, in: items).map { Action(kind: .menu, title: $0.title, app: app, element: $0.value) }
        case .click:
            let buttons = AXButtonPresser.visibleButtons(in: app).map { (title: $0.title, value: $0.element) }
            return best(query, in: buttons).map { Action(kind: .click, title: $0.title, app: app, element: $0.value) }
        }
    }

    /// App au premier plan, si ce n'est pas VoiceWake lui-même.
    static func frontApp() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }
}
