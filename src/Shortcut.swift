import CoreGraphics
import Foundation

struct KeyCombo {
    let modifiers: [Key]
    let main: Key?
}

enum ShortcutStep {
    case press(KeyCombo, times: Int)
    case hold(KeyCombo, seconds: Double)
}

/// Raccourci décrit en texte. Exemples :
///   "ctrl+shift+v"        combinaison
///   "option+space"        combinaison
///   "double option"       double appui (ex. Quick Entry de Claude)
///   "capslock"            Verr. Maj. seul
///   "fn"                  touche Fn / globe seule
///   "hold 1.5 fn"         maintenir 1,5 s
///   "cmd+k then v"        enchaînement
///   "keycode:57"          code brut
struct Shortcut: Codable {
    let spec: String
    let steps: [ShortcutStep]
    /// "button:Dicter|Maintenez appuyé pour enregistrer" : clique le bouton micro de l'app (Accessibilité).
    var buttons: [String] = []

    init(spec: String) throws {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigError("Raccourci vide.") }
        if trimmed.lowercased().hasPrefix("button:") {
            let labels = trimmed.dropFirst(7).split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !labels.isEmpty else { throw ConfigError("Bouton sans libellé : \(trimmed)") }
            self.spec = trimmed
            self.steps = []
            self.buttons = labels
            return
        }
        let parts = trimmed.components(separatedBy: " then ").filter { !$0.isEmpty }
        self.spec = trimmed
        self.steps = try parts.map { try Shortcut.parseStep($0, in: trimmed) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            try self.init(spec: s)
            return
        }
        // Ancien format : { "key": "v", "modifiers": ["command"] }
        struct Legacy: Decodable { var key: String?; var keyCode: Int?; var modifiers: [String]? }
        let l = try c.decode(Legacy.self)
        let main = l.keyCode.map { "keycode:\($0)" } ?? l.key ?? ""
        try self.init(spec: ((l.modifiers ?? []) + [main]).filter { !$0.isEmpty }.joined(separator: "+"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(spec)
    }

    private static func parseStep(_ raw: String, in spec: String) throws -> ShortcutStep {
        var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var times = 1
        var hold: Double?

        switch tokens.first?.lowercased() {
        case "double", "2x": times = 2; tokens.removeFirst()
        case "triple", "3x": times = 3; tokens.removeFirst()
        case "hold":
            tokens.removeFirst()
            if let first = tokens.first, let seconds = Double(first.replacingOccurrences(of: ",", with: ".")) {
                hold = seconds
                tokens.removeFirst()
            } else {
                hold = 1
            }
        default: break
        }

        let names = tokens.joined().split(separator: "+").map(String.init)
        guard !names.isEmpty else { throw ConfigError("Raccourci incomplet : \(spec)") }
        var mods: [Key] = []
        var mains: [Key] = []
        for n in names {
            guard let k = KeyMap.key(named: n) else { throw ConfigError("Touche inconnue « \(n) » dans « \(spec) »") }
            if k.isModifier { mods.append(k) } else { mains.append(k) }
        }
        guard mains.count <= 1 else { throw ConfigError("Une seule touche principale par étape : \(spec)") }
        let combo = KeyCombo(modifiers: mods, main: mains.first)
        if let hold { return .hold(combo, seconds: hold) }
        return .press(combo, times: times)
    }
}

/// Rejoue un raccourci avec de vrais événements clavier (appui puis relâchement de chaque touche).
enum ShortcutPlayer {
    private static let queue = DispatchQueue(label: "voicewake.shortcut")

    static func play(_ shortcut: Shortcut, completion: @escaping () -> Void) {
        queue.async {
            for (i, step) in shortcut.steps.enumerated() {
                if i > 0 { wait(0.15) }
                switch step {
                case let .press(combo, times):
                    for t in 0..<times {
                        if t > 0 { wait(0.1) }
                        down(combo); wait(0.03); up(combo)
                    }
                case let .hold(combo, seconds):
                    down(combo); wait(seconds); up(combo)
                }
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func down(_ c: KeyCombo) {
        var flags: CGEventFlags = []
        for m in c.modifiers {
            if m.code == KeyMap.capsLock { toggleCapsLock(); continue }
            flags.formUnion(m.flags)
            post(m.code, type: .flagsChanged, flags: flags)
            wait(0.02)
        }
        if let k = c.main { post(k.code, type: .keyDown, flags: flags) }
    }

    private static func up(_ c: KeyCombo) {
        var held = c.modifiers.filter { $0.code != KeyMap.capsLock }
        var flags = held.reduce(CGEventFlags()) { $0.union($1.flags) }
        if let k = c.main { post(k.code, type: .keyUp, flags: flags) }
        while let m = held.popLast() {
            wait(0.02)
            flags = held.reduce(CGEventFlags()) { $0.union($1.flags) }
            post(m.code, type: .flagsChanged, flags: flags)
        }
    }

    /// Verr. Maj. se bascule : un seul événement, dans l'état opposé à l'état actuel.
    private static func toggleCapsLock() {
        let on = !CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        post(KeyMap.capsLock, type: .flagsChanged, flags: on ? .maskAlphaShift : [])
    }

    private static func post(_ code: CGKeyCode, type: CGEventType, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: type != .keyUp) else { return }
        e.type = type
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private static func wait(_ seconds: Double) { usleep(UInt32(max(0, seconds) * 1_000_000)) }
}
