import Foundation
import PluginHost

/// A registration owns its complete, unique wrapper set. No callback runs inline.
final class PluginPillCallbacks: @unchecked Sendable {
    typealias Owner = PluginHost.CallbackOwner
    private let lock = NSLock()
    let owner: Owner
    let handles: [String: Int64]
    private let dispatcher: PluginCallbackDispatcher
    private let isCurrent: @Sendable () -> Bool
    private let release: @Sendable (Owner, [Int64]) -> Void
    private var open = true
    private var transferred = false
    private var released = false
    private var results: [UUID: NativeServiceCallbackControl] = [:]

    init(owner: Owner, handles: [String: Int64], dispatcher: PluginCallbackDispatcher,
         isCurrent: @escaping @Sendable () -> Bool, release: @escaping @Sendable (Owner, [Int64]) -> Void) {
        self.owner = owner; self.handles = handles; self.dispatcher = dispatcher
        self.isCurrent = isCurrent; self.release = release
    }
    func transfer() { self.lock.lock(); self.transferred = true; self.lock.unlock() }
    private var isOpen: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.open }

    @discardableResult func send(_ name: String, arguments: String, gate: @escaping @Sendable () -> Bool) -> Bool {
        guard let handle = self.handles[name] else { return true }
        self.lock.lock()
        guard self.open, self.transferred, self.isCurrent() else { self.lock.unlock(); return false }
        let accepted = self.dispatcher.callback(self.owner, handle, "__call__", arguments, shouldExecute: { [weak self] in
            guard let self else { return false }
            return self.isOpen && self.isCurrent() && gate()
        })
        self.lock.unlock()
        return accepted
    }

    @discardableResult func longPress(arguments: String, gate: @escaping @Sendable () -> Bool,
                                     completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let handle = self.handles["longPress"] else { if gate() { completion(false) }; return true }
        let identity = UUID()
        let control = NativeServiceCallbackControl(deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        self.lock.lock()
        guard self.open, self.transferred, self.isCurrent(), self.results.count < 4 else { self.lock.unlock(); return false }
        self.results[identity] = control // Pins the lease before the Task can enqueue on owner FIFO.
        self.lock.unlock()
        let task = Task { [self] in
            var handled = false
            do {
                try Task.checkCancellation()
                guard control.isActive else { throw CancellationError() }
                let json = try await self.dispatcher.result(self.owner, handle, "__call__", arguments, shouldExecute: { [weak self] in
                    guard let self else { return false }
                    return self.isOpen && self.isCurrent() && control.isActive && gate()
                })
                try Task.checkCancellation()
                if case let .bool(value) = try NativeServiceWire.decode(json) { handled = value }
            } catch { /* A failed/expired handler falls back only in a still-current native selection. */ }
            control.completed()
            self.endResult(identity)
            if self.isCurrent() && gate() { completion(handled) }
        }
        control.bindCancellation { task.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { control.cancel() }
        return true
    }

    /// Before transfer, rejection leaves ownership to the SDK/C marshalling transaction.
    func close() {
        self.lock.lock()
        self.open = false
        let controls = Array(self.results.values)
        let handles = self.takeReleaseIfReady()
        self.lock.unlock()
        for control in controls { control.cancel() }
        if let handles { self.release(self.owner, handles) }
    }
    private func endResult(_ id: UUID) {
        self.lock.lock(); self.results.removeValue(forKey: id)
        let handles = self.takeReleaseIfReady()
        self.lock.unlock()
        if let handles { self.release(self.owner, handles) }
    }
    private func takeReleaseIfReady() -> [Int64]? {
        guard !self.open, self.transferred, self.results.isEmpty, !self.released else { return nil }
        self.released = true
        return self.handles.values.sorted()
    }
}

/// Bounded release outbox. Failed admission never silently loses a live owner's handles.
/// Retiring registrations still occupy bridge capacity until FIFO release is admitted.
final class PluginPillReleaseQueue: @unchecked Sendable {
    private struct Pending {
        let owner: PluginHost.CallbackOwner
        let handles: [Int64]
        let completed: @Sendable () -> Void
    }
    private let queue = DispatchQueue(label: "Exteraless.Pills.CallbackRelease", qos: .utility)
    private let dispatcher: PluginCallbackDispatcher
    private var pending: [Pending] = []
    private var scheduled = false
    private var retries = 0
    init(dispatcher: PluginCallbackDispatcher) { self.dispatcher = dispatcher }

    func enqueue(owner: PluginHost.CallbackOwner, handles: [Int64], completed: @escaping @Sendable () -> Void) {
        self.queue.async {
            self.pending.append(.init(owner: owner, handles: handles, completed: completed))
            self.retries = 0
            self.schedule()
        }
    }
    func kick() { self.queue.async { self.retries = 0; self.schedule() } }
    private func schedule() {
        guard !self.pending.isEmpty, !self.scheduled else { return }
        self.scheduled = true
        self.queue.async { self.flush() }
    }
    private func flush() {
        self.scheduled = false
        let batch = self.pending; self.pending.removeAll()
        let owners = Set(batch.map(\.owner))
        for owner in owners {
            let group = batch.filter { $0.owner == owner }
            let handles = Array(Set(group.flatMap(\.handles))).sorted()
            // Retired interpreters are cleared by Host teardown; never resolve these handles by plugin ID.
            if self.dispatcher.captureOwner(owner.pluginId) != owner || self.dispatcher.release(owner, handles) {
                for item in group { item.completed() }
            } else { self.pending.append(contentsOf: group) }
        }
        if !self.pending.isEmpty, self.retries < 8 {
            self.retries += 1; self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + min(0.5, Double(self.retries) * 0.05)) { self.flush() }
        }
        // After the bounded retry window, keep pending identities and retry on the next native operation/unload.
    }
}
