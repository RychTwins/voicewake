import Foundation

/// Une perte d'identité invalide le tour, même si l'utilisateur revient ensuite.
final class ConversationGuard<Identity: Equatable> {
    private let original: Identity
    private let lock = NSLock()
    private var cancelled = false

    init(_ original: Identity) { self.original = original }

    func check(_ current: Identity?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if current != original { cancelled = true }
        return !cancelled
    }
}
