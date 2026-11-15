import Foundation

/// Serializes the native private state and coalesces presentation invalidations.
/// Notifications drain only after the OUTERMOST recursive state lock is released.
/// The separate drain lock is never held while invoking a public observer.
public final class HiddenAccountPresentationLock: @unchecked Sendable {
    private let stateLock = NSRecursiveLock()
    private var depth = 0
    private var revision: UInt64 = 0
    private var dirty = false
    private let publicationLock = NSLock()
    private var queuedRevision: UInt64?
    private var isPublishing = false
    private let publish: @Sendable (UInt64) -> Void

    public init(publish: @escaping @Sendable (UInt64) -> Void) {
        self.publish = publish
    }

    public func lock() {
        stateLock.lock()
        depth += 1
    }

    public func unlock() {
        precondition(depth > 0)
        depth -= 1
        let outermost = depth == 0
        if outermost && dirty {
            // Queue under the state lock, so concurrent writers cannot publish an
            // older revision after a newer one. Reentrant observers are coalesced.
            publicationLock.lock()
            queuedRevision = revision
            publicationLock.unlock()
            dirty = false
        }
        stateLock.unlock()
        if outermost { drain() }
    }

    public func invalidatePresentations() {
        lock()
        revision &+= 1
        dirty = true
        unlock()
    }

    public var presentationRevision: UInt64 {
        lock(); defer { unlock() }
        return revision
    }

    private func drain() {
        publicationLock.lock()
        guard !isPublishing else { publicationLock.unlock(); return }
        isPublishing = true
        while let value = queuedRevision {
            queuedRevision = nil
            publicationLock.unlock()
            publish(value)
            publicationLock.lock()
        }
        isPublishing = false
        publicationLock.unlock()
    }
}

/// The state used by the native helper before/after the first account emission.
/// Process object tokens are NOT persisted identities or credential authority.
public struct HiddenAccountSnapshot: Sendable {
    public struct Entry: Sendable {
        public let identity: PrivacyExtrasAccountIdentity
        public let object: ObjectIdentifier
        public init(identity: PrivacyExtrasAccountIdentity, object: ObjectIdentifier) {
            self.identity = identity
            self.object = object
        }
    }

    public private(set) var hasAccountSnapshot = false
    public private(set) var identities: [PrivacyExtrasAccountIdentity] = []
    private var objects: [PrivacyExtrasAccountIdentity: ObjectIdentifier] = [:]

    public init() {}

    /// True only when an existing full identity now names a different Account
    /// object. Selecting another existing account is not an object replacement.
    @discardableResult
    public mutating func update(_ accounts: [Entry]) -> Bool {
        var newObjects: [PrivacyExtrasAccountIdentity: ObjectIdentifier] = [:]
        var ordered: [PrivacyExtrasAccountIdentity] = []
        var replaced = false
        for account in accounts.prefix(HiddenAccountPolicy.maximumAccounts) {
            guard newObjects[account.identity] == nil else { continue }
            if let previous = objects[account.identity], previous != account.object { replaced = true }
            newObjects[account.identity] = account.object
            ordered.append(account.identity)
        }
        hasAccountSnapshot = true
        objects = newObjects
        identities = ordered
        return replaced
    }

    /// Called only by confirmed native teardown/empty-account composition.
    public mutating func confirmEmpty() {
        hasAccountSnapshot = true
        identities = []
        objects = [:]
    }

    public func requiresUnlockRouting(available: Bool, panicConfigured: Bool, accountCodeKeys: Set<String>) -> Bool {
        guard available else { return true }
        if hasAccountSnapshot && identities.isEmpty { return false }
        if panicConfigured { return true }
        if !hasAccountSnapshot { return !accountCodeKeys.isEmpty }
        return identities.contains { accountCodeKeys.contains($0.storageKey) }
    }
}
