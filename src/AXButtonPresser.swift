import AppKit
import ApplicationServices

/// Trouve un bouton par son libellé (titre ou description) dans les fenêtres d'une app et le presse.
enum AXButtonPresser {
    private static let roles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXRadioButton"]

    static func focusedWindow(in app: NSRunningApplication) -> AXUIElement? {
        value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
    }

    static func focusedTextField(in app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let field: AXUIElement = value(root, kAXFocusedUIElementAttribute), isEditable(field) else { return nil }
        return field
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
        if app.isActive { return true }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(el as! AXUIElement, &pid)
        return pid == app.processIdentifier
    }

    /// Demande à une app Electron/Chromium de construire son arbre d'accessibilité.
    /// La construction est asynchrone : à faire à l'avance, pas au moment du clic.
    static func enableAccessibility(_ app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Renvoie le libellé du bouton pressé, ou nil.
    static func press(_ labels: [String], in app: NSRunningApplication, window: AXUIElement? = nil) -> String? {
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
               window == nil || (isFrontmost(app) && focusedWindow(in: app).map { CFEqual($0, w) } == true),
               AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                return name
            }
        }
        return nil
    }

    /// Tous les éléments (boutons ou autres rôles si `anyRole`) dont le libellé exact est dans `labels`, dans l'ordre de l'arbre.
    static func all(_ labels: [String], in app: NSRunningApplication, anyRole: Bool = false) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let wanted = labels.map { $0.lowercased() }
        var out: [AXUIElement] = []
        for w in (value(root, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
            collect(w, wanted, anyRole: anyRole, depth: 0, into: &out)
        }
        return out
    }

    /// Presse le dernier élément trouvé (ex. « Lire à voix haute » du message le plus récent).
    static func pressLast(_ labels: [String], in app: NSRunningApplication) -> Bool {
        guard let last = all(labels, in: app).last else { return false }
        return AXUIElementPerformAction(last, kAXPressAction as CFString) == .success
    }

    /// Choisit une option dans un menu ouvert de l'app (menu contextuel ou déroulant), libellé exact.
    static func pressMenuItem(_ label: String, in app: NSRunningApplication) -> Bool {
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
        guard AXIsProcessTrusted(), let item = search(AXUIElementCreateApplication(app.processIdentifier), 0) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
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
        if let role: String = value(e, kAXRoleAttribute), roles.contains(role) {
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
