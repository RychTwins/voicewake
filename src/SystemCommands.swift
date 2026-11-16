import AppKit

/// Commandes du Mac, valables dans toutes les apps : lancer, basculer, cacher, quitter une app ; fenêtre
/// (réduire, plein écran, fermer) ; son, luminosité, musique (touches multimédia) ; capture d'écran.
enum SystemCommand: Equatable {
    case launch(String)          // chemin de l'app
    case activate(String)
    case quit(String)            // identifiant de bundle (app ouverte)
    case hide(String)
    case minimize, fullScreen, closeWindow
    case volumeUp, volumeDown, mute, unmute, volume(Int)
    case brightnessUp, brightnessDown
    case nextTrack, previousTrack, playPause
    case screenshot

    /// Action sensible : demande « je confirme ».
    var dangerous: Bool { if case .quit = self { return true }; return false }
}

/// App installée ou ouverte : nom affiché (localisé), chemin, identifiant.
struct InstalledApp: Equatable {
    let name: String
    let path: String
    let bundleID: String?
}

enum SystemCommands {
    // Phrases (normalisées) suivies d'un nom d'app. « ouvre <app> » : seulement si le nom est exactement une app.
    static let launchPrefixes = ["lance", "demarre", "ouvre l application", "ouvre l app", "ouvre"]
    static let activatePrefixes = ["bascule sur", "passe sur", "va dans l app", "montre moi", "montre"]
    static let quitPrefixes = ["quitte", "ferme l application", "ferme l app", "ferme"]
    static let hidePrefixes = ["cache", "masque"]
    /// « Cette app », « l'app » : l'app au premier plan.
    static let frontWords: Set<String> = ["cette app", "l app", "cette application", "l application", "app", "application"]

    /// Noms parlés courants → nom d'app (normalisés).
    static let aliases: [String: String] = [
        "preferences systeme": "reglages systeme", "parametres systeme": "reglages systeme",
        "les parametres systeme": "reglages systeme", "les reglages systeme": "reglages systeme",
        "parametres du mac": "reglages systeme", "les parametres du mac": "reglages systeme",
        "le finder": "finder", "chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code",
        "le terminal": "terminal", "l app store": "app store", "la musique": "musique", "les notes": "notes",
        "le calendrier": "calendrier", "les mails": "mail", "les messages": "messages", "plans": "plans",
    ]

    static let fixed: [(phrases: [String], command: SystemCommand)] = [
        (["minimise la fenetre", "reduis la fenetre", "minimise", "reduis"], .minimize),
        (["plein ecran", "mets en plein ecran", "passe en plein ecran", "quitte le plein ecran", "sors du plein ecran"], .fullScreen),
        (["ferme la fenetre", "ferme cette fenetre"], .closeWindow),
        (["monte le son", "augmente le son", "plus fort", "monte le volume", "augmente le volume"], .volumeUp),
        (["baisse le son", "diminue le son", "moins fort", "baisse le volume", "diminue le volume"], .volumeDown),
        (["coupe le son", "mode silencieux", "silence"], .mute),
        (["remets le son", "reactive le son", "active le son"], .unmute),
        (["augmente la luminosite", "plus lumineux", "monte la luminosite"], .brightnessUp),
        (["baisse la luminosite", "moins lumineux", "diminue la luminosite"], .brightnessDown),
        (["musique suivante", "chanson suivante", "piste suivante", "morceau suivant", "titre suivant"], .nextTrack),
        (["musique precedente", "chanson precedente", "piste precedente", "morceau precedent", "titre precedent"], .previousTrack),
        (["pause la musique", "mets la musique en pause", "arrete la musique", "coupe la musique",
          "remets la musique", "relance la musique", "joue la musique", "reprends la musique"], .playPause),
        (["capture d ecran", "fais une capture d ecran", "prends une capture d ecran"], .screenshot),
    ]

    /// Toutes les phrases fixes (indices de reconnaissance).
    static var fixedPhrases: [String] { fixed.flatMap(\.phrases) }

