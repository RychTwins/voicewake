import AppKit
import AVFoundation
import Speech

/// Vérifications de bon fonctionnement : autorisations, apps, modèles. Au démarrage, un problème est dit à voix
/// haute (une fois) au lieu de faire échouer les commandes en silence ; `voicewake diagnostic` montre tout.
enum Diagnostic {
    struct Check { let name: String; let ok: Bool; let fix: String }

    static func run(_ config: Config) -> [Check] {
        var out: [Check] = []
        out.append(Check(name: "Accessibilité", ok: AXIsProcessTrusted(),
                         fix: "Réglages Système > Confidentialité et sécurité > Accessibilité : autoriser VoiceWake."))
        out.append(Check(name: "Micro", ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         fix: "Réglages Système > Confidentialité et sécurité > Micro : autoriser VoiceWake."))
        out.append(Check(name: "Reconnaissance vocale", ok: SFSpeechRecognizer.authorizationStatus() == .authorized,
                         fix: "Réglages Système > Confidentialité et sécurité > Reconnaissance vocale : autoriser VoiceWake."))
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: config.locale))
        out.append(Check(name: "Modèle vocal local (\(config.locale))", ok: recognizer?.supportsOnDeviceRecognition == true,
                         fix: "Réglages Système > Clavier > Dictée : activer la dictée en \(config.locale)."))
        for t in config.targets {
            out.append(Check(name: "App \(t.appName ?? t.id)", ok: ShortcutTrigger.appURL(for: t) != nil,
                             fix: "Installer l'app, ou retirer la cible « \(t.id) » de la configuration."))
        }
        if config.interpreter?.enabled ?? true {
            out.append(Check(name: "Interpréteur local (Apple Intelligence)", ok: Interpreter.isAvailable,
                             fix: "Réglages Système > Apple Intelligence et Siri : activer Apple Intelligence (\(Interpreter.unavailableReason))."))
        }
        if let v = config.voiceFilter, v.enabled == true {
            out.append(Check(name: "Modèle de voix", ok: FileManager.default.fileExists(atPath: VoicePrint.defaultModelPath(v)),
                             fix: "Télécharger wespeaker_int8.mlmodelc dans ~/.config/voicewake/models/ (voir le README)."))
            out.append(Check(name: "Empreinte de voix", ok: VoicePrint.loadProfile(VoicePrint.defaultPath(v)) != nil,
                             fix: "voicewake voix apprends"))
        }
        let routines = Routines.problems(config.routines ?? [])
        out.append(Check(name: "Routines", ok: routines.isEmpty, fix: routines.joined(separator: " ")))
        return out
    }

    /// Phrase dite au démarrage s'il y a un problème (aucune phrase de commande dedans).
    static func spokenSummary(_ checks: [Check]) -> String? {
        let failed = checks.filter { !$0.ok }
        guard !failed.isEmpty else { return nil }
        if failed.count == 1 { return "VoiceWake : problème avec \(failed[0].name). Le détail est dans le journal." }
        return "VoiceWake : \(failed.count) problèmes, dont \(failed[0].name). Le détail est dans le journal."
    }
}
