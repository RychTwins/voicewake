import AppKit
import ApplicationServices

/// Trouve un bouton par son libellé (titre ou description) dans les fenêtres d'une app et le presse.
enum AXButtonPresser {
    private static let roles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXRadioButton"]

    static func focusedWindow(in app: NSRunningApplication) -> AXUIElement? {
        value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
    }

    static func currentWindow(in app: NSRunningApplication) -> AXUIElement? {
        focusedWindow(in: app) ?? value(AXUIElementCreateApplication(app.processIdentifier), kAXMainWindowAttribute)
    }

    enum ConversationIdentity: Equatable {
        case route(String)
        case anchor(AXUIElement)
    }

    /// Ne retient ni le texte du brouillon ni la réponse en cours de génération.
    static func conversationIdentity(in window: AXUIElement, target: Target) -> ConversationIdentity? {
        let inEditor = target.id.contains("@")
        let assistants = [
            "com.anthropic.claudefordesktop": "claude", "com.openai.codex": "codex",
            "com.google.GeminiMacOS": "gemini", "com.openai.chat": "chatgpt"
        ]
        let assistant = inEditor ? target.id.split(separator: "@").first.map(String.init) : assistants[target.bundleID ?? ""]
        guard let assistant else { return nil }
        var remaining = 4000
        // Chat tout neuf de Claude (pas encore d'identifiant dans l'adresse) : la page elle-même sert de repère,
        // sinon l'envoi automatique après un silence reste désactivé pour tout le premier message.
        var newChat: ConversationIdentity?
        func find(in element: AXUIElement, depth: Int, inOutline: Bool) -> ConversationIdentity? {
            guard remaining > 0, depth < 65 else { return nil }
            remaining -= 1
            let role: String? = value(element, kAXRoleAttribute)
            if role == "AXMenuBar" { return nil }
            switch assistant {
            case "claude":
                if role == "AXWebArea", let url: URL = value(element, kAXURLAttribute) {
                    if let id = claudeConversationID(url) { return .route(id) }
                    if newChat == nil, url.host == "claude.ai" { newChat = .route("page:" + url.path) }
                }
            case "gemini":
                if !inEditor, role == "AXOutline",
                   let rows: [AXUIElement] = value(element, kAXSelectedRowsAttribute), rows.count == 1 {
                    return .anchor(rows[0])
                }
                if !inEditor, inOutline, role == "AXButton" || role == "AXRow",
                   (value(element, kAXSelectedAttribute) as Bool?) == true ||
                    (value(element, "AXARIACurrent") as String?) == "page" {
                    return .anchor(element)
                }
            case "codex":
                // Le titre de la fenêtre change pendant la réponse. Le repère est le message, jamais le titre.
                if !inEditor, role == "AXHeading",
                   let title: String = value(element, kAXTitleAttribute) ?? value(element, kAXDescriptionAttribute),
                   ["vous avez dit", "you said"].contains(normalize(title)) {
                    return .anchor(element)
                }
            case "chatgpt":
                if !inEditor, role == "AXWebArea", let url: URL = value(element, kAXURLAttribute),
                   url.scheme == "https", url.host == "chatgpt.com", url.pathComponents.count == 3,
                   url.pathComponents[1] == "c", let id = url.pathComponents.last, let uuid = UUID(uuidString: id) {
                    return .route(uuid.uuidString)
                }
            default: break
            }
            for child in (value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let result = find(in: child, depth: depth + 1, inOutline: inOutline || role == "AXOutline") { return result }
            }
            return nil
        }
        // Aucun repère (chat neuf de Codex ou Gemini, assistant intégré à un éditeur) : repère provisoire, remplacé
        // par le vrai dès qu'il apparaît. Sans lui, l'envoi automatique après un silence restait désactivé.
        if let found = find(in: window, depth: 0, inOutline: false) { return found }
        // Parcours interrompu (longue conversation, fenêtre très chargée) : repère inconnu, qui n'annule rien.
        if remaining <= 0 { return .route("page:") }
        return newChat ?? .route("page:new")
    }

