import Foundation

/// Langue des commandes vocales. Le français est la langue source : ses phrases sont écrites dans le code et ne
/// passent par aucune table (comportement strictement inchangé). Les autres langues sont des « packs » : une
/// table qui donne, pour chaque phrase française, ses équivalents.
///
/// La langue suit `locale` (« en-US » → pack « en »). Le moteur vocal n'écoute qu'une langue à la fois : les
/// commandes se disent donc dans la langue de `locale`, jamais dans deux langues en même temps.
///
/// Ajouter une langue : un fichier `src/Lang+xx.swift` sur le modèle de `Lang+en.swift`, ou, sans recompiler,
/// `~/.config/voicewake/lang/xx.json` (mêmes clés). `voicewake langue xx` liste ce qui reste à traduire.
struct LanguagePack: Codable {
    /// Phrase française (telle qu'écrite dans le code) → équivalents. Une phrase absente n'existe pas dans cette langue.
    var phrases: [String: [String]] = [:]
    /// Listes entières remplacées (mots vides, mots de fin de phrase, débuts de question…), par nom.
    var lists: [String: [String]] = [:]
    /// Tables nom → valeur remplacées (rangs « first » → 0, noms d'assistants dits seuls « claude » → « claude »).
    var maps: [String: [String: String]] = [:]
    /// Phrases dites à voix haute par VoiceWake : texte français (avec ses %@) → traduction.
    var speech: [String: String] = [:]
    /// Corrections d'erreurs de reconnaissance propres à la langue : [motif, remplacement].
    var fixes: [[String]] = []

    mutating func merge(_ other: LanguagePack) {
        phrases.merge(other.phrases) { _, new in new }
        lists.merge(other.lists) { _, new in new }
        maps.merge(other.maps) { _, new in new }
        speech.merge(other.speech) { _, new in new }
        fixes += other.fixes
    }
}

enum Lang {
    /// Code de la langue active (« fr », « en »…).
    private(set) static var code = "fr"
    private static var pack = LanguagePack()
    static var isSource: Bool { code == "fr" }

    /// Packs fournis avec VoiceWake.
    static let builtIn: [String: LanguagePack] = ["en": .english]

    static func externalPath(_ code: String) -> String {
        ("~/.config/voicewake/lang/\(code).json" as NSString).expandingTildeInPath
    }

    static func load(_ code: String) -> LanguagePack? {
        var pack = builtIn[code]
        if let data = FileManager.default.contents(atPath: externalPath(code)),
           let extra = try? JSONDecoder().decode(LanguagePack.self, from: data) {
            if pack == nil { pack = extra } else { pack?.merge(extra) }
        }
        return pack
    }

    /// À appeler dès que la configuration est lue. Renvoie faux si la langue n'a pas de pack : les commandes
    /// intégrées restent alors en français (les phrases de la configuration, elles, sont toujours respectées).
    @discardableResult
    static func configure(locale: String) -> Bool {
        let wanted = String(locale.prefix(2)).lowercased()
        guard wanted != "fr" else { code = "fr"; pack = LanguagePack(); return true }
        guard let found = load(wanted) else { code = "fr"; pack = LanguagePack(); return false }
        code = wanted
        pack = found
        return true
    }

    /// Phrases de commande : chaque phrase française est remplacée par ses équivalents.
    static func t(_ french: [String]) -> [String] {
        if recording != nil { recording?.phrases += french; return french }
        guard !isSource else { return french }
        var seen = Set<String>(), out: [String] = []
        for f in french { for p in pack.phrases[f] ?? [] where seen.insert(p).inserted { out.append(p) } }
        return out
    }

    /// Liste entière propre à la langue (mots vides, mots de liaison…).
    static func list(_ name: String, _ french: [String]) -> [String] {
        if recording != nil { recording?.lists.append(name); return french }
        return isSource ? french : pack.lists[name] ?? []
    }

    static func map(_ name: String, _ french: [String: String]) -> [String: String] {
        if recording != nil { recording?.maps.append(name); return french }
        return isSource ? french : pack.maps[name] ?? [:]
    }

    /// Phrase dite à voix haute, avec ses valeurs (%@).
    static func say(_ french: String, _ args: CVarArg...) -> String {
        String(format: isSource ? french : pack.speech[french] ?? french, arguments: args)
    }

    static var fixes: [(pattern: String, replacement: String)]? {
        isSource ? nil : pack.fixes.filter { $0.count == 2 }.map { ($0[0], $0[1]) }
    }

    // MARK: Inventaire (voicewake langue)

    /// Ce qu'un pack doit couvrir : phrases, listes, tables et annonces de la langue source.
    struct Inventory {
        var phrases: [String] = []
        var lists: [String] = []
        var maps: [String] = []
        var speech: [String] = []
    }

    /// Non nil pendant l'inventaire : chaque liste consultée y note ce qu'elle demande.
    static var recording: Inventory?

    /// Ce qui manque au pack `code` par rapport à l'inventaire.
    static func missing(in code: String, inventory: Inventory) -> Inventory? {
        guard let p = load(code) else { return nil }
        return Inventory(phrases: inventory.phrases.filter { p.phrases[$0] == nil },
                         lists: inventory.lists.filter { p.lists[$0] == nil },
                         maps: inventory.maps.filter { p.maps[$0] == nil },
                         speech: inventory.speech.filter { p.speech[$0] == nil })
    }
}

/// Tout ce que VoiceWake dit à voix haute, en français (langue source). Les %@ sont remplacés dans l'ordre.
enum Spoken {
    static let thisAction = "cette action"
    static let confirm = "Confirmer %@ ?"
    static let thisApp = "cette application"
    static let helpApp = "Dans %@, on peut choisir l'une des %@ options de menu en disant le mot menu puis son nom, ou l'un des %@ boutons visibles avec clique sur."
    static let helpPalette = "La palette de commandes s'utilise en disant palette puis la commande."
    static let helpNotDriven = "%@ n'est pas une application pilotée."
    static let helpSkills = "%@ skills et commandes slash se lancent avec lance le skill puis leur nom."
    static let helpSidebar = "Un projet de la barre latérale s'ouvre avec ouvre puis son nom."
    static let helpReadme = "La liste complète est dans le fichier lisez-moi."
    static let statusDraft = "Brouillon gardé pour %@, en attente d'envoi encore %@ secondes."
    static let statusDictating = "Dictée en cours vers %@."
    static let statusReaderPaused = "Lecteur intégré en pause."
    static let statusReaderOn = "Lecteur intégré en cours."
    static let statusReading = "Lecture à voix haute de %@ en cours."
    static let statusReadingPaused = "Lecture de %@ en pause."
    static let statusIdleFront = "En veille, prêt. %@ est au premier plan."
    static let statusIdle = "En veille, prêt."

    static let all = [thisAction, confirm, thisApp, helpApp, helpPalette, helpNotDriven, helpSkills, helpSidebar, helpReadme,
                      statusDraft, statusDictating, statusReaderPaused, statusReaderOn, statusReading, statusReadingPaused,
                      statusIdleFront, statusIdle]
}
