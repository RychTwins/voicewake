import AppKit
import AVFoundation

/// Lecteur intégré : lit un texte (voix ElevenLabs ou voix du Mac) à partir d'un endroit précis.
/// Pas de bandeau à l'écran : seule la voix. Navigation : vitesse, phrase précédente ou suivante.
final class Reader: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var text = ""
    private(set) var isActive = false   // en lecture ou en pause
    private(set) var isPaused = false
    var voiceName: String?
    /// Voix ElevenLabs : le texte est découpé en segments (le premier, court, démarre vite ; les suivants
    /// sont synthétisés pendant qu'il est lu). Vide avec la voix du Mac.
    private final class Segment {
        let start: Int, length: Int, text: String
        var clip: AudioClip?
        /// Instants de prononciation de chaque unité UTF-16 du segment, ou nil (position estimée).
        var timings: [Double]?
        var failed = false
        init(start: Int, length: Int, text: String) { self.start = start; self.length = length; self.text = text }
    }
    private var segments: [Segment] = []
    private var current = 0
    /// Le segment en cours attend son audio.
    private var waiting = false
    /// Déplacement demandé dans un segment pas encore prêt (indice local).
    private var pendingLocalSeek: Int?
    private var usesElevenLabs: Bool { !segments.isEmpty }
    /// Extrait ElevenLabs en cours.
    private var clip: AudioClip? { segments.indices.contains(current) ? segments[current].clip : nil }
    private var timings: [Double]? { segments.indices.contains(current) ? segments[current].timings : nil }
    private var generation = 0
    var onFinish: (() -> Void)?

    /// Voix du Mac : énoncé en cours, qui commence à `utteranceStart` dans `text`.
    private var utterance: AVSpeechUtterance?
    private var utteranceStart = 0
    private var locale = "fr-FR"
    /// Voix du Mac en pause après un déplacement : la lecture reprendra à cet endroit.
    private var resumeFrom: Int?
    /// Vitesse relative (1 = normale), de `minRate` à `maxRate`.
    private(set) var rate: Double = 1
    static let minRate = 0.5, maxRate = 2.0, rateStep = 1.25

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
        // Voix ElevenLabs : sans alignement, position seulement estimée (débit irrégulier : nombres,
        // heures, pauses) ; on regarde donc bien plus loin devant, pour que la voix ne déclenche jamais
        // ses propres commandes. Voix du Mac ou alignement ElevenLabs : position exacte.
        var ahead = 80
        if usesElevenLabs {
            updateClipPosition()
            ahead = timings == nil ? 500 : 150
        }
        let p = min(max(0, position), ns.length)
        let lo = max(0, p - 700), hi = min(ns.length, p + ahead)
        guard hi > lo else { return "" }
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

    /// Lit avec la voix ElevenLabs si elle est activée, sinon (ou en cas d'échec) avec la voix du Mac.
    func speak(_ text: String, config: Config) {
        guard config.elevenLabs?.enabled == true else { return speak(text, locale: config.locale) }
        stop()
        self.text = text
        locale = config.locale
        position = 0
        isActive = true
        isPaused = false
        generation += 1
        let gen = generation
        let ns = text as NSString
        segments = Self.segmentRanges(in: ns).map { Segment(start: $0.location, length: $0.length, text: ns.substring(with: $0)) }
        current = 0
        waiting = true
        // Tous les segments sont demandés en même temps : la lecture commence dès que le premier est prêt.
        for (i, seg) in segments.enumerated() {
            ElevenLabs.synthesize(seg.text, config: config) { [weak self] speech in
                guard let self, gen == self.generation, self.isActive, self.usesElevenLabs else { return }
                if let speech, let clip = AudioClip(speech.audio) {
                    seg.clip = clip
                    seg.timings = speech.timings
                    clip.rate = Float(self.rate)
                    clip.onFinish = { [weak self] in self?.segmentFinished(i, gen) }
                } else {
                    seg.failed = true
                }
                if i == self.current, self.waiting { self.startCurrent() }
            }
        }
    }

    /// Lance le segment en cours s'il est prêt ; voix du Mac à partir de là s'il a échoué.
    private func startCurrent() {
        let seg = segments[current]
        if seg.failed {
            let from = seg.start + (pendingLocalSeek ?? 0)
            endClip()
            if isPaused { resumeFrom = from; position = from } else { speakMac(from: from) }
            return
        }
        guard let clip = seg.clip else { waiting = true; return }
        waiting = false
        log("Lecteur intégré : segment \(current + 1) sur \(segments.count).")
        if let local = pendingLocalSeek { seekClip(seg, local); pendingLocalSeek = nil }
        if !isPaused { clip.play() }
    }

    private func segmentFinished(_ i: Int, _ gen: Int) {
        guard gen == generation, isActive, usesElevenLabs, i == current else { return }
        if current + 1 < segments.count {
            current += 1
            segments[current].clip?.seek(to: 0) // déjà joué avant un retour en arrière : repartir du début
            startCurrent()
        } else {
            isActive = false
            endClip()
            onFinish?()
        }
    }

    private func seekClip(_ seg: Segment, _ local: Int) {
        guard let clip = seg.clip else { return }
        if let t = seg.timings, t.count == seg.length, local < seg.length { clip.seek(to: t[max(0, local)]) }
        else if seg.length > 0 { clip.seek(to: clip.duration * Double(local) / Double(seg.length)) }
    }

    /// Position dans `text` d'après l'audio ElevenLabs : exacte avec l'alignement, sinon proportionnelle.
    private func updateClipPosition() {
        guard segments.indices.contains(current) else { return }
        let seg = segments[current]
        guard let clip = seg.clip else { position = seg.start + (pendingLocalSeek ?? 0); return }
        guard let timings = seg.timings, timings.count == seg.length, seg.length > 0 else {
            position = seg.start + Int(clip.progress * Double(seg.length))
            return
        }
        // Dernier caractère dont la prononciation a commencé (recherche dichotomique).
        let now = clip.currentTime
        var lo = 0, hi = seg.length - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if timings[mid] <= now { lo = mid } else { hi = mid - 1 }
        }
        position = seg.start + lo
    }

    private func endClip() {
        for seg in segments { seg.clip?.stop() }
        segments = []
        current = 0
        waiting = false
        pendingLocalSeek = nil
    }

    /// Segments à synthétiser : un premier court (une ou deux phrases, ~300 caractères au plus) pour démarrer
    /// vite, puis des blocs d'au plus ~1 500 caractères, coupés en fin de phrase (sinon entre deux mots).
    static func segmentRanges(in ns: NSString, firstMax: Int = 300, restMax: Int = 1500) -> [NSRange] {
        guard ns.length > 0 else { return [] }
        let starts = sentenceStarts(in: ns)
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let limit = out.isEmpty ? firstMax : restMax
            if ns.length - from <= limit { out.append(NSRange(location: from, length: ns.length - from)); break }
            // Dernier début de phrase dans la limite (en laissant au moins 60 caractères au segment).
            var cut = starts.last(where: { $0 > from + 60 && $0 <= from + limit })
            if cut == nil {
                cut = wordStart(in: ns, at: from + limit)
                if cut! <= from { cut = from + limit }
            }
            out.append(NSRange(location: from, length: cut! - from))
            from = cut!
        }
        return out
    }

    func speak(_ text: String, locale: String) {
        stop()
        self.text = text
        self.locale = locale
        isActive = true
        isPaused = false
        speakMac(from: 0)
    }

    /// Voix du Mac : (re)lit `text` à partir de l'indice `start`, à la vitesse en cours.
    private func speakMac(from start: Int) {
        let ns = text as NSString
        let from = min(max(0, start), ns.length)
        resumeFrom = nil
        utteranceStart = from
        position = from
        let u = AVSpeechUtterance(string: ns.substring(from: from))
        u.voice = Self.bestVoice(locale: locale, preferred: voiceName)
        u.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate,
                               Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        utterance = u
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        synth.speak(u)
    }

    func pause() {
        guard isActive, !isPaused else { return }
        clip?.pause() // segment pas encore prêt : il ne démarrera pas tant que la lecture est en pause
        synth.pauseSpeaking(at: .word)
        isPaused = true
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        if usesElevenLabs { clip?.play(); return } // pas encore prêt : démarrera à son arrivée
        if let from = resumeFrom { speakMac(from: from) } else { synth.continueSpeaking() }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isPaused = false
        generation += 1
        endClip()
        resumeFrom = nil
        utterance = nil
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: Navigation

    /// Change la vitesse (« plus vite » : `faster` true). Renvoie la nouvelle vitesse, ou nil si déjà à la limite.
    @discardableResult
    func changeRate(faster: Bool) -> Double? {
        guard isActive else { return nil }
        let next = min(max(faster ? rate * Self.rateStep : rate / Self.rateStep, Self.minRate), Self.maxRate)
        guard abs(next - rate) > 0.001 else { return nil }
        rate = next
        if usesElevenLabs {
            for seg in segments { seg.clip?.rate = Float(rate) }
            return rate
        }
        // Voix du Mac : la vitesse d'un énoncé est fixe ; on relit depuis le début du mot en cours.
        let start = Self.wordStart(in: text as NSString, at: position)
        if isPaused { stopMac(resumeAt: start) } else { speakMac(from: start) }
        return rate
    }

    /// « Répète » / « phrase précédente » (`forward` false) ou « phrase suivante » (`forward` true).
    /// Renvoie false s'il n'y a pas de phrase dans ce sens.
    @discardableResult
    func skipSentence(forward: Bool) -> Bool {
        guard isActive else { return false }
        if usesElevenLabs { updateClipPosition() }
        guard let target = Self.sentenceTarget(in: text as NSString, from: position, forward: forward) else { return false }
        seek(to: target)
        return true
    }

    private func seek(to index: Int) {
        position = index
        if usesElevenLabs {
            let i = segments.lastIndex(where: { $0.start <= index }) ?? 0
            let local = index - segments[i].start
            if i != current { clip?.pause(); current = i }
            let seg = segments[i]
            if let c = seg.clip {
                waiting = false
                seekClip(seg, local)
                if !isPaused { c.play() }
            } else {
                pendingLocalSeek = local
                if seg.failed { startCurrent() } else { waiting = true }
            }
            return
        }
        if isPaused { stopMac(resumeAt: index) } else { speakMac(from: index) }
    }

    /// Voix du Mac en pause : abandonne l'énoncé et reprendra à `index` au prochain `resume()`.
    private func stopMac(resumeAt index: Int) {
        utterance = nil
        synth.stopSpeaking(at: .immediate)
        resumeFrom = index
        position = index
    }

    /// Début des phrases de `ns` : 0, puis après « . », « ! », « ? », « … » suivis d'un espace, et après chaque retour à la ligne.
    static func sentenceStarts(in ns: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            var end: Int?
            if c == 10 { end = i + 1 }
            else if c == 46 || c == 33 || c == 63 || c == 0x2026, i + 1 < ns.length,
                    ns.character(at: i + 1) == 32 || ns.character(at: i + 1) == 10 { end = i + 1 }
            if var e = end {
                while e < ns.length, ns.character(at: e) == 32 || ns.character(at: e) == 10 { e += 1 }
                if e < ns.length, e > starts.last! { starts.append(e) }
                i = e
            } else { i += 1 }
        }
        return starts
    }

    /// Où aller depuis `position`. En arrière : début de la phrase en cours, ou de la précédente si l'on vient
    /// de la commencer (moins de 20 caractères lus). En avant : début de la phrase suivante.
    static func sentenceTarget(in ns: NSString, from position: Int, forward: Bool) -> Int? {
        let starts = sentenceStarts(in: ns)
        guard let current = starts.lastIndex(where: { $0 <= position }) else { return nil }
        if forward { return current + 1 < starts.count ? starts[current + 1] : nil }
        if position - starts[current] >= 20 || current == 0 { return starts[current] }
        return starts[current - 1]
    }

    /// Début du mot qui contient l'indice `i`.
    static func wordStart(in ns: NSString, at i: Int) -> Int {
        var lo = min(max(0, i), ns.length)
        while lo > 0, ns.character(at: lo - 1) != 32, ns.character(at: lo - 1) != 10 { lo -= 1 }
        return lo
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

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in
            guard u === utterance else { return } // rappel d'un énoncé abandonné
            position = utteranceStart + range.location
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in
            guard isActive, u === utterance else { return }
            isActive = false
            utterance = nil
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
    /// Libellés des boutons qui suivent chaque réponse de l'assistant : fin du texte à lire.
    static func messageEndLabels(_ t: Target) -> [String] {
        [t.readAloudShortcut, t.pauseReadShortcut, t.resumeReadShortcut].flatMap { $0?.buttons ?? [] }
    }

    /// Mots du texte affiché, marques de fin de message comprises (voir `AXButtonPresser.messageEnd`).
    static func tokens(in app: NSRunningApplication, target: Target) -> [String] {
        AXButtonPresser.windowTexts(in: app, boundaries: messageEndLabels(target)).joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// Texte à lire depuis `start` : jusqu'à la fin de la réponse (boutons de l'app exclus), `maxWords` au plus.
    static func passage(_ tokens: [String], from start: Int, maxWords: Int = 500) -> [String] {
        var out: [String] = []
        for t in tokens[start...] {
            if t == AXButtonPresser.messageEnd { break }
            out.append(t)
            if out.count >= maxWords { break }
        }
        return out
    }

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
    var onHighlight: ((Int, NSRect?) -> Void)?
    private let overlay = ReaderOverlay()
    private var targetID: String?
    private var text = ""
    private var ranges: [NSRange] = []                      // position de chaque mot affiché dans `text`
    private var flat: [(word: String, token: Int)] = []     // mots normalisés → mot affiché
    private var position: Int?                              // indice dans `flat`
    private var hideWork: DispatchWorkItem?
    private var loadedAt = Date.distantPast

    /// true : surligne le bloc en cours directement dans l'app (sélection) ; false : bandeau.
    var selectInApp = false
    private var blocks: [(element: AXUIElement, web: AXUIElement?, text: String)] = []
    private var tokenBlock: [Int] = []       // mot affiché → bloc
    private var selectedBlock = -1
    private var scrolledBlock = -1
    private let highlight = HighlightOverlay()

    /// Charge le texte affiché par l'app (une fois par lecture).
    private func load(_ app: NSRunningApplication) {
        blocks = AXButtonPresser.textBlocks(in: app)
        var tokens: [String] = []
        tokenBlock = []
        for (bi, b) in blocks.enumerated() {
            for t in b.text.split(whereSeparator: { $0 == " " || $0 == "\n" }) { tokens.append(String(t)); tokenBlock.append(bi) }
        }
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
        selectedBlock = -1
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
        if selectInApp {
            // Surlignage posé sur le bloc en cours ; position relue à chaque fois (défilement de la page).
            let b = tokenBlock[flat[hit].token]
            selectedBlock = b
            var frame = blocks[b].web.flatMap { AXButtonPresser.textFrame(of: blocks[b].element, in: $0, app: app) }
            if frame == nil, b != scrolledBlock {
                // Passage hors de l'écran : on demande à l'app de le faire défiler dans la vue (une fois par bloc).
                scrolledBlock = b
                AXUIElementPerformAction(blocks[b].element, "AXScrollToVisible" as CFString)
                frame = blocks[b].web.flatMap { AXButtonPresser.textFrame(of: blocks[b].element, in: $0, app: app) }
            }
            onHighlight?(b, frame)
            if let frame { highlight.show(frame) } else { highlight.hide() }
        } else {
            overlay.show(text: text, range: ranges[flat[hit].token])
        }
        onProgress?(flat[hit].token, ranges.count)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func stop() {
        hideWork?.cancel()
        overlay.hide()
        highlight.hide()
        targetID = nil
        flat = []
    }
}

/// Rectangle jaune transparent posé par-dessus un passage de texte d'une autre application.
final class HighlightOverlay {
    private var window: NSWindow?

    func show(_ frame: NSRect) {
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.28).cgColor
            view.layer?.cornerRadius = 4
            view.autoresizingMask = [.width, .height]
            w.contentView = view
            window = w
        }
        window?.setFrame(frame.insetBy(dx: -3, dy: -2), display: true)
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }
}
