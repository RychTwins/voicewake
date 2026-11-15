import Foundation

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
        print("Tous les tests passent.")
    }
}
