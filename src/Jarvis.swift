import Foundation

enum JarvisRoutine: String, CaseIterable {
    case openProject = "ouvrir-voicewake"
    case gitStatus = "etat-du-depot"

    var phrases: [String] {
        switch self {
        case .openProject: return ["ouvre voicewake", "ouvre le projet voicewake", "ouvre mon projet voicewake"]
        case .gitStatus: return ["etat du depot", "statut du depot", "etat git"]
        }
    }
}

enum JarvisAction {
    case routine(JarvisRoutine)
    case assistant(Target)
    case unknownAssistant

    var description: String {
        switch self {
        case let .routine(routine): return "routine : \(routine.rawValue)"
        case let .assistant(target): return target.id
        case .unknownAssistant: return "assistant non configuré"
        }
    }
}

enum Jarvis {
    /// « Jarvis » et ce que le moteur entend parfois à la place.
    static let wakeNames: Set<String> = ["jarvis", "jaris", "jarvisse", "jarvice", "djarvis"]
    static let greetings: Set<String> = ["salut", "dis", "dit", "hey", "he", "ok", "bonjour"]
    static let assistantPrefixes = ["dis a ", "dit a ", "demande a ", "dis ", "dit "]
    /// « Jarvis, démarre Claude » : sans effet si le nom n'est pas celui d'un assistant.
    static let startPrefixes = ["demarre ", "lance ", "active ", "ouvre "]

    static func names(for target: Target) -> Set<String> {
        let prefixes = ["salut ", "dis ", "dit ", "di ", "hey ", "he ", "say "]
        let aliases = target.phrases.map(normalize).compactMap { phrase in
            prefixes.first(where: phrase.hasPrefix).map { String(phrase.dropFirst($0.count)) }
        }
        return Set((aliases + [normalize(target.id), normalize(target.appName ?? "")]).filter { !$0.isEmpty })
    }

    static func perform(
        _ action: JarvisAction, config: Config, router: Router, trigger: ShortcutTrigger,
        completion: @escaping (Target?, Bool) -> Void
    ) {
        switch action {
        case let .routine(routine):
            run(routine, config: config) { completion(nil, $0) }
        case let .assistant(target):
            let selected = router.inEditor(target) ?? target
            guard ShortcutTrigger.runningApp(for: selected) != nil || ShortcutTrigger.appURL(for: selected) != nil else {
                speak("\(target.id) n’est pas installé.", config: config) { completion(nil, false) }
                return
            }
            // Annonce avant le micro : seulement si `jarvisAnnounce` est activé (sinon, comme « Salut Claude »).
            let announce: (@escaping () -> Void) -> Void = { next in
                if config.jarvisAnnounce == true { speak("J’ouvre la dictée avec \(target.id).", config: config, completion: next) }
                else { next() }
            }
            announce {
                let external = selected.id == target.id ? config.externalDictation : nil
                trigger.fire(selected, external: external) { started in
                    if started { completion(selected, true) }
                    else { speak("Impossible d’ouvrir la dictée.", config: config) { completion(nil, false) } }
                }
            }
        case .unknownAssistant:
            speak("Cet assistant n’est pas configuré.", config: config) { completion(nil, false) }
        }
    }

    private static func run(_ routine: JarvisRoutine, config: Config, completion: @escaping (Bool) -> Void) {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let installedPath = try? String(contentsOf: resources.appendingPathComponent("project-path"), encoding: .utf8)
        let project = (config.jarvisProjectPath ?? installedPath ?? FileManager.default.currentDirectoryPath) as NSString
        let scripts = installedPath == nil ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts") : resources.appendingPathComponent("scripts")
        DispatchQueue.global().async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scripts.appendingPathComponent(routine.rawValue + ".sh").path, project.expandingTildeInPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            var success = false
            var message: String
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                success = process.terminationStatus == 0
                message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty { message = success ? "Routine terminée." : "La routine a échoué." }
            } catch {
                message = "Impossible de lancer la routine."
            }
            print(message)
            let result = success
            DispatchQueue.main.async { speak(message, config: config) { completion(result) } }
        }
    }

    /// Annonce : voix ElevenLabs si elle est activée, sinon voix du Mac.
    static func speak(_ message: String, config: Config, completion: @escaping () -> Void) {
        ElevenLabs.say(message, config: config) { said in
            if said { completion() } else { speakWithSystemVoice(message, completion: completion) }
        }
    }

    private static func speakWithSystemVoice(_ message: String, completion: @escaping () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-f", "-"]
        let input = Pipe()
        process.standardInput = input
        process.terminationHandler = { _ in DispatchQueue.main.async(execute: completion) }
        do {
            try process.run()
            try? input.fileHandleForWriting.write(contentsOf: Data(message.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            log("Confirmation vocale indisponible.")
            DispatchQueue.main.async(execute: completion)
        }
    }
}
