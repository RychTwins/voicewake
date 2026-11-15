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
        check(Universal.allowedApps(config).contains("dev.zed.Zed") && !Universal.allowedApps(config).contains("com.apple.finder"),
              "liste blanche : éditeurs oui, app quelconque non")

        // Confirmation vocale.
        check(Universal.answer("Je confirme", config: config) == .confirm, "je confirme : confirme")
        check(Universal.answer("oui", config: config) == nil, "un simple oui ne confirme jamais")
        check(Universal.answer("non", config: config) == .cancel, "non : annule")
        check(Universal.answer("oui mais non", config: config) == nil, "énoncé plus long : ni oui ni non")
        check(Universal.confirmationPrompt("Supprimer la conversation", config: config) == "Confirmer « Supprimer la conversation » ?", "question avec le libellé")
        check(Universal.confirmationPrompt("Non lu", config: config) == "Confirmer cette action ?", "libellé contenant « non » : jamais répété")
        check(Universal.answer(Universal.confirmationPrompt("Supprimer", config: config), config: config) == nil, "la question n'est jamais une réponse")

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
