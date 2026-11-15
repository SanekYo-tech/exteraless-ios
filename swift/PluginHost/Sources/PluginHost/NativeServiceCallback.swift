import Foundation

/// Completion of Python execution, distinct from the dispatcher's Bool admission
/// result. The coordinator's result route uses the SAME owner FIFO as release.
public typealias NativeServiceCallbackResult = Result<PluginJSONValue, BridgeFailure>
public typealias NativeServiceAcknowledgedRelease<Owner: Hashable & Sendable> = @Sendable (
    Owner, [Int64], @escaping @Sendable () -> Void
) -> Void
public typealias NativeServiceResultCallback<Owner: Hashable & Sendable> = @Sendable (
    Owner, Int64, String, String, NativeServiceCallbackControl,
    @escaping @Sendable (NativeServiceCallbackResult) -> Void
) -> Bool

/// Checked again by the dispatcher immediately before Python entry. A timed-out
/// URL barrier must not execute a callback that is still waiting in the owner FIFO.
/// An already executing callback remains subject to the Host watchdog; its late
/// return cannot change a completed native opening decision.
public final class NativeServiceCallbackControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationFinished = false
    private var cancellation: (@Sendable () -> Void)?
    private var executionCheck: (@Sendable () -> Bool)?
    public let deadlineNanoseconds: UInt64

    public init(deadlineNanoseconds: UInt64) { self.deadlineNanoseconds = deadlineNanoseconds }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    public func bindCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancellationFinished {
            lock.unlock()
        } else if cancelled || DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
            lock.unlock()
            cancellation()
        } else {
            self.cancellation = cancellation
            lock.unlock()
        }
    }

    public func completed() {
        lock.lock(); defer { lock.unlock() }
        cancellationFinished = true
        cancellation = nil
    }

    public func bindExecutionCheck(_ check: @escaping @Sendable () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        executionCheck = check
    }

    public var allowsExecution: Bool {
        lock.lock()
        let check = executionCheck
        let active = !cancelled && DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds
        lock.unlock()
        return active && (check?() ?? true)
    }
}

public enum NativeServiceCallbackTransport {
    /// Adapts the actual coordinator API. Lease pins below cover the interval
    /// BEFORE this Task reaches the dispatcher's synchronous enqueue, so a racing
    /// unregister cannot put release ahead of the result request in its FIFO.
    public static func result(using dispatcher: PluginCallbackDispatcher) -> NativeServiceResultCallback<PluginHost.CallbackOwner> {
        return { owner, handle, method, arguments, control, completion in
            guard control.isActive else { return false }
            let task = Task {
                let result: NativeServiceCallbackResult
                do {
                    try Task.checkCancellation()
                    guard control.isActive else { throw CancellationError() }
                    let json = try await dispatcher.result(owner, handle, method, arguments,
                        shouldExecute: { control.allowsExecution })
                    try Task.checkCancellation()
                    result = .success(try NativeServiceWire.decode(json))
                } catch is CancellationError {
                    result = .failure(.unavailable("Native service callback cancelled"))
                } catch let failure as BridgeFailure {
                    result = .failure(failure)
                } catch {
                    result = .failure(.unavailable(NativeServiceLogEvent.redacted(String(describing: error), maximumBytes: 1024)))
                }
                control.completed()
                completion(result)
            }
            control.bindCancellation { task.cancel() }
            return true
        }
    }
}

/// A unique Python wrapper lease. Enqueue and release are serialized at this gate
/// so removal cannot release a handle ahead of a concurrently admitted callback.
/// Transport closures only enqueue: they must not call Python or re-enter the gate.
public final class NativeServiceCallbackLease<Owner: Hashable & Sendable>: @unchecked Sendable {
    public let id: String
    public let pluginId: String
    public let owner: Owner
    public let handle: Int64
    private let lock = NSLock()
    private var open = true
    private var releaseHandleOnClose = true
    private var retiredOnce = false
    private var pendingResults: [UUID: NativeServiceCallbackControl] = [:]
    private let isCurrent: @Sendable (Owner) -> Bool
    private let callback: @Sendable (Owner, Int64, String, String) -> Bool
    private let resultCallback: NativeServiceResultCallback<Owner>?
    private let release: @Sendable (Owner, [Int64]) -> Void
    private let acknowledgedRelease: NativeServiceAcknowledgedRelease<Owner>?
    private let retired: @Sendable (String) -> Void

    fileprivate init(pluginId: String, owner: Owner, handle: Int64,
                     isCurrent: @escaping @Sendable (Owner) -> Bool,
                     callback: @escaping @Sendable (Owner, Int64, String, String) -> Bool,
                     resultCallback: NativeServiceResultCallback<Owner>?,
                     release: @escaping @Sendable (Owner, [Int64]) -> Void,
                     acknowledgedRelease: NativeServiceAcknowledgedRelease<Owner>?,
                     retired: @escaping @Sendable (String) -> Void) {
        self.id = UUID().uuidString
        self.pluginId = pluginId
        self.owner = owner
        self.handle = handle
        self.isCurrent = isCurrent
        self.callback = callback
        self.resultCallback = resultCallback
        self.release = release
        self.acknowledgedRelease = acknowledgedRelease
        self.retired = retired
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open && isCurrent(owner)
    }

