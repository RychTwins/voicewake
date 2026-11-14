import Carbon
import CoreGraphics

/// Une touche physique. `flags` est vide pour une touche normale.
struct Key {
    let code: CGKeyCode
    let flags: CGEventFlags
    var isModifier: Bool { KeyMap.isModifier(code) }
}

enum KeyMap {
    static let capsLock: CGKeyCode = 57

    // Touches de modification : noms acceptés, code, drapeaux (dont bits gauche/droite).
    private static let modifiers: [(names: [String], code: CGKeyCode, flags: UInt64)] = [
        (["control", "ctrl", "⌃", "lcontrol", "lctrl"], 59, CGEventFlags.maskControl.rawValue | 0x0001),
        (["rcontrol", "rctrl"], 62, CGEventFlags.maskControl.rawValue | 0x2000),
        (["option", "opt", "alt", "⌥", "loption", "lalt"], 58, CGEventFlags.maskAlternate.rawValue | 0x0020),
        (["roption", "ropt", "ralt"], 61, CGEventFlags.maskAlternate.rawValue | 0x0040),
        (["shift", "⇧", "lshift", "maj"], 56, CGEventFlags.maskShift.rawValue | 0x0002),
        (["rshift", "rmaj"], 60, CGEventFlags.maskShift.rawValue | 0x0004),
        (["command", "cmd", "⌘", "lcommand", "lcmd"], 55, CGEventFlags.maskCommand.rawValue | 0x0008),
        (["rcommand", "rcmd"], 54, CGEventFlags.maskCommand.rawValue | 0x0010),
        (["fn", "globe"], 63, CGEventFlags.maskSecondaryFn.rawValue),
        (["capslock", "caps", "verrmaj"], 57, CGEventFlags.maskAlphaShift.rawValue),
    ]

    // Touches non imprimables. Le premier nom est le nom canonique.
    private static let specials: [(names: [String], code: CGKeyCode)] = [
        (["space", "espace"], 49), (["return", "entree"], 36), (["enter"], 76), (["tab"], 48),
        (["escape", "esc"], 53), (["delete", "backspace"], 51), (["forwarddelete", "suppr"], 117),
        (["up"], 126), (["down"], 125), (["left"], 123), (["right"], 124),
        (["home"], 115), (["end"], 119), (["pageup"], 116), (["pagedown"], 121),
        (["f1"], 122), (["f2"], 120), (["f3"], 99), (["f4"], 118), (["f5"], 96), (["f6"], 97),
        (["f7"], 98), (["f8"], 100), (["f9"], 101), (["f10"], 109), (["f11"], 103), (["f12"], 111),
        (["f13"], 105), (["f14"], 107), (["f15"], 113), (["f16"], 106), (["f17"], 64),
        (["f18"], 79), (["f19"], 80), (["f20"], 90),
        (["comma"], 43), (["period"], 47), (["slash"], 44), (["semicolon"], 41),
        (["minus"], 27), (["equal"], 24), (["quote"], 39), (["backslash"], 42), (["grave"], 50),
    ]

    // Repli QWERTY si la disposition active ne donne pas le caractère.
    private static let ansi: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    // Ordre d'affichage canonique des modificateurs.
    private static let order: [CGKeyCode] = [59, 62, 58, 61, 56, 60, 55, 54, 63, 57]

    static func isModifier(_ code: CGKeyCode) -> Bool { modifiers.contains { $0.code == code } }

    static func key(named raw: String) -> Key? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("keycode:"), let n = UInt16(name.dropFirst(8)) {
            let flags = modifiers.first { $0.code == n }.map { CGEventFlags(rawValue: $0.flags) } ?? []
            return Key(code: n, flags: flags)
        }
        if let m = modifiers.first(where: { $0.names.contains(name) }) {
            return Key(code: m.code, flags: CGEventFlags(rawValue: m.flags))
        }
        if let s = specials.first(where: { $0.names.contains(name) }) { return Key(code: s.code, flags: []) }
        if name.count == 1, let code = layoutCodes[name] ?? ansi[name] { return Key(code: code, flags: []) }
        return nil
    }

    static func name(for code: CGKeyCode) -> String {
        if let m = modifiers.first(where: { $0.code == code }) { return m.names[0] }
        if let s = specials.first(where: { $0.code == code }) { return s.names[0] }
        if let c = character(for: code), c.count == 1, c != "+", !c.trimmingCharacters(in: .whitespaces).isEmpty {
            return c
        }
        return "keycode:\(code)"
    }

    /// "ctrl+shift+v" dans un ordre stable.
    static func comboName(modifiers codes: [CGKeyCode], main: CGKeyCode?) -> String {
        let sorted = codes.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        return (sorted + (main.map { [$0] } ?? [])).map(name(for:)).joined(separator: "+")
    }

    /// Caractère -> code selon la disposition active (AZERTY, QWERTZ…).
    private static let layoutCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]
        for code in CGKeyCode(0)..<CGKeyCode(128) where !isModifier(code) {
            guard !specials.contains(where: { $0.code == code }),
                  let c = character(for: code), map[c] == nil else { continue }
            map[c] = code
        }
        return map
    }()

    private static func character(for code: CGKeyCode) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }
}
