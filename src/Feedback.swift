import AppKit

/// Sons de confirmation : VoiceWake n'a pas d'interface, ces sons disent ce qu'il a compris.
/// Sons système de macOS, volume bas ; désactivables avec `"feedbackSounds": false`.
enum Feedback {
    enum Event: String, CaseIterable {
        /// Commande de lecture exécutée (pause, reprise, « lis à partir de », « fais la lecture »).
        case understood
        /// Micro de l'assistant ouvert (activation, « écoute », conversation continue).
        case micOpen
        /// Micro coupé sans envoi (« ok arrête », « garde le brouillon », silence).
        case micClosed
        /// Message envoyé.
        case sent
        /// Commande attribuée à la voix de lecture : la redire pour la faire passer.
        case ignored
        /// Action impossible (passage introuvable, bouton absent, assistant fermé…).
        case failed

        var defaultSound: String {
            switch self {
            case .understood: return "Tink"
            case .micOpen: return "Pop"
            case .micClosed: return "Bottle"
            case .sent: return "Glass"
            case .ignored: return "Purr"
            case .failed: return "Basso"
            }
        }
    }

    private static var enabled = true
    private static var volume: Float = 0.35
    private static var sounds: [Event: NSSound] = [:]

    static func configure(_ config: Config) {
        enabled = config.feedbackSounds ?? true
        volume = Float(min(max(config.feedbackVolume ?? 0.35, 0), 1))
        sounds = [:]
        guard enabled else { return }
        for event in Event.allCases {
            let name = config.feedbackSoundNames?[event.rawValue] ?? event.defaultSound
            guard let sound = NSSound(named: NSSound.Name(name)) else {
                log("Son de confirmation introuvable : \(name) (\(event.rawValue)).")
                continue
            }
            sound.volume = volume
            sounds[event] = sound
        }
    }

    static func play(_ event: Event) {
        guard enabled, let sound = sounds[event] else { return }
        DispatchQueue.main.async {
            sound.stop() // rejouable immédiatement
            sound.play()
        }
    }
}
