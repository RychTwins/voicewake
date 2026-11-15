@main
struct ConversationTests {
    static func main() {
        for target in ["claude", "codex", "gemini"] {
            let a = "\(target)-chat-A"
            let b = "\(target)-chat-B"

            let unchanged = ConversationGuard(a)
            assert(unchanged.check(a))
            assert(unchanged.check(a), "Autorise l'envoi après cinq secondes dans le chat d'origine")
            assert(unchanged.check(a), "Autorise la reprise du micro dans le chat d'origine")

            let changed = ConversationGuard(a)
            assert(changed.check(a))
            assert(!changed.check(b), "Annule le décompte en changeant de chat dans la même fenêtre")
            assert(!changed.check(a), "Revenir dans le chat ne réarme pas l'envoi")

            let changedDuringSubmit = ConversationGuard(a)
            assert(changedDuringSubmit.check(a), "Le chat correspond avant l'arrêt du micro")
            assert(!changedDuringSubmit.check(b), "Un changement pendant l'arrêt interdit le clic Envoyer")

            let changedDuringPlayback = ConversationGuard(a)
            assert(changedDuringPlayback.check(a))
            assert(!changedDuringPlayback.check(b))
            assert(!changedDuringPlayback.check(a), "Revenir au chat avant la fin ne rouvre pas le micro")

            let unidentified = ConversationGuard(a)
            assert(!unidentified.check(nil), "Un chat non identifié invalide l'envoi")
            assert(!unidentified.check(a))
            print("\(target) : garde de conversation validée")
        }
    }
}
