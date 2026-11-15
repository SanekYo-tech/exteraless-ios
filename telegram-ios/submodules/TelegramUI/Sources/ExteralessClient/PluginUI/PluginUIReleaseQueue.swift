import Foundation

/// Terminal delivery and release may both be refused by the bounded Host FIFO.
/// Retain the remaining ordered batch until admission or owner retirement. The
/// lease store reserves its handles/quota before this queue is called, so retry
/// storage cannot grow by churning new leases while the control lane is full.
final class PluginUIReleaseQueue<Owner: Hashable & Sendable>: @unchecked Sendable {
    typealias Retirement = PluginUILeaseStore<Owner>.Retirement
    typealias Delivery = PluginUILeaseStore<Owner>.Delivery
    private final class Batch {
        let retirement: Retirement
        var nextDelivery = 0
        init(_ retirement: Retirement) { self.retirement = retirement }
    }
    private let lock = NSLock()
    private var pending: [Owner: [Batch]] = [:]
    private var draining = Set<Owner>()
    private var retryScheduled = false
    private let queue = DispatchQueue(label: "exteraless.ui-release")
    private let isCurrent: @Sendable (Owner) -> Bool
    private let callback: @Sendable (Delivery) -> Bool
    private let release: @Sendable (Owner, [Int64]) -> Bool
    private let completed: @Sendable (Retirement) -> Void

    init(isCurrent: @escaping @Sendable (Owner) -> Bool, callback: @escaping @Sendable (Delivery) -> Bool,
         release: @escaping @Sendable (Owner, [Int64]) -> Bool, completed: @escaping @Sendable (Retirement) -> Void) {
        self.isCurrent = isCurrent
        self.callback = callback
        self.release = release
        self.completed = completed
    }

    func retire(_ retirement: Retirement) {
        self.lock.lock()
        self.pending[retirement.owner, default: []].append(Batch(retirement))
        self.lock.unlock()
        self.drain(retirement.owner)
    }

    // Exposed internally so the fixture can retry deterministically, without
    // sleeping or opening a dispatcher/interpreter. Production uses the timer.
    func retryPending() {
        self.lock.lock()
        let owners = Array(self.pending.keys)
        self.lock.unlock()
        for owner in owners { self.drain(owner) }
    }

    private func drain(_ owner: Owner) {
        self.lock.lock()
        guard self.draining.insert(owner).inserted else { self.lock.unlock(); return }
        self.lock.unlock()
        while true {
            self.lock.lock()
            guard let batch = self.pending[owner]?.first else {
                self.pending.removeValue(forKey: owner)
                self.draining.remove(owner)
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            let retirement = batch.retirement
            var admitted = true
            if self.isCurrent(owner) {
                while batch.nextDelivery < retirement.deliveries.count {
                    guard self.callback(retirement.deliveries[batch.nextDelivery]) else { admitted = false; break }
                    batch.nextDelivery += 1
                }
                if admitted && !retirement.handles.isEmpty { admitted = self.release(owner, retirement.handles) }
            }
            guard admitted else {
                self.lock.lock(); self.draining.remove(owner); self.lock.unlock()
                self.scheduleRetry()
                return
            }
            self.lock.lock()
            self.pending[owner]?.removeFirst()
            self.lock.unlock()
            self.completed(retirement)
        }
    }

    private func scheduleRetry() {
        self.lock.lock()
        guard !self.retryScheduled else { self.lock.unlock(); return }
        self.retryScheduled = true
        self.lock.unlock()
        self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.retryScheduled = false; self.lock.unlock()
            self.retryPending()
        }
    }
}
