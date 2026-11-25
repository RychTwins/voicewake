import AppKit

/// Skill ou commande slash qu'on peut lancer à la voix : `text` est ce qui est tapé dans la zone de saisie.
struct SkillEntry: Equatable {
    enum Source: Int { case personal = 0, builtin = 1, plugin = 2 }
    /// Ex. "/compact", "/superpowers:brainstorming", "$pdf".
    let text: String
    /// Façons de le dire, en mots normalisés (ex. ["brainstorming"], ["superpowers", "brainstorming"]).
    let aliases: [[String]]
    let source: Source
}

/// Catalogue des skills et commandes slash, lu sur le disque (rien n'est envoyé ailleurs).
enum SkillCatalog {
    /// Commandes intégrées de Claude Code (documentation officielle, commandes courantes).
    static let claudeBuiltins = ["help", "clear", "compact", "model", "context", "usage", "cost", "status", "skills",
                                 "permissions", "init", "review", "security-review", "rewind", "plugin", "add-dir",
                                 "reload-skills", "reload-plugins", "memory", "config", "doctor", "agents", "mcp", "resume"]
    /// Commandes slash intégrées de l'app Codex (documentation officielle).
    static let codexBuiltins = ["feedback", "goal", "init", "mcp", "plan", "review", "status"]

