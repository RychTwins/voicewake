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
            guard seen.insert(text).inserted, aliases.allSatisfy({ !$0.isEmpty }) else { return }
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
            for (key, installs) in plugins.sorted(by: { $0.key < $1.key }) {
                let plugin = String(key.split(separator: "@").first ?? Substring(key))
                for install in installs {
                    guard let path = install["installPath"] as? String else { continue }
                    let base = URL(fileURLWithPath: path)
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
            + skills(in: home.appendingPathComponent(".codex/skills")).map { SkillEntry(text: "$" + $0, aliases: [words($0)], source: .personal) }
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
    /// puis skills personnels, commandes intégrées, plugins.
    static func match(_ query: [String], in entries: [SkillEntry]) -> (entry: SkillEntry, consumed: Int)? {
        var best: (entry: SkillEntry, consumed: Int)?
        for e in entries {
            for alias in e.aliases where alias.count <= query.count {
                // « code review » ↔ code-review ; « codereview » ↔ code review.
                let matches = zip(alias, query).allSatisfy { same($0, $1) }
                guard matches else { continue }
                let n = alias.count
                if best == nil || n > best!.consumed || (n == best!.consumed && e.source.rawValue < best!.entry.source.rawValue) {
                    best = (e, n)
                }
            }
        }
        return best
    }

    static let defaultPhrases = ["lance le skill", "utilise le skill", "lance la compétence", "lance la commande",
                                 "commande slash", "skill", "compétence", "slash"]

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
