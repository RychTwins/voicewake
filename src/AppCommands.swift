import AppKit
import AVFoundation

/// Commandes vocales de gestion de l'assistant au premier plan, dites en veille.
enum AppCommand: String, CaseIterable {
    case clearDraft, newChat, copyResponse, status, help

    static let defaultPhrases: [AppCommand: [String]] = [
        .clearDraft: ["efface le brouillon", "efface tout", "vide le brouillon", "supprime le brouillon"],
        .newChat: ["nouvelle conversation", "nouvelle discussion", "nouvelle session", "nouveau chat"],
        .copyResponse: ["copie la réponse", "copier la réponse", "copie la dernière réponse"],
        .status: ["où on en est", "on en est où", "où en est on", "quel est l'état"],
        .help: ["quelles commandes", "quelles sont les commandes", "qu'est ce que je peux dire", "aide vocale", "liste des commandes"],
    ]

    func phrases(_ c: Config) -> [String] {
        let custom: [String]?
        switch self {
        case .clearDraft: custom = c.clearDraftPhrases
        case .newChat: custom = c.newChatPhrases
        case .copyResponse: custom = c.copyResponsePhrases
        case .status: custom = c.statusPhrases
        case .help: custom = c.helpPhrases
        }
        return custom ?? Self.defaultPhrases[self] ?? []
    }

    /// Commande présente dans la transcription (la plus récente si plusieurs), ou nil.
    static func match(_ text: String, router: Router, config: Config) -> AppCommand? {
        var best: (command: AppCommand, at: String.Index)?
        let n = " " + normalize(text) + " "
        for command in allCases {
            for p in command.phrases(config).map(normalize) where !p.isEmpty {
                guard let r = n.range(of: " " + p + " ", options: .backwards) else { continue }
                if best == nil || r.lowerBound > best!.at { best = (command, r.lowerBound) }
            }
        }
        return best?.command
    }
}

/// Navigation du lecteur intégré : seulement pendant une lecture « lis à partir de … »
/// (la lecture à voix haute des applications ne permet ni de changer la vitesse ni de reculer).
enum ReaderNav: String, CaseIterable {
    case faster, slower, repeatSentence, nextSentence

    static let defaultPhrases: [ReaderNav: [String]] = [
        .faster: ["plus vite", "lis plus vite", "accélère"],
        .slower: ["moins vite", "lis moins vite", "ralentis", "plus lentement"],
        .repeatSentence: ["répète", "répète la phrase", "phrase précédente", "reviens en arrière", "recule"],
        .nextSentence: ["phrase suivante", "saute la phrase", "passe à la suite"],
    ]

    func phrases(_ c: Config) -> [String] {
        let custom: [String]?
        switch self {
        case .faster: custom = c.readFasterPhrases
        case .slower: custom = c.readSlowerPhrases
        case .repeatSentence: custom = c.readRepeatPhrases
        case .nextSentence: custom = c.readNextPhrases
        }
        return custom ?? Self.defaultPhrases[self] ?? []
    }

    static func allPhrases(_ c: Config) -> [String] { allCases.flatMap { $0.phrases(c) } }

    /// Commande présente dans la transcription (la plus récente si plusieurs), ou nil.
    static func match(_ text: String, config: Config) -> ReaderNav? {
        var best: (nav: ReaderNav, at: String.Index)?
        let n = " " + normalize(text) + " "
        for nav in allCases {
            for p in nav.phrases(config).map(normalize) where !p.isEmpty {
                guard let r = n.range(of: " " + p + " ", options: .backwards) else { continue }
                if best == nil || r.lowerBound > best!.at { best = (nav, r.lowerBound) }
            }
        }
        return best?.nav
    }
}

/// Exécution des commandes dans l'app : toujours sur la fenêtre au premier plan, jamais en arrière-plan.
enum AppActions {
    static let defaultNewChatItems = ["Nouvelle conversation", "Nouvelle session", "Nouveau chat", "Nouvelle discussion",
                                      "New Chat", "New Conversation", "New Session"]
    static let defaultCopyLabels = ["Copier", "Copy"]

    /// `completion(réussi, détail pour le journal)`, sur la file principale.
    static func run(_ command: AppCommand, target t: Target, completion: @escaping (Bool, String) -> Void) {
        let done = { (ok: Bool, detail: String) in DispatchQueue.main.async { completion(ok, detail) } }
        guard let app = ShortcutTrigger.runningApp(for: t), AXButtonPresser.isFrontmost(app) else {
            return done(false, "\(t.id) n'est pas au premier plan")
        }
        switch command {
        case .status, .help:
            done(true, "")

        case .newChat:
            DispatchQueue.global().async {
                let items = t.newChatMenuItems ?? defaultNewChatItems
                if let chosen = AXButtonPresser.pressMenuBarItem(items, in: app) { done(true, "menu « \(chosen) »") }
                else { done(false, "aucune commande de menu parmi \(items.joined(separator: " | "))") }
            }

        case .copyResponse:
            DispatchQueue.global().async {
                let labels = t.copyResponseShortcut?.buttons ?? defaultCopyLabels
                guard let window = AXButtonPresser.currentWindow(in: app) else { return done(false, "fenêtre introuvable") }
                let before = NSPasteboard.general.changeCount
                guard AXButtonPresser.pressLast(labels, in: app, window: window) else {
                    return done(false, "bouton introuvable (\(labels.joined(separator: " | ")))")
                }
                // Vérifie que le presse-papier a bien changé (jusqu'à 1 s).
                for _ in 0..<10 {
                    usleep(100_000)
                    if NSPasteboard.general.changeCount != before { return done(true, "réponse copiée") }
                }
                done(false, "presse-papier inchangé")
            }

        case .clearDraft:
            // Seulement si le curseur est dans un champ de saisie : Cmd+A puis Effacement ne touchent qu'à lui.
            guard AXButtonPresser.focusedTextField(in: app) != nil else {
                return done(false, "aucun champ de saisie sélectionné")
            }
            guard let keys = try? Shortcut(spec: "cmd+a then delete") else { return done(false, "raccourci invalide") }
            ShortcutPlayer.play(keys, to: app.processIdentifier, while: { AXButtonPresser.isFrontmost(app) }) { played in
                done(played, played ? "brouillon effacé" : "app passée en arrière-plan")
            }
        }
    }
}

/// Courte annonce parlée avec une voix du Mac (« Où on en est ? »). `onFinish` : fin de l'annonce.
final class Announcer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Vrai pendant une annonce dite par une autre voix que celle du Mac (ElevenLabs).
    var external = false
    var isSpeaking: Bool { synth.isSpeaking || external }

    func say(_ text: String, locale: String, voice: String?, onFinish: @escaping () -> Void) {
        synth.stopSpeaking(at: .immediate)
        self.onFinish = onFinish
        let u = AVSpeechUtterance(string: text)
        u.voice = Reader.bestVoice(locale: locale, preferred: voice)
        synth.speak(u)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            let done = self?.onFinish
            self?.onFinish = nil
            done?()
        }
    }
}