    public var supportsResults: Bool { resultCallback != nil }

    @discardableResult
    public func send(method: String = "__call__", argumentsJSON: String, terminal: Bool = false) -> Bool {
        lock.lock()
        guard open else { lock.unlock(); return false }
        let admitted = isCurrent(owner) && callback(owner, handle, method, argumentsJSON)
        // Rejected callbacks cannot leave an apparently active native lease behind.
        let shouldRetire = terminal || !admitted
        if shouldRetire {
            open = false
        }
        let controls = shouldRetire ? Array(pendingResults.values) : []
        let notify = retireIfReady()
        lock.unlock()
        for control in controls { control.cancel() }
        if notify { notifyRetired() }
        return admitted
    }

    /// Completion may arrive after close/timeout. Consumers must gate it with a
    /// one-shot operation identity. Close still queues release AFTER this request.
    public func request(argumentsJSON: String, control: NativeServiceCallbackControl,
                        completion: @escaping @Sendable (NativeServiceCallbackResult) -> Void) -> Bool {
        lock.lock()
        guard open, isCurrent(owner), control.isActive, pendingResults.count < 64, let resultCallback else { lock.unlock(); return false }
        let identity = UUID()
        pendingResults[identity] = control
        control.bindExecutionCheck { [weak self] in self?.isOpen == true }
        let admitted = resultCallback(owner, handle, "__call__", argumentsJSON, control) { [self] result in
            if endResult(identity) { completion(result) }
        }
        lock.unlock()
        if !admitted { _ = endResult(identity) }
        return admitted
    }

    private func endResult(_ identity: UUID) -> Bool {
        lock.lock()
        let existed = pendingResults.removeValue(forKey: identity) != nil
        let notify = retireIfReady()
        lock.unlock()
        if notify { notifyRetired() }
        return existed
    }

    /// Called under the lease lock. FIFO release is an enqueue-only operation.
    private func retireIfReady() -> Bool {
        guard !open, pendingResults.isEmpty, !retiredOnce else { return false }
        retiredOnce = true
        if releaseHandleOnClose && acknowledgedRelease == nil { release(owner, [handle]) }
        return true
    }

    private func notifyRetired() {
        if releaseHandleOnClose, let acknowledgedRelease {
            let retired = self.retired
            let id = self.id
            acknowledgedRelease(owner, [handle]) { retired(id) }
        } else { retired(id) }
    }

    public func close() { finish(releaseHandle: true) }

    /// Admission failed: the SDK still owns the handle and will release it itself.
    public func reject() { finish(releaseHandle: false) }

    private func finish(releaseHandle: Bool) {
        lock.lock()
        guard open else { lock.unlock(); return }
        open = false
        releaseHandleOnClose = releaseHandle
        let controls = Array(pendingResults.values)
        let notify = retireIfReady()
        lock.unlock()
        for control in controls { control.cancel() }
        if notify { notifyRetired() }
    }
}

/// Shared across scheduling/registrations/account services in one provider. A
/// reused C handle is rejected instead of being silently owned by two leases.
public final class NativeServiceLeasePool<Owner: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumPerOwner: Int
    private let maximumTotal: Int
    private var leases: [String: NativeServiceCallbackLease<Owner>] = [:]

    public init(maximumPerOwner: Int = 128, maximumTotal: Int = 1024) {
        self.maximumPerOwner = max(1, maximumPerOwner)
        self.maximumTotal = max(1, maximumTotal)
    }

    public func make(pluginId: String, owner: Owner, handle: Int64,
                     isCurrent: @escaping @Sendable (Owner) -> Bool,
                     callback: @escaping @Sendable (Owner, Int64, String, String) -> Bool,
                     resultCallback: NativeServiceResultCallback<Owner>? = nil,
                     release: @escaping @Sendable (Owner, [Int64]) -> Void,
                     acknowledgedRelease: NativeServiceAcknowledgedRelease<Owner>? = nil) throws -> NativeServiceCallbackLease<Owner> {
        guard handle > 0 else { throw BridgeFailure.malformed("Native service requires a positive callback handle") }
        lock.lock(); defer { lock.unlock() }
        let owned = leases.values.filter { $0.owner == owner }
        guard leases.count < maximumTotal, owned.count < maximumPerOwner else {
            throw BridgeFailure.unavailable("Native service callback lease budget exhausted")
        }
        guard !owned.contains(where: { $0.handle == handle }) else {
            throw BridgeFailure.invalidHandle("A callback wrapper already belongs to another native service lease")
        }
        let lease = NativeServiceCallbackLease(pluginId: pluginId, owner: owner, handle: handle,
            isCurrent: isCurrent, callback: callback, resultCallback: resultCallback, release: release, acknowledgedRelease: acknowledgedRelease,
            retired: { [weak self] id in self?.forget(id) })
        leases[lease.id] = lease
        return lease
    }

    private func forget(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        leases.removeValue(forKey: id)
    }

    public func closeAll(pluginId: String? = nil) {
        lock.lock()
        let selected = leases.values.filter { pluginId == nil || $0.pluginId == pluginId }
        lock.unlock()
        for lease in selected { lease.close() }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return leases.count
    }

    deinit {
        for lease in leases.values { lease.close() }
    }
}
