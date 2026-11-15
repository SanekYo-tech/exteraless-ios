import Foundation

/// One enqueue operation, not another origin registry. Before the native write
/// boundary its subscriber owns cancellation. After beginCommit the native job
/// owns completion/tracking even when that subscriber disappears.
public final class ExteralessTLEnqueueCommit: @unchecked Sendable {
    private enum Phase { case provisional, committing, finished, cancelled }
    private let lock = NSLock()
    private var phase: Phase = .provisional
    private var subscribed = true
    private var nativeCancellation: (() -> Void)?
    private let canCommit: () -> Bool
    private let cancelProvisional: () -> Void

    public init(canCommit: @escaping () -> Bool, cancelProvisional: @escaping () -> Void) {
        self.canCommit = canCommit
        self.cancelProvisional = cancelProvisional
    }

    /// Recheck after an asynchronous authorization/preparation boundary. This is
    /// observational: the actual transaction must still call beginCommit again.
    public func allowsContinuation() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.phase == .provisional && self.subscribed && self.canCommit()
    }

    /// Called inside the real enqueue transaction, immediately before its writes.
    public func beginCommit() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.phase == .provisional, self.subscribed, self.canCommit() else { return false }
        self.phase = .committing
        return true
    }

    public func bindCancellation(_ cancel: @escaping () -> Void) {
        self.lock.lock()
        if self.phase == .finished || self.phase == .cancelled {
            self.lock.unlock()
            cancel()
        } else {
            let previous = self.nativeCancellation
            self.nativeCancellation = cancel
            self.lock.unlock()
            previous?()
        }
    }

    /// nil means a duplicate/late terminal. track ALWAYS runs for the native
    /// completion winner, before delivery is checked, including after disposal.
    public func complete(track: (_ commitWasClaimed: Bool) -> Void) -> Bool? {
        self.lock.lock()
        guard self.phase == .provisional || self.phase == .committing else { self.lock.unlock(); return nil }
        let claimed = self.phase == .committing
        self.phase = .finished
        let cancel = self.nativeCancellation
        self.nativeCancellation = nil
        self.lock.unlock()
        track(claimed)
        cancel?()
        self.lock.lock(); defer { self.lock.unlock() }
        return self.subscribed
    }

    public func cancelSubscriber() {
        self.lock.lock()
        self.subscribed = false
        let provisional = self.phase == .provisional
        let cancel: (() -> Void)?
        if provisional {
            self.phase = .cancelled
            cancel = self.nativeCancellation
            self.nativeCancellation = nil
        } else {
            // Never dispose a claimed commit before its real IDs reach tracking.
            cancel = nil
        }
        self.lock.unlock()
        if provisional { self.cancelProvisional() }
        cancel?()
    }
}
