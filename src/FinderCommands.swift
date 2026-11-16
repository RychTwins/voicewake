import AppKit

/// Finder à la voix : aller dans un dossier, copier / déplacer / supprimer la sélection, vider la corbeille,
/// renommer, nouveau dossier, ouvrir, présentation. Les actions sur la sélection n'agissent que si le Finder
/// est au premier plan ; supprimer et vider la corbeille demandent « je confirme ».
enum FinderCommand: Equatable {
    case goTo(String)                 // nom de dossier dit
    case copy(to: String), move(to: String)
    case trash, emptyTrash
    case rename(String)               // nouveau nom (texte d'origine)
    case newFolder(String?)
    case open
    case view(String)                 // list, icon, column, flow

    /// Agit sur la sélection du Finder (Finder au premier plan requis).
    var needsFinderFront: Bool {
        switch self {
        case .goTo, .emptyTrash: return false
        default: return true
        }
    }

    var dangerous: Bool { self == .trash || self == .emptyTrash }

    /// Libellé (journal, confirmation) sans nom de fichier ni de dossier.
    var title: String {
        switch self {
        case .goTo: return "aller dans un dossier"
        case .copy: return "copier la sélection"
        case .move: return "déplacer la sélection"
        case .trash: return "mettre la sélection à la corbeille"
        case .emptyTrash: return "vider la corbeille (définitif)"
        case .rename: return "renommer"
        case .newFolder: return "nouveau dossier"
        case .open: return "ouvrir la sélection"
        case .view: return "changer la présentation"
        }
    }
}

enum FinderCommands {
    private static let object = "(?: (?:le|la|les|ce|ces|cette|ca))?(?: (?:fichier|fichiers|dossier|dossiers|selection|element|elements|document|documents|image|images))?"
    private static let into = " (?:dans|vers|sur|a) (?:(?:le|mon) dossier )?(?:les |le |la |l |mes |mon |ma )?(.+)"

    private static func capture(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        if m.numberOfRanges < 2 { return "" }
        return Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? ""
    }

    /// Commande Finder dans l'énoncé entier (texte d'origine : pour garder les accents d'un nouveau nom).
    static func match(_ text: String) -> FinderCommand? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        if let d = capture("(?:va|vas|aller|allez) (?:dans|sur|a) (?:le dossier )?(?:les |le |la |l |mes |mon |ma )?(.+)", s)
            ?? capture("ouvre (?:le dossier|mon dossier|mes) (?:les |le |la |l )?(.+)", s) { return .goTo(d) }
        if ["vide la corbeille", "vider la corbeille", "videz la corbeille"].contains(s) { return .emptyTrash }
        // Avant « mets … dans » : « mets-le à la corbeille ».
        if capture("(?:supprime|supprimer|jette|efface)" + object, s) != nil || capture("(?:mets|envoie|jette)" + object + " (?:a|dans) la corbeille", s) != nil,
           s != "efface", !s.hasPrefix("efface le brouillon") { return .trash }
        if let d = capture("(?:copie|copier|duplique)" + object + "(?: et (?:envoie|mets|colle|place)(?: le| la| les)?)?" + into, s)
            ?? capture("(?:envoie|mets|colle|place)" + object + into, s) { return .copy(to: d) }
        if let d = capture("(?:deplace|deplacer|bouge|range)" + object + into, s) { return .move(to: d) }
        if let words = capture("renomme" + object + " en (.+)", s) {
            // Nom d'origine (accents, majuscules) : les derniers mots du texte, autant que dans la version normalisée.
            let count = words.split(separator: " ").count
            let tail = SkillCatalog.originalSlice(text, skippingWords: s.split(separator: " ").count - count, droppingLastWords: 0)
            return .rename(tail.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?")))
        }
        if ["nouveau dossier", "cree un dossier", "cree un nouveau dossier", "fais un nouveau dossier"].contains(s) { return .newFolder(nil) }
        if let n = capture("(?:nouveau dossier|cree un dossier|cree un nouveau dossier) (?:nomme|appele|qui s appelle) (.+)", s) {
            let count = n.split(separator: " ").count
            return .newFolder(SkillCatalog.originalSlice(text, skippingWords: s.split(separator: " ").count - count, droppingLastWords: 0))
        }
        if ["ouvre le fichier", "ouvre la selection", "ouvre ca", "ouvre les fichiers", "ouvre le document"].contains(s) { return .open }
        if let v = capture("(?:affiche|affichage|presentation|vue)(?: en| par)? (liste|icones|colonnes|galerie)", s) {
            return .view(["liste": "list", "icones": "icon", "colonnes": "column", "galerie": "flow"][v] ?? "list")
        }
        return nil
    }