    static func claudeConversationID(_ url: URL) -> String? {
        let path = url.pathComponents
        guard url.host == "claude.ai", path.count == 3,
              ["chat", "code", "epitaxy"].contains(path[1]),
              let id = path.last, UUID(uuidString: String(id.suffix(36))) != nil else { return nil }
        return id
    }

    static func codexReplyHeading(in window: AXUIElement) -> AXUIElement? {
        let assistant = ["chatgpt said", "chatgpt a dit", "codex said", "codex a dit"]
        var latest: AXUIElement?
        var budget = 4000
        func scan(_ node: AXUIElement, depth: Int) {
            guard budget > 0, depth < 65 else { return }
            budget -= 1
            let role: String? = value(node, kAXRoleAttribute)
            if role == "AXHeading", let title: String = value(node, kAXTitleAttribute) {
                let label = normalize(title)
                if assistant.contains(label) { latest = node }
                if ["you said", "vous avez dit"].contains(label) { latest = nil }
            }
            for child in (value(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                scan(child, depth: depth + 1)
            }
        }
        scan(window, depth: 0)
        return budget > 0 ? latest : nil
    }

    /// Réponse Codex terminée et délimitée par sa propre action Copier.
    static func codexReply(in window: AXUIElement) -> (heading: AXUIElement, text: String)? {
        guard let latest = codexReplyHeading(in: window), let parent: AXUIElement = value(latest, kAXParentAttribute),
              let siblings: [AXUIElement] = value(parent, kAXChildrenAttribute),
              let index = siblings.firstIndex(where: { CFEqual($0, latest) }) else { return nil }

        var words: [String] = []
        var nodes = 2000
        func collectText(_ node: AXUIElement, depth: Int) {
            guard nodes > 0, depth < 50 else { return }
            nodes -= 1
            let role: String? = value(node, kAXRoleAttribute)
            if role.map(roles.contains) == true { return }
            if role == "AXStaticText", let text: String = value(node, kAXValueAttribute), !text.isEmpty {
                words.append(text)
            }
            for child in (value(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                collectText(child, depth: depth + 1)
            }
        }
        for sibling in siblings.dropFirst(index + 1) {
            let role: String? = value(sibling, kAXRoleAttribute)
            if role == "AXButton" {
                let title: String = value(sibling, kAXTitleAttribute) ?? value(sibling, kAXDescriptionAttribute) ?? ""
                let labels = ["copier", "copy", "copier la reponse", "copy response", "copier le message", "copy message"]
                guard labels.contains(normalize(title)), nodes > 0, !words.isEmpty else { return nil }
                return (latest, words.joined(separator: " "))
            }
            guard role == "AXGroup" || role == "AXStaticText" else { return nil }
            collectText(sibling, depth: 0)
        }
        return nil
    }

    static func focusedTextField(in app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let field: AXUIElement = value(root, kAXFocusedUIElementAttribute), isEditable(field) else { return nil }
        return field
    }

    /// Donne le focus au champ et vérifie qu'il l'a bien reçu (sinon on ne tape rien).
    static func focusVerified(_ field: AXUIElement, in app: NSRunningApplication) -> Bool {
        _ = focus(field)
        usleep(150_000)
        guard let now = focusedTextField(in: app) else { return false }
        return CFEqual(now, field)
    }

    /// Zone de saisie de l'assistant : le champ qui a le focus s'il est modifiable, sinon le dernier champ
    /// modifiable de la fenêtre (le composeur est en bas de la conversation).
    static func composerField(in app: NSRunningApplication) -> AXUIElement? {
        if let f = focusedTextField(in: app) { return f }
        guard let window = currentWindow(in: app) else { return nil }
        var last: AXUIElement?
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 80, visited < 4000 else { return }
            visited += 1
            if isEditable(e) { last = e }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child, depth + 1) }
        }
        walk(window, 0)
        return last
    }

    static func textField(in window: AXUIElement, labeled labels: [String]) -> AXUIElement? {
        guard !labels.isEmpty else { return nil }
        let wanted = Set(labels.map(normalize))
        func findField(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth <= 120 else { return nil }
            if isEditable(element) {
                let names: [String] = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { value(element, $0) }
                if names.contains(where: { wanted.contains(normalize($0)) }) { return element }
            }
            let children: [AXUIElement] = value(element, kAXChildrenAttribute) ?? []
            return children.lazy.compactMap { findField($0, depth: depth + 1) }.first
        }
        return findField(window, depth: 0)
    }

    static func focus(_ field: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func startMacOSDictation(in app: NSRunningApplication, while allowed: () -> Bool) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = value(root, kAXMenuBarAttribute) else { return false }
        let menus: [AXUIElement] = value(bar, kAXChildrenAttribute) ?? []
        for menu in menus {
            let groups: [AXUIElement] = value(menu, kAXChildrenAttribute) ?? []
            for group in groups {
                let items: [AXUIElement] = value(group, kAXChildrenAttribute) ?? []
                for item in items where (value(item, kAXIdentifierAttribute) as String?) == "startDictation:" {
                    guard (value(item, kAXEnabledAttribute) as Bool?) != false, allowed() else { return false }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let role: String? = value(element, kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox",
              (value(element, kAXSubroleAttribute) as String?) != "AXSecureTextField",
              (value(element, kAXEnabledAttribute) as Bool?) != false else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// L'app est-elle réellement au premier plan ? `isActive` peut rester périmé dans un service
    /// en arrière-plan : on confirme par l'app active du système et par l'Accessibilité.
    static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
           let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(el as! AXUIElement, &pid) == .success { return pid == app.processIdentifier }
        }
        if let front = NSWorkspace.shared.frontmostApplication { return front.processIdentifier == app.processIdentifier }
        return app.isActive
    }

    /// Blocs de texte de la fenêtre active, avec leur élément et la zone web qui les contient.
    static func textBlocks(in app: NSRunningApplication) -> [(element: AXUIElement, web: AXUIElement?, text: String)] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var out: [(element: AXUIElement, web: AXUIElement?, text: String)] = []
        func walk(_ e: AXUIElement, _ depth: Int, _ web: AXUIElement?) {
            if depth > 150 || out.count > 6000 { return }
            let role: String? = value(e, kAXRoleAttribute)
            if role == "AXMenuBar" { return }
            let area = role == "AXWebArea" ? e : web
            if role == "AXStaticText", let s: String = value(e, kAXValueAttribute), !s.isEmpty { out.append((e, area, s)) }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child, depth + 1, area) }
        }
        if let w: AXUIElement = value(root, kAXFocusedWindowAttribute) ?? value(root, kAXMainWindowAttribute) { walk(w, 0, nil) }
        return out
    }

    /// Rectangle à l'écran d'un élément (coordonnées Cocoa, origine en bas à gauche), ou nil.
    static func frame(of element: AXUIElement) -> NSRect? {
        var p: CFTypeRef?, sz: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sz) == .success,
              let p, let sz, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(sz) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(sz as! AXValue, .cgSize, &size),
              size.width > 2, size.height > 2, let primary = NSScreen.screens.first else { return nil }
        // L'Accessibilité compte depuis le haut de l'écran principal.
        return NSRect(x: origin.x, y: primary.frame.height - origin.y - size.height, width: size.width, height: size.height)
    }

    /// Rectangle réel d'un bloc de texte web (coordonnées Cocoa), seulement s'il est visible dans la fenêtre active.
    static func textFrame(of element: AXUIElement, in web: AXUIElement, app: NSRunningApplication) -> NSRect? {
        var range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(web, "AXTextMarkerRangeForUIElement" as CFString, element, &range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(web, "AXBoundsForTextMarkerRange" as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 2, rect.height > 2,
              let primary = NSScreen.screens.first else { return nil }
        let cocoa = NSRect(x: rect.minX, y: primary.frame.height - rect.minY - rect.height, width: rect.width, height: rect.height)
        // Visible seulement : entièrement dans la fenêtre active de l'app.
        // Partie visible seulement : découpée sur la fenêtre active de l'app.
        guard let window = focusedWindow(in: app), let visible = frame(of: window) else { return nil }
        let shown = cocoa.intersection(visible)
        return shown.isNull || shown.height < 6 || shown.width < 6 ? nil : shown
    }

    /// Sélectionne un bloc de texte dans l'app (comme un surlignage à la souris).
    @discardableResult
    static func select(_ element: AXUIElement, in web: AXUIElement) -> Bool {
        var range: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(web, "AXTextMarkerRangeForUIElement" as CFString, element, &range) == .success,
              let range else { return false }
        return AXUIElementSetAttributeValue(web, "AXSelectedTextMarkerRange" as CFString, range) == .success
    }

    /// Marque de fin de message insérée par `windowTexts(in:boundaries:)` (jamais affichée, sans espace).
    static let messageEnd = "\u{1}"
    /// Titres cachés qui ouvrent chaque message (application Claude, en français et en anglais).
    static let messageHeadingPrefixes = ["vous avez dit", "claude a répondu", "you said", "claude responded", "claude said"]

    /// Tout le texte affiché dans les fenêtres de l'app (messages, titres), dans l'ordre de l'écran.
    /// `boundaries` : libellés des boutons qui suivent chaque réponse (ex. « Lire à voix haute ») ;
    /// à chacun, et entre deux fenêtres, une marque `messageEnd` est insérée.
    static func windowTexts(in app: NSRunningApplication, boundaries: [String] = [], window: AXUIElement? = nil) -> [String] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let ends = Set(boundaries.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        var out: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            if depth > 150 || out.count > 6000 { return }
            let role: String? = value(e, kAXRoleAttribute)
            if role == "AXMenuBar" { return }
            if role == "AXStaticText", let s: String = value(e, kAXValueAttribute), !s.isEmpty { out.append(s) }
            else if role == "AXHeading", let s: String = value(e, kAXTitleAttribute) ?? value(e, kAXDescriptionAttribute) {
                // « Vous avez dit : … » / « Claude a répondu : … » : titre caché qui annonce un message
                // (et répète son texte) → début d'un nouveau message, pas du texte à lire.
                let lower = s.lowercased()
                if !ends.isEmpty, messageHeadingPrefixes.contains(where: { lower.hasPrefix($0) }) {
                    if out.last != messageEnd { out.append(messageEnd) }
                } else { out.append(s) }
            }
            else if !ends.isEmpty, let role, roles.contains(role),
                    [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute)].compactMap({ $0 as String? })
                        .contains(where: { ends.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }),
                    out.last != messageEnd {
                out.append(messageEnd)
            }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child, depth + 1) }
        }
        // Fenêtre active d'abord (certaines apps ne listent pas toutes leurs fenêtres), puis les autres.
        if let window {
            walk(window, 0)
            return out
        }
        var windows: [AXUIElement] = []
        if let focused: AXUIElement = value(root, kAXFocusedWindowAttribute) { windows.append(focused) }
        if let main: AXUIElement = value(root, kAXMainWindowAttribute), !windows.contains(where: { CFEqual($0, main) }) { windows.append(main) }
        for w in (value(root, kAXWindowsAttribute) as [AXUIElement]?) ?? [] where !windows.contains(where: { CFEqual($0, w) }) {
            windows.append(w)
        }
        for w in windows {
            walk(w, 0)
            if !ends.isEmpty, !out.isEmpty, out.last != messageEnd { out.append(messageEnd) }
        }
        return out
    }

    /// Demande à une app Electron/Chromium de construire son arbre d'accessibilité.
    /// La construction est asynchrone : à faire à l'avance, pas au moment du clic.
    static func enableAccessibility(_ app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Renvoie le libellé du bouton pressé, ou nil.
    static func press(_ labels: [String], in app: NSRunningApplication, window: AXUIElement? = nil,
                      while allowed: () -> Bool = { true }) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Applications Electron/Chromium : exposer l'arbre d'accessibilité.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let windows: [AXUIElement]
        if let window {
            windows = [window]
        } else {
            let focused: AXUIElement? = value(root, kAXFocusedWindowAttribute)
            windows = [focused].compactMap { $0 } + ((value(root, kAXWindowsAttribute) as [AXUIElement]?) ?? [])
        }

        let wanted = labels.map { $0.lowercased() }
        // Libellé exact uniquement : évite de cliquer un message qui contient le mot.
        for w in windows {
            if let (el, name) = find(w, wanted, depth: 0),
               window == nil || (isFrontmost(app) && currentWindow(in: app).map { CFEqual($0, w) } == true),
               activate(el, in: app, while: allowed) {
                return name
            }
        }
        return nil
    }

    /// L'envoi automatique n'agit que si un bouton d'envoi actif est identifiable sans ambiguïté.
    static func pressUniqueSend(_ labels: [String], in app: NSRunningApplication, window: AXUIElement,
                                while allowed: () -> Bool) -> Bool {
        guard let field = composerField(in: app) else { return false }
        // Une carte de choix peut aussi avoir un bouton « Envoyer » : il faut un voisin du composeur.
        func ancestors(_ element: AXUIElement) -> [AXUIElement] {
            var parents: [AXUIElement] = []
            var current = element
            for _ in 0..<5 {
                guard let parent: AXUIElement = value(current, kAXParentAttribute), !CFEqual(parent, window),
                      (value(parent, kAXRoleAttribute) as String?) != "AXWebArea" else { break }
                parents.append(parent)
                current = parent
            }
            return parents
        }
        let fieldParents = ancestors(field)
        let buttons = all(labels, in: app, window: window).filter {
            guard (value($0, kAXEnabledAttribute) as Bool?) == true,
                  (value($0, kAXRoleAttribute) as String?) == "AXButton" else { return false }
            let buttonParents = ancestors($0)
            return fieldParents.contains { node in buttonParents.contains { CFEqual(node, $0) } }
        }
        guard buttons.count == 1 else { return false }
        return activate(buttons[0], in: app, while: allowed)
    }

    /// Tous les éléments (boutons ou autres rôles si `anyRole`) dont le libellé exact est dans `labels`, dans l'ordre de l'arbre.
    static func all(_ labels: [String], in app: NSRunningApplication, window: AXUIElement? = nil, anyRole: Bool = false) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let wanted = labels.map { $0.lowercased() }
        var out: [AXUIElement] = []
        for w in window.map({ [$0] }) ?? ((value(root, kAXWindowsAttribute) as [AXUIElement]?) ?? []) {
            collect(w, wanted, anyRole: anyRole, depth: 0, into: &out)
        }
        return out
    }

    /// Presse le dernier élément trouvé (ex. « Lire à voix haute » du message le plus récent).
    static func pressLast(_ labels: [String], in app: NSRunningApplication, window: AXUIElement,
                          while allowed: () -> Bool = { true }) -> Bool {
        guard let last = all(labels, in: app, window: window).last,
              isFrontmost(app), currentWindow(in: app).map({ CFEqual($0, window) }) == true else { return false }
        return activate(last, in: app, while: allowed)
    }

    /// Appuie sur un élément : action AXPress s'il la propose, sinon focus clavier + Espace, sinon vrai clic de souris.
    /// (Codex : « Lire à voix haute » n'expose pas AXPress ; l'action « réussit » sans rien lancer.)
    static func activate(_ el: AXUIElement, in app: NSRunningApplication, while allowed: () -> Bool = { true }) -> Bool {
        guard allowed() else { return false }
        var names: CFArray?
        let listed = AXUIElementCopyActionNames(el, &names) == .success
        if !listed || ((names as? [String]) ?? []).contains(kAXPressAction as String) {
            return allowed() && AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        }
        guard isFrontmost(app) else { return false }
        AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
        usleep(300_000)
        // Sans pointeur : on donne le focus clavier à l'élément, puis Espace, envoyé à l'app seulement.
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let before: AXUIElement? = value(root, kAXFocusedUIElementAttribute)
        if AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            usleep(250_000)
            // Espace seulement si le focus est bien sur l'élément : sinon il s'écrirait dans le champ de saisie.
            if isFrontmost(app), let focused: AXUIElement = value(root, kAXFocusedUIElementAttribute),
               CFEqual(focused, el), allowed() {
                let source = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: down)?.postToPid(app.processIdentifier)
                    usleep(50_000)
                }
                usleep(250_000)
                if let before { AXUIElementSetAttributeValue(before, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
                return true
            }
        }
        // Focus refusé : vrai clic de souris (le pointeur bouge un court instant).
        func rect(_ e: AXUIElement) -> CGRect? {
            var p: CFTypeRef?, sz: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sz) == .success,
                  let p, let sz, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(sz) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(sz as! AXValue, .cgSize, &size),
                  size.width > 2, size.height > 2 else { return nil }
            return CGRect(origin: origin, size: size)
        }
        /// Centre de l'élément, seulement si l'app est devant et que le point est dans sa fenêtre active.
        func target() -> CGPoint? {
            guard allowed(), isFrontmost(app), let r = rect(el), let window = currentWindow(in: app),
                  let w = rect(window) else { return nil }
            let point = CGPoint(x: r.midX, y: r.midY)
            return w.contains(point) ? point : nil
        }
        guard let point = target() else { return false }
        let back = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ at: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, point)
        usleep(250_000) // le survol fait apparaître la barre d'actions du message
        // Rien n'a bougé pendant l'attente (autre app passée devant, défilement) : sinon on ne clique pas.
        guard let again = target(), abs(again.x - point.x) < 2, abs(again.y - point.y) < 2 else {
            if let back { post(.mouseMoved, back) }
            return false
        }
        post(.leftMouseDown, point)
        usleep(60_000)
        post(.leftMouseUp, point)
        usleep(150_000)
        if let back { post(.mouseMoved, back) }
        return true
    }

    /// Choisit une commande de la barre de menus de l'app (ex. Fichier > « Nouvelle session »), sans ouvrir le menu.
    /// Premier libellé trouvé dans l'ordre de `labels`, libellé exact, option active uniquement. Renvoie le libellé choisi.
    static func pressMenuBarItem(_ labels: [String], in app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = value(root, kAXMenuBarAttribute) else { return nil }
        var items: [(title: String, element: AXUIElement)] = []
        // Menus et sous-menus (ex. Affichage > Vue divisée > …), options actives seulement.
        func collectItems(_ menu: AXUIElement, _ depth: Int) {
            guard depth < 4 else { return }
            for item in (value(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
            where (value(item, kAXEnabledAttribute) as Bool?) != false {
                if let title: String = value(item, kAXTitleAttribute), !title.isEmpty { items.append((title, item)) }
                for sub in (value(item, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collectItems(sub, depth + 1) }
            }
        }
        for top in (value(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        where (value(top, kAXTitleAttribute) as String?) != "Apple" {
            for menu in (value(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collectItems(menu, 0) }
        }
        for label in labels {
            let wanted = label.lowercased().trimmingCharacters(in: .whitespaces)
            if let hit = items.first(where: { $0.title.lowercased() == wanted }),
               AXUIElementPerformAction(hit.element, kAXPressAction as CFString) == .success { return hit.title }
        }
        return nil
    }

    /// Toutes les options actives de la barre de menus (sous-menus compris, menu Apple exclu), avec leur chemin
    /// (« Affichage > Vue divisée ») et leur raccourci éventuel.
    static func allMenuBarItems(in app: NSRunningApplication) -> [(title: String, path: String, element: AXUIElement)] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = value(root, kAXMenuBarAttribute) else { return [] }
        var out: [(title: String, path: String, element: AXUIElement)] = []
        func collect(_ menu: AXUIElement, _ path: String, _ depth: Int) {
            guard depth < 4, out.count < 1500 else { return }
            for item in (value(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
            where (value(item, kAXEnabledAttribute) as Bool?) != false {
                guard let title: String = value(item, kAXTitleAttribute), !title.isEmpty else { continue }
                let subs = (value(item, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                if subs.isEmpty { out.append((title, path, item)) }
                for sub in subs { collect(sub, path + " > " + title, depth + 1) }
            }
        }
        for top in (value(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            guard let t: String = value(top, kAXTitleAttribute), t != "Apple", !t.isEmpty else { continue }
            for menu in (value(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collect(menu, t, 0) }
        }
        return out
    }

    /// Libellé actuel d'un élément (titre ou description) et s'il est actif : relu juste avant d'agir.
    static func currentLabel(of e: AXUIElement) -> (label: String?, enabled: Bool) {
        let label = [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute)].compactMap { $0 as String? }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (label, (value(e, kAXEnabledAttribute) as Bool?) != false)
    }

    /// Boutons actifs de la fenêtre au premier plan, avec leur libellé (titre ou description).
    static func visibleButtons(in app: NSRunningApplication) -> [(title: String, element: AXUIElement)] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = value(root, kAXFocusedWindowAttribute) ?? value(root, kAXMainWindowAttribute) else { return [] }
        var out: [(title: String, element: AXUIElement)] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 80, out.count < 1500 else { return }
            if let role: String = value(e, kAXRoleAttribute), roles.contains(role) || role == "AXLink",
               (value(e, kAXEnabledAttribute) as Bool?) != false,
               let t = [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute)].compactMap({ $0 as String? })
                   .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                out.append((t, e))
            }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child, depth + 1) }
        }
        walk(window, 0)
        return out
    }

    /// Options actives des menus de la barre de menus dont le titre est dans `tops` (ex. « Discussions »).
    static func menuBarItems(under tops: [String], in app: NSRunningApplication) -> [(title: String, element: AXUIElement)] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = value(root, kAXMenuBarAttribute) else { return [] }
        let wanted = Set(tops.map { $0.lowercased() })
        var out: [(title: String, element: AXUIElement)] = []
        for top in (value(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        where (value(top, kAXTitleAttribute) as String?).map({ wanted.contains($0.lowercased()) }) == true {
            for menu in (value(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (value(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                where (value(item, kAXEnabledAttribute) as Bool?) != false {
                    if let t: String = value(item, kAXTitleAttribute), !t.isEmpty { out.append((t, item)) }
                }
            }
        }
        return out
    }

    /// Entrée de la barre latérale de l'app (Claude : projets, sessions, navigation).
    struct SidebarEntry {
        enum Kind { case project, session, newSession }
        let title: String
        let element: AXUIElement
        let kind: Kind
        /// Projet (titre de section) sous lequel l'entrée apparaît, ou nil.
        let project: String?
    }

    static let sidebarLabels = ["barre latérale", "sidebar"]
    static let newSessionPrefixes = ["nouvelle session dans ", "new session in "]

    /// Entrées de la barre latérale de la fenêtre active, dans l'ordre de l'écran (vide si l'app n'en expose pas).
    static func sidebarEntries(in app: NSRunningApplication) -> [SidebarEntry] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = value(root, kAXFocusedWindowAttribute) ?? value(root, kAXMainWindowAttribute) else { return [] }
        func label(_ e: AXUIElement) -> String? {
            [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute)].compactMap { $0 as String? }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        func findSidebar(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 40 { return nil }
            if (value(e, kAXRoleAttribute) as String?) == "AXGroup",
               let l = label(e)?.lowercased(), sidebarLabels.contains(l) { return e }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let hit = findSidebar(child, depth + 1) { return hit }
            }
            return nil
        }
        guard let sidebar = findSidebar(window, 0) else { return [] }
        var out: [SidebarEntry] = []
        var section: String?
        func walk(_ e: AXUIElement, _ depth: Int) {
            if depth > 60 || out.count > 800 { return }
            let role: String? = value(e, kAXRoleAttribute)
            if role == "AXHeading", let l = label(e) { section = l }
            else if role == "AXButton", let l = label(e) {
                let lower = l.lowercased()
                if newSessionPrefixes.contains(where: { lower.hasPrefix($0) }) {
                    out.append(SidebarEntry(title: l, element: e, kind: .newSession, project: section))
                } else if let section, l == section {
                    out.append(SidebarEntry(title: l, element: e, kind: .project, project: section))
                } else {
                    out.append(SidebarEntry(title: l, element: e, kind: .session, project: section))
                }
            }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child, depth + 1) }
        }
        walk(sidebar, 0)
        return out
    }

    /// Choisit l'option dès que le menu est ouvert (essai toutes les 20 ms) : le menu ne reste visible qu'un instant.
    static func pressMenuItemSoon(_ label: String, in app: NSRunningApplication, within seconds: Double = 1.2,
                                  while allowed: () -> Bool = { true }) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard allowed() else { return false }
            if pressMenuItem(label, in: app, while: allowed) { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }

    /// Choisit une option dans un menu ouvert de l'app (menu contextuel ou déroulant), libellé exact.
    static func pressMenuItem(_ label: String, in app: NSRunningApplication,
                              while allowed: () -> Bool = { true }) -> Bool {
        let wanted = label.lowercased()
        // Jamais dans la barre de menus en haut de l'écran ; option active uniquement, libellé exact.
        func search(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 60 { return nil }
            let role: String? = value(e, kAXRoleAttribute)
            if role == "AXMenuBar" { return nil }
            if role == "AXMenuItem", (value(e, kAXTitleAttribute) as String?)?.lowercased() == wanted,
               (value(e, kAXEnabledAttribute) as Bool?) != false { return e }
            for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let hit = search(child, depth + 1) { return hit }
            }
            return nil
        }
        guard AXIsProcessTrusted() else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Chemin rapide : un menu ouvert est souvent un enfant direct de l'app ou de sa fenêtre active.
        var near = (value(root, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        if let window: AXUIElement = value(root, kAXFocusedWindowAttribute) { near += (value(window, kAXChildrenAttribute) as [AXUIElement]?) ?? [] }
        let menus = near.filter { (value($0, kAXRoleAttribute) as String?) == "AXMenu" }
        guard let item = menus.lazy.compactMap({ search($0, 0) }).first ?? search(root, 0) else { return false }
        return allowed() && AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func collect(_ e: AXUIElement, _ wanted: [String], anyRole: Bool, depth: Int, into out: inout [AXUIElement]) {
        if depth > 120 { return }
        let role: String? = value(e, kAXRoleAttribute)
        if anyRole || role.map(roles.contains) == true {
            let names = [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute)].compactMap { $0 as String? }
            if names.contains(where: { wanted.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }) { out.append(e) }
        }
        for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            collect(child, wanted, anyRole: anyRole, depth: depth + 1, into: &out)
        }
    }

    private static func find(_ e: AXUIElement, _ wanted: [String], depth: Int) -> (AXUIElement, String)? {
        if depth > 120 { return nil }
        if let role: String = value(e, kAXRoleAttribute), roles.contains(role),
           (value(e, kAXEnabledAttribute) as Bool?) != false {
            for name in [value(e, kAXTitleAttribute), value(e, kAXDescriptionAttribute)].compactMap({ $0 as String? }) {
                if wanted.contains(name.lowercased().trimmingCharacters(in: .whitespaces)) { return (e, name) }
            }
        }
        for child in (value(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let hit = find(child, wanted, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func value<T>(_ e: AXUIElement, _ attribute: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? T
    }
}
