import Foundation
import ApplicationServices

// Tests sans micro du lecteur intégré : alignement ElevenLabs, fin de réponse.
// swiftc -wmo -parse-as-library tests/reader.swift $(ls src/*.swift | grep -v main.swift) -framework AppKit -framework AVFoundation -framework Speech -framework CoreAudio -o /tmp/reader-tests && /tmp/reader-tests
@main
struct ReaderTests {
    static func check(_ ok: Bool, _ name: String) {
        if !ok { print("ÉCHEC : \(name)"); exit(1) }
        print("ok : \(name)")
    }

    static func main() {
        // Alignement : un instant par unité UTF-16 (accents, émoji sur deux unités).
        let text = "Écoute 👍 là"
        let chars = text.map(String.init)
        let starts = chars.indices.map { NSNumber(value: Double($0) * 0.1) }
        let t = ElevenLabs.timings(["characters": chars, "character_start_times_seconds": starts], text: text)
        check(t?.count == (text as NSString).length, "un instant par unité UTF-16")
        check(t?[7] == t?[8], "émoji : même instant pour ses deux unités")
        check(ElevenLabs.timings(["characters": ["a"], "character_start_times_seconds": [0]], text: "ab") == nil,
              "alignement incomplet refusé (position estimée)")
        check(ElevenLabs.timings(nil, text: "ab") == nil, "pas d'alignement")

        // Réponse complète de /with-timestamps.
        let json: [String: Any] = [
            "audio_base64": Data("mp3".utf8).base64EncodedString(),
            "alignment": ["characters": ["o", "k"], "character_start_times_seconds": [0, 0.2],
                          "character_end_times_seconds": [0.2, 0.4]],
        ]
        let speech = ElevenLabs.parse(try! JSONSerialization.data(withJSONObject: json), text: "ok")
        check(speech?.audio == Data("mp3".utf8) && speech?.timings == [0, 0.2], "réponse /with-timestamps lue")
        check(ElevenLabs.parse(Data("{}".utf8), text: "ok") == nil, "réponse sans audio refusée")

        // Fin de réponse : on s'arrête à la marque posée au bouton « Lire à voix haute ».
        let end = AXButtonPresser.messageEnd
        let tokens = ["Question", end, "Cause", ":", "voilà", "fin.", end, "Tu", "refais", "le", "test", "?"]
        let start = PassageFinder.find(["cause", "voila"], in: tokens)
        check(start == 2, "passage trouvé malgré les marques")
        check(PassageFinder.passage(tokens, from: 2) == ["Cause", ":", "voilà", "fin."], "lecture arrêtée à la fin de la réponse")
        check(PassageFinder.passage(tokens, from: 7) == ["Tu", "refais", "le", "test", "?"], "dernier bloc sans marque")
        check(PassageFinder.passage(tokens, from: 2, maxWords: 2) == ["Cause", ":"], "limite de mots")
        // Segments ElevenLabs : un premier court, puis des blocs coupés en fin de phrase, sans trou ni recouvrement.
        let short = "Une seule phrase courte." as NSString
        check(Reader.segmentRanges(in: short) == [NSRange(location: 0, length: short.length)], "texte court : un seul segment")
        let sentence = "Voici une phrase de test assez ordinaire qui fait environ quatre-vingts caractères. "
        let long = String(repeating: sentence, count: 60) as NSString
        let parts = Reader.segmentRanges(in: long)
        check(parts.count >= 3, "texte long : plusieurs segments")
        check(parts[0].length <= 300 && parts[0].length >= 60, "premier segment court (démarrage rapide)")
        check(parts.dropFirst().allSatisfy { $0.length <= 1500 }, "segments suivants de 1 500 caractères au plus")
        check(zip(parts, parts.dropFirst()).allSatisfy { $0.location + $0.length == $1.location } && parts.last.map { $0.location + $0.length } == long.length,
              "segments contigus, tout le texte couvert")
        check(parts.dropLast().allSatisfy { long.substring(with: $0).hasSuffix(". ") }, "coupés en fin de phrase")
        let words = String(repeating: "mot ", count: 200) as NSString
        check(Reader.segmentRanges(in: words).first.map { words.substring(with: $0).hasSuffix(" ") } == true, "sans ponctuation : coupé entre deux mots")

        // Cache audio ElevenLabs.
        let settings = ElevenLabsSettings(enabled: true, voiceID: "v", model: nil, keyFile: nil)
        let k1 = ElevenLabs.cacheKey("bonjour", settings, locale: "fr-FR")
        check(k1 != ElevenLabs.cacheKey("bonjour", ElevenLabsSettings(enabled: true, voiceID: "w", model: nil, keyFile: nil), locale: "fr-FR"),
              "clé du cache : dépend de la voix")
        ElevenLabs.store(ElevenLabs.Speech(audio: Data([1]), timings: nil), key: k1)
        check(ElevenLabs.cached(k1)?.audio == Data([1]), "extrait relu depuis le cache")
        for i in 0..<ElevenLabs.cacheLimit { ElevenLabs.store(ElevenLabs.Speech(audio: Data([2]), timings: nil), key: "k\(i)") }
        check(ElevenLabs.cached(k1) == nil, "cache limité : les plus anciens sont oubliés")

        // Navigation par phrases.
        let story = "Première phrase ici. Deuxième phrase un peu plus longue ! Troisième ?\nQuatrième ligne." as NSString
        let sentenceStarts = Reader.sentenceStarts(in: story)
        check(sentenceStarts == [0, 21, 58, 70], "débuts de phrases (. ! ? et retour à la ligne)")
        check(Reader.sentenceTarget(in: story, from: 45, forward: true) == 58, "phrase suivante")
        check(Reader.sentenceTarget(in: story, from: 45, forward: false) == 21, "répète : début de la phrase en cours")
        check(Reader.sentenceTarget(in: story, from: 24, forward: false) == 0, "répète juste après le début : phrase précédente")
        check(Reader.sentenceTarget(in: story, from: 75, forward: true) == nil, "pas de phrase après la dernière")
        check(Reader.wordStart(in: story, at: 25) == 21, "début du mot en cours")

        // Phrases de commande (configuration d'exemple).
        guard let config = try? Config.load(path: "config.example.json") else { print("ÉCHEC : config.example.json illisible"); exit(1) }
        let router = Router(config: config)
        check(AppCommand.match("bon efface le brouillon", router: router, config: config) == .clearDraft, "efface le brouillon")
        check(AppCommand.match("nouvelle conversation", router: router, config: config) == .newChat, "nouvelle conversation")
        check(AppCommand.match("copie la réponse", router: router, config: config) == .copyResponse, "copie la réponse")
        check(AppCommand.match("où on en est", router: router, config: config) == .status, "où on en est (accents ignorés)")
        check(AppCommand.match("je copie le code", router: router, config: config) == nil, "phrase ordinaire : aucune commande")
        check(!router.isSendCommand("efface le brouillon"), "efface le brouillon n'envoie pas")
        check(ReaderNav.match("plus vite", config: config) == .faster, "plus vite")
        check(ReaderNav.match("ralentis", config: config) == .slower, "ralentis")
        check(ReaderNav.match("répète", config: config) == .repeatSentence, "répète")
        check(ReaderNav.match("phrase suivante", config: config) == .nextSentence, "phrase suivante")
        check(ReaderNav.match("plus vite non moins vite", config: config) == .slower, "la commande la plus récente l'emporte")

        // Navigation : phrases et noms de projets.
        guard let claudeTarget = config.target(id: "claude") else { print("ÉCHEC : cible claude absente"); exit(1) }
        func nav(_ t: String) -> String {
            switch NavCommands.match(t, target: claudeTarget, config: config) {
            case let .command(c)?: return "cmd:" + (((c.menu ?? []) + (c.buttons ?? [])).first ?? "")
            case let .open(q)?: return "open:" + q.joined(separator: " ")
            case let .newSessionIn(q)?: return "new:" + q.joined(separator: " ")
            case nil: return "-"
            }
        }
        check(nav("session précédente") == "cmd:Session précédente", "session précédente → menu")
        check(nav("ouvre les paramètres") == "cmd:Paramètres…", "commande fixe avant « ouvre <nom> »")
        check(nav("ouvre Equality Holding") == "open:equality holding", "ouvre <projet>")
        check(nav("nouvelle session dans VoxTV") == "new:voxtv", "nouvelle session dans <projet>")
        check(nav("je reviens à la page précédente demain") == "-", "phrase au milieu d'une autre : rien")
        check(nav("nouvelle conversation") == "-", "nouvelle conversation reste la commande de gestion")
        check(nav("il faut que j'ouvre la porte") == "-", "« ouvre » au milieu d'une phrase : rien")
        check(nav("ouvre un texte beaucoup trop long pour être un nom de projet ici") == "-", "nom trop long : rien")

        let dummy = AXUIElementCreateApplication(getpid())
        typealias E = AXButtonPresser.SidebarEntry
        let sidebar = [
            E(title: "Artéfacts", element: dummy, kind: .session, project: "Navigation"),
            E(title: "Equality ERP", element: dummy, kind: .project, project: "Equality ERP"),
            E(title: "Audit du projet", element: dummy, kind: .session, project: "Equality ERP"),
            E(title: "Equality Holding", element: dummy, kind: .project, project: "Equality Holding"),
            E(title: "Nouvelle session dans Equality Holding", element: dummy, kind: .newSession, project: "Equality Holding"),
            E(title: "VoxTV", element: dummy, kind: .project, project: "VoxTV"),
            E(title: "Vue magazine et Vox mag", element: dummy, kind: .session, project: "VoxTV"),
        ]
        func best(_ q: String, _ kinds: Set<E.Kind> = [.project, .session]) -> String? {
            NavCommands.bestEntry(q.split(separator: " ").map(String.init), in: sidebar, kinds: kinds)?.title
        }
        check(best("equality holding") == "Equality Holding", "projet exact")
        check(best("le projet equality erp") == "Equality ERP", "mots vides ignorés")
        check(best("vox tv") == "VoxTV", "nom dit en deux mots (« vox tv » ↔ VoxTV)")
        check(best("vox mag") == "Vue magazine et Vox mag", "session par quelques mots")
        check(best("equality") == "Equality ERP", "nom partiel : premier projet le plus proche")
        check(best("inconnu") == nil, "aucun résultat")
        check(best("equality holding", [.newSession]) == "Nouvelle session dans Equality Holding", "bouton nouvelle session du projet")

        // Codex et Gemini : commandes de leurs menus.
        func navFor(_ id: String, _ t: String) -> String {
            guard let target = config.target(id: id), case let .command(c)? = NavCommands.match(t, target: target, config: config) else { return "-" }
            return (c.menu ?? []).first ?? ""
        }
        check(navFor("codex", "conversation précédente") == "Élément précédent de la barre latérale", "Codex : conversation précédente")
        check(navFor("codex", "page précédente") == "Retour", "Codex : page précédente")
        check(navFor("gemini", "zoom avant") == "Augmenter la taille du texte", "Gemini : zoom avant (libellé propre)")
        check(navFor("gemini", "toutes les discussions") == "Afficher toutes les discussions", "Gemini : toutes les discussions")
        check(navFor("chatgpt", "zoom avant") == "-", "ChatGPT : pas de commandes par défaut")

        guard let geminiTarget = config.target(id: "gemini") else { print("ÉCHEC : cible gemini absente"); exit(1) }
        check(NavCommands.isConversationTitle("Test du mode vocal automatique", for: geminiTarget), "conversation récente acceptée")
        check(!NavCommands.isConversationTitle("Supprimer la discussion", for: geminiTarget), "action destructrice refusée")
        check(!NavCommands.isConversationTitle("Afficher toutes les discussions", for: geminiTarget), "commande de l'app refusée")
        check(!NavCommands.isConversationTitle("Récentes", for: geminiTarget), "en-tête de menu refusé")

        // Commandes universelles.
        func uni(_ t: String) -> String {
            guard let m = Universal.match(t, config: config) else { return "-" }
            return (m.kind == .menu ? "menu:" : "click:") + m.query.joined(separator: " ")
        }
        check(uni("menu afficher le terminal") == "menu:afficher le terminal", "menu <libellé>")
        check(uni("clique sur artéfacts") == "click:artefacts", "clique sur <libellé>")
        check(uni("appuie sur le bouton partager") == "click:partager", "appuie sur le bouton <libellé>")
        check(uni("je clique sur le lien") == "-", "« clique » au milieu d'une phrase : rien")
        let menuItems: [(title: String, value: Int)] = [("Afficher le terminal", 1), ("Afficher les fichiers", 2), ("Terminal", 3), ("Zoom avant", 4)]
        check(Universal.best(["terminal"], in: menuItems)?.value == 3, "libellé exact préféré")
        check(Universal.best(["afficher", "terminal"], in: menuItems)?.value == 1, "plusieurs mots")
        check(Universal.best(["zoom", "avant"], in: menuItems)?.value == 4, "zoom avant")
        check(Universal.best(["inexistant"], in: menuItems) == nil, "rien ne correspond")
        check(Universal.isDangerous("Supprimer la conversation"), "supprimer : sensible")
        check(Universal.isDangerous("Se déconnecter"), "se déconnecter : sensible")
        check(Universal.isDangerous("Sign out"), "sign out : sensible")
        check(!Universal.isDangerous("Afficher le terminal"), "afficher : pas sensible")
        check(Universal.isDangerous("Données de session", path: "Aide > Dépannage > Supprimer les données"), "chemin de menu sensible")
        check(Universal.isDangerous("Move to Trash"), "trash : sensible")
        check(Universal.isDangerous("Autoriser"), "autoriser : sensible")
        let tied: [(title: String, value: Int)] = [("Afficher le terminal", 1), ("Afficher le navigateur", 2)]
        check(Universal.best(["afficher"], in: tied) == nil, "deux libellés aussi proches : ambigu, rien")
        let vague: [(title: String, value: Int)] = [("Tout afficher", 1), ("Afficher le terminal", 2)]
        check(Universal.best(["afficher"], in: vague) == nil, "phrase vague : rien")
        check(Universal.best(["tout", "afficher"], in: vague)?.value == 1, "libellé exact : choisi")
        check(Universal.best(["terminal"], in: vague)?.value == 2, "seul candidat : choisi")
        check(Universal.allowedApps(config).contains("dev.zed.Zed") && !Universal.allowedApps(config).contains("com.apple.Safari") && Universal.allowedApps(config).contains("com.apple.finder"),
              "liste blanche : éditeurs et Finder oui, app quelconque non")

        // Confirmation vocale.
        check(Universal.answer("Je confirme", config: config) == .confirm, "je confirme : confirme")
        check(Universal.answer("oui", config: config) == nil, "un simple oui ne confirme jamais")
        check(Universal.answer("non", config: config) == .cancel, "non : annule")
        check(Universal.answer("oui mais non", config: config) == nil, "énoncé plus long : ni oui ni non")
        check(Universal.confirmationPrompt("Supprimer la conversation", config: config) == "Confirmer « Supprimer la conversation » ?", "question avec le libellé")
        check(Universal.confirmationPrompt("Non lu", config: config) == "Confirmer cette action ?", "libellé contenant « non » : jamais répété")
        check(Universal.answer(Universal.confirmationPrompt("Supprimer", config: config), config: config) == nil, "la question n'est jamais une réponse")

        // Skills : catalogue lu sur un faux dossier personnel.
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vw-home-\(getpid())")
        let fm = FileManager.default
        func skill(_ dir: URL, _ name: String, declared: String? = nil) {
            try? fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            let head = declared.map { "---\nname: \($0)\ndescription: x\n---\n" } ?? "# \(name)\n"
            fm.createFile(atPath: dir.appendingPathComponent(name).appendingPathComponent("SKILL.md").path, contents: Data(head.utf8))
        }
        skill(home.appendingPathComponent(".claude/skills"), "code-simplification")
        skill(home.appendingPathComponent(".claude/skills"), "dossier-x", declared: "veille-freelance")
        let pluginDir = home.appendingPathComponent(".claude/plugins/cache/officiel/superpowers/1.0")
        skill(pluginDir.appendingPathComponent("skills"), "brainstorming")
        try? fm.createDirectory(at: home.appendingPathComponent(".claude/plugins"), withIntermediateDirectories: true)
        let registry = ["version": 2, "plugins": ["superpowers@officiel": [["installPath": pluginDir.path]]]] as [String: Any]
        fm.createFile(atPath: home.appendingPathComponent(".claude/plugins/installed_plugins.json").path,
                      contents: try! JSONSerialization.data(withJSONObject: registry))
        skill(home.appendingPathComponent(".codex/skills"), "pdf")
        let claudeSkills = SkillCatalog.claude(home: home)
        func sk(_ said: String, _ list: [SkillEntry]) -> String? {
            SkillCatalog.match(normalize(said).split(separator: " ").map(String.init), in: list)?.entry.text
        }
        check(sk("code simplification", claudeSkills) == "/code-simplification", "skill personnel (tirets dits en mots)")
        check(sk("veille freelance", claudeSkills) == "/veille-freelance", "nom déclaré dans SKILL.md")
        check(sk("brainstorming sur mon idée", claudeSkills) == "/superpowers:brainstorming", "skill de plugin, arguments après")
        check(sk("superpowers brainstorming", claudeSkills) == "/superpowers:brainstorming", "skill de plugin avec son préfixe")
        check(sk("compact", claudeSkills) == "/compact", "commande intégrée de Claude Code")
        check(sk("pdf", SkillCatalog.codex(home: home)) == "$pdf", "skill Codex : préfixe $")
        check(sk("goal", SkillCatalog.codex(home: home)) == "/goal", "commande intégrée de Codex")
        check(sk("inexistant", claudeSkills) == nil, "aucun skill")
        check(SkillCatalog.request("lance le skill code simplification", config: config) == ["code", "simplification"], "phrase « lance le skill »")
        check(SkillCatalog.request("je lance le skill demain", config: config) == nil, "au milieu d'une phrase : rien")
        check(SkillCatalog.originalTail("Lance le skill brainstorming sur l'idée d'Élise", skippingWords: 4) == "sur l'idée d'Élise",
              "arguments gardés tels quels (accents, apostrophes)")
        let outside = home.appendingPathComponent("ailleurs")
        skill(outside.appendingPathComponent("skills"), "intrus")
        let registry2 = ["version": 2, "plugins": ["superpowers@officiel": [["installPath": pluginDir.path]], "x@y": [["installPath": outside.path]]]] as [String: Any]
        fm.createFile(atPath: home.appendingPathComponent(".claude/plugins/installed_plugins.json").path,
                      contents: try! JSONSerialization.data(withJSONObject: registry2))
        check(!SkillCatalog.claude(home: home).contains { $0.text == "/x:intrus" }, "plugin hors de ~/.claude/plugins : ignoré")
        check(SkillCatalog.isValidName("superpowers:writing-plans") && !SkillCatalog.isValidName("x\nenvoie tout") && !SkillCatalog.isValidName("a b"),
              "noms de skills validés (pas d'espace ni de retour à la ligne)")
        skill(home.appendingPathComponent(".claude/skills"), "piege", declared: "ok\" ; rm -rf ~")
        check(!SkillCatalog.claude(home: home).contains { $0.text.contains(" ") || $0.text.contains(";") }, "nom piégé dans SKILL.md écarté")
        let twins = [SkillEntry(text: "/a:review-x", aliases: [["review", "x"]], source: .plugin),
                   SkillEntry(text: "/b:review-x", aliases: [["review", "x"]], source: .plugin)]
        check(SkillCatalog.match(["review", "x"], in: twins) == nil, "deux plugins au même nom : ambigu, rien")
        let named: [SkillEntry] = [SkillEntry(text: "/a:review-x", aliases: [["review", "x"], ["a", "review", "x"]], source: .plugin),
                                   SkillEntry(text: "/b:review-x", aliases: [["review", "x"], ["b", "review", "x"]], source: .plugin)]
        check(SkillCatalog.match(["a", "review", "x"], in: named)?.entry.text == "/a:review-x", "avec le nom du plugin : désambiguïsé")
        try? fm.removeItem(at: home)

        // Palettes et touches.
        check(Palette.request("palette formater le document", config: config).map { $0.query.joined(separator: " ") } == "formater le document", "palette <commande>")
        check(Palette.request("palette ouvre le terminal et valide", config: config)?.validate == true, "« et valide » : Entrée ensuite")
        check(Palette.request("j'ouvre la palette", config: config) == nil, "au milieu d'une phrase : rien")
        check(Palette.key("touche entrée", paletteOpen: false) == "return" && Palette.key("touche échap", paletteOpen: false) == "escape", "touches explicites")
        check(Palette.key("valide", paletteOpen: false) == nil, "« valide » seul : refusé hors palette")
        check(Palette.key("Valide", paletteOpen: true) == "return", "« valide » juste après une palette")
        check(Palette.key("je valide demain", paletteOpen: true) == nil, "touche seulement si dite seule")
        check(SkillCatalog.originalSlice("Palette ouvre l'éditeur, et valide", skippingWords: 1, droppingLastWords: 2) == "ouvre l'éditeur,",
              "commande d'origine sans « et valide »")
        check(Palette.shortcut(for: "dev.zed.Zed", config: config) == "cmd+shift+p", "palette de Zed")
        check(Palette.shortcut(for: "com.anthropic.claudefordesktop", config: config) == "cmd+k", "palette de Claude")

        check(AppCommand.match("quelles commandes", router: router, config: config) == .help, "quelles commandes : aide vocale")

        // Indices de reconnaissance.
        let hints = Coordinator.hints(base: ["salut claude", "Salut Claude"], names: ["VoxTV", "Equality Holding"],
                                      config: config, target: claudeTarget)
        check(hints.first == "salut claude" && !hints.contains("Salut Claude"), "phrases d'activation d'abord, sans doublon")
        check(hints.contains("ouvre VoxTV") && hints.contains("Equality Holding"), "noms de projets et « ouvre <projet> »")
        check(hints.contains("session précédente"), "commandes de navigation")
        let many = Coordinator.hints(base: [], names: (0..<300).map { "Projet \($0)" }, config: config, target: claudeTarget)
        check(many.count <= Coordinator.maxHints, "100 indices au plus")

        // Voix de lecture contre voix de l'utilisateur.
        let pause = config.readPausePhrases ?? []
        let reading = "Tu refais le test « lis à partir de… » puis « arrête la lecture » ?"
        check(VoiceFilter.spokenByReader("tout de suite arrête la lecture", phrases: pause, spokenNow: reading, router: router),
              "commande lue par la voix, mot précédent déformé : attribuée à la voix")
        check(!VoiceFilter.spokenByReader("arrête la lecture", phrases: pause, spokenNow: "Le passage parle d'autre chose.", router: router),
              "commande absente du texte lu : c'est l'utilisateur")
        var insist = Insistence()
        let t0 = Date()
        check(!insist.accept("arrete la lecture", spokenNow: reading, now: t0), "1re fois : ignorée")
        check(insist.accept("arrete la lecture", spokenNow: reading, now: t0.addingTimeInterval(2)), "redite dans les 6 s : acceptée")
        var late = Insistence()
        _ = late.accept("arrete la lecture", spokenNow: reading, now: t0)
        check(!late.accept("arrete la lecture", spokenNow: reading, now: t0.addingTimeInterval(7)), "redite après 6 s : recompte depuis 1")
        let twice = "arrête la lecture, puis arrête la lecture"
        var again = Insistence()
        _ = again.accept("arrete la lecture", spokenNow: twice, now: t0)
        check(!again.accept("arrete la lecture", spokenNow: twice, now: t0.addingTimeInterval(1)), "texte qui la répète : 2e fois encore ignorée")
        check(again.accept("arrete la lecture", spokenNow: twice, now: t0.addingTimeInterval(2)), "3e fois : toujours acceptée")

        // Routines : phrase dite seule, « routine <nom> », validation.
        check(Routines.match("Prépare VoxTV !", config: config)?.name == "voxtv", "routine : phrase dite seule")
        check(Routines.match("routine fin de journée", config: config)?.name == "fin de journée", "routine : « routine <nom> »")
        check(Routines.match("je prépare voxtv demain", config: config) == nil, "routine : phrase au milieu d'un texte ignorée")
        check(Routines.delay(Routine(name: "x", phrases: nil, steps: ["a"], delaySeconds: 60)) == 10, "routine : délai plafonné")
        check(Routines.problems([Routine(name: nil, phrases: [], steps: ["a"], delaySeconds: nil)]).count == 1, "routine sans phrase ni nom refusée")
        check(Routines.problems([Routine(name: "x", phrases: nil, steps: Array(repeating: "a", count: 11), delaySeconds: nil)]).count == 1, "routine trop longue refusée")
        check(Routines.problems(config.routines ?? []).isEmpty, "routines d'exemple valides")

        // « Écris … »
        check(WriteCommand.request("Écris rendez-vous demain", config: config) == 1, "écris : phrase reconnue")
        check(WriteCommand.request("écrit bonjour", config: config) == 1, "écris : variante « écrit »")
        check(WriteCommand.request("tape le texte bonjour", config: config) == 3, "écris : « tape le texte »")
        check(WriteCommand.request("écris", config: config) == nil, "écris : sans texte, rien")
        check(WriteCommand.request("j'écris un mail", config: config) == nil, "écris : au milieu d'une phrase, rien")
        check(WriteCommand.text("Écris : Rendez-vous demain à 10 h, l'équipe.", phraseWords: 1) == "Rendez-vous demain à 10 h, l'équipe.", "écris : texte d'origine conservé")
        check(WriteCommand.text("tape le texte J'arrive", phraseWords: 3) == "J'arrive", "écris : apostrophe conservée")

        // Bilan des commandes ratées (fichier temporaire).
        Bilan.path = NSTemporaryDirectory() + "voicewake-bilan-\(getpid()).json"
        Bilan.enabled = true
        let b0 = Date(timeIntervalSince1970: 1_000_000)
        Bilan.record(.universal, "Menu Afficher", now: b0)
        Bilan.record(.universal, "menu afficher", now: b0.addingTimeInterval(1))
        Bilan.record(.skill, "un deux trois quatre cinq six sept huit neuf dix", now: b0.addingTimeInterval(2))
        let bl = Bilan.load()
        check(bl.count == 2 && Bilan.top(bl).first?.count == 2, "bilan : même phrase comptée deux fois")
        check(bl.contains { $0.phrase.split(separator: " ").count == Bilan.maxWords }, "bilan : 8 mots au plus")
        let perms = (try? FileManager.default.attributesOfItem(atPath: Bilan.path)[.posixPermissions] as? Int) ?? nil
        check(perms == 0o600, "bilan : fichier lisible par toi seul")
        for i in 0..<(Bilan.maxEntries + 5) { Bilan.record(.nav, "projet \(i)", now: b0.addingTimeInterval(Double(10 + i))) }
        let capped = Bilan.load()
        check(capped.count == Bilan.maxEntries && !capped.contains { $0.phrase == "projet 0" }, "bilan : 100 entrées au plus, les plus anciennes partent")
        Bilan.enabled = false
        Bilan.record(.nav, "désactivé")
        check(!Bilan.load().contains { $0.phrase == "desactive" }, "bilan désactivé : rien n'est écrit")
        Bilan.clear()
        check(Bilan.load().isEmpty, "bilan effacé")

        // Commandes du Mac (apps fictives).
        let notes = InstalledApp(name: "Notes", path: "/A/Notes.app", bundleID: "com.apple.Notes")
        let vsc = InstalledApp(name: "Visual Studio Code", path: "/A/VSC.app", bundleID: "com.microsoft.VSCode")
        let sysSettings = InstalledApp(name: "System Settings", path: "/A/SS.app", bundleID: "com.apple.systempreferences")
        let claudeApp = InstalledApp(name: "Claude", path: "/A/Claude.app", bundleID: "com.anthropic.claudefordesktop")
        let installed = [notes, vsc, sysSettings, claudeApp]
        func sys(_ t: String) -> SystemCommand? { SystemCommands.match(t, apps: installed, running: [claudeApp], front: "com.microsoft.VSCode") }
        check(sys("Lance Notes") == .launch("/A/Notes.app"), "mac : lance une app")
        check(sys("ouvre notes") == .launch("/A/Notes.app"), "mac : « ouvre <app> » exact")
        check(sys("ouvre visual") == nil, "mac : « ouvre » + nom partiel laissé aux projets")
        check(sys("lance visual") == .launch("/A/VSC.app"), "mac : « lance » + début de nom unique")
        check(sys("ouvre les paramètres système") == .launch("/A/SS.app"), "mac : paramètres système (nom anglais)")
        check(sys("ouvre les paramètres") == nil, "mac : « paramètres » seul laissé à l'app")
        check(sys("ferme Claude") == .quit("com.anthropic.claudefordesktop") && sys("ferme Claude")!.dangerous, "mac : quitter demande confirmation")
        check(sys("ferme notes") == nil, "mac : quitter une app fermée : rien")
        check(sys("ferme la palette") == nil, "mac : « ferme la palette » laissé aux touches")
        check(sys("cache cette app") == .hide("com.microsoft.VSCode"), "mac : cacher l'app au premier plan")
        check(sys("bascule sur claude") == .activate("/A/Claude.app"), "mac : basculer sur une app ouverte")
        check(sys("musique suivante") == .nextTrack && sys("monte le son") == .volumeUp, "mac : musique et son")
        check(sys("volume 40") == .volume(40) && sys("volume 400") == nil, "mac : volume à un niveau")
        check(sys("je monte le son demain") == nil, "mac : phrase au milieu d'un texte ignorée")
        check(WakeName.command(after: "Jarvis, ferme Claude", names: ["jarvis"]) == "ferme claude", "nom d'appel retiré")
        check(WakeName.command(after: "bon alors jarvis monte le son", names: ["jarvis"]) == "monte le son", "nom d'appel en pleine dictée")
        check(WakeName.command(after: "ferme claude", names: ["jarvis"]) == nil, "sans nom d'appel : nil")

        // Finder et Réglages Système.
        check(FinderCommands.match("Copie le fichier et envoie-le dans Téléchargements") == .copy(to: "telechargements"), "finder : copie dans un dossier")
        check(FinderCommands.match("déplace-le dans le dossier voxtv") == .move(to: "voxtv"), "finder : déplace")
        check(FinderCommands.match("mets-le à la corbeille") == .trash && FinderCommand.trash.dangerous, "finder : corbeille avec confirmation")
        check(FinderCommands.match("supprime le fichier") == .trash, "finder : supprime")
        check(FinderCommands.match("efface le brouillon") == nil, "finder : « efface le brouillon » laissé à l'assistant")
        check(FinderCommands.match("vide la corbeille") == .emptyTrash && !FinderCommand.emptyTrash.needsFinderFront, "finder : vider la corbeille")
        check(FinderCommands.match("renomme le fichier en Facture Été 2026") == .rename("Facture Été 2026"), "finder : renommer (accents gardés)")
        check(FinderCommands.match("nouveau dossier nommé Clients") == .newFolder("Clients"), "finder : nouveau dossier nommé")
        check(FinderCommands.match("va dans mes documents") == .goTo("documents"), "finder : aller dans un dossier")
        check(FinderCommands.match("affiche en colonnes") == .view("column"), "finder : présentation")
        check(FinderCommands.match("je copie le code dans le chat") == nil, "finder : phrase ordinaire ignorée")
        var fcfg = config
        fcfg.folders = ["Clients VIP": "/tmp"]
        check(FinderCommands.resolve("clients vip", config: fcfg, current: nil) == "/tmp", "finder : dossier nommé dans la config")
        check(FinderCommands.resolve("téléchargements", config: fcfg, current: nil) == NSHomeDirectory() + "/Downloads", "finder : dossier connu")
        check(SettingsCommands.match("ouvre les réglages du son") == .pane("com.apple.Sound-Settings.extension"), "réglages : volet du son")
        check(SettingsCommands.match("paramètres bluetooth") == .pane("com.apple.BluetoothSettings"), "réglages : volet bluetooth")
        check(SettingsCommands.match("coupe le wifi") == .wifi(false) && SettingsCommand.wifi(false).dangerous, "réglages : couper le wifi demande confirmation")
        check(SettingsCommands.match("mode sombre") == .darkMode(true), "réglages : mode sombre")
        check(SettingsCommands.match("ouvre les paramètres") == nil, "réglages : « paramètres » seul laissé à l'app")

        check(FinderCommands.script("return 1", ["-e"]).ok == false, "osascript : argument en « - » refusé")
        check(FinderCommands.perform(.rename("-x"), config: config).ok == false, "renommer : nom en « - » refusé")

        // Musique.
        check(MediaCommands.match("Cherche Aya Nakamura sur Spotify", front: nil) == .spotifySearch("aya nakamura"), "musique : recherche Spotify")
        check(MediaCommands.match("mets du jazz sur YouTube", front: nil) == .youtubeSearch("jazz"), "musique : recherche YouTube (article retiré)")
        check(MediaCommands.match("joue Thriller dans Musique", front: nil) == .musicPlay("thriller"), "musique : lecture dans Musique")
        check(MediaCommands.match("cherche Daft Punk", front: MediaCommands.spotify) == .spotifySearch("daft punk"), "musique : « cherche … » avec Spotify devant")
        check(MediaCommands.match("cherche Daft Punk", front: "com.microsoft.VSCode") == nil, "musique : « cherche … » ailleurs : rien")
        check(MediaCommands.match("c'est quoi cette chanson", front: nil) == .nowPlaying, "musique : titre en cours")
        check(MediaCommands.match("lecture aléatoire", front: nil) == .shuffle(true), "musique : aléatoire")

        // Navigateurs.
        let safari = "com.apple.Safari"
        check(BrowserCommands.match("va sur github point com", front: nil) == .open(URL(string: "https://github.com")!), "navigateur : « va sur github point com »")
        check(BrowserCommands.match("va sur YouTube", front: nil) == .open(URL(string: "https://youtube.com")!), "navigateur : site connu")
        check(BrowserCommands.match("va sur le bureau", front: nil) == nil, "navigateur : « va sur le bureau » laissé au Finder")
        check(BrowserCommands.match("cherche météo Paris sur Google", front: nil) == .open(URL(string: "https://www.google.com/search?q=m%C3%A9t%C3%A9o%20Paris")!), "navigateur : recherche Google (accents gardés)")
        check(BrowserCommands.match("nouvel onglet", front: safari) == .keys("cmd+t", "nouvel onglet"), "navigateur : nouvel onglet")
        check(BrowserCommands.match("nouvel onglet", front: "com.microsoft.VSCode") == nil, "navigateur : raccourcis seulement navigateur devant")
        check(BrowserCommands.match("onglet trois", front: safari) == .keys("cmd+3", "onglet 3"), "navigateur : onglet par numéro")
        check(BrowserCommands.match("cherche dans la page Facture", front: safari) == .findInPage("Facture"), "navigateur : recherche dans la page")
        check(BrowserCommands.url(fromSpoken: "rm -rf") == nil, "navigateur : adresse invalide refusée")

        // Rotation du journal (sortie standard redirigée vers un fichier temporaire).
        let tmp = NSTemporaryDirectory() + "voicewake-test-\(getpid()).log"
        FileManager.default.createFile(atPath: tmp, contents: Data(repeating: 65, count: 200))
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        freopen(tmp, "a", stdout)
        rotateLogIfNeeded(path: tmp, maxBytes: 100)
        fflush(stdout)
        dup2(saved, STDOUT_FILENO); close(saved)
        let archived = (try? FileManager.default.attributesOfItem(atPath: tmp + ".1")[.size] as? Int) ?? nil
        let fresh = (try? String(contentsOfFile: tmp, encoding: .utf8)) ?? ""
        check(archived == 200, "journal trop gros archivé en .1")
        check(fresh.contains("Journal précédent archivé"), "journal neuf ouvert")
        try? FileManager.default.removeItem(atPath: tmp); try? FileManager.default.removeItem(atPath: tmp + ".1")

        print("Tous les tests passent.")
    }
}
