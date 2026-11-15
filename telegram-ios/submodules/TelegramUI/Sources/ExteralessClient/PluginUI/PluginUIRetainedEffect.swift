import Foundation
import PluginHost

/// A retained native effect owns its budget credit until its actual completion
/// or the last queued/deferred closure releases it. Expiring validity does not
/// release memory credit: a cancelled main-queue block still retains its payload.
final class PluginUIRetainedEffect: @unchecked Sendable {
    private let ticket: PluginNativeEffectBudget.Ticket
    private let nativeLease: PluginNativeCallLease

    init(budget: PluginNativeEffectBudget, pluginId: String, bytes: Int,
         isCurrent: @escaping @Sendable () -> Bool) throws {
        // Construct on the originating C owner worker. The shared constructor
        // captures its real Host batch revocation, independently of TL ancestry.
        let nativeLease = PluginNativeCallLease(isCurrent: isCurrent)
        try nativeLease.check()
        self.ticket = try budget.reserve(pluginId: pluginId, bytes: bytes)
        self.nativeLease = nativeLease
    }

    var permitsExecution: Bool { self.ticket.isActive && self.nativeLease.isCurrent }
    func finish() { self.ticket.finish() }
    // Ticket.deinit also finishes when an intercepted/handled/cancelled opening
    // drops the continuation without calling it. No cancelAll/refund-on-revoke.
}