    /// Commande reconnue dans l'énoncé entier, sinon nil. `apps` : apps installées ; `running` : apps ouvertes ;
    /// `front` : identifiant de l'app au premier plan.
    static func match(_ text: String, apps: [InstalledApp], running: [InstalledApp], front: String?) -> SystemCommand? {
        let said = normalize(text)
        guard !said.isEmpty else { return nil }
        for f in fixed where f.phrases.contains(said) { return f.command }
        let words = said.split(separator: " ").map(String.init)
        if words.count >= 2, words[0] == "volume" || (words.count >= 3 && words[0] == "mets" && words[1] == "le" && words[2] == "volume") {
            if let n = words.last.flatMap(Int.init), (0...100).contains(n) { return .volume(n) }
        }
        func rest(after prefixes: [String]) -> String? {
            for p in prefixes.sorted(by: { $0.count > $1.count }) where said.hasPrefix(p + " ") {
                return String(said.dropFirst(p.count + 1))
            }
            return nil
        }
        if let name = rest(after: quitPrefixes) {
            if frontWords.contains(name), let front { return .quit(front) }
            if let app = find(name, in: running), let id = app.bundleID { return .quit(id) }
            return nil
        }
        if let name = rest(after: hidePrefixes) {
            if frontWords.contains(name), let front { return .hide(front) }
            if let app = find(name, in: running), let id = app.bundleID { return .hide(id) }
            return nil
        }
        if let name = rest(after: activatePrefixes), let app = find(name, in: running + apps) {
            return running.contains(app) ? .activate(app.path) : .launch(app.path)
        }
        // « Ouvre <nom> » sert aussi aux projets et aux menus : seulement un nom d'app exact.
        if let name = rest(after: launchPrefixes),
           let app = find(name, in: apps + running, exactOnly: said.hasPrefix("ouvre ") && !said.hasPrefix("ouvre l app")) {
            return .launch(app.path)
        }
        return nil
    }

    /// App désignée par son nom : exact (ou alias), sinon une seule app dont le nom commence par ces mots.
    /// Noms français → noms anglais (le nom affiché dépend de la langue du système).
    static let english: [String: String] = [
        "reglages systeme": "system settings", "musique": "music", "calendrier": "calendar", "plans": "maps",
        "rappels": "reminders", "calculette": "calculator", "calculatrice": "calculator", "contacts": "contacts",
        "apercu": "preview", "editeur de script": "script editor", "moniteur d activite": "activity monitor",
    ]

    static func find(_ spoken: String, in apps: [InstalledApp], exactOnly: Bool = false) -> InstalledApp? {
        let name = aliases[spoken] ?? spoken
        guard !name.isEmpty else { return nil }
        let names = [name] + (english[name].map { [$0] } ?? [])
        if let exact = apps.first(where: { names.contains(normalize($0.name)) }) { return exact }
        if exactOnly { return nil }
        let starts = Dictionary(grouping: apps.filter { normalize($0.name).hasPrefix(name + " ") }, by: \.path)
        return starts.count == 1 ? starts.values.first?.first : nil
    }

    // MARK: Apps du Mac

    private static var cachedApps: [InstalledApp] = []
    private static var cachedAt = Date.distantPast

