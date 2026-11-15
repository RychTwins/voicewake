import AppKit

/// Commande vocale d'une application : phrases → commande de la barre de menus ou bouton (libellés exacts).
struct VoiceCommand: Codable {
    var phrases: [String]
    /// Commandes de menu essayées dans l'ordre (ex. ["Session précédente", "Previous Session"]).
    var menu: [String]?
    /// Boutons de la fenêtre essayés si aucun menu ne convient (ex. ["Artéfacts", "Artifacts"]).
    var buttons: [String]?
}

/// Ce qu'une phrase demande à l'application au premier plan.
enum NavRequest {
    case command(VoiceCommand)
    /// « Ouvre Equality Holding » : projet ou session de la barre latérale.
    case open([String])
    /// « Nouvelle session dans VoxTV ».
    case newSessionIn([String])
}

/// Navigation à la voix dans l'application (Claude par défaut) : menus, barre latérale, projets.
/// Les phrases doivent terminer la transcription (dites seules) : une phrase ordinaire qui les contient
/// au milieu ne déclenche rien.
enum NavCommands {
    static let defaultOpenPhrases = ["ouvre le projet", "ouvre la session", "ouvre la conversation", "va dans le projet", "ouvre"]
    /// Nom cité après « ouvre » : au plus ce nombre de mots.
    static let maxNameWords = 8
    static let defaultNewSessionInPhrases = ["nouvelle session dans", "nouvelle conversation dans", "nouvelle session pour"]

    /// Commandes de l'application Claude (libellés relevés dans ses menus et sa barre latérale, FR et EN).
    static let claude: [VoiceCommand] = [
        VoiceCommand(phrases: ["page précédente", "retour en arrière"], menu: ["Retour", "Back"]),
        VoiceCommand(phrases: ["page suivante"], menu: ["Avancer", "Forward"]),
        VoiceCommand(phrases: ["conversation précédente", "session précédente"],
                     menu: ["Session précédente", "Conversation précédente", "Previous Session", "Previous Conversation"]),
        VoiceCommand(phrases: ["conversation suivante", "session suivante"],
                     menu: ["Session suivante", "Conversation suivante", "Next Session", "Next Conversation"]),
        VoiceCommand(phrases: ["rouvre la session", "rouvre la conversation"],
                     menu: ["Rouvrir la session fermée", "Rouvrir la conversation fermée", "Reopen Closed Session"]),
        VoiceCommand(phrases: ["ouvre la recherche", "cherche une conversation", "recherche une conversation"],
                     buttons: ["Rechercher", "Search"]),
        VoiceCommand(phrases: ["ouvre les artéfacts", "mes artéfacts", "ouvre les artefacts"],
                     buttons: ["Artéfacts", "Artefacts", "Artifacts"]),
        VoiceCommand(phrases: ["ouvre la personnalisation", "personnalisation"],
                     buttons: ["Personnalisation", "Personalization", "Customize"]),
        VoiceCommand(phrases: ["ouvre créer", "menu créer"], buttons: ["Créer", "Create"]),
        VoiceCommand(phrases: ["palette de commandes", "ouvre la palette"], menu: ["Palette de commandes…", "Command Palette…"]),
        VoiceCommand(phrases: ["masque la barre latérale", "cache la barre latérale"],
                     menu: ["Masquer la barre latérale", "Hide Sidebar"]),
        VoiceCommand(phrases: ["affiche la barre latérale", "montre la barre latérale"],
                     menu: ["Afficher la barre latérale", "Show Sidebar"]),
        VoiceCommand(phrases: ["mode code", "passe en mode code", "va dans code"], menu: ["Code"]),
        VoiceCommand(phrases: ["mode discussion", "mode chat", "passe en mode discussion"], menu: ["Claude", "Chat"]),
        VoiceCommand(phrases: ["ouvre les paramètres", "ouvre les réglages"], menu: ["Paramètres…", "Settings…"]),
        VoiceCommand(phrases: ["affiche le terminal", "ouvre le terminal"], menu: ["Afficher le terminal", "Show Terminal"]),
        VoiceCommand(phrases: ["affiche les fichiers"], menu: ["Afficher les fichiers", "Show Files"]),
        VoiceCommand(phrases: ["affiche les modifications"], menu: ["Afficher les modifications", "Show Changes"]),
        VoiceCommand(phrases: ["affiche le navigateur"], menu: ["Afficher le navigateur", "Show Browser"]),
        VoiceCommand(phrases: ["ferme le volet", "ferme le panneau"], menu: ["Fermer le volet", "Close Pane"]),
        VoiceCommand(phrases: ["zoom avant", "agrandis le texte"], menu: ["Zoomer", "Zoom In"]),
        VoiceCommand(phrases: ["zoom arrière", "réduis le texte"], menu: ["Zoom arrière", "Zoom Out"]),
        VoiceCommand(phrases: ["taille normale", "taille réelle"], menu: ["Taille réelle", "Actual Size"]),
        VoiceCommand(phrases: ["plein écran"], menu: ["Passer en plein écran", "Enter Full Screen"]),
        VoiceCommand(phrases: ["raccourcis clavier"], menu: ["Raccourcis clavier", "Keyboard Shortcuts"]),
    ]

    static func commands(for t: Target) -> [VoiceCommand] {
        t.voiceCommands ?? (t.bundleID == "com.anthropic.claudefordesktop" ? claude : [])
    }

