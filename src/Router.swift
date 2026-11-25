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
        let conversation = config.continuousConversation == true ? Lang.t(["attends je réfléchis", "garde le brouillon"]) : []
        let names = (config.bareNames ?? true) ? ["Claude", "Codex", "Gemini", "ChatGPT", "Antigravity", "assistant"] : []
        return Array(Set(config.targets.flatMap(\.phrases) + config.frontmostPhrases + conversation + names))
    }

    /// Nom dit seul (« Claude. ») et ses déformations courantes → identifiant de la cible ; "" = app au premier plan.
    static var bareNames: [String: String] {
        Lang.map("router.bareNames", [
            "claude": "claude", "clode": "claude", "clod": "claude", "glode": "claude", "claud": "claude",
            "codex": "codex", "codecs": "codex", "code x": "codex", "codeks": "codex",
            "gemini": "gemini", "jemini": "gemini", "jimini": "gemini", "jeminy": "gemini", "gemmini": "gemini",
            "chatgpt": "chatgpt", "chat gpt": "chatgpt", "chat gbt": "chatgpt", "chat jpt": "chatgpt",
            "antigravity": "antigravity", "anti gravity": "antigravity", "antigravite": "antigravity",
            "assistant": "",
        ])
    }

    /// Cible appelée par son nom dit seul, sans rien avant ni après (en veille seulement : une dictée n'est
    /// jamais concernée). Le filtre de voix garantit que c'est bien l'utilisateur qui l'a dit.
    func bareName(_ text: String) -> Target? {
        guard config.bareNames ?? true, let id = Self.bareNames[normalize(text)] else { return nil }
        return id.isEmpty ? frontmostTarget() : config.target(id: id)
    }

    /// Vrai si le texte demande la lecture de la dernière réponse (« fais la lecture »).
    func containsReadAloudPhrase(_ text: String) -> Bool { containsAny(text, config.readAloudPhrases) }

    /// Vrai si le texte est exactement une phrase d'activation (rien avant, rien après).
    func isWakePhrase(_ text: String) -> Bool {
        let n = normalize(text)
        return targetPhrases.contains { $0.phrase == n } || frontmostPhrases.contains(n)
    }

    func route(_ text: String) -> Target? {
        let n = " " + normalize(text) + " "
        if let hit = targetPhrases.first(where: { n.contains(" " + $0.phrase + " ") }) {
            return config.target(id: hit.id)
        }
        if frontmostPhrases.contains(where: { n.contains(" " + $0 + " ") }) {
            return frontmostTarget()
        }
        return bareName(text)
    }

    private var sendCommands: Set<String> {
        guard let phrases = config.sendPhrases, !phrases.isEmpty else { return [] }
        let explicit = Lang.t(["ok tu peux envoyer", "c est bon tu peux envoyer"])
        // Toute phrase de `sendPhrases` compte : c'est l'utilisateur qui choisit les siennes (« ok on voit »).
        return Set(phrases.map(normalize) + explicit).subtracting([""])
    }

    func isSendCommand(_ text: String) -> Bool {
        sendCommands.contains(normalize(text))
    }

    /// Vrai si la transcription se termine par une phrase d'arrêt du micro.
    func endsWithStopPhrase(_ text: String) -> Bool { endsWith(text, stopCommands) }

    private var stopCommands: [String] {
        (config.stopPhrases ?? []) + (config.continuousConversation == true ? Lang.t(["garde le brouillon"]) : [])
    }

    func isStandaloneStop(_ text: String) -> Bool {
        let phrase = normalize(text)
        return !phrase.isEmpty && stopCommands.map(normalize).contains(phrase)
    }

    func isThoughtPause(_ text: String) -> Bool {
        config.continuousConversation == true && Lang.t(["attends je réfléchis"]).map(normalize).contains(normalize(text))
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
        return ((config.interruptPhrases ?? []) + strongInterruptPhrases).map(normalize).contains { !$0.isEmpty && n.contains(" " + $0 + " ") }
    }

    /// Interruptions « nommées » (« stop Claude », « Claude écoute ») : elles n'apparaissent presque jamais dans une
    /// réponse lue, donc elles passent du premier coup, sans vérifier si la voix de lecture vient de les dire.
    var strongInterruptPhrases: [String] {
        if let custom = config.strongInterruptPhrases { return custom }
        let names = Set(config.targets.map { normalize($0.id) } + ["claude", "codex", "gemini", "chatgpt", "assistant"])
            .filter { $0.count >= 4 && !$0.contains(" ") }
        let patterns = Lang.list("router.strongInterrupts", ["stop %@", "%@ stop", "écoute %@", "%@ écoute", "écoute moi %@", "attends %@"])
        return names.flatMap { name in patterns.map { $0.replacingOccurrences(of: "%@", with: name) } }
    }

    /// Interruption nommée entendue, sauf si `shown` (texte affiché ou lu) la contient aussi : la voix de lecture
    /// pourrait alors être en train de la dire, et la vérification habituelle s'applique.
    /// Phrases retirées du texte tapé par VoiceWake.
    var sendPhrasesForTyping: [String] { Array(sendCommands) + (config.sendPhrases ?? []) }
    var stopPhrasesForTyping: [String] { stopCommands }
    var thoughtPausePhrases: [String] { Lang.t(["attends je réfléchis", "attends", "je réfléchis", "garde le brouillon"]) }

    /// Texte d'origine sans la phrase finale (la plus longue qui le termine) parmi `phrases`.
    func withoutTrailing(_ text: String, _ phrases: [String]) -> String {
        let n = " " + normalize(text)
        guard let hit = phrases.map(normalize).filter({ !$0.isEmpty && n.hasSuffix(" " + $0) }).max(by: { $0.count < $1.count })
        else { return text }
        return SkillCatalog.originalSlice(text, skippingWords: 0, droppingLastWords: hit.split(separator: " ").count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
    }

    func isStrongInterrupt(_ text: String, notIn shown: String) -> Bool {
        let n = " " + normalize(text) + " ", seen = " " + normalize(shown) + " "
        return strongInterruptPhrases.map(normalize).contains { !$0.isEmpty && n.contains(" " + $0 + " ") && !seen.contains(" " + $0 + " ") }
    }

    private func endsWith(_ text: String, _ phrases: [String]?) -> Bool { suffix(text, phrases) != nil }

    /// La plus longue phrase normalisée qui termine le texte.
    private func suffix(_ text: String, _ phrases: [String]?) -> String? {
        let n = " " + normalize(text)
        return (phrases ?? []).map(normalize).filter { !$0.isEmpty && n.hasSuffix(" " + $0) }.max { $0.count < $1.count }
    }

    private static var closedPanels = Set<String>()

    /// Éditeur au premier plan qui intègre cet assistant → cible « dans l'éditeur ».
    /// nil si aucun éditeur n'est au premier plan, s'il n'intègre pas l'assistant,
    /// ou si le panneau de l'assistant n'est pas ouvert (bouton introuvable) : l'app de bureau prend le relais.
    func inEditor(_ t: Target) -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication, let bid = front.bundleIdentifier,
              let editor = config.editors?.first(where: { $0.bundleIDs.contains(bid) }),
              let a = editor.assistants[t.id] else { return nil }
        if !a.shortcut.buttons.isEmpty, AXButtonPresser.all(a.shortcut.buttons, in: front).isEmpty {
            // Appelé souvent (surveillance des questions) : n'écrire qu'une fois par situation.
            let key = "\(editor.id)/\(t.id)"
            if Self.closedPanels.insert(key).inserted { log("\(editor.id) au premier plan, mais panneau \(t.id) fermé : app de bureau.") }
            return nil
        }
        Self.closedPanels.remove("\(editor.id)/\(t.id)")
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
