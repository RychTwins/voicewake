import AppKit

/// Réglages Système à la voix : ouvrir un volet (« ouvre les réglages du son »), Wi-Fi, mode sombre.
/// Dans le volet ouvert, « clique sur … » et « menu … » font le reste (Réglages Système est une app autorisée).
enum SettingsCommand: Equatable {
    case pane(String)       // identifiant du volet
    case wifi(Bool)
    case darkMode(Bool)

    /// Couper le Wi-Fi peut couper la connexion en cours : confirmation.
    var dangerous: Bool { self == .wifi(false) }

    var title: String {
        switch self {
        case .pane: return "ouvrir un volet des réglages"
        case let .wifi(on): return on ? "activer le Wi-Fi" : "couper le Wi-Fi"
        case let .darkMode(on): return on ? "mode sombre" : "mode clair"
        }
    }
}

enum SettingsCommands {
    /// Nom dit (normalisé) → volet des Réglages Système (macOS 13 et plus).
    static let panes: [String: String] = [
        "wifi": "com.apple.wifi-settings-extension", "wi fi": "com.apple.wifi-settings-extension",
        "reseau": "com.apple.Network-Settings.extension", "bluetooth": "com.apple.BluetoothSettings",
        "son": "com.apple.Sound-Settings.extension", "audio": "com.apple.Sound-Settings.extension",
        "ecran": "com.apple.Displays-Settings.extension", "ecrans": "com.apple.Displays-Settings.extension",
        "moniteur": "com.apple.Displays-Settings.extension", "affichage": "com.apple.Displays-Settings.extension",
        "notifications": "com.apple.Notifications-Settings.extension", "batterie": "com.apple.Battery-Settings.extension",
        "clavier": "com.apple.Keyboard-Settings.extension", "souris": "com.apple.Mouse-Settings.extension",
        "trackpad": "com.apple.Trackpad-Settings.extension",
        "confidentialite": "com.apple.settings.PrivacySecurity.extension", "securite": "com.apple.settings.PrivacySecurity.extension",
        "confidentialite et securite": "com.apple.settings.PrivacySecurity.extension",
        "accessibilite": "com.apple.Accessibility-Settings.extension",
        "fond d ecran": "com.apple.Wallpaper-Settings.extension", "fond ecran": "com.apple.Wallpaper-Settings.extension",
        "general": "com.apple.systempreferences.GeneralSettings",
        "mise a jour": "com.apple.Software-Update-Settings.extension", "mises a jour": "com.apple.Software-Update-Settings.extension",
        "concentration": "com.apple.Focus-Settings.extension", "ne pas deranger": "com.apple.Focus-Settings.extension",
        "ecran verrouille": "com.apple.Lock-Screen-Settings.extension", "utilisateurs": "com.apple.Users-Groups-Settings.extension",
        "centre de controle": "com.apple.ControlCenter-Settings.extension", "apparence": "com.apple.Appearance-Settings.extension",
        "bureau et dock": "com.apple.Desktop-Settings.extension", "dock": "com.apple.Desktop-Settings.extension",
        "partage": "com.apple.Sharing-Settings.extension", "imprimantes": "com.apple.Print-Scan-Settings.extension",
        "siri": "com.apple.Siri-Settings.extension", "stockage": "com.apple.settings.Storage",
        "date et heure": "com.apple.Date-Time-Settings.extension", "langue": "com.apple.Localization-Settings.extension",
        "langue et region": "com.apple.Localization-Settings.extension", "touch id": "com.apple.Touch-ID-Settings.extension",
        "mots de passe": "com.apple.Passwords-Settings.extension", "temps d ecran": "com.apple.Screen-Time-Settings.extension",
    ]

    static func match(_ text: String) -> SettingsCommand? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        switch s {
        case "active le wifi", "allume le wifi", "remets le wifi", "active le wi fi": return .wifi(true)
        case "coupe le wifi", "desactive le wifi", "eteins le wifi", "coupe le wi fi": return .wifi(false)
        case "active le mode sombre", "mode sombre", "passe en mode sombre", "mets le mode sombre": return .darkMode(true)
        case "mode clair", "desactive le mode sombre", "passe en mode clair", "mets le mode clair": return .darkMode(false)
        default: break
        }
        let prefixes = ["ouvre les reglages", "ouvre les parametres", "ouvre le reglage", "ouvre les preferences",
                        "reglages", "parametres", "va dans les reglages", "va dans les parametres"]
        for p in prefixes.sorted(by: { $0.count > $1.count }) where s.hasPrefix(p + " ") {
            var rest = String(s.dropFirst(p.count + 1))
            for article in ["du ", "de la ", "des ", "de l ", "de ", "d "] where rest.hasPrefix(article) {
                rest = String(rest.dropFirst(article.count)); break
            }
            if let id = panes[rest] { return .pane(id) }
        }
        return nil
    }

    static func perform(_ c: SettingsCommand) -> Bool {
        switch c {
        case let .pane(id):
            guard let url = URL(string: "x-apple.systempreferences:\(id)") else { return false }
            return NSWorkspace.shared.open(url)
        case let .wifi(on):
            guard let device = wifiDevice() else { return false }
            return run("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"]).ok
        case let .darkMode(on):
            return FinderCommands.script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)").ok
        }
    }

    /// Interface Wi-Fi (souvent en0), lue dans networksetup.
    static func wifiDevice() -> String? {
        let out = run("/usr/sbin/networksetup", ["-listallhardwareports"]).output
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") { return String(lines[i + 1].dropFirst(8)) }
        }
        return nil
    }

    private static func run(_ tool: String, _ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "") }
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