    /// Phrase de navigation qui termine la transcription, pour la cible `t` (ou n'importe quelle cible si nil).
    static func match(_ text: String, target t: Target?, config: Config) -> NavRequest? {
        let n = normalize(text)
        guard !n.isEmpty else { return nil }
        let words = n.split(separator: " ").map(String.init)
        // « Nouvelle session dans X » / « Ouvre X » : la phrase doit ouvrir l'énoncé (le moteur repart d'une
        // transcription vide après chaque pause), suivie d'un nom court. « Il faut que j'ouvre la porte » ou
        // une phrase lue à voix haute qui contient « ouvre » au milieu ne déclenchent donc rien.
        func query(after phrases: [String]) -> [String]? {
            var best: [String]?
            for p in phrases.map(normalize) where !p.isEmpty {
                let pw = p.split(separator: " ").map(String.init)
                guard words.count > pw.count, Array(words.prefix(pw.count)) == pw else { continue }
                let rest = Array(words.dropFirst(pw.count))
                guard rest.count <= maxNameWords else { continue }
                if best == nil || rest.count < best!.count { best = rest }
            }
            return best
        }
        // Commandes fixes d'abord : « ouvre les paramètres » n'est pas « ouvre <projet> ».
        let fixed = t.map(commands(for:)) ?? config.targets.flatMap(commands(for:))
        for c in fixed {
            if c.phrases.map(normalize).contains(where: { !$0.isEmpty && (n == $0 || n.hasSuffix(" " + $0)) }) { return .command(c) }
        }
        if let q = query(after: config.newSessionInPhrases ?? defaultNewSessionInPhrases), !q.isEmpty { return .newSessionIn(q) }
        if let q = query(after: config.openPhrases ?? defaultOpenPhrases), !q.isEmpty { return .open(q) }
        return nil
    }

    /// Mots vides retirés du nom cité (« ouvre le projet VoxTV » → « voxtv »).
    static let fillers: Set<String> = ["le", "la", "les", "l", "de", "du", "des", "d", "un", "une", "mon", "ma", "mes",
                                       "projet", "session", "conversation", "discussion", "dossier", "s'il", "te", "plait"]

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 2
    }

    /// Entrée de la barre latérale dont le titre contient tous les mots cités (petites différences tolérées).
    /// Priorité : correspondance la plus serrée (moins de mots en trop), puis projet, puis ordre de l'écran.
    static func bestEntry(_ query: [String], in entries: [AXButtonPresser.SidebarEntry],
                          kinds: Set<AXButtonPresser.SidebarEntry.Kind>) -> AXButtonPresser.SidebarEntry? {
        let q = query.filter { !fillers.contains($0) }
        guard !q.isEmpty else { return nil }
        var best: (entry: AXButtonPresser.SidebarEntry, extra: Int, rank: Int)?
        for e in entries where kinds.contains(e.kind) {
            var title = normalize(e.title).split(separator: " ").map(String.init)
            if e.kind == .newSession { title = title.filter { !["nouvelle", "session", "dans", "new", "in"].contains($0) } }
            // Tous les mots cités, ou le nom collé (« equality erp » ↔ « equality-erp »).
            let joined = title.joined()
            guard q.allSatisfy({ w in title.contains(where: { same($0, w) }) }) || joined == q.joined() else { continue }
            let extra = title.count - q.count
            let rank = e.kind == .project ? 0 : 1
            if best == nil || extra < best!.extra || (extra == best!.extra && rank < best!.rank) { best = (e, extra, rank) }
        }
        return best?.entry
    }

    /// Exécute la demande dans l'app au premier plan. `completion(réussi, détail)` sur la file principale.
    static func run(_ request: NavRequest, target t: Target, completion: @escaping (Bool, String) -> Void) {
        let done = { (ok: Bool, detail: String) in DispatchQueue.main.async { completion(ok, detail) } }
        guard let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) else {
            return done(false, "\(t.id) n'est pas au premier plan")
        }
        DispatchQueue.global().async {
            switch request {
            case let .command(c):
                if let menu = c.menu, let chosen = AXButtonPresser.pressMenuBarItem(menu, in: app) {
                    return done(true, "menu « \(chosen) »")
                }
                if let buttons = c.buttons, let pressed = AXButtonPresser.press(buttons, in: app, window: AXButtonPresser.currentWindow(in: app)) {
                    return done(true, "bouton « \(pressed) »")
                }
                let labels = ((c.menu ?? []) + (c.buttons ?? [])).joined(separator: " | ")
                done(false, "introuvable : \(labels)")

            case let .newSessionIn(q):
                let entries = AXButtonPresser.sidebarEntries(in: app)
                guard let e = bestEntry(q, in: entries, kinds: [.newSession]) else {
                    return done(false, "aucun projet « \(q.joined(separator: " ")) » dans la barre latérale")
                }
                done(AXButtonPresser.activate(e.element, in: app), "« \(e.title) »")

            case let .open(q):
                let entries = AXButtonPresser.sidebarEntries(in: app)
                guard let e = bestEntry(q, in: entries, kinds: [.project, .session]) else {
                    return done(false, "rien ne correspond à « \(q.joined(separator: " ")) » dans la barre latérale")
                }
                // Projet : sa session la plus récente (la première listée), sinon une nouvelle session dedans.
                if e.kind == .project {
                    let inProject = entries.filter { $0.project == e.title }
                    if let first = inProject.first(where: { $0.kind == .session }) {
                        return done(AXButtonPresser.activate(first.element, in: app), "projet « \(e.title) », session « \(first.title) »")
                    }
                    if let fresh = inProject.first(where: { $0.kind == .newSession }) {
                        return done(AXButtonPresser.activate(fresh.element, in: app), "projet « \(e.title) », nouvelle session")
                    }
                }
                done(AXButtonPresser.activate(e.element, in: app), "« \(e.title) »")
            }
        }
    }
}
