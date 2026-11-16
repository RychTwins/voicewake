import AppKit

/// Navigateurs à la voix (Safari, Chrome, Comet, Arc, Brave, Edge, Firefox) : onglets, pages, zoom, favoris,
/// recherche dans la page ; « va sur github.com » et « cherche … sur Google » depuis n'importe quelle app.
enum BrowserCommand: Equatable {
    case keys(String, String)        // raccourci, libellé
    case findInPage(String)          // texte d'origine
    case open(URL)

    /// Raccourcis : navigateur au premier plan requis.
    var needsBrowserFront: Bool { if case .open = self { return false }; return true }

    var title: String {
        switch self {
        case let .keys(_, label): return label
        case .findInPage: return "recherche dans la page"
        case .open: return "ouvrir une page"
        }
    }
}

enum BrowserCommands {
    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "ai.perplexity.comet", "company.thebrowser.Browser",
                                        "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera"]

    static let keys: [(phrases: [String], spec: String, label: String)] = [
        (["nouvel onglet", "ouvre un nouvel onglet", "ouvre un onglet"], "cmd+t", "nouvel onglet"),
        (["ferme l onglet", "ferme cet onglet", "ferme l onglet actuel"], "cmd+w", "fermer l'onglet"),
        (["onglet suivant", "va a l onglet suivant"], "ctrl+tab", "onglet suivant"),
        (["onglet precedent", "va a l onglet precedent"], "ctrl+shift+tab", "onglet précédent"),
        (["rouvre l onglet", "rouvre le dernier onglet", "rouvre l onglet ferme"], "cmd+shift+t", "rouvrir l'onglet"),
        (["recharge", "recharge la page", "actualise", "actualise la page", "rafraichis la page", "rafraichis"], "cmd+r", "recharger"),
        (["page precedente", "reviens en arriere", "retour en arriere", "precedent"], "cmd+left", "page précédente"),
        (["page suivante", "avance", "va en avant"], "cmd+right", "page suivante"),
        (["zoom avant", "agrandis la page", "zoome", "agrandis"], "cmd+equal", "zoom avant"),
        (["zoom arriere", "reduis la page", "dezoome"], "cmd+minus", "zoom arrière"),
        (["taille normale", "zoom normal", "taille reelle"], "cmd+0", "taille normale"),
        (["ajoute aux favoris", "mets en favori", "ajoute un signet", "ajoute aux signets"], "cmd+d", "favori"),
        (["nouvelle fenetre"], "cmd+n", "nouvelle fenêtre"),
        (["navigation privee", "fenetre privee", "ouvre une fenetre privee"], "cmd+shift+n", "fenêtre privée"),
        (["descends", "descends la page", "fais defiler", "defile"], "pagedown", "descendre"),
        (["remonte", "remonte la page"], "pageup", "remonter"),
        (["tout en haut", "haut de la page", "va tout en haut"], "cmd+up", "haut de la page"),
        (["tout en bas", "bas de la page", "va tout en bas"], "cmd+down", "bas de la page"),
        (["barre d adresse", "va dans la barre d adresse"], "cmd+l", "barre d'adresse"),
    ]

    static let numbers = ["un": 1, "premier": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9]

    /// Sites dits sans leur extension (« va sur youtube »).
    static let sites: [String: String] = [
        "youtube": "youtube.com", "google": "google.com", "github": "github.com", "gmail": "mail.google.com",
        "facebook": "facebook.com", "instagram": "instagram.com", "twitter": "x.com", "x": "x.com",
        "linkedin": "linkedin.com", "netflix": "netflix.com", "amazon": "amazon.fr", "wikipedia": "fr.wikipedia.org",
        "reddit": "reddit.com", "chatgpt": "chatgpt.com", "claude": "claude.ai", "whatsapp": "web.whatsapp.com",
        "google maps": "maps.google.com", "maps": "maps.google.com", "drive": "drive.google.com", "google drive": "drive.google.com",
        "vercel": "vercel.com", "supabase": "supabase.com",
    ]

    /// Adresse dite → URL https (« github point com », « github.com/anthropics »), sinon nil.
    static func url(fromSpoken original: String) -> URL? {
        var s = original.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        if let known = sites[normalize(s)] { return URL(string: "https://" + known) }
        s = s.replacingOccurrences(of: " point ", with: ".").replacingOccurrences(of: " slash ", with: "/")
            .replacingOccurrences(of: " ", with: "")
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)) }
        guard s.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}(/[^\\s]*)?$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + s)
    }

    static func google(_ q: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }

    /// `front` : identifiant de l'app au premier plan.
    static func match(_ text: String, front: String?) -> BrowserCommand? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        let words = s.split(separator: " ").map(String.init)
        func originalAfter(_ n: Int) -> String { SkillCatalog.originalSlice(text, skippingWords: n, droppingLastWords: 0) }
        // Partout : « va sur <site> », « ouvre le site <site> », « cherche … sur Google ».
        for p in ["va sur le site", "ouvre le site", "va sur"] {
            let pw = p.split(separator: " ").count
            if s.hasPrefix(p + " "), let u = url(fromSpoken: originalAfter(pw)) { return .open(u) }
        }
        for p in ["cherche", "recherche"] where s.hasPrefix(p + " ") {
            for suffix in [" sur google", " sur internet", " sur le web"] where s.hasSuffix(suffix) {
                // Texte d'origine (accents) entre « cherche » et « sur Google ».
                let q = SkillCatalog.originalSlice(text, skippingWords: 1, droppingLastWords: suffix.split(separator: " ").count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
                if !q.isEmpty, let u = google(q) { return .open(u) }
            }
        }
        guard let front, browsers.contains(front) else { return nil }
        for k in keys where k.phrases.contains(s) { return .keys(k.spec, k.label) }
        if words.count == 2, words[0] == "onglet", let n = numbers[words[1]] ?? Int(words[1]), (1...9).contains(n) {
            return .keys("cmd+\(n)", "onglet \(n)")
        }
        if s == "dernier onglet" { return .keys("cmd+9", "dernier onglet") }
        for p in ["cherche dans la page", "trouve dans la page"] where s.hasPrefix(p + " ") {
            return .findInPage(originalAfter(p.split(separator: " ").count))
        }
        for suffix in [" dans la page", " sur la page"] where s.hasSuffix(suffix) && (s.hasPrefix("cherche ") || s.hasPrefix("trouve ")) {
            let q = SkillCatalog.originalSlice(text, skippingWords: 1, droppingLastWords: 3)
            if !q.isEmpty { return .findInPage(q) }
        }
        if s.hasPrefix("cherche ") || s.hasPrefix("recherche ") {
            let q = originalAfter(1).trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
            if !q.isEmpty, let u = google(q) { return .open(u) }
        }
        return nil
    }

    /// Hors fil principal.
    static func perform(_ c: BrowserCommand, front: NSRunningApplication?) -> Bool {
        switch c {
        case let .keys(spec, _):
            guard let app = front else { return false }
            return Palette.pressKey(spec, in: app)
        case let .findInPage(q):
            guard let app = front, Palette.pressKey("cmd+f", in: app) else { return false }
            usleep(300_000)
            return TextTyper.type(q, to: app.processIdentifier, while: { AXButtonPresser.isFrontmost(app) })
        case let .open(url):
            // Navigateur au premier plan : la page s'ouvre dedans ; sinon le navigateur par défaut.
            if let app = front, let id = app.bundleIdentifier, browsers.contains(id), let appURL = app.bundleURL {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
            return NSWorkspace.shared.open(url)
        }
    }
}
