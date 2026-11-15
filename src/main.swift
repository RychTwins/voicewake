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
  sons           fait entendre chaque son de confirmation
  action <cible> <clearDraft|newChat|copyResponse>   exécute une commande de gestion dans 3 s (app au premier plan)
  dis <cible> "phrase"   exécute une phrase de navigation dans 3 s (ex. "ouvre voxtv", "session précédente")
  barre <cible>  liste les projets et sessions de la barre latérale
  trouve <bundle-id> "menu …"   montre l'option ou le bouton visé, sans cliquer
  skill <cible> "nom arguments"  montre le skill ou la commande slash qui serait tapé
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
    app.setActivationPolicy(.accessory) // pas d'icône dans le Dock
    rotateLogIfNeeded()
    // Service lancé pour des jours : vérification toutes les heures.
    let logTimer = Timer(timeInterval: 3600, repeats: true) { _ in rotateLogIfNeeded() }
    RunLoop.main.add(logTimer, forMode: .common)
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
        if external.useMacOSDictationMenu == true { print("- démarrage via le menu Dictée macOS") }
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

case "passage":
    // voicewake passage <cible> "citation" : montre où commencerait « lis à partir de … » (sans lire).
    let t = requireTarget(args)
    guard let app = ShortcutTrigger.runningApp(for: t) else { print("\(t.id) n'est pas ouverte."); exit(1) }
    AXButtonPresser.enableAccessibility(app)
    usleep(800_000)
    let tokens = PassageFinder.tokens(in: app, target: t)
    let query = normalize(args.dropFirst(2).joined(separator: " ")).split(separator: " ").map(String.init)
    if let i = PassageFinder.find(query, in: tokens) {
        let words = PassageFinder.passage(tokens, from: i)
        print("→ début : « \(words.prefix(14).joined(separator: " ")) … »")
        print("→ fin   : « … \(words.suffix(14).joined(separator: " ")) » (\(words.count) mots)")
    } else {
        print("→ passage introuvable (\(tokens.count) mots affichés)")
    }

case "highlight":
    // voicewake highlight <cible> "quelques mots" : pose 6 s le surlignage sur le bloc de texte trouvé (essai).
    let t = requireTarget(args)
    guard let target = ShortcutTrigger.runningApp(for: t) else { print("\(t.id) n'est pas ouverte."); exit(1) }
    app.setActivationPolicy(.accessory)
    AXButtonPresser.enableAccessibility(target)
    usleep(800_000)
    let wanted = normalize(args.dropFirst(2).joined(separator: " "))
    let blocks = AXButtonPresser.textBlocks(in: target)
    guard let block = blocks.last(where: { (" " + normalize($0.text) + " ").contains(" " + wanted + " ") }), let web = block.web else {
        print("→ texte introuvable (\(blocks.count) blocs)"); exit(1)
    }
    guard let frame = AXButtonPresser.textFrame(of: block.element, in: web, app: target) else {
        print("→ bloc trouvé mais hors de l'écran"); exit(1)
    }
    print("→ surlignage posé : \(NSStringFromRect(frame))")
    let overlay = HighlightOverlay()
    overlay.show(frame)
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()

case "route":
    let text = args.dropFirst().joined(separator: " ")
    let router = Router(config: config)
    print(router.route(text).map { "→ \($0.id)" } ?? "→ aucune cible")
    if let nav = NavCommands.match(text, target: nil, config: config) {
        switch nav {
        case let .command(c): print("→ navigation : \(((c.menu ?? []) + (c.buttons ?? [])).first ?? "?")")
        case let .open(q): print("→ ouvrir : \(q.joined(separator: " "))")
        case let .newSessionIn(q): print("→ nouvelle session dans : \(q.joined(separator: " "))")
        }
    } else if let command = AppCommand.match(text, router: router, config: config) { print("→ commande : \(command.rawValue)") }
    if config.externalDictation == nil && router.isThoughtPause(text) {
        print("→ suspension de l'envoi automatique")
    } else if config.externalDictation == nil && router.isSendCommand(text) {
        print("→ phrase d'envoi (pendant une dictée)")
    } else if (config.externalDictation == nil || config.externalDictation?.stopShortcut != nil) && router.endsWithStopPhrase(text) {
        print("→ phrase d'arrêt du micro (pendant une dictée)")
    }

