@main
struct SilenceTests {
    static func main() {
        func sends(_ content: DictatedContent, now: Double = 15, started: Double = 9,
                   buffer: Double = 15, speech: Double = 10, delay: Double = 5) -> Bool {
            content.shouldSend(now: now, startedAt: started, lastBuffer: buffer, lastSpeech: speech, delay: delay)
        }

        assert(!sends(.empty), "Aucun texte reconnu")
        assert(!sends(.ready, now: 14.9, buffer: 14.9), "Silence de moins de cinq secondes")
        assert(sends(.ready), "Cinq secondes de silence après la dernière parole")
        assert(!sends(.ready, speech: 14), "Reprise de la parole avant la fin du décompte")
        assert(!sends(.ready, buffer: 10), "Flux audio interrompu")
        assert(!sends(.ready, speech: 0), "Aucune parole depuis l'ouverture du micro")
        assert(!sends(.ready, delay: 0), "Envoi automatique désactivé")

        var content = DictatedContent.paused
        assert(!sends(content), "Envoi suspendu pendant la réflexion")
        content.heardContent()
        assert(!sends(content, started: 11), "Une transcription de la parole avant la pause ne relance pas le décompte")
        assert(sends(content, now: 17, started: 11, buffer: 17, speech: 12), "Reprise de la dictée après la pause")

        content = .held
        content.heardContent()
        assert(!sends(content), "Le brouillon reste en attente même si une transcription arrive après l'arrêt")
        print("11 scénarios d'envoi après silence réussis.")
    }
}