    /// Nom de skill ou de plugin acceptable : lettres, chiffres, « - _ . : », 64 caractères au plus. Un nom venu
    /// d'un fichier est tapé dans l'assistant : rien d'autre (espaces, retours à la ligne, texte) n'y entre.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$", options: .regularExpression) != nil
    }

    static func words(_ name: String) -> [String] {
        normalize(name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ":", with: " ")).split(separator: " ").map(String.init)
    }

    /// Nom déclaré dans l'en-tête du SKILL.md (`name: …`), sinon nil.
    static func declaredName(_ file: URL) -> String? {
        guard let head = try? String(contentsOf: file, encoding: .utf8).prefix(2000), head.hasPrefix("---") else { return nil }
        for line in head.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            if line.hasPrefix("name:") {
                let v = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Dossiers `<dossier>/<nom>/SKILL.md` → noms des skills.
    static func skills(in dir: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { sub in
            let file = sub.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: file.path) else { return nil }
            return declaredName(file) ?? sub.lastPathComponent
        }.sorted()
    }

    /// Claude : skills personnels, anciennes commandes (~/.claude/commands), commandes intégrées, skills des plugins installés.
    static func claude(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SkillEntry] {
        var out: [SkillEntry] = []
        var seen = Set<String>()
        func add(_ text: String, _ aliases: [[String]], _ source: SkillEntry.Source) {
            guard isValidName(String(text.dropFirst())), seen.insert(text).inserted, aliases.allSatisfy({ !$0.isEmpty }) else { return }
            out.append(SkillEntry(text: text, aliases: aliases, source: source))
        }
        let claudeDir = home.appendingPathComponent(".claude")
        for name in skills(in: claudeDir.appendingPathComponent("skills")) { add("/" + name, [words(name)], .personal) }
        let commands = (try? FileManager.default.contentsOfDirectory(at: claudeDir.appendingPathComponent("commands"), includingPropertiesForKeys: nil)) ?? []
        for file in commands where file.pathExtension == "md" {
            let name = file.deletingPathExtension().lastPathComponent
            add("/" + name, [words(name)], .personal)
        }
        for name in claudeBuiltins { add("/" + name, [words(name)], .builtin) }
        // Plugins installés : installed_plugins.json → "<plugin>@<marketplace>": [{ installPath }].
        let registry = claudeDir.appendingPathComponent("plugins/installed_plugins.json")
        if let data = try? Data(contentsOf: registry),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let plugins = json["plugins"] as? [String: [[String: Any]]] {
            let pluginsRoot = claudeDir.appendingPathComponent("plugins").standardizedFileURL.resolvingSymlinksInPath().path + "/"
            for (key, installs) in plugins.sorted(by: { $0.key < $1.key }) {
                let plugin = String(key.split(separator: "@").first ?? Substring(key))
                guard isValidName(plugin) else { continue }
                for install in installs {
                    guard let path = install["installPath"] as? String else { continue }
                    // Seulement des plugins installés sous ~/.claude/plugins.
                    let base = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                    guard base.path.hasPrefix(pluginsRoot) else { continue }
                    for name in skills(in: base.appendingPathComponent("skills")) + skills(in: base) {
                        add("/\(plugin):\(name)", [words(name), words(plugin) + words(name)], .plugin)
                    }
                }
            }
        }
        return out
    }

    /// Codex : commandes intégrées ("/…") et skills de ~/.codex/skills ("$…").
    static func codex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SkillEntry] {
        codexBuiltins.map { SkillEntry(text: "/" + $0, aliases: [words($0)], source: .builtin) }
            + skills(in: home.appendingPathComponent(".codex/skills")).filter(isValidName)
                .map { SkillEntry(text: "$" + $0, aliases: [words($0)], source: .personal) }
    }

    static func entries(for t: Target) -> [SkillEntry] {
        switch t.bundleID {
        case "com.openai.codex": return codex()
        case "com.google.GeminiMacOS", "com.openai.chat": return []
        default: return claude() // app Claude et extension Claude Code des éditeurs
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 2
    }

    /// Skill dont un alias commence la citation : (skill, nombre de mots consommés). Le plus long alias l'emporte,
    /// une correspondance exacte passe avant une approchée ; à égalité exacte : skill personnel, commande intégrée,
    /// puis plugin. Deux candidats différents à égalité restante (ex. deux plugins au même nom, ou deux noms
    /// approchés) : ambigu, nil — rien n'est tapé.
    static func match(_ query: [String], in entries: [SkillEntry]) -> (entry: SkillEntry, consumed: Int)? {
        typealias Score = (consumed: Int, exact: Int, source: Int)
        func better(_ a: Score, _ b: Score) -> Bool {
            if a.consumed != b.consumed { return a.consumed > b.consumed }
            if a.exact != b.exact { return a.exact > b.exact }
            return a.source < b.source
        }
        var best: (entry: SkillEntry, score: Score)?
        var tie = false
        for e in entries {
            var top: Score?
            for alias in e.aliases where alias.count <= query.count && zip(alias, query).allSatisfy({ same($0, $1) }) {
                let sc: Score = (alias.count, alias == Array(query.prefix(alias.count)) ? 1 : 0, e.source.rawValue)
                if top == nil || better(sc, top!) { top = sc }
            }
            guard let sc = top else { continue }
            if best == nil || better(sc, best!.score) { best = (e, sc); tie = false }
            else if !better(best!.score, sc), e.text != best!.entry.text { tie = true }
        }
        guard let best, !tie else { return nil }
        return (best.entry, best.score.consumed)
    }

    static var defaultPhrases: [String] {
        Lang.t(["lance le skill", "utilise le skill", "lance la compétence", "lance la commande",
                "commande slash", "skill", "compétence", "slash"])
    }

    /// « Lance le skill code review sur ce fichier » → (mots du nom et des arguments, texte d'origine des arguments
    /// à partir de l'indice de mot normalisé `n`). Phrase en début d'énoncé.
    static func request(_ text: String, config: Config) -> [String]? {
        let words = normalize(text).split(separator: " ").map(String.init)
        for p in (config.skillPhrases ?? defaultPhrases).map(normalize).sorted(by: { $0.count > $1.count }) where !p.isEmpty {
            let pw = p.split(separator: " ").map(String.init)
            if words.count > pw.count, Array(words.prefix(pw.count)) == pw { return Array(words.dropFirst(pw.count)) }
        }
        return nil
    }

    /// Texte d'origine entre les `skip` premiers et les `drop` derniers mots normalisés (mots comptés comme
    /// `normalize` les découpe : « l'idée » compte pour deux).
    static func originalSlice(_ text: String, skippingWords skip: Int, droppingLastWords drop: Int) -> String {
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)[...]
        var count = 0
        while let t = tokens.first, count < skip { count += normalize(t).split(separator: " ").count; tokens = tokens.dropFirst() }
        count = 0
        while let t = tokens.last, count < drop { count += normalize(t).split(separator: " ").count; tokens = tokens.dropLast() }
        return tokens.joined(separator: " ")
    }

    /// Texte d'origine (accents, majuscules, ponctuation) après les `skip` premiers mots normalisés.
    static func originalTail(_ text: String, skippingWords skip: Int) -> String {
        var count = 0
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)[...]
        while let t = tokens.first, count < skip {
            count += normalize(t).split(separator: " ").count
            tokens = tokens.dropFirst()
        }
        return tokens.joined(separator: " ")
    }
}

/// Tape du texte dans l'app au premier plan (événements clavier Unicode, sans toucher au presse-papier).
enum TextTyper {
    static func type(_ text: String, to pid: pid_t, while allowed: () -> Bool) -> Bool {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            guard allowed() else { return false }
            let chunk = Array(units[i..<min(units.count, i + 16)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return false }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.postToPid(pid)
            }
            usleep(12_000)
            i += 16
        }
        return true
    }
}
