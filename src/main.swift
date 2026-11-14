import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
Usage : voicewake [commande] [--config chemin]
  run            écoute en continu (défaut, lancé par le LaunchAgent)
  check          vérifie la configuration et les autorisations
  test <cible>   envoie le raccourci de la cible dans 3 s (sans micro)
  record <cible> enregistre le raccourci que tu tapes au clavier
  set <cible> "raccourci"   ex. "ctrl+shift+v", "double option", "capslock", "hold 1 fn"
  route "texte"  montre quelle cible une phrase déclencherait
"""

var args = Array(CommandLine.arguments.dropFirst())
var configPath = Config.defaultPath()
if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
    configPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let command = args.first ?? "run"

let config: Config
do {
    config = try Config.load(path: configPath)
} catch {
    log("Configuration invalide (\(configPath)) : \(error.localizedDescription)")
    exit(1)
}

/// Recharge le service s'il tourne, pour appliquer la nouvelle config.
func restartAgent() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", "gui/\(getuid())/io.github.voicewake"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func save(_ shortcut: Shortcut, for id: String) -> Never {
    do {
        try Config.saveShortcut(shortcut, targetID: id, path: configPath)
        restartAgent()
        print("✓ \(id) → « \(shortcut.spec) » enregistré. Teste : voicewake test \(id)")
        exit(0)
    } catch {
        print("Échec : \(error.localizedDescription)")
        exit(1)
    }
}

func requireTarget(_ args: [String]) -> Target {
    guard args.count >= 2, let t = config.target(id: args[1]) else {
        print("Cibles : \(config.targets.map(\.id).joined(separator: ", "))")
        exit(1)
    }
    return t
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // aucune fenêtre, aucune icône dans le Dock

switch command {
case "run":
    do {
        let coordinator = try Coordinator(config: config)
        coordinator.start()
        withExtendedLifetime(coordinator) { app.run() }
    } catch {
        log(error.localizedDescription)
        exit(1)
    }

case "check":
    print("Configuration OK : \(configPath)")
    for t in config.targets {
        let installed = ShortcutTrigger.appURL(for: t) != nil
        let running = ShortcutTrigger.runningApp(for: t) != nil
        print("- \(t.id) : « \(t.shortcut.spec) » | installée : \(installed ? "oui" : "NON") | ouverte : \(running ? "oui" : "non")")
        print("    phrases : \(t.phrases.joined(separator: ", "))")
    }
    print("- premier plan : \(config.frontmostPhrases.joined(separator: ", ")) → défaut : \(config.defaultTarget ?? "aucun")")
    for e in config.editors ?? [] {
        print("- éditeur \(e.id) (\(e.bundleIDs.joined(separator: ", "))) : \(e.assistants.keys.sorted().joined(separator: ", "))")
    }
    if let external = config.externalDictation {
        print("- dictée externe par défaut : « \(external.shortcut.spec) »")
        print("- arrêt vocal : \(external.stopShortcut?.spec ?? "désactivé") | envoi vocal : désactivé")
    } else {
        print("- envoi vocal : \((config.sendPhrases ?? []).isEmpty ? "désactivé" : (config.sendPhrases ?? []).joined(separator: ", "))")
    }
    print("Accessibilité : \(ShortcutTrigger.checkAccessibility(prompt: false) ? "OK" : "NON")")

case "test":
    let t = requireTarget(args)
    guard ShortcutTrigger.checkAccessibility(prompt: true) else { exit(1) }
    let external = config.externalDictation
    print("Raccourci de \(t.id) (« \((external?.shortcut ?? t.shortcut).spec) ») dans 3 s…")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        // Même règle que la voix : un éditeur au premier plan avec l'assistant intégré est prioritaire.
        let target = external == nil ? (Router(config: config).inEditor(t) ?? t) : t
        print("→ \(target.id)")
        ShortcutTrigger().fire(target, external: external) { started in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(started ? 0 : 1) }
        }
    }
    app.run()

case "set":
    let t = requireTarget(args)
    guard args.count >= 3 else { print(usage); exit(1) }
    do {
        save(try Shortcut(spec: args.dropFirst(2).joined(separator: " ")), for: t.id)
    } catch {
        print("Raccourci invalide : \(error.localizedDescription)")
        exit(1)
    }

case "record":
    let t = requireTarget(args)
    let recorder = ShortcutRecorder()
    let started = recorder.start(timeout: 15) { spec in
        guard let spec, let shortcut = try? Shortcut(spec: spec) else {
            print("Aucun raccourci détecté.")
            exit(1)
        }
        print("Détecté : « \(spec) »")
        save(shortcut, for: t.id)
    }
    guard started else {
        print("Autoriser le Terminal : Réglages Système > Confidentialité et sécurité > Surveillance de l'entrée, puis relancer.")
        exit(1)
    }
    print("Tape maintenant le raccourci vocal de \(t.id) (15 s)…")
    withExtendedLifetime(recorder) { app.run() }

case "route":
    let text = args.dropFirst().joined(separator: " ")
    let router = Router(config: config)
    print(router.route(text).map { "→ \($0.id)" } ?? "→ aucune cible")
    if config.externalDictation == nil && router.endsWithSendPhrase(text) {
        print("→ phrase d'envoi (pendant une dictée)")
    } else if (config.externalDictation == nil || config.externalDictation?.stopShortcut != nil) && router.endsWithStopPhrase(text) {
        print("→ phrase d'arrêt du micro (pendant une dictée)")
    }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
