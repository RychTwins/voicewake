import Foundation

/// Une perte d'identité invalide le tour, même si l'utilisateur revient ensuite.
final class ConversationGuard<Identity: Equatable> {
    private var original: Identity
    /// Vrai si `new` est la suite légitime de `old` (chat neuf qui reçoit son identifiant après le premier
    /// envoi) : il devient alors le repère au lieu d'invalider le tour.
    var succeeds: ((_ old: Identity, _ new: Identity) -> Bool)?
    private let lock = NSLock()
    private var cancelled = false

    init(_ original: Identity) { self.original = original }

    /// Vrai pour un repère « inconnu » (fenêtre trop grande pour être parcourue en entier) : il ne prouve ni que
    /// le chat est le même ni qu'il a changé, donc il n'invalide rien et ne sert jamais de référence.
    var isUnknown: ((Identity) -> Bool)?

    /// Durée pendant laquelle un écart doit persister avant d'invalider le tour. Une app qui passe au premier plan
    /// ou une page qui se recharge donne un repère faux pendant un instant : ce n'est pas un changement de chat.
    var grace: TimeInterval = 0
    private var mismatchSince: TimeInterval?
    private(set) var lastMismatch = ""

    /// Vrai une fois le tour invalidé pour de bon (écart resté plus longtemps que `grace`).
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Vrai si l'action est permise maintenant. Un écart, même bref, renvoie faux (on n'agit jamais dans le doute).
    func check(_ current: Identity?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        if let current {
            if isUnknown?(current) == true { mismatchSince = nil; return true }
            if isUnknown?(original) == true { original = current; mismatchSince = nil; return true }
            if current != original, succeeds?(original, current) == true { original = current }
            if current == original { mismatchSince = nil; return true }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let since = mismatchSince ?? now
        mismatchSince = since
        lastMismatch = "\(original) → \(current.map { "\($0)" } ?? "aucun")"
        if now - since >= grace { cancelled = true }
        return false
    }
}
