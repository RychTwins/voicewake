import Foundation

extension Lang {
    /// Tout ce que la langue source (français) demande à un pack, relevé en consultant chaque liste.
    static func inventory(config: Config) -> Inventory {
        recording = Inventory()
        defer { recording = nil }
        _ = NavCommands.defaultOpenPhrases
        _ = NavCommands.defaultNewSessionInPhrases
        _ = NavCommands.builtIn
        _ = NavCommands.fillers
        _ = Universal.defaultMenuPhrases
        _ = Universal.defaultClickPhrases
        _ = Universal.defaultConfirmPhrases
        _ = Universal.defaultCancelPhrases
        _ = Palette.defaultPhrases
        _ = Palette.keys
        _ = Palette.validateWords
        _ = SkillCatalog.defaultPhrases
        _ = WriteCommand.defaultPhrases
        for c in AppCommand.allCases { _ = t(AppCommand.defaultPhrases[c] ?? []) }
        for n in ReaderNav.allCases { _ = t(ReaderNav.defaultPhrases[n] ?? []) }
        _ = QuestionAnswer.ordinals
        _ = QuestionAnswer.freePrefixes
        _ = TurnEnd.continuation
        _ = TurnEnd.questionStarts
        _ = Router.bareNames
        let router = Router(config: config)
        _ = router.thoughtPausePhrases
        _ = router.isSendCommand("")
        // Listes consultées au fil des phrases, sans propriété à elles.
        for name in ["universal.fillers", "palette.validate", "and", "andThen", "skill.send", "question.skip",
                     "question.fillers", "question.aloneOrdinals", "router.strongInterrupts", "routine.call"] {
            _ = list(name, [])
        }
        var inv = recording ?? Inventory()
        var seen = Set<String>()
        inv.phrases = inv.phrases.filter { seen.insert($0).inserted }
        seen = []
        inv.lists = inv.lists.filter { seen.insert($0).inserted }
        seen = []
        inv.maps = inv.maps.filter { seen.insert($0).inserted }
        inv.speech = Spoken.all
        return inv
    }
}
