import Foundation

/// A short commit gate for a user operation. Invalidation waits for a commit
/// already in progress; once it returns, that owner can make no later writes.
public final class EmojiPackLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    public init() {}

    public func invalidate() {
        lock.lock(); active = false; lock.unlock()
    }

    public func commit<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw EmojiPackError.cancelled }
        return try body()
    }
}
