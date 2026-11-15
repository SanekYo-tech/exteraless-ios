import Foundation

/// A provider captures owner synchronously when accepting an operation. Native
/// UI/network completions may then enqueue callbacks or release their unique
/// leases from any thread. No callback ever executes on the calling thread.
public final class PluginCallbackDispatcher: @unchecked Sendable {
    /// Control capacity is reserved for small terminal bookkeeping/release, not
    /// an unbounded exemption for TL payloads. Counts include executing work.
    public struct Limits: Sendable {
        public let callbacks: Int
        public let callbacksPerOwner: Int
        public let callbackBytes: Int
        public let controls: Int
        public let controlsPerOwner: Int
        public let controlBytes: Int

        public init(callbacks: Int = 1024, callbacksPerOwner: Int = 256, callbackBytes: Int = 33_554_432,
                    controls: Int = 1024, controlsPerOwner: Int = 128, controlBytes: Int = 4_194_304) {
            self.callbacks = min(1024, max(1, callbacks))
            self.callbacksPerOwner = min(256, max(1, callbacksPerOwner))
            self.callbackBytes = min(33_554_432, max(1, callbackBytes))
            self.controls = min(1024, max(1, controls))
            self.controlsPerOwner = min(128, max(1, controlsPerOwner))
            self.controlBytes = min(4_194_304, max(1, controlBytes))
        }
    }

