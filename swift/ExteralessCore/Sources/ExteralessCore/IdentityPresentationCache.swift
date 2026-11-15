import Foundation

/// Published immutable account snapshots, safe for async text/layout queues. No
/// native peers or derived/server names are retained here. A replaced/cleared
/// lease cannot republish a late Postbox callback into a new account lifetime.
public final class IdentityPresentationCache: @unchecked Sendable {
    public struct Lease: Hashable, Sendable {
        public let account: IdentityAccountId
        fileprivate let token: UUID
    }

    private struct Entry {
        let token: UUID
        var sequence: UInt64
        var state: IdentityAccountState?
    }

    public static let maximumAccounts = 64
    private let lock = NSLock()
    private var entries: [IdentityAccountId: Entry] = [:]
    private var version: UInt64 = 0

    public init() {}

    public var revision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return version
    }

    public func begin(account: IdentityAccountId) throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        guard account.userId > 0 else { throw IdentityError.invalidData }
        guard entries[account] != nil || entries.count < Self.maximumAccounts else { throw IdentityError.quotaExceeded }
        let lease = Lease(account: account, token: UUID())
        entries[account] = Entry(token: lease.token, sequence: 0, state: nil)
        version &+= 1
        return lease
    }

    @discardableResult
    public func publish(_ state: IdentityAccountState, lease: Lease, sequence: UInt64) throws -> Bool {
        try state.validate(owner: lease.account)
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[lease.account], entry.token == lease.token, sequence > entry.sequence else { return false }
        entry.sequence = sequence
        let changed = entry.state != state
        entry.state = state
        entries[lease.account] = entry
        if changed { version &+= 1 }
        return changed
    }

    public func snapshot(account: IdentityAccountId) -> IdentityAccountState? {
        lock.lock(); defer { lock.unlock() }
        return entries[account]?.state
    }

    public func isCurrent(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[lease.account]?.token == lease.token
    }

    @discardableResult
    public func end(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[lease.account]?.token == lease.token else { return false }
        entries.removeValue(forKey: lease.account)
        version &+= 1
        return true
    }
}
