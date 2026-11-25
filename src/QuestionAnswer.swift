import AppKit

/// Répondre à la voix aux questions affichées par l'assistant (carte à options avec « Autre » et « Passer ») :
/// dire le libellé d'une option (« envoyer tout de suite »), son rang (« la deuxième »), « passe », ou
/// « réponds … » pour une réponse libre (tapée dans « Autre » puis envoyée).
struct QuestionCard {
    /// Titres des options (libellé suivi de sa description), dans l'ordre affiché.
    var options: [String]
    var hasOther: Bool
    /// Cases des options lues à l'écran : la réponse n'agit que sur ces mêmes éléments.
    var elements: [AXUIElement] = []
}

enum QuestionAnswer {
    enum Reply: Equatable {
        case option(Int)
        case skip
        case free(String)   // texte d'origine
    }

    static let otherLabels = ["autre", "other"]
    static let skipLabels = ["passer", "skip"]
    /// Rang dit → indice de l'option (mots déjà normalisés).
    static var ordinals: [String: Int] {
        Lang.map("question.ordinals", [
            "premiere": "0", "premier": "0", "un": "0", "une": "0", "1": "0", "deuxieme": "1", "seconde": "1", "second": "1",
            "deux": "1", "2": "1", "troisieme": "2", "trois": "2", "3": "2", "quatrieme": "3", "quatre": "3", "4": "3",
        ]).compactMapValues { Int($0) }
    }
    static var freePrefixes: [String] { Lang.list("question.freePrefixes", ["reponds", "reponse", "ma reponse est", "ma reponse"]) }
    /// Rang qui suffit dit seul (« deuxième ») ; un chiffre seul (« deux ») demande un mot de plus (« option deux »).
    static func standsAlone(_ word: String) -> Bool {
        Lang.isSource ? word.hasSuffix("ieme") || word == "premiere" : Lang.list("question.aloneOrdinals", []).contains(word)
    }

    /// Réponse dite pour cette carte, sinon nil. Option : libellé exact (ou début de titre propre à une seule option).
    static func match(_ text: String, card: QuestionCard) -> Reply? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        let words = s.split(separator: " ").map(String.init)
        // Réponse libre : « réponds non, ne fusionne pas ».
        for p in freePrefixes.sorted(by: { $0.count > $1.count }) where s.hasPrefix(p + " ") {
            let n = p.split(separator: " ").count
            let free = SkillCatalog.originalSlice(text, skippingWords: n, droppingLastWords: 0)
                .trimmingCharacters(in: CharacterSet(charactersIn: " :,"))
            return card.hasOther && !free.isEmpty ? .free(free) : nil
        }
        if Lang.list("question.skip", ["passe", "passer", "passe la question", "saute la question"]).contains(s) { return .skip }
        // Rang : « la deuxième », « option deux », « la première option », « choix trois ».
        let noise = Lang.list("question.fillers", ["la", "le", "l", "option", "choix", "reponse", "numero"])
        let core = words.filter { !noise.contains($0) }
        if core.count == 1, let i = ordinals[core[0]], words.count >= 2 || standsAlone(words[0]),
           i < card.options.count { return .option(i) }
        let titles = card.options.map(normalize)
        if let i = titles.firstIndex(of: s) { return .option(i) }
        let starts = titles.indices.filter { titles[$0].hasPrefix(s + " ") }
        if starts.count == 1 { return .option(starts[0]) }
        // Libellé suivi de « (Recommended) » ou « recommandé » dans le titre : le dire sans ce mot suffit (déjà couvert).
        return nil
    }

    // MARK: Lecture de la carte (hors fil principal)

    /// Carte de question visible : dans l'app Claude, les options sont des cases (AXCheckBox) d'un même groupe,
    /// avec « Autre » dans un sous-groupe ; « Passer » est un bouton à côté.
    static func card(in app: NSRunningApplication) -> (card: QuestionCard, buttons: [AXUIElement], other: AXUIElement?, skip: AXUIElement?)? {
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func title(_ e: AXUIElement) -> String {
            [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attr(e, $0) as? String }.first { !$0.isEmpty } ?? ""
        }
        let buttons = AXButtonPresser.visibleButtons(in: app)
        func element(_ v: CFTypeRef?) -> AXUIElement? {
            guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        guard let other = buttons.last(where: { otherLabels.contains(normalize($0.title)) })?.element,
              let p1 = element(attr(other, kAXParentAttribute)), let container = element(attr(p1, kAXParentAttribute)) else { return nil }
        let children = (attr(container, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let options = children.filter {
            (attr($0, kAXRoleAttribute) as? String) == "AXCheckBox" && !title($0).isEmpty && !otherLabels.contains(normalize(title($0)))
        }
        guard !options.isEmpty, options.count <= 8 else { return nil }
        let skip = buttons.last(where: { skipLabels.contains(normalize($0.title)) })?.element
        return (QuestionCard(options: options.map(title), hasOther: true, elements: options), options, other, skip)
    }

    static let submitLabels = ["envoyer", "submit", "send", "valider"]

    /// Bouton « Envoyer » de la carte : frère de « Passer ».
    static func submit(near skip: AXUIElement?, in app: NSRunningApplication) -> Bool {
        guard let skip, AXButtonPresser.isFrontmost(app) else { return false }
        var parent: CFTypeRef?, kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(skip, kAXParentAttribute as CFString, &parent) == .success, let parent,
              CFGetTypeID(parent) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return false }
        for c in children {
            var t: CFTypeRef?, d: CFTypeRef?
            AXUIElementCopyAttributeValue(c, kAXTitleAttribute as CFString, &t)
            AXUIElementCopyAttributeValue(c, kAXDescriptionAttribute as CFString, &d)
            let title = normalize(((t as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? (d as? String) ?? "")
            if submitLabels.contains(title) { return AXUIElementPerformAction(c, kAXPressAction as CFString) == .success }
        }
        return false
    }

    /// Exécute la réponse ; la carte est relue juste avant (rien ne se passe si elle a changé ou disparu).
    static func perform(_ reply: Reply, expected: QuestionCard, in app: NSRunningApplication) -> Bool {
        guard AXButtonPresser.isFrontmost(app), let now = card(in: app), now.card.options == expected.options,
              expected.elements.isEmpty || (expected.elements.count == now.buttons.count
                  && zip(expected.elements, now.buttons).allSatisfy { CFEqual($0, $1) }) else { return false }
        func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
        switch reply {
        case let .option(i):
            guard i < now.buttons.count else { return false }
            // Choisir l'option (case cochée), puis « Envoyer » à côté de « Passer ».
            let target = now.buttons[i]
            var checked: CFTypeRef?
            AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &checked)
            if (checked as? Int) != 1 { guard press(target) else { return false } }
            usleep(300_000)
            return submit(near: now.skip, in: app)
        case .skip:
            return now.skip.map(press) ?? false
        case let .free(text):
            guard let other = now.other, press(other) else { return false }
            usleep(400_000)
            guard let field = AXButtonPresser.focusedTextField(in: app),
                  TextTyper.type(text, to: app.processIdentifier, while: {
                      AXButtonPresser.isFrontmost(app) && AXButtonPresser.focusedTextField(in: app).map { CFEqual($0, field) } == true
                  }) else { return false }
            usleep(200_000)
            return submit(near: now.skip, in: app) // jamais de touche Entrée « à l'aveugle »
        }
    }
}