case "action":
    // voicewake action <cible> <commande> : laisse 3 s pour mettre l'app devant, puis exécute la commande.
    let t = requireTarget(args)
    guard args.count >= 3, let command = AppCommand(rawValue: args[2]), command != .status else {
        print("Commandes : clearDraft, newChat, copyResponse"); exit(1)
    }
    print("Mets \(t.id) au premier plan : \(command.rawValue) dans 3 s…")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    var finished = false
    AppActions.run(command, target: t) { ok, detail in
        print(ok ? "✓ \(detail)" : "✗ \(detail)")
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

case "dis", "say":
    // voicewake dis claude "ouvre voxtv" : exécute une phrase de navigation dans 3 s, sans la voix.
    let t = requireTarget(args)
    let phrase = args.dropFirst(2).joined(separator: " ")
    guard let request = NavCommands.match(phrase, target: t, config: config) else { print("→ pas une commande de navigation"); exit(1) }
    print("Mets \(t.id) au premier plan : « \(phrase) » dans 3 s…")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    var navDone = false
    NavCommands.run(request, target: t) { ok, detail in print(ok ? "✓ \(detail)" : "✗ \(detail)"); navDone = true }
    while !navDone { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

case "barre":
    // voicewake barre claude : liste les projets et sessions de la barre latérale (ce que « ouvre … » peut viser).
    let t = requireTarget(args)
    guard let target = ShortcutTrigger.runningApp(for: t) else { print("\(t.id) n'est pas ouverte."); exit(1) }
    AXButtonPresser.enableAccessibility(target)
    usleep(500_000)
    for e in AXButtonPresser.sidebarEntries(in: target) where e.kind != .newSession {
        print(e.kind == .project ? "▸ \(e.title)" : "    \(e.title)")
    }

case "lecteur":
    // voicewake lecteur "texte" : lit le texte avec le lecteur intégré (ElevenLabs si activé), comme « lis à partir de ».
    let text = args.dropFirst().joined(separator: " ")
    guard !text.isEmpty else { print("Usage : voicewake lecteur \"texte\""); exit(1) }
    let reader = Reader()
    reader.voiceName = config.readerVoice
    var over = false
    reader.onFinish = { over = true }
    let began = Date()
    reader.speak(text, config: config)
    if args.contains("--vite") { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); reader.changeRate(faster: true); reader.changeRate(faster: true); reader.changeRate(faster: true) }
    while !over { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print(String(format: "Lecture terminée en %.1f s.", Date().timeIntervalSince(began)))

case "trouve":
    // voicewake trouve <bundle-id> "menu afficher le terminal" : montre l'option ou le bouton visé, sans cliquer.
    guard args.count >= 3, let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[1] }) else {
        print("Usage : voicewake trouve <bundle-id> \"menu …\" | \"clique sur …\""); exit(1)
    }
    AXButtonPresser.enableAccessibility(app)
    usleep(300_000)
    let phrase = args.dropFirst(2).joined(separator: " ")
    guard let u = Universal.match(phrase, config: config) else { print("→ pas une commande universelle"); exit(1) }
    if let a = Universal.find(u.kind, u.query, in: app) {
        print("→ \(u.kind == .menu ? "menu" : "bouton") « \(a.title) »\(a.path.isEmpty ? "" : " (\(a.path))")\(a.dangerous ? " — confirmation requise" : "")")
    } else { print("→ rien ne correspond") }

case "skill":
    // voicewake skill <cible> "code review sur ce fichier" : montre ce qui serait tapé (sans rien taper).
    let t = requireTarget(args)
    let entries = SkillCatalog.entries(for: t)
    let phrase = args.dropFirst(2).joined(separator: " ")
    guard !phrase.isEmpty else { print("\(entries.count) skills et commandes pour \(t.id)."); exit(0) }
    let q = normalize(phrase).split(separator: " ").map(String.init)
    if let hit = SkillCatalog.match(q, in: entries) {
        let args2 = SkillCatalog.originalTail(phrase, skippingWords: hit.consumed)
        print("→ « \(hit.entry.text)\(args2.isEmpty ? "" : " " + args2) » (\(entries.count) connus)")
    } else { print("→ aucun skill ne correspond (\(entries.count) connus)") }

case "sons", "sounds":
    // Fait entendre les sons de confirmation, dans l'ordre, avec leur signification.
    let meaning: [Feedback.Event: String] = [
        .understood: "commande comprise", .micOpen: "micro ouvert", .micClosed: "micro coupé sans envoi",
        .sent: "message envoyé", .ignored: "commande ignorée (voix de lecture) : la redire", .failed: "action impossible",
    ]
    guard config.feedbackSounds ?? true else { print("Sons désactivés (\"feedbackSounds\": false)."); exit(0) }
    Feedback.configure(config)
    for event in Feedback.Event.allCases {
        print("→ \(config.feedbackSoundNames?[event.rawValue] ?? event.defaultSound) : \(meaning[event] ?? "")")
        Feedback.play(event)
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
    }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
