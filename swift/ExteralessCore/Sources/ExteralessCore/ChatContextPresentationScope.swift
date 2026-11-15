import Foundation

/// Queue-confined presentation lifetime. The native integration owns this on MainActor;
/// tests inject lightweight screens and factories without constructing any Account or UI.
public final class ChatContextPresentationScope<Identity: Equatable, Screen: AnyObject> {
    public struct Lease {
        fileprivate let identity: Identity
        fileprivate let epoch: UUID
    }
    private final class Reference {
        weak var screen: Screen?
        init(_ screen: Screen) { self.screen = screen }
    }
    private var epoch = UUID()
    private var screens: [Reference] = []
    private let invalidate: (Screen) -> Void
    public private(set) var currentIdentity: Identity?

    public init(invalidate: @escaping (Screen) -> Void) { self.invalidate = invalidate }

    /// Only the integration's explicit account update is allowed to call activate.
    public func activate(_ identity: Identity) -> Lease {
        if currentIdentity != identity {
            clear()
            currentIdentity = identity
        }
        return Lease(identity: identity, epoch: epoch)
    }

    public func clear() {
        currentIdentity = nil
        epoch = UUID()
        let previous = screens
        screens.removeAll()
        for reference in previous {
            if let screen = reference.screen { invalidate(screen) }
        }
    }

    private func accepts(_ lease: Lease, identity: Identity) -> Bool {
        currentIdentity == identity && lease.identity == identity && lease.epoch == epoch
    }

    /// No creation, registration, presentation or invalidation on a stale callback.
    /// Recheck after creation too: a factory can synchronously trigger an account change.
    @discardableResult
    public func open(identity: Identity, lease: Lease, factory: () -> Screen, present: (Screen) -> Void) -> Bool {
        guard accepts(lease, identity: identity) else { return false }
        let screen = factory()
        guard accepts(lease, identity: identity) else { invalidate(screen); return false }
        screens.removeAll { $0.screen == nil }
        screens.append(Reference(screen))
        present(screen)
        return true
    }
}
