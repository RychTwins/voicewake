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
        // Français
        "supprimer", "supprime", "suppression", "effacer", "efface", "vider", "vide", "corbeille", "archiver", "archive",
        "deconnecter", "deconnexion", "quitter", "reinitialiser", "desinstaller", "envoyer", "publier", "partager",
        "autoriser", "approuver", "accepter", "confirmer", "valider", "rejeter", "refuser", "revoquer", "abandonner",
        "ignorer", "ecraser", "remplacer", "payer", "acheter", "souscrire", "abonner", "redemarrer", "desactiver",
        "fusionner", "pousser", "deplacer", "transferer", "fermer",
        // Anglais
        "delete", "remove", "erase", "clear", "empty", "trash", "archive", "quit", "logout", "signout", "reset",
        "uninstall", "send", "publish", "share", "allow", "approve", "accept", "confirm", "reject", "deny", "revoke",
        "discard", "overwrite", "replace", "pay", "buy", "purchase", "subscribe", "restart", "disable", "merge", "push",
        "move", "transfer", "close",
    ]

    static let defaultConfirmPhrases = ["oui", "je confirme", "confirme", "oui vas y", "oui confirme"]
    static let defaultCancelPhrases = ["non", "annule", "laisse tomber", "non merci"]
    /// Délai pour confirmer une action sensible.
    static let confirmSeconds: TimeInterval = 8

    enum Answer { case confirm, cancel }

    /// Réponse à une demande de confirmation : l'énoncé entier doit être la phrase (« oui », « non »…).
    static func answer(_ text: String, config: Config) -> Answer? {
        let n = normalize(text)
        if (config.confirmPhrases ?? defaultConfirmPhrases).map(normalize).contains(n) { return .confirm }
        if (config.cancelPhrases ?? defaultCancelPhrases).map(normalize).contains(n) { return .cancel }
        return nil
    }

    /// Question posée à voix haute : jamais de phrase de réponse dedans (VoiceWake entend sa propre annonce).
    static func confirmationPrompt(_ title: String, config: Config) -> String {
        let answers = Set(((config.confirmPhrases ?? defaultConfirmPhrases) + (config.cancelPhrases ?? defaultCancelPhrases)).map(normalize))
        let safe = normalize(title).split(separator: " ").contains { answers.contains(String($0)) } ? "cette action" : "« \(title) »"
        return "Confirmer \(safe) ?"
    }

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

    /// Libellé visé, seulement s'il est clairement désigné : correspondance exacte (aux mots vides près) et unique,
    /// ou bien seul libellé qui contient tous les mots cités (petites différences tolérées). Sinon nil : on n'agit
    /// pas sur une phrase vague (« menu afficher ») ou ambiguë.
    static func best<T>(_ query: [String], in candidates: [(title: String, value: T)]) -> (title: String, value: T)? {
        let q = query.filter { !fillers.contains($0) }
        guard !q.isEmpty else { return nil }
        var exact: [(title: String, value: T)] = [], partial: [(title: String, value: T)] = []
        for c in candidates {
            let words = normalize(c.title).split(separator: " ").map(String.init).filter { !fillers.contains($0) }
            guard q.allSatisfy({ w in words.contains(where: { same($0, w) }) }) || words.joined() == q.joined() else { continue }
            if words.count == q.count || words.joined() == q.joined() { exact.append(c) } else { partial.append(c) }
        }
        func unique(_ list: [(title: String, value: T)]) -> (title: String, value: T)? {
            guard let first = list.first else { return nil }
            return list.allSatisfy({ normalize($0.title) == normalize(first.title) }) ? first : nil
        }
        if !exact.isEmpty { return unique(exact) }
        return unique(partial)
    }

    /// Action sensible si le libellé, ou le chemin de menu qui y mène (« Dépannage > … »), contient un mot à risque.
    static func isDangerous(_ title: String, path: String = "") -> Bool {
        if !path.isEmpty, isDangerous(path) { return true }
        return isDangerousLabel(title)
    }

    private static func isDangerousLabel(_ title: String) -> Bool {
        let words = normalize(title).split(separator: " ").map(String.init)
        // « Se déconnecter » → « se deconnecter » ; « Sign out » → « signout ».
        let joined = zip(words, words.dropFirst()).map { $0 + $1 }
        return !Set(words + joined).isDisjoint(with: dangerWords)
    }

    /// Action trouvée, prête à être exécutée (après confirmation si `dangerous`).
    struct Action {
        let kind: Kind
        let title: String
        var path: String = ""
        let app: NSRunningApplication
        let element: AXUIElement
        var dangerous: Bool { Universal.isDangerous(title, path: path) }

        /// Revérifie juste avant d'agir : même app au premier plan, élément toujours là, actif et au même libellé,
        /// et pas devenu sensible (sauf confirmation déjà donnée).
        func perform(confirmed: Bool = false) -> Bool {
            guard Universal.frontApp()?.processIdentifier == app.processIdentifier else { return false }
            let now = AXButtonPresser.currentLabel(of: element)
            guard now.enabled, let label = now.label, normalize(label) == normalize(title) else { return false }
            if !confirmed, Universal.isDangerous(label, path: path) { return false }
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
            let items = AXButtonPresser.allMenuBarItems(in: app).map { (title: $0.title, value: ($0.element, $0.path)) }
            return best(query, in: items).map { Action(kind: .menu, title: $0.title, path: $0.value.1, app: app, element: $0.value.0) }
        case .click:
            let buttons = AXButtonPresser.visibleButtons(in: app).map { (title: $0.title, value: $0.element) }
            return best(query, in: buttons).map { Action(kind: .click, title: $0.title, app: app, element: $0.value) }
        }
    }

    /// Éditeurs de code acceptés en plus des cibles et éditeurs de la configuration.
    static let defaultApps = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "dev.zed.Zed", "dev.zed.Zed-Preview",
                              "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]

    /// Applications pilotables par les commandes universelles : cibles, éditeurs configurés, éditeurs connus,
    /// et `universalApps` (liste blanche) : jamais une app quelconque.
    static func allowedApps(_ config: Config) -> Set<String> {
        Set(config.targets.compactMap(\.bundleID) + (config.editors ?? []).flatMap(\.bundleIDs)
            + (config.universalApps ?? defaultApps))
    }

    /// App au premier plan, si ce n'est pas VoiceWake lui-même.
    static func frontApp() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }
}