    // MARK: Dossiers

    static let known: [String: String] = [
        "bureau": "~/Desktop", "documents": "~/Documents", "telechargements": "~/Downloads", "telechargement": "~/Downloads",
        "applications": "/Applications", "images": "~/Pictures", "photos": "~/Pictures", "musique": "~/Music",
        "videos": "~/Movies", "films": "~/Movies", "dossier personnel": "~", "maison": "~", "accueil": "~",
        "developer": "~/Developer", "developpement": "~/Developer", "corbeille": "~/.Trash",
    ]

    /// Dossier désigné : nom connu, `folders` de la config, puis sous-dossier du dossier courant du Finder,
    /// du dossier personnel, du Bureau, des Documents ou de Developer (nom exact, sinon un seul qui commence ainsi).
    static func resolve(_ spoken: String, config: Config, current: String?) -> String? {
        let name = normalize(spoken)
        guard !name.isEmpty else { return nil }
        let expand = { (p: String) in (p as NSString).expandingTildeInPath }
        if let p = config.folders?.first(where: { normalize($0.key) == name })?.value { return expand(p) }
        if let p = known[name] { return expand(p) }
        let roots = [current].compactMap { $0 } + ["~", "~/Desktop", "~/Documents", "~/Developer"].map(expand)
        let fm = FileManager.default
        var prefixed: [String] = []
        for root in roots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !item.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(item)
                var dir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { continue }
                let n = normalize(item)
                if n == name { return path }
                if n.hasPrefix(name + " ") { prefixed.append(path) }
            }
        }
        return Set(prefixed).count == 1 ? prefixed.first : nil
    }

    // MARK: Exécution (hors fil principal)

    /// AppleScript lancé par osascript ; les noms passent en arguments (jamais collés dans le script).
    static func script(_ source: String, _ args: [String] = []) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "") }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func currentFolder() -> String? {
        let r = script("tell application \"Finder\" to if (count of Finder windows) > 0 then return POSIX path of (target of front Finder window as alias)")
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    private static let selection = """
    on run argv
      tell application "Finder"
        set s to selection
        if (count of s) is 0 then error "aucune sélection"
        %@
      end tell
    end run
    """

    /// true si fait ; `detail` : raison d'un échec.
    static func perform(_ c: FinderCommand, config: Config) -> (ok: Bool, detail: String) {
        func onSelection(_ body: String, _ args: [String] = []) -> (Bool, String) {
            let r = script(String(format: selection, body), args)
            return (r.ok, r.ok ? "fait" : "aucun fichier sélectionné ou action refusée")
        }
        switch c {
        case let .goTo(name):
            guard let path = resolve(name, config: config, current: currentFolder()) else { return (false, "dossier introuvable") }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return (true, "dossier ouvert")
        case let .copy(name), let .move(name):
            guard let path = resolve(name, config: config, current: currentFolder()) else { return (false, "dossier introuvable") }
            let verb: String
            if case .copy = c { verb = "duplicate" } else { verb = "move" }
            return onSelection("\(verb) s to (POSIX file (item 1 of argv) as alias)", [path])
        case .trash:
            return onSelection("delete s")
        case .emptyTrash:
            let r = script("tell application \"Finder\" to empty trash")
            return (r.ok, r.ok ? "corbeille vidée" : "corbeille non vidée")
        case let .rename(name):
            guard !name.isEmpty, !name.contains("/"), !name.contains(":") else { return (false, "nom invalide") }
            return onSelection("if (count of s) is not 1 then error \"un seul fichier\"\nset name of item 1 of s to (item 1 of argv)", [name])
        case let .newFolder(name):
            if let name, name.isEmpty || name.contains("/") || name.contains(":") { return (false, "nom invalide") }
            let body = """
            on run argv
              tell application "Finder"
                if (count of Finder windows) > 0 then
                  set d to (target of front Finder window)
                else
                  set d to desktop
                end if
                if (count of argv) > 0 then
                  make new folder at d with properties {name:(item 1 of argv)}
                else
                  make new folder at d
                end if
              end tell
            end run
            """
            let r = script(body, name.map { [$0] } ?? [])
            return (r.ok, r.ok ? "dossier créé" : "dossier non créé")
        case .open:
            return onSelection("open s")
        case let .view(v):
            let r = script("tell application \"Finder\" to set current view of front Finder window to \(v) view")
            return (r.ok, r.ok ? "présentation changée" : "aucune fenêtre du Finder")
        }
    }
}
