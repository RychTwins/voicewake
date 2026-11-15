import Foundation

enum DictatedContent {
    case empty, ready, paused, held

    mutating func heardContent() {
        if self != .held { self = .ready }
    }

    func shouldSend(
        now: TimeInterval, startedAt: TimeInterval, lastBuffer: TimeInterval,
        lastSpeech: TimeInterval, delay: TimeInterval
    ) -> Bool {
        self == .ready && delay > 0 && lastSpeech >= startedAt &&
            now - lastBuffer < 0.5 && now - lastSpeech >= delay
    }
}
