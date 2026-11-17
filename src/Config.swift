import CoreGraphics
import Foundation

private let logDateFormatter = ISO8601DateFormatter()

func log(_ message: String) {
    print("[\(logDateFormatter.string(from: Date()))] \(message)")
}

/// Journal du service (~/Library/Logs/voicewake.log, ouvert par le LaunchAgent comme sortie standard) :
/// au-delà de `maxBytes`, il devient voicewake.log.1 (l'ancien est remplacé) et un journal neuf commence.
/// Ne fait rien si la sortie standard n'est pas ce fichier (terminal, autre chemin).
func rotateLogIfNeeded(path: String = ("~/Library/Logs/voicewake.log" as NSString).expandingTildeInPath,
                       maxBytes: Int = 5_000_000) {
    var out = stat(), file = stat()
    guard fstat(STDOUT_FILENO, &out) == 0, stat(path, &file) == 0,
          out.st_ino == file.st_ino, out.st_dev == file.st_dev, Int(file.st_size) > maxBytes else { return }
    fflush(stdout); fflush(stderr)
    let old = path + ".1"
    try? FileManager.default.removeItem(atPath: old)
    guard (try? FileManager.default.moveItem(atPath: path, toPath: old)) != nil else { return }
    freopen(path, "a", stdout)
    freopen(path, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    log("Journal précédent archivé : \(old).")
}

/// "Salut, Chat GPT !" -> "salut chat gpt"
func normalize(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .joined(separator: " ")
}

struct ConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Target: Codable {
    var id: String
    var appName: String?
    var bundleID: String?
    var phrases: [String]
    var shortcut: Shortcut
    /// Mettre l'application au premier plan avant le raccourci (inutile pour un raccourci global).
    var activate: Bool?
    /// Attente après le lancement d'une application fermée.
    var launchDelaySeconds: Double?
    /// Libellés AX exacts du champ de saisie pour la dictée externe.
    var dictationFieldLabels: [String]?
    /// Envoi vocal : touche d'envoi (défaut "return").
    var submitShortcut: Shortcut?
    /// Couper le micro de l'app avant l'envoi (défaut true).
    var stopBeforeSubmit: Bool?
    /// Raccourci qui coupe le micro de l'app (défaut : `shortcut`). Ex. "button:Arrêter la dictée".
    var stopShortcut: Shortcut?
    /// Après un envoi vocal : bouton de lecture à cliquer quand la réponse est finie. Ex. "button:Lire à voix haute".
    var readAloudShortcut: Shortcut?
    /// Option à choisir dans le menu ouvert par readAloudShortcut (ex. Gemini : « Autres actions » puis « Écouter »).
    var readAloudMenuItem: String?
    /// Libellés visibles tant que l'assistant répond (ex. "Arrêter"). Optionnel.
    var busyLabels: [String]?
    /// Attente maximale de la fin de la réponse (défaut 600 s).
    var readAloudTimeoutSeconds: Double?
    /// Met la lecture à voix haute en pause (ex. "button:Pause"), avant de rouvrir le micro.
    var pauseReadShortcut: Shortcut?
    /// Reprend la lecture en pause (ex. "button:Reprendre").
    var resumeReadShortcut: Shortcut?
    /// Attente entre l'arrêt du micro et l'envoi, le temps que le texte s'affiche (défaut 1,5 s).
    var submitDelaySeconds: Double?
    /// « Nouvelle conversation » : commande de la barre de menus (libellés exacts, le premier trouvé).
    /// Défaut : Nouvelle conversation, Nouvelle session, Nouveau chat, Nouvelle discussion (et en anglais).
    var newChatMenuItems: [String]?
    /// « Copie la réponse » : bouton de copie du dernier message (défaut "button:Copier|Copy").
    var copyResponseShortcut: Shortcut?
    /// Commandes vocales de navigation (menus, boutons). Défaut : celles de l'app Claude (voir `NavCommands.claude`).
    var voiceCommands: [VoiceCommand]?

    var automaticSubmitShortcut: Shortcut? {
        if let submitShortcut, !submitShortcut.buttons.isEmpty { return submitShortcut }
        guard ["com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat", "com.google.GeminiMacOS"]
            .contains(bundleID ?? "") else { return nil }
        return try? Shortcut(spec: "button:Envoyer|Send|Envoyer le message|Send message")
    }
}

/// Un assistant intégré à un éditeur (ex. extension Claude Code dans VS Code).
struct EditorAssistant: Codable {
    var shortcut: Shortcut
    var stopShortcut: Shortcut?
    var submitShortcut: Shortcut?
    var readAloudShortcut: Shortcut?
    var busyLabels: [String]?
    var pauseReadShortcut: Shortcut?
    /// Reprend la lecture en pause (ex. "button:Reprendre").
    var resumeReadShortcut: Shortcut?
}

/// Éditeur de code : s'il est au premier plan, « Dis Claude » vise l'assistant intégré plutôt que l'app de bureau.
struct Editor: Codable {
    var id: String
    var bundleIDs: [String]
    var preferredAssistant: String?
    /// Clé = id de la cible (claude, codex, gemini…).
    var assistants: [String: EditorAssistant]
}

struct ConversationSettings: Codable {
    /// Temps laissé à l'assistant pour ouvrir le micro après le déclenchement.
    var startGraceSeconds: Double
    /// Micro libre pendant ce temps = conversation terminée.
    var idleSecondsBeforeResume: Double
    /// Sécurité : reprise forcée après cette durée.
    var maxPauseMinutes: Double
}

struct ExternalDictation: Codable {
    var shortcut: Shortcut
    var useMacOSDictationMenu: Bool?
    /// Omettre pour les outils à maintien, ou si l'arrêt se fait dans l'outil.
    var stopShortcut: Shortcut?
}

struct Config: Codable {
    var locale: String
    var requireOnDevice: Bool
    /// Annulation d'écho : VoiceWake n'entend pas la voix de lecture des haut-parleurs (défaut true).
    var echoCancellation: Bool?
    /// « Efface le brouillon », « Nouvelle conversation », « Copie la réponse », « Où on en est ? »
    /// (défauts dans `AppCommand`).
    var clearDraftPhrases: [String]?
    var newChatPhrases: [String]?
    var copyResponsePhrases: [String]?
    var statusPhrases: [String]?
    var helpPhrases: [String]?
    /// « Ouvre <projet ou session> » et « Nouvelle session dans <projet> » (défauts dans `NavCommands`).
    var openPhrases: [String]?
    /// Commandes universelles : « menu <libellé> », « clique sur <libellé> » (défauts dans `Universal`).
    var menuPhrases: [String]?
    var clickPhrases: [String]?
    /// Applications pilotables par « menu … » / « clique sur … » en plus des cibles et éditeurs (identifiants de bundle).
    /// Défaut : VS Code, Zed, Cursor, Windsurf.
    var universalApps: [String]?
    /// Réponses à une demande de confirmation (« oui », « non »…), dites seules.
    var confirmPhrases: [String]?
    /// « Lance le skill … », « commande … » (défauts dans `SkillCatalog`).
    var skillPhrases: [String]?
    /// « Palette <commande> » : phrases et raccourci d'ouverture par identifiant d'app (défauts dans `Palette`).
    var palettePhrases: [String]?
    var paletteShortcuts: [String: String]?
    var cancelPhrases: [String]?
    /// Routines vocales : une phrase dite seule enchaîne plusieurs commandes vocales (voir `Routines`).
    var routines: [Routine]?
    /// « Écris … » : tape le texte dicté dans le champ qui a le focus (défauts dans `WriteCommand`, liste vide = désactivé).
    var writePhrases: [String]?
    /// Bilan local des commandes ratées (`voicewake bilan`), défaut true.
    var failureReport: Bool?
    /// Nom d'appel (« Jarvis, ferme Claude ») : en veille il est ignoré ; pendant une dictée, il coupe le micro
    /// et exécute la commande au lieu de l'écrire. Défaut ["jarvis"], liste vide = désactivé.
    var wakeNames: [String]?
    /// Commandes du Mac (lancer, quitter, fenêtres, son, musique…), défaut true (si `jarvis` est activé).
    var systemCommands: Bool?
    /// Mode « Jarvis » (en pause, défaut false) : nom d'appel, commandes du Mac, Finder, Réglages, musique,
    /// navigateurs et interpréteur IA. Désactivé, VoiceWake ne pilote que les assistants IA et les éditeurs.
    var jarvis: Bool?
    var jarvisEnabled: Bool { jarvis ?? false }
    /// Dossiers nommés pour le Finder (« copie le fichier dans voxtv ») : {"voxtv": "~/Developer/voxtv"}.
    var folders: [String: String]?
    /// Répondre à la voix aux questions de l'assistant (options, « passe », « réponds … »), défaut true.
    var answerQuestions: Bool?
    var newSessionInPhrases: [String]?
    /// Navigation du lecteur intégré (« lis à partir de … ») : vitesse, phrase précédente ou suivante (défauts dans `ReaderNav`).
    var readFasterPhrases: [String]?
    var readSlowerPhrases: [String]?
    var readRepeatPhrases: [String]?
    var readNextPhrases: [String]?
    /// Sons de confirmation (commande comprise, micro ouvert/coupé, envoi, commande ignorée, échec). Défaut true.
    var feedbackSounds: Bool?
    /// Volume des sons de confirmation, de 0 à 1 (défaut 0,35).
    var feedbackVolume: Double?
    /// Sons système à utiliser par événement (understood, micOpen, micClosed, sent, ignored, failed), ex. {"sent": "Hero"}.
    var feedbackSoundNames: [String: String]?
    var cooldownSeconds: Double
    /// Attente maximale du résultat définitif du moteur avant d'agir sur une phrase d'activation (défaut 1,8 s).
    var wakeMaxWaitSeconds: Double?
    var debug: Bool
    /// Essai à blanc : journalise la cible reconnue sans rien déclencher (pour régler les phrases).
    var dryRun: Bool?
    var conversation: ConversationSettings
    /// Phrases qui visent l'application au premier plan.
    var frontmostPhrases: [String]
    /// Cible si l'application au premier plan n'est pas une cible.
    var defaultTarget: String?
    /// Phrases d'envoi dites en fin de dictée (« ok envoie »). Vide ou absent = pas d'envoi vocal.
    var sendPhrases: [String]?
    /// Pause minimale (s) avant « ok envoie » / « ok arrête » : évite l'envoi quand la phrase est citée en pleine phrase. 0 = désactivé.
    var sendPauseBeforeSeconds: Double?
    /// Phrases qui coupent seulement le micro (« ok arrête ») pour relire avant « ok envoie ».
    var stopPhrases: [String]?
    /// Silence après la phrase d'envoi ou d'arrêt avant d'agir (défaut 1,2 s).
    var sendSilenceSeconds: Double?
    /// Pendant la lecture à voix haute : met la lecture en pause et rouvre le micro (« écoute »).
    var interruptPhrases: [String]?
    /// Pendant la lecture : pause seulement (« arrête la lecture »).
    var readPausePhrases: [String]?
    /// Lecture en pause : reprise (« reprends la lecture »).
    var readResumePhrases: [String]?
    /// En veille : « fais la lecture » lance la lecture à voix haute de la dernière réponse de l'assistant au premier plan.
    var readAloudPhrases: [String]?
    /// En conversation continue, durée du silence avant l'envoi (défaut 5 s, 0 pour désactiver).
    var autoSendSilenceSeconds: Double?
    /// « Lis à partir de <quelques mots du passage> » : le lecteur intégré lit depuis cet endroit.
    var readFromPhrases: [String]?
    /// Bandeau qui suit la lecture à voix haute des apps, mot en cours surligné (défaut false).
    var showReadingProgress: Bool?
    /// Suivi de lecture dans l'app elle-même : le bloc de texte en cours est sélectionné (expérimental).
    var highlightReadingInApp: Bool?
    /// Voix du lecteur intégré (nom, ex. "Thomas") ; défaut : la meilleure voix installée pour `locale`.
    var readerVoice: String?
    /// Après « ok arrête », durée d'attente de « ok envoie » (défaut 180 s).
    var reviewSeconds: Double?
    /// Conversation continue : à la fin de la lecture de la réponse, le micro de l'assistant se rouvre (défaut false).
    var continuousConversation: Bool?
    /// Conversation continue : sans parole pendant ce délai, le micro est refermé (défaut 10 s).
    var continueSilenceSeconds: Double?
    /// Voix ElevenLabs pour le lecteur intégré (optionnel, désactivé par défaut).
    var elevenLabs: ElevenLabsSettings?
    /// Interpréteur IA : « Jarvis, <phrase libre> » reformulée en commande par Claude (optionnel, désactivé par défaut).
    var interpreter: InterpreterSettings?
    /// Interruptions qui passent du premier coup pendant une lecture (défaut : « stop Claude », « Claude écoute »…).
    var strongInterruptPhrases: [String]?
    /// Fin de tour naturelle (défaut true) : question → envoi plus rapide, phrase en suspens → attente plus longue.
    var naturalTurnEnd: Bool?
    /// Filtre « ma voix uniquement » (optionnel ; empreinte créée par `voicewake voix apprends`).
    var voiceFilter: VoiceFilterSettings?
    var targets: [Target]
    /// Éditeurs de code avec assistants intégrés (prioritaires quand ils sont au premier plan).
    var editors: [Editor]?
    /// Si renseigné, utilise ce raccourci de dictée pour toutes les cibles macOS.
    var externalDictation: ExternalDictation?

    func editorID(for bundleID: String) -> String? {
        if let editor = editors?.first(where: { $0.bundleIDs.contains(bundleID) }) { return editor.id }
        return ["com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode",
                "com.todesktop.230313mzl4w4u92": "cursor"][bundleID]
    }

    static func defaultPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/voicewake/config.json")
    }

    static func load(path: String) throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    func validate() throws {
        if let dictation = externalDictation,
           !dictation.shortcut.buttons.isEmpty || dictation.stopShortcut?.buttons.isEmpty == false {
            throw ConfigError("externalDictation : utiliser des raccourcis clavier.")
        }
        guard !targets.isEmpty else { throw ConfigError("Aucune cible définie.") }
        var ids = Set<String>()
        for t in targets {
            guard ids.insert(t.id).inserted else { throw ConfigError("Cible en double : \(t.id)") }
            guard t.appName != nil || t.bundleID != nil else {
                throw ConfigError("\(t.id) : appName ou bundleID requis.")
            }
            guard !t.phrases.isEmpty else { throw ConfigError("\(t.id) : aucune phrase.") }
        }
        if let problem = Routines.problems(routines ?? []).first { throw ConfigError(problem) }
        if let d = defaultTarget, !ids.contains(d) {
            throw ConfigError("defaultTarget inconnue : \(d)")
        }
    }

    func target(id: String) -> Target? { targets.first { $0.id == id } }

    /// Remplace le raccourci d'une cible en gardant le reste du fichier.
    static func saveShortcut(_ shortcut: Shortcut, targetID: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var targets = root["targets"] as? [[String: Any]],
              let i = targets.firstIndex(where: { $0["id"] as? String == targetID })
        else { throw ConfigError("Cible introuvable : \(targetID)") }
        targets[i]["shortcut"] = shortcut.spec
        root["targets"] = targets
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        _ = try load(path: path) // revalide
    }
}