    /// Apps installées (dossiers Applications), noms localisés (« Réglages Système »). Mise en cache 5 min.
    static func installedApps() -> [InstalledApp] {
        if Date().timeIntervalSince(cachedAt) < 300, !cachedApps.isEmpty { return cachedApps }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]
        var out: [InstalledApp] = []
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(item)
                if dir == "/System/Library/CoreServices", item != "Finder.app" { continue }
                let id = Bundle(path: path)?.bundleIdentifier
                let display = (fm.displayName(atPath: path) as NSString).deletingPathExtension
                out.append(InstalledApp(name: display, path: path, bundleID: id))
                let file = (item as NSString).deletingPathExtension
                if normalize(file) != normalize(display) { out.append(InstalledApp(name: file, path: path, bundleID: id)) }
            }
        }
        cachedApps = out
        cachedAt = Date()
        return out
    }

    static func runningApps() -> [InstalledApp] {
        // Nom affiché et nom du fichier (l'app Codex s'affiche « ChatGPT » mais s'appelle Codex.app).
        NSWorkspace.shared.runningApplications.flatMap { app -> [InstalledApp] in
            guard app.activationPolicy == .regular, let name = app.localizedName, let url = app.bundleURL else { return [] }
            let file = url.deletingPathExtension().lastPathComponent
            return [InstalledApp(name: name, path: url.path, bundleID: app.bundleIdentifier)]
                + (normalize(file) == normalize(name) ? [] : [InstalledApp(name: file, path: url.path, bundleID: app.bundleIdentifier)])
        }
    }

    /// Les cibles se disent aussi par leur nom VoiceWake (« codex » pour ChatGPT.app).
    static func targetApps(_ config: Config) -> [InstalledApp] {
        config.targets.compactMap { t in
            guard let app = ShortcutTrigger.runningApp(for: t), let url = app.bundleURL else { return nil }
            return InstalledApp(name: t.id, path: url.path, bundleID: app.bundleIdentifier)
        }
    }

    /// Nom à dire dans le journal et la confirmation.
    static func appName(_ idOrPath: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == idOrPath }) {
            return app.localizedName ?? idOrPath
        }
        return (FileManager.default.displayName(atPath: idOrPath) as NSString).deletingPathExtension
    }

    // MARK: Exécution

    /// Exécute la commande (appelée sur le fil principal). true si l'action a été faite.
    static func perform(_ c: SystemCommand) -> Bool {
        let ws = NSWorkspace.shared
        switch c {
        case let .launch(path), let .activate(path):
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = true
            ws.openApplication(at: URL(fileURLWithPath: path), configuration: conf)
            return true
        case let .quit(id):
            guard id != Bundle.main.bundleIdentifier,
                  let app = ws.runningApplications.first(where: { $0.bundleIdentifier == id }) else { return false }
            return app.terminate() // l'app demande elle-même d'enregistrer les documents modifiés
        case let .hide(id):
            return ws.runningApplications.first(where: { $0.bundleIdentifier == id })?.hide() ?? false
        case .minimize:
            return setWindow(kAXMinimizedAttribute, true)
        case .fullScreen:
            guard let w = frontWindow() else { return false }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &value)
            let now = (value as? Bool) ?? false
            return AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (!now) as CFBoolean) == .success
        case .closeWindow:
            guard let w = frontWindow() else { return false }
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let b = button else { return false }
            return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
        case .volumeUp: return auxKey(0)
        case .volumeDown: return auxKey(1)
        case .mute: return setMuted(true)
        case .unmute: return setMuted(false)
        case let .volume(n): return runScript("set volume output volume \(max(0, min(100, n)))")
        case .brightnessUp: return auxKey(2)
        case .brightnessDown: return auxKey(3)
        case .playPause: return auxKey(16)
        case .nextTrack: return auxKey(17)
        case .previousTrack: return auxKey(18)
        case .screenshot:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
            let file = NSHomeDirectory() + "/Desktop/Capture VoiceWake \(f.string(from: Date())).png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", file]
            return (try? p.run()) != nil
        }
    }

    private static func frontWindow() -> AXUIElement? {
        guard let app = Universal.frontApp() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &w) == .success, let w else { return nil }
        return (w as! AXUIElement)
    }

    private static func setWindow(_ attribute: String, _ value: Bool) -> Bool {
        guard let w = frontWindow() else { return false }
        return AXUIElementSetAttributeValue(w, attribute as CFString, value as CFBoolean) == .success
    }

    private static func setMuted(_ muted: Bool) -> Bool { runScript("set volume output muted \(muted)") }

    /// AppleScript des « Standard Additions » (volume) : aucune autorisation d'automatisation requise.
    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    /// Touche spéciale du clavier Apple (son 0/1, luminosité 2/3, lecture 16, suivant 17, précédent 18) :
    /// comme si on appuyait dessus, donc valable pour Spotify, Musique, YouTube…
    private static func auxKey(_ key: Int32) -> Bool {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1),
                  let cg = e.cgEvent else { return false }
            cg.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Nom d'appel (« Jarvis, ferme Claude »).
enum WakeName {
    static let defaults = ["jarvis"]

    /// Commande après le nom d'appel, à sa dernière occurrence (« jarvis ferme claude » → « ferme claude »), sinon nil.
    static func command(after text: String, names: [String]) -> String? {
        let words = normalize(text).split(separator: " ").map(String.init)
        let all = names.map(normalize).filter { !$0.isEmpty }.map { $0.split(separator: " ").map(String.init) }
        for i in stride(from: words.count - 1, through: 0, by: -1) {
            for nw in all where i + nw.count <= words.count && Array(words[i..<(i + nw.count)]) == nw {
                return words[(i + nw.count)...].joined(separator: " ")
            }
        }
        return nil
    }
}
