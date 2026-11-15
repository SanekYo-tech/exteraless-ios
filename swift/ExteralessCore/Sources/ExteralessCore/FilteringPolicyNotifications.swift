import Foundation

public enum FilteringNotificationDisposition: Equatable, Sendable {
    case allow, suppress, awaitMessage
}

public extension FilteringDecision {
    /// Presentation may retain an undecided history row, but an incomplete regex
    /// is never permission to deliver its text, sound, attachments or sender intent.
    var notificationDisposition: FilteringNotificationDisposition {
        if isHidden { return .suppress }
        return incomplete ? .awaitMessage : .allow
    }
}

public struct FilteringNotificationRevision: Equatable, Sendable {
    public let filtering: UInt64
    public let hidden: UInt64
    public init(filtering: UInt64, hidden: UInt64) {
        self.filtering = filtering
        self.hidden = hidden
    }
}

public enum FilteringNotificationEffect: Hashable, Sendable {
    case sound, vibration, enqueue
}

/// Admission is captured with the evaluated batch, never refreshed by a later UI
/// callback. The provider is consulted outside this mutex, as are all effects.
public final class FilteringNotificationAdmission: @unchecked Sendable {
    public let batchId: UUID
    public let accountIdentity: PrivacyExtrasAccountIdentity
    public let revision: FilteringNotificationRevision
    private let accountObject: ObjectIdentifier
    private let currentRevision: @Sendable () -> FilteringNotificationRevision?
    private let lock = NSLock()
    private var revoked = false
    private var performed: Set<FilteringNotificationEffect> = []

    public init(batchId: UUID, accountIdentity: PrivacyExtrasAccountIdentity, accountObject: ObjectIdentifier,
                revision: FilteringNotificationRevision,
                currentRevision: @escaping @Sendable () -> FilteringNotificationRevision?) {
        self.batchId = batchId
        self.accountIdentity = accountIdentity
        self.accountObject = accountObject
        self.revision = revision
        self.currentRevision = currentRevision
    }

    public func isCurrent(accountIdentity: PrivacyExtrasAccountIdentity, accountObject: ObjectIdentifier) -> Bool {
        lock.lock()
        guard !revoked, self.accountIdentity == accountIdentity, self.accountObject == accountObject else {
            revoked = true
            lock.unlock()
            return false
        }
        lock.unlock()
        let current = currentRevision()
        lock.lock(); defer { lock.unlock() }
        guard !revoked, current == revision else { revoked = true; return false }
        return true
    }

    @discardableResult
    public func performIfCurrent(accountIdentity: PrivacyExtrasAccountIdentity, accountObject: ObjectIdentifier,
                                 effect: FilteringNotificationEffect, _ action: () -> Void) -> Bool {
        guard isCurrent(accountIdentity: accountIdentity, accountObject: accountObject) else { return false }
        lock.lock()
        guard !revoked, performed.insert(effect).inserted else { lock.unlock(); return false }
        lock.unlock()
        // Also covers cancellation or policy changes while another stage claimed
        // its slot. The synchronous effect's admission point is this final check.
        guard isCurrent(accountIdentity: accountIdentity, accountObject: accountObject) else { return false }
        action()
        return true
    }

    public func cancel() { lock.lock(); revoked = true; lock.unlock() }
}
