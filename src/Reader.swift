import AppKit
import AVFoundation

/// Lecteur intégré : lit un texte avec une voix du Mac à partir d'un endroit précis,
/// et affiche le passage en cours avec le mot prononcé surligné.
final class Reader: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let overlay = ReaderOverlay()
    private var text = ""
    private(set) var isActive = false   // en lecture ou en pause
    private(set) var isPaused = false
    var voiceName: String?
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Texte normalisé en cours de lecture (pour reconnaître la voix du lecteur dans le micro).
    var spokenText: String { text }

    func speak(_ text: String, locale: String) {
        stop()
        self.text = text
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(locale: locale, preferred: voiceName)
        isActive = true
        isPaused = false
        overlay.show(text: text, range: NSRange(location: 0, length: 0))
        synth.speak(utterance)
    }

    func pause() {
        guard isActive, !isPaused else { return }
        synth.pauseSpeaking(at: .word)
        isPaused = true
    }

    func resume() {
        guard isActive, isPaused else { return }
        synth.continueSpeaking()
        isPaused = false
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isPaused = false
        synth.stopSpeaking(at: .immediate)
        overlay.hide()
    }

    /// Meilleure voix installée pour la langue : Premium, puis Améliorée, puis standard.
    static func bestVoice(locale: String, preferred: String?) -> AVSpeechSynthesisVoice? {
        let lang = String(locale.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        if let preferred, let v = voices.first(where: { $0.name.localizedCaseInsensitiveContains(preferred) }) { return v }
        let exact = voices.filter { $0.language == locale }
        return (exact.isEmpty ? voices : exact).max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: locale)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in if isActive { overlay.show(text: text, range: range) } }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in
            guard isActive else { return }
            isActive = false
            overlay.hide()
            onFinish?()
        }
    }
}

/// Bandeau flottant en bas de l'écran : le passage en cours, mot prononcé surligné.
final class ReaderOverlay {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    private func makePanel() -> NSPanel {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(900, screen.width - 80)
        let frame = NSRect(x: screen.midX - width / 2, y: screen.minY + 60, width: width, height: 110)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        label.frame = box.bounds.insetBy(dx: 20, dy: 14)
        label.autoresizingMask = [.width, .height]
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        box.addSubview(label)
        p.contentView = box
        return p
    }

    /// Affiche ~25 mots autour du mot en cours.
    func show(text: String, range: NSRange) {
        let ns = text as NSString
        let start = max(0, range.location - 70), end = min(ns.length, range.location + range.length + 110)
        var lo = start, hi = end
        while lo > 0, ns.character(at: lo) != 32 { lo -= 1 }                 // début de mot
        while hi < ns.length, ns.character(at: hi) != 32 { hi += 1 }          // fin de mot
        let window = NSRange(location: lo, length: hi - lo)
        let shown = NSMutableAttributedString(
            string: ns.substring(with: window).replacingOccurrences(of: "\n", with: " "),
            attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
        let local = NSRange(location: range.location - lo, length: range.length)
        if local.location >= 0, local.location + local.length <= shown.length, local.length > 0 {
            shown.addAttributes([.font: NSFont.systemFont(ofSize: 20, weight: .bold),
                                 .foregroundColor: NSColor.systemYellow], range: local)
        }
        label.attributedStringValue = shown
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

/// Retrouve dans un texte l'endroit cité à la voix (« lis à partir de … »).
enum PassageFinder {
    /// Indice du mot où commence la dernière occurrence du plus long début de la citation
    /// (au moins 2 mots si elle en a plusieurs), ou nil.
    static func find(_ query: [String], in tokens: [String]) -> Int? {
        // Mots normalisés du texte, avec l'indice du mot affiché d'origine.
        var flat: [(word: String, token: Int)] = []
        for (ti, t) in tokens.enumerated() {
            for w in normalize(t).split(separator: " ") { flat.append((String(w), ti)) }
        }
        // Tolère les petites différences de transcription (« limite » / « limites »).
        func same(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            let (short, long) = a.count <= b.count ? (a, b) : (b, a)
            return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 2
        }
        var length = min(query.count, 6)
        let minLength = min(2, query.count)
        while length >= minLength {
            var i = flat.count - length
            while i >= 0 {
                if (0..<length).allSatisfy({ same(flat[i + $0].word, query[$0]) }) { return flat[i].token }
                i -= 1
            }
            length -= 1
        }
        return nil
    }
}
