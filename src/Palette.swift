import AppKit

/// Palettes de commandes des éditeurs (VS Code, Zed, Cursor…) et de Claude, et touches à la voix.
enum Palette {
    static var defaultPhrases: [String] { Lang.t(["palette", "commande palette", "dans la palette"]) }

    /// Raccourci qui ouvre la palette, par application (configurable avec `paletteShortcuts`).
    static let defaultShortcuts: [String: String] = [
        "com.microsoft.VSCode": "cmd+shift+p", "com.microsoft.VSCodeInsiders": "cmd+shift+p",
        "dev.zed.Zed": "cmd+shift+p", "dev.zed.Zed-Preview": "cmd+shift+p",
        "com.todesktop.230313mzl4w4u92": "cmd+shift+p", "com.exafunction.windsurf": "cmd+shift+p",
        "com.anthropic.claudefordesktop": "cmd+k",
    ]

    static func shortcut(for bundleID: String, config: Config) -> String? {
        config.paletteShortcuts?[bundleID] ?? defaultShortcuts[bundleID]
    }

    /// « Palette formater le document » → mots normalisés de la commande, nombre de mots de la phrase d'appel,
    /// et « … et valide » (Entrée ensuite).
    static func request(_ text: String, config: Config) -> (query: [String], phraseWords: Int, validate: Bool)? {
        var words = normalize(text).split(separator: " ").map(String.init)
        for p in (config.palettePhrases ?? defaultPhrases).map(normalize).sorted(by: { $0.count > $1.count }) where !p.isEmpty {
            let pw = p.split(separator: " ").map(String.init)
            guard words.count > pw.count, Array(words.prefix(pw.count)) == pw else { continue }
            words.removeFirst(pw.count)
            let validate = words.count >= 2 && Lang.list("palette.validate", ["valide", "execute", "lance"]).contains(words.last!) && Lang.list("and", ["et"]).contains(words[words.count - 2])
            if validate { words.removeLast(2) }
            return words.isEmpty || words.count > 10 ? nil : (words, pw.count, validate)
        }
        return nil
    }

    /// Touches, dites seules (énoncé entier), sous une forme explicite : un mot courant isolé ne suffit pas.
    static var keys: [(phrases: [String], spec: String)] {
        [
            (Lang.t(["touche entrée", "appuie sur entrée"]), "return"),
            (Lang.t(["touche échap", "appuie sur échap", "ferme la palette"]), "escape"),
            (Lang.t(["touche tab"]), "tab"),
            (Lang.t(["flèche bas"]), "down"),
            (Lang.t(["flèche haut"]), "up"),
        ]
    }
    /// « Valide » seul n'est accepté que juste après « palette … » (commande tapée, en attente).
    static var validateWords: [String] { Lang.list("palette.validateAlone", ["valide", "execute"]) }
    static let paletteWindow: TimeInterval = 20

    static func key(_ text: String, paletteOpen: Bool) -> String? {
        let n = normalize(text)
        if paletteOpen, validateWords.contains(n) { return "return" }
        return keys.first { $0.phrases.map(normalize).contains(n) }?.spec
    }

    /// Ouvre la palette de l'app, tape la commande (texte d'origine), puis Entrée si demandé. Hors file principale.
    static func run(_ command: String, validate: Bool, shortcut spec: String, in app: NSRunningApplication) -> Bool {
        guard let open = try? Shortcut(spec: spec) else { return false }
        let pid = app.processIdentifier
        let front = { AXButtonPresser.isFrontmost(app) }
        let semaphore = DispatchSemaphore(value: 0)
        var opened = false
        ShortcutPlayer.play(open, to: pid, while: front) { opened = $0; semaphore.signal() }
        semaphore.wait()
        guard opened else { return false }
        usleep(350_000) // la palette s'ouvre
        guard TextTyper.type(command, to: pid, while: front) else { return false }
        guard validate else { return true }
        usleep(400_000) // la liste se filtre
        return pressKey("return", in: app)
    }

    static func pressKey(_ spec: String, in app: NSRunningApplication) -> Bool {
        guard let s = try? Shortcut(spec: spec) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        ShortcutPlayer.play(s, to: app.processIdentifier, while: { AXButtonPresser.isFrontmost(app) }) { ok = $0; semaphore.signal() }
        semaphore.wait()
        return ok
    }
}