    private weak var host: PluginHost?
    private let log: (@Sendable (String) -> Void)?
    private let limits: Limits
    private let lock = NSLock()
    private final class PendingResult: @unchecked Sendable {
        let value = OneShotResult<String>()
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            value.fail(CancellationError())
        }
    }
    private enum Content: Sendable {
        case callback(Int64, String, String, PendingResult?, @Sendable () -> Bool)
        case release([Int64])
    }
    private struct Work: Sendable {
        let content: Content
        let control: Bool
        let bytes: Int
        let activity: PluginHostActivity
    }
    private struct OwnerCounts {
        var callbacks = 0
        var controls = 0
    }
    private var queues: [PluginHost.CallbackOwner: [Work]] = [:]
    private var ownerCounts: [PluginHost.CallbackOwner: OwnerCounts] = [:]
    private var queuedCallbacks = 0
    private var queuedBytes = 0
    private var queuedControls = 0
    private var controlBytes = 0

    public init(host: PluginHost, log: (@Sendable (String) -> Void)? = nil, limits: Limits = Limits()) {
        self.host = host
        self.log = log
        self.limits = limits
    }

    public func captureOwner(_ pluginId: String) -> PluginHost.CallbackOwner? {
        host?.callbackOwner(id: pluginId)
    }

    public func hasPermission(_ pluginId: String, _ permission: PluginPermission) -> Bool {
        host?.permissions.has(pluginId, permission) ?? false
    }

    var outstandingWorkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedCallbacks + queuedControls
    }

    @discardableResult
    public func callback(_ owner: PluginHost.CallbackOwner, _ handle: Int64,
                         _ method: String, _ argumentsJSON: String,
                         shouldExecute: @escaping @Sendable () -> Bool = { true }, guaranteed: Bool = false) -> Bool {
        enqueue(owner, handle, method, argumentsJSON, result: nil, shouldExecute: shouldExecute, guaranteed: guaranteed)
    }

    public func result(_ owner: PluginHost.CallbackOwner, _ handle: Int64,
                        _ method: String, _ argumentsJSON: String,
                        shouldExecute: @escaping @Sendable () -> Bool = { true }, guaranteed: Bool = false) async throws -> String {
        try Task.checkCancellation()
        let pending = PendingResult()
        guard enqueue(owner, handle, method, argumentsJSON, result: pending,
                      shouldExecute: shouldExecute, guaranteed: guaranteed) else {
            throw PluginHostError.runtimeFailure("Native callback could not be admitted")
        }
        let value = try await withTaskCancellationHandler(operation: {
            try await pending.value.awaitValue()
        }, onCancel: { pending.cancel() })
        try Task.checkCancellation()
        return value
    }

    private func enqueue(_ owner: PluginHost.CallbackOwner, _ handle: Int64,
                         _ method: String, _ argumentsJSON: String, result: PendingResult?,
                         shouldExecute: @escaping @Sendable () -> Bool, guaranteed: Bool) -> Bool {
        guard handle > 0, !method.isEmpty, method.utf8.count <= 256 else { return false }
        let bytes = argumentsJSON.utf8.count
        guard bytes <= (guaranteed ? 16_384 : 16_777_216) else { return false }
        return append(owner, content: .callback(handle, method, argumentsJSON, result, shouldExecute),
                      control: guaranteed, bytes: bytes)
    }

    private func append(_ owner: PluginHost.CallbackOwner, content: Content, control: Bool, bytes: Int) -> Bool {
        guard let host, let activity = try? host.reserveCallbackActivity(owner) else { return false }
        lock.lock()
        let ownerBudget = ownerCounts[owner] ?? OwnerCounts()
        let admitted: Bool
        if control {
            admitted = queuedControls < limits.controls && ownerBudget.controls < limits.controlsPerOwner
                && controlBytes + bytes <= limits.controlBytes
        } else {
            admitted = queuedCallbacks < limits.callbacks && ownerBudget.callbacks < limits.callbacksPerOwner
                && queuedBytes + bytes <= limits.callbackBytes
        }
        guard admitted else {
            lock.unlock()
            activity.finish()
            log?("Plugin \(control ? "control" : "callback") queue is full: \(owner.pluginId)")
            return false
        }
        if control {
            queuedControls += 1
            controlBytes += bytes
            ownerCounts[owner, default: OwnerCounts()].controls += 1
        } else {
            queuedCallbacks += 1
            queuedBytes += bytes
            ownerCounts[owner, default: OwnerCounts()].callbacks += 1
        }
        let start = queues[owner] == nil
        queues[owner, default: []].append(Work(content: content, control: control, bytes: bytes, activity: activity))
        lock.unlock()
        if start { Task { await self.drain(owner) } }
        return true
    }

    @discardableResult
    public func release(_ owner: PluginHost.CallbackOwner, _ handles: [Int64]) -> Bool {
        guard !handles.isEmpty else { return true }
        guard handles.count <= 4096, handles.allSatisfy({ $0 > 0 }) else { return false }
        let unique = Array(Set(handles)).sorted()
        // Control operations share the same FIFO as callbacks. Independent
        // unstructured Tasks could otherwise release a handle before its click.
        return append(owner, content: .release(unique), control: true, bytes: unique.count * MemoryLayout<Int64>.size)
    }

    private func next(_ owner: PluginHost.CallbackOwner) -> Work? {
        lock.lock(); defer { lock.unlock() }
        guard var queue = queues[owner], !queue.isEmpty else {
            queues.removeValue(forKey: owner)
            return nil
        }
        let item = queue.removeFirst()
        queues[owner] = queue
        return item
    }

    private func finished(_ item: Work, owner: PluginHost.CallbackOwner) {
        lock.lock()
        if item.control {
            queuedControls -= 1
            controlBytes -= item.bytes
            ownerCounts[owner]?.controls -= 1
        } else {
            queuedCallbacks -= 1
            queuedBytes -= item.bytes
            ownerCounts[owner]?.callbacks -= 1
        }
        if let counts = ownerCounts[owner], counts.callbacks == 0 && counts.controls == 0 {
            ownerCounts.removeValue(forKey: owner)
        }
        lock.unlock()
        item.activity.finish()
    }

    private func drain(_ owner: PluginHost.CallbackOwner) async {
        while let item = next(owner) {
            defer { finished(item, owner: owner) }
            let pending: PendingResult?
            if case .callback(_, _, _, let value, _) = item.content { pending = value } else { pending = nil }
            if pending?.isCancelled == true { continue }
            guard let host else {
                pending?.value.fail(PluginHostError.notRunning)
                continue
            }
            do {
                switch item.content {
                case let .callback(handle, method, arguments, completion, shouldExecute):
                    let result = try await host.performCallbackResult(id: owner.pluginId, handle: handle, method: method,
                        argumentsJSON: arguments, expectedOwner: owner,
                        shouldExecute: { completion?.isCancelled != true && shouldExecute() }, activity: item.activity)
                    completion?.value.succeed(result)
                case let .release(handles):
                    try await host.performCallbackRelease(handles, expectedOwner: owner, activity: item.activity)
                }
            } catch {
                let failure = bridgePluginError(error)
                pending?.value.fail(failure)
                switch failure {
                case .superseded, .notRunning: break
                default: log?("Plugin callback \(owner.pluginId): \(failure)")
                }
            }
        }
    }
}
