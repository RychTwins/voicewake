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

    private var position = 0
    /// Tout le texte en cours de lecture.
    var fullText: String { text }
    /// Ce que le lecteur vient de dire et va dire dans l'instant (autour du mot en cours) :
    /// sert à reconnaître sa propre voix dans le micro, sans bloquer une commande dite ailleurs dans le texte.
    var spokenNow: String {
        // Large fenêtre vers l'arrière : la transcription du micro a plusieurs secondes de retard.
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let p = min(max(0, position), ns.length)
        let lo = max(0, p - 700), hi = min(ns.length, p + 80)
        guard hi > lo else { return "" }
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

    func speak(_ text: String, locale: String) {
        stop()
        self.text = text
        position = 0
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
        let spoken = utterance.speechString
        DispatchQueue.main.async { [self] in
            guard spoken == text else { return } // rappel d'une lecture précédente
            position = range.location
            if isActive { overlay.show(text: text, range: range) }
        }
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

    /// Affiche ce qui vient d'être lu et la fin de la phrase en cours, jamais au-delà :
    /// le texte qui suit la réponse (éléments de l'interface de l'app) n'apparaît donc pas.
    func show(text: String, range: NSRange) {
        let ns = text as NSString
        let wordEnd = min(ns.length, range.location + range.length)
        let start = max(0, range.location - 70), end = min(ns.length, wordEnd + 110)
        var lo = start, hi = end
        while lo > 0, ns.character(at: lo) != 32 { lo -= 1 }                 // début de mot
        while hi < ns.length, ns.character(at: hi) != 32 { hi += 1 }          // fin de mot
        // Fin de phrase : . ? ! … suivi d'un espace ou de la fin du texte.
        func endsSentence(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length else { return false }
            let c = ns.character(at: i)
            guard c == 46 || c == 63 || c == 33 || c == 0x2026 else { return false }
            return i + 1 >= ns.length || ns.character(at: i + 1) == 32 || ns.character(at: i + 1) == 10
        }
        var i = max(range.location, wordEnd - 1)
        while i < hi {
            if endsSentence(i) { hi = i + 1; break }
            i += 1
        }
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

/// Suit la lecture à voix haute d'une application en l'écoutant : la transcription du micro est
/// alignée sur le texte affiché, et le bandeau montre le mot en cours.
final class ReadingFollower {
    /// (mot en cours, nombre de mots) : pour le journal en mode debug.
    var onProgress: ((Int, Int) -> Void)?
    private let overlay = ReaderOverlay()
    private var targetID: String?
    private var text = ""
    private var ranges: [NSRange] = []                      // position de chaque mot affiché dans `text`
    private var flat: [(word: String, token: Int)] = []     // mots normalisés → mot affiché
    private var position: Int?                              // indice dans `flat`
    private var hideWork: DispatchWorkItem?
    private var loadedAt = Date.distantPast

    /// Charge le texte affiché par l'app (une fois par lecture).
    private func load(_ app: NSRunningApplication) {
        let tokens = AXButtonPresser.windowTexts(in: app).joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        text = tokens.joined(separator: " ")
        ranges = []; flat = []
        var offset = 0
        for (i, t) in tokens.enumerated() {
            let length = (t as NSString).length
            ranges.append(NSRange(location: offset, length: length))
            offset += length + 1
            for w in normalize(t).split(separator: " ") { flat.append((String(w), i)) }
        }
        position = nil
    }

    private func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 2
    }

    /// `transcript` : ce que le micro entend pendant la lecture de `target`.
    func follow(_ transcript: String, target: Target, app: NSRunningApplication) {
        // Un seul chargement par lecture (même s'il est vide), puis au plus un toutes les 10 s.
        if targetID != target.id || (flat.isEmpty && Date().timeIntervalSince(loadedAt) > 10) {
            targetID = target.id
            loadedAt = Date()
            load(app)
        }
        let words = normalize(transcript).split(separator: " ").map(String.init)
        // Premier accrochage : 5 mots exacts (preuve que c'est bien la lecture). Ensuite 3 mots, tolérants.
        let need = position == nil ? 5 : 3
        guard words.count >= need else { return }
        let tail = Array(words.suffix(need))
        let exact = position == nil
        // Près de la position connue d'abord (la lecture avance), sinon partout, en partant de la fin.
        func search(_ range: ReversedCollection<Range<Int>>) -> Int? {
            for i in range where i + tail.count <= flat.count {
                if (0..<tail.count).allSatisfy({ exact ? flat[i + $0].word == tail[$0] : same(flat[i + $0].word, tail[$0]) }) { return i + tail.count - 1 }
            }
            return nil
        }
        var hit: Int?
        if let p = position { hit = search((max(0, p - 4)..<min(flat.count, p + 80)).reversed()) }
        if hit == nil, position == nil { hit = search((0..<flat.count).reversed()) }
        guard let hit else { return }
        position = hit
        overlay.show(text: text, range: ranges[flat[hit].token])
        onProgress?(flat[hit].token, ranges.count)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func stop() {
        hideWork?.cancel()
        overlay.hide()
        targetID = nil
        flat = []
    }
}
