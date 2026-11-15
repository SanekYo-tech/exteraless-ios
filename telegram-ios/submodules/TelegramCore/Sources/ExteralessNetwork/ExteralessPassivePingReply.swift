import Foundation

/// Wrappers may receive a delayed or duplicate reply from an inner engine.
/// Complete each passive read once, preserve its timestamp, and recheck freshness.
final class ExteralessPassivePingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((ExteralessPillPassivePingSample?) -> Void)?

    init(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void) { self.reply = reply }

    func complete(_ sample: ExteralessPillPassivePingSample?) {
        lock.lock(); let reply = self.reply; self.reply = nil; lock.unlock()
        reply?(sample.flatMap { $0.isFresh() ? $0 : nil })
    }
}
