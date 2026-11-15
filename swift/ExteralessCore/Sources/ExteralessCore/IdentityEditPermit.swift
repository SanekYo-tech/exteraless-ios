import Foundation

/// A settings/editor lifetime, pinned to the account that opened it. Native
/// transactions check this after queueing, so an account switch cancels pending
/// edits instead of committing them against the newly selected account.
public final class IdentityEditPermit: @unchecked Sendable {
    public let account: IdentityAccountId
    private let lock = NSLock()
    private var active = true

    public init(account: IdentityAccountId) { self.account = account }

    public func invalidate() {
        lock.lock(); active = false; lock.unlock()
    }

    public func check(owner: IdentityAccountId) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw IdentityError.inactiveAccount }
        guard account == owner else { throw IdentityError.differentAccount }
    }
}
