import AppKit

/// Associe une transcription à une cible.
struct Router {
    let config: Config
    private let targetPhrases: [(phrase: String, id: String)]
    private let frontmostPhrases: [String]

    init(config: Config) {
        self.config = config
        // Les phrases les plus longues d'abord : "salut chatgpt" avant "salut chat".
        self.targetPhrases = config.targets
            .flatMap { t in t.phrases.map { (normalize($0), t.id) } }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        self.frontmostPhrases = config.frontmostPhrases.map(normalize).filter { !$0.isEmpty }
    }

    /// Mots soufflés au moteur pour mieux reconnaître les noms propres.
    var hints: [String] {
        let routines = JarvisRoutine.allCases.flatMap { $0.phrases.map { "jarvis " + $0 } }
        let assistants = config.targets.map { "salut jarvis démarre " + $0.id }
        return Array(Set(config.targets.flatMap(\.phrases) + config.frontmostPhrases
                         + (config.commands ?? []).flatMap(\.phrases) + routines + assistants + ["salut jarvis"]))
    }

    func jarvisAssistant(_ name: String) -> Target? {
        let name = normalize(name)
        if let target = config.targets.first(where: { normalize($0.id) == name }) { return target }
        let matches = config.targets.filter { Jarvis.names(for: $0).contains(name) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Vrai si le texte demande la lecture de la dernière réponse (« fais la lecture »).
    func containsReadAloudPhrase(_ text: String) -> Bool { containsAny(text, config.readAloudPhrases) }

    /// « [Salut] Jarvis, <ordre> » en début de phrase. « Salut Jarvis » seul n'est pas un ordre :
    /// c'est une phrase générale (assistant au premier plan).
    func jarvis(_ text: String) -> JarvisAction? {
        let words = normalize(text).split(separator: " ").map(String.init)
        guard let i = words.firstIndex(where: Jarvis.wakeNames.contains), i + 1 < words.count,
              i == 0 || (i == 1 && Jarvis.greetings.contains(words[0])) else { return nil }
        let instruction = words[(i + 1)...].joined(separator: " ")
        // Routine : la phrase exacte, ou suivie d'autres mots (« … s'il te plaît »).
        if let routine = JarvisRoutine.allCases.first(where: { r in
            r.phrases.contains { instruction == $0 || instruction.hasPrefix($0 + " ") }
        }) {
            return .routine(routine)
        }
        // « Jarvis Claude » : le nom seul suffit.
        if let target = jarvisAssistant(instruction) { return .assistant(target) }
        let start = Jarvis.startPrefixes.first(where: instruction.hasPrefix)
        guard let prefix = start ?? Jarvis.assistantPrefixes.first(where: instruction.hasPrefix) else { return nil }
        // « démarre Claude s'il te plaît » : le nom est au début de ce qui suit le verbe.
        let name = instruction.dropFirst(prefix.count).split(separator: " ")
        for n in stride(from: name.count, to: 0, by: -1) {
            if let target = jarvisAssistant(name.prefix(n).joined(separator: " ")) { return .assistant(target) }
        }
        // Nom inconnu (« Jarvis dit que… ») : Jarvis se tait, ce n'était pas un ordre.
        return nil
    }

    /// Vrai si le texte est exactement une phrase d'activation (rien avant, rien après).
    func isWakePhrase(_ text: String) -> Bool {
        let n = normalize(text)
        return targetPhrases.contains { $0.phrase == n } || frontmostPhrases.contains(n) || isJarvisGreeting(n)
    }

    func route(_ text: String) -> Target? {
        let phrase = normalize(text)
        if isJarvisGreeting(phrase) { return frontmostTarget() }
        let n = " " + phrase + " "
        if let hit = targetPhrases.first(where: { n.contains(" " + $0.phrase + " ") }) {
            return config.target(id: hit.id)
        }
        if frontmostPhrases.contains(where: { !isJarvisGreeting($0) && n.contains(" " + $0 + " ") }) {
            return frontmostTarget()
        }
        return nil
    }

    private func isJarvisGreeting(_ phrase: String) -> Bool {
        let words = phrase.split(separator: " ")
        return words.count == 2 && Jarvis.greetings.contains(String(words[0])) &&
            Jarvis.wakeNames.contains(String(words[1]))
    }

    /// Commande vocale dont une phrase termine la transcription (la plus longue), ou nil.
    func command(_ text: String) -> VoiceCommand? {
        let n = " " + normalize(text)
        var best: (command: VoiceCommand, length: Int)?
        for c in config.commands ?? [] {
            for p in c.phrases.map(normalize) where !p.isEmpty && n.hasSuffix(" " + p) && p.count > (best?.length ?? 0) {
                best = (c, p.count)
            }
        }
        return best?.command
    }

    private var sendCommands: Set<String> {
        guard let phrases = config.sendPhrases, !phrases.isEmpty else { return [] }
        let explicit = ["ok tu peux envoyer", "c est bon tu peux envoyer"]
        let ambiguous = ["ok on voit", "okay on voit", "ok on voie"]
        return Set(phrases.map(normalize) + explicit).subtracting(ambiguous + [""])
    }

    func isSendCommand(_ text: String) -> Bool {
        sendCommands.contains(normalize(text))
    }

    /// Vrai si la transcription se termine par une phrase d'arrêt du micro.
    func endsWithStopPhrase(_ text: String) -> Bool { endsWith(text, config.stopPhrases) }

    func isStandaloneStop(_ text: String) -> Bool {
        let phrase = normalize(text)
        return !phrase.isEmpty && (config.stopPhrases ?? []).map(normalize).contains(phrase)
    }

    /// Dernière phrase de `phrases` présente dans le texte, avec le mot qui la précède (texte normalisé).
    func lastMatch(_ text: String, _ phrases: [String]?) -> (phrase: String, previous: String?)? {
        let n = " " + normalize(text) + " "
        var best: (phrase: String, previous: String?, at: String.Index)?
        for p in (phrases ?? []).map(normalize) where !p.isEmpty {
            guard let r = n.range(of: " " + p + " ", options: .backwards) else { continue }
            if let b = best, b.at > r.lowerBound || (b.at == r.lowerBound && b.phrase.count >= p.count) { continue }
            let before = n[..<r.lowerBound].split(separator: " ").last.map(String.init)
            best = (p, before, r.lowerBound)
        }
        return best.map { ($0.phrase, $0.previous) }
    }

    /// Mots dits après « lis à partir de » (normalisés), ou nil.
    func readFromQuery(_ text: String) -> [String]? {
        let n = " " + normalize(text) + " "
        var best: Range<String.Index>?
        for p in (config.readFromPhrases ?? []).map(normalize) where !p.isEmpty {
            if let r = n.range(of: " " + p + " ", options: .backwards), best == nil || r.lowerBound > best!.lowerBound { best = r }
        }
        guard let best else { return nil }
        let words = n[best.upperBound...].split(separator: " ").map(String.init)
        return words.isEmpty ? nil : words
    }

    func containsAny(_ text: String, _ phrases: [String]?) -> Bool {
        let n = " " + normalize(text) + " "
        return (phrases ?? []).map(normalize).contains { !$0.isEmpty && n.contains(" " + $0 + " ") }
    }

    /// Vrai si la transcription contient une phrase d'interruption de la lecture.
    func containsInterruptPhrase(_ text: String) -> Bool {
        let n = " " + normalize(text) + " "
        return (config.interruptPhrases ?? []).map(normalize).contains { !$0.isEmpty && n.contains(" " + $0 + " ") }
    }

    private func endsWith(_ text: String, _ phrases: [String]?) -> Bool { suffix(text, phrases) != nil }

    /// La plus longue phrase normalisée qui termine le texte.
    private func suffix(_ text: String, _ phrases: [String]?) -> String? {
        let n = " " + normalize(text)
        return (phrases ?? []).map(normalize).filter { !$0.isEmpty && n.hasSuffix(" " + $0) }.max { $0.count < $1.count }
    }

    /// Éditeur au premier plan qui intègre cet assistant → cible « dans l'éditeur ».
    /// nil si aucun éditeur n'est au premier plan, s'il n'intègre pas l'assistant,
    /// ou si le panneau de l'assistant n'est pas ouvert (bouton introuvable) : l'app de bureau prend le relais.
    func inEditor(_ t: Target) -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication, let bid = front.bundleIdentifier,
              let editor = config.editors?.first(where: { $0.bundleIDs.contains(bid) }),
              let a = editor.assistants[t.id] else { return nil }
        if !a.shortcut.buttons.isEmpty, AXButtonPresser.all(a.shortcut.buttons, in: front).isEmpty {
            log("\(editor.id) au premier plan, mais panneau \(t.id) fermé : app de bureau.")
            return nil
        }
        var e = t
        e.id = "\(t.id)@\(editor.id)"
        e.bundleID = bid
        e.appName = front.localizedName
        e.shortcut = a.shortcut
        e.stopShortcut = a.stopShortcut
        e.submitShortcut = a.submitShortcut
        e.readAloudShortcut = a.readAloudShortcut
        e.busyLabels = a.busyLabels
        e.pauseReadShortcut = a.pauseReadShortcut
        e.resumeReadShortcut = a.resumeReadShortcut
        e.activate = true
        return e
    }

    func frontmostTarget() -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return config.defaultTarget.flatMap(config.target(id:)) }
        if let bid = front.bundleIdentifier,
           let editor = config.editors?.first(where: { $0.bundleIDs.contains(bid) }),
           let id = editor.preferredAssistant, let target = config.target(id: id),
           let integrated = inEditor(target) { return integrated }
        if let bid = front.bundleIdentifier, let target = activeEditorTarget(bundleID: bid) { return target }
        if let t = config.targets.first(where: { ShortcutTrigger.matches(front, $0) }) {
            return t
        }
        // Éditeur au premier plan : son assistant intégré (defaultTarget en priorité).
        if let bid = front.bundleIdentifier, let editor = config.editors?.first(where: { $0.bundleIDs.contains(bid) }) {
            let ids = [config.defaultTarget].compactMap { $0 } + editor.assistants.keys.sorted()
            for id in ids where editor.assistants[id] != nil {
                if let target = config.target(id: id), let integrated = inEditor(target) { return integrated }
            }
        }
        if let d = config.defaultTarget { return config.target(id: d) }
        log("Phrase générale : aucune cible au premier plan et pas de defaultTarget.")
        return nil
    }

    /// Cible temporaire qui conserve le champ déjà actif, sans choisir un assistant dans l'éditeur.
    func activeEditorTarget(bundleID: String) -> Target? {
        guard let dictation = config.externalDictation, let editor = config.editorID(for: bundleID) else { return nil }
        return Target(id: editor, appName: nil, bundleID: bundleID, phrases: [], shortcut: dictation.shortcut)
    }
}
