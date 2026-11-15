import Foundation

/// A refused control admission is not a released C reference. Coalesce only
/// already-retired leases and retry enqueue, using the existing owner FIFO.
/// This timer services release backpressure, never client/network status polling.
public final class NativeServiceReleaseQueue<Owner: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Exteraless.NativeLeaseRelease", qos: .utility)
    private let current: @Sendable (Owner) -> Bool
    private let submit: @Sendable (Owner, [Int64]) -> Bool
    private struct Completion {
        let handles: Set<Int64>
        let done: @Sendable () -> Void
    }
    private var pending: [Owner: Set<Int64>] = [:]
    private var completions: [Owner: [Completion]] = [:]
    private var timer: DispatchSourceTimer?
    private var keepAlive: NativeServiceReleaseQueue?

    public init(current: @escaping @Sendable (Owner) -> Bool, submit: @escaping @Sendable (Owner, [Int64]) -> Bool) {
        self.current = current
        self.submit = submit
    }

    public func release(_ owner: Owner, _ handles: [Int64], onAccepted: @escaping @Sendable () -> Void = {}) {
        guard !handles.isEmpty, handles.count <= 4096, handles.allSatisfy({ $0 > 0 }) else { return }
        lock.lock()
        guard current(owner) else { lock.unlock(); onAccepted(); return } // retired C interpreter owns its final sweep
        if pending[owner] == nil, submit(owner, handles) { lock.unlock(); onAccepted(); return }
        pending[owner, default: []].formUnion(handles)
        completions[owner, default: []].append(Completion(handles: Set(handles), done: onAccepted))
        // Pool admission credits remain occupied until onAccepted, so repeated
        // post/cancel cannot exceed 128/owner, 1024 globally while C is backpressured.
        if timer == nil {
            keepAlive = self
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer
            timer.resume()
        }
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        var completed: [@Sendable () -> Void] = []
        for owner in Array(pending.keys) {
            guard current(owner) else {
                pending.removeValue(forKey: owner)
                completed.append(contentsOf: completions.removeValue(forKey: owner)?.map(\.done) ?? [])
                continue
            }
            let handles = Array(pending[owner, default: []].sorted().prefix(4096))
            if submit(owner, handles) {
                pending[owner]?.subtract(handles)
                let stillPending = pending[owner] ?? []
                let done = completions[owner, default: []].filter { $0.handles.isDisjoint(with: stillPending) }
                completed.append(contentsOf: done.map(\.done))
                completions[owner]?.removeAll { $0.handles.isDisjoint(with: stillPending) }
                if pending[owner]?.isEmpty == true { pending.removeValue(forKey: owner) }
                if completions[owner]?.isEmpty == true { completions.removeValue(forKey: owner) }
            }
        }
        if pending.isEmpty {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            keepAlive = nil
        }
        lock.unlock()
        for done in completed { done() }
    }

    public var pendingHandleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.values.reduce(0) { $0 + $1.count }
    }
}

public enum NativeServiceReleaseTransport {
    public static func acknowledged(_ dispatcher: PluginCallbackDispatcher) -> NativeServiceAcknowledgedRelease<PluginHost.CallbackOwner> {
        let queue = NativeServiceReleaseQueue<PluginHost.CallbackOwner>(
            current: { dispatcher.captureOwner($0.pluginId) == $0 }, submit: { dispatcher.release($0, $1) })
        return { owner, handles, accepted in queue.release(owner, handles, onAccepted: accepted) }
    }
}
