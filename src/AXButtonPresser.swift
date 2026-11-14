import AppKit
import ApplicationServices

/// Trouve un bouton par son libellé (titre ou description) dans les fenêtres d'une app et le presse.
enum AXButtonPresser {
    private static let roles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXRadioButton"]

    /// Renvoie le libellé du bouton pressé, ou nil.
    static func press(_ labels: [String], in app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Applications Electron/Chromium : exposer l'arbre d'accessibilité.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windows: [AXUIElement] = []
        if let focused: AXUIElement = value(root, kAXFocusedWindowAttribute) { windows.append(focused) }
        windows += (value(root, kAXWindowsAttribute) as [AXUIElement]?) ?? []

        let wanted = labels.map { $0.lowercased() }
        // Libellé exact uniquement : évite de cliquer un message qui contient le mot.
        for w in windows {
            if let (el, name) = find(w, wanted, depth: 0),
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
