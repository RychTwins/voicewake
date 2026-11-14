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
        Array(Set(config.targets.flatMap(\.phrases) + config.frontmostPhrases))
    }

    func route(_ text: String) -> Target? {
        let n = " " + normalize(text) + " "
        if let hit = targetPhrases.first(where: { n.contains(" " + $0.phrase + " ") }) {
            return config.target(id: hit.id)
        }
        if frontmostPhrases.contains(where: { n.contains(" " + $0 + " ") }) {
            return frontmostTarget()
        }
        return nil
    }

    /// Vrai si la transcription se termine par une phrase d'envoi.
    func endsWithSendPhrase(_ text: String) -> Bool { endsWith(text, config.sendPhrases) }

    /// Courte commande d'envoi : au plus `sendMaxWords` mots, dont le dernier est une forme de `sendVerbs`.
    func isShortSendCommand(_ text: String) -> Bool {
        let words = normalize(text).split(separator: " ").map(String.init)
        let verbs = Set((config.sendVerbs ?? []).map(normalize))
        guard let last = words.last, !verbs.isEmpty else { return false }
        guard words.count <= (config.sendMaxWords ?? 5), verbs.contains(last) else { return false }
        // « Le Chromebook envoie » n'est pas un ordre : la phrase doit commencer par un mot d'amorce.
        let leads = (config.sendLeadWords ?? []).map(normalize).filter { !$0.isEmpty }
        if words.count == 1 || leads.isEmpty { return true }
        let joined = words.joined(separator: " ") + " "
        return leads.contains { joined.hasPrefix($0 + " ") }
    }

    /// Vrai si la transcription se termine par une phrase d'arrêt du micro.
    func endsWithStopPhrase(_ text: String) -> Bool { endsWith(text, config.stopPhrases) }

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

    /// Ce qui précède la phrase finale (texte normalisé), ou nil si la phrase n'y est pas.
    func bodyBeforeCommand(_ text: String) -> String? {
        guard let p = suffix(text, (config.sendPhrases ?? []) + (config.stopPhrases ?? [])) else { return nil }
        return String(normalize(text).dropLast(p.count + 1))
    }

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
            if let id = ids.first(where: { editor.assistants[$0] != nil }), let t = config.target(id: id) { return t }
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
