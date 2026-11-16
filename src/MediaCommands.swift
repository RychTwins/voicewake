import AppKit

/// Musique à la voix : recherche Spotify et YouTube, lecture dans Musique, titre en cours, lecture aléatoire.
/// (Suivant, précédent, pause : touches multimédia, voir `SystemCommands`.)
enum MediaCommand: Equatable {
    case spotifySearch(String)
    case youtubeSearch(String)
    case musicPlay(String)       // Musique (Apple) : joue le premier morceau de la bibliothèque qui correspond
    case nowPlaying
    case shuffle(Bool)

    var title: String {
        switch self {
        case .spotifySearch: return "recherche Spotify"
        case .youtubeSearch: return "recherche YouTube"
        case .musicPlay: return "lecture dans Musique"
        case .nowPlaying: return "titre en cours"
        case let .shuffle(on): return on ? "lecture aléatoire" : "lecture dans l'ordre"
        }
    }
}

enum MediaCommands {
    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"

    private static func capture(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    /// « du jazz » → « jazz » (la recherche n'a pas besoin de l'article).
    static func query(_ q: String) -> String {
        for a in ["de la ", "de l ", "du ", "des ", "un peu de ", "de "] where q.hasPrefix(a) && q.count > a.count { return String(q.dropFirst(a.count)) }
        return q
    }

    /// `front` : identifiant de l'app au premier plan (« cherche … » seul vise Spotify ou Musique devant).
    static func match(_ text: String, front: String?) -> MediaCommand? {
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        if ["quelle est cette chanson", "c est quoi cette chanson", "c est quoi ce morceau", "qu est ce qui passe",
            "quel est ce morceau", "c est quoi cette musique", "quelle chanson passe", "quel est le titre"].contains(s) { return .nowPlaying }
        if ["lecture aleatoire", "active la lecture aleatoire", "active l aleatoire", "mode aleatoire", "melange"].contains(s) { return .shuffle(true) }
        if ["desactive la lecture aleatoire", "desactive l aleatoire", "lecture dans l ordre"].contains(s) { return .shuffle(false) }
        if let m = capture("(?:cherche|recherche|trouve|mets|joue|lance)(?: moi)? (.+) (?:sur|dans) (spotify|youtube|you tube|musique|apple music)", s),
           m.count == 2, !m[0].isEmpty {
            switch m[1] {
            case "spotify": return .spotifySearch(query(m[0]))
            case "musique", "apple music": return .musicPlay(query(m[0]))
            default: return .youtubeSearch(query(m[0]))
            }
        }
        if front == spotify, let m = capture("(?:cherche|recherche|trouve|joue|mets)(?: moi)? (.+)", s), let q = m.first, !q.isEmpty {
            return .spotifySearch(query(q))
        }
        if front == music, let m = capture("(?:joue|mets|cherche)(?: moi)? (.+)", s), let q = m.first, !q.isEmpty {
            return .musicPlay(query(q))
        }
        return nil
    }

    private static func isRunning(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    /// (fait, texte à dire) — hors fil principal.
    static func perform(_ c: MediaCommand) -> (ok: Bool, say: String?) {
        switch c {
        case let .spotifySearch(q):
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: ":/?#&")
            guard let enc = q.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "spotify:search:\(enc)") else { return (false, nil) }
            return (NSWorkspace.shared.open(url), nil)
        case let .youtubeSearch(q):
            var comps = URLComponents(string: "https://www.youtube.com/results")!
            comps.queryItems = [URLQueryItem(name: "search_query", value: q)]
            guard let url = comps.url else { return (false, nil) }
            return (NSWorkspace.shared.open(url), nil)
        case let .musicPlay(q):
            let r = FinderCommands.script("""
            on run argv
              tell application "Music"
                set found to (every track of library playlist 1 whose name contains (item 1 of argv) or artist contains (item 1 of argv))
                if (count of found) is 0 then error "rien"
                play item 1 of found
              end tell
            end run
            """, [q])
            return (r.ok, r.ok ? nil : "Rien trouvé dans ta bibliothèque Musique.")
        case .nowPlaying:
            for (id, app) in [(spotify, "Spotify"), (music, "Music")] where isRunning(id) {
                let r = FinderCommands.script("""
                tell application "\(app)"
                  if player state is playing then return (name of current track) & " — " & (artist of current track)
                end tell
                """)
                if r.ok, !r.output.isEmpty { return (true, r.output.replacingOccurrences(of: " — ", with: ", de ")) }
            }
            return (false, "Aucune musique en cours.")
        case let .shuffle(on):
            for (id, app, prop) in [(spotify, "Spotify", "shuffling"), (music, "Music", "shuffle enabled")] where isRunning(id) {
                return (FinderCommands.script("tell application \"\(app)\" to set \(prop) to \(on)").ok, nil)
            }
            return (false, nil)
        }
    }
}
