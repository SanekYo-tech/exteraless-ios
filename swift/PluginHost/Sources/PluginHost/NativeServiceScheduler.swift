import Foundation

/// Each SDK queue has a real serial native scheduler. Python executes only after
/// submission to its captured interpreter worker. One timer per name, not one
/// asyncAfter closure retained for every cancelled long-delay task.
public final class NativeServiceOwnerScheduler<Owner: Hashable & Sendable>: @unchecked Sendable {
    public static var maximumDelayMs: Int64 { 86_400_000 }
    public static var queueNames: Set<String> {
        ["UI", "STAGE_QUEUE", "GLOBAL_QUEUE", "CACHE_CLEAR_QUEUE", "SEARCH_QUEUE",
         "PHONE_BOOK_QUEUE", "THEME_QUEUE", "EXTERNAL_NETWORK_QUEUE", "PLUGINS_QUEUE"]
    }

    private struct Entry {
        let lease: NativeServiceCallbackLease<Owner>
        let queue: String
        let deadline: UInt64
        let sequence: UInt64
    }
    private let lock = NSLock()
    private let maximumPerOwner: Int
    private let maximumTotal: Int
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    private var timers: [String: DispatchSourceTimer] = [:]

    public init(maximumPerOwner: Int = 128, maximumTotal: Int = 1024) {
        self.maximumPerOwner = max(1, maximumPerOwner)
        self.maximumTotal = max(1, maximumTotal)
        for name in Self.queueNames {
            let queue = DispatchQueue(label: "Exteraless.NativeOwnerTasks.\(name)", qos: name == "UI" ? .userInitiated : .utility)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .distantFuture)
            timer.setEventHandler { [weak self] in self?.fire(queue: name) }
            timers[name] = timer
            timer.resume()
        }
    }

    public static func validate(delayMs: Int64, queue: String) throws {
        guard (0...maximumDelayMs).contains(delayMs) else {
            throw BridgeFailure.malformed("postToOwner.delayMs must be between 0 and 86400000 milliseconds")
        }
        guard queueNames.contains(queue) else { throw BridgeFailure.unimplemented("UnsupportedOwnerQueue: \(queue)") }
    }

    public func schedule(_ lease: NativeServiceCallbackLease<Owner>, delayMs: Int64, queue: String) throws -> String {
        try Self.validate(delayMs: delayMs, queue: queue)
        lock.lock(); defer { lock.unlock() }
        guard entries.count < maximumTotal, entries.values.filter({ $0.lease.owner == lease.owner }).count < maximumPerOwner else {
            throw BridgeFailure.unavailable("Native owner task budget exhausted")
        }
        guard entries[lease.id] == nil else { throw BridgeFailure.invalidHandle("Owner task lease already scheduled") }
        sequence &+= 1
        entries[lease.id] = Entry(lease: lease, queue: queue,
            deadline: DispatchTime.now().uptimeNanoseconds + UInt64(delayMs) * 1_000_000, sequence: sequence)
        arm(queue)
        return lease.id
    }

    public func cancel(id: String, owner: Owner) -> Bool {
        lock.lock()
        guard let entry = entries[id], entry.lease.owner == owner else { lock.unlock(); return false }
        entries.removeValue(forKey: id)
        arm(entry.queue)
        lock.unlock()
        entry.lease.close()
        return true
    }

    public func cancelAll(pluginId: String? = nil) {
        lock.lock()
        let removed = entries.values.filter { pluginId == nil || $0.lease.pluginId == pluginId }
        for entry in removed { entries.removeValue(forKey: entry.lease.id) }
        for name in Set(removed.map(\.queue)) { arm(name) }
        lock.unlock()
        for entry in removed { entry.lease.close() }
    }

    private func arm(_ queue: String) {
        let next = entries.values.filter { $0.queue == queue }.map(\.deadline).min()
        timers[queue]?.schedule(deadline: next.map { DispatchTime(uptimeNanoseconds: $0) } ?? .distantFuture,
                                leeway: .milliseconds(1))
    }

    private func fire(queue: String) {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let due = entries.values.filter { $0.queue == queue && $0.deadline <= now }.sorted {
            $0.deadline == $1.deadline ? $0.sequence < $1.sequence : $0.deadline < $1.deadline
        }
        for entry in due { entries.removeValue(forKey: entry.lease.id) }
        arm(queue)
        lock.unlock()
        for entry in due {
            // Even admission failure retires this lease, in the original owner.
            entry.lease.send(method: "run", argumentsJSON: "[]", terminal: true)
        }
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    deinit {
        for timer in timers.values { timer.cancel() }
        for entry in entries.values { entry.lease.close() }
    }
}
