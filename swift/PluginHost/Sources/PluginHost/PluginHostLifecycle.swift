import Foundation

/// A cancellable, multi-waiter completion. Cancelling an observer never cancels
/// an interpreter's native destruction or changes its quiescence accounting.
final class PluginLifecycleSignal<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Value, PluginHostError>?
    private var waiters: [UUID: OneShotResult<Value>] = [:]

    func succeed(_ value: Value) { complete(.success(value)) }
    func fail(_ error: PluginHostError) { complete(.failure(error)) }

    private func complete(_ value: Result<Value, PluginHostError>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = value
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { deliver(value, to: waiter) }
    }

    private func deliver(_ value: Result<Value, PluginHostError>, to waiter: OneShotResult<Value>) {
        switch value {
        case .success(let result): waiter.succeed(result)
        case .failure(let error): waiter.fail(error)
        }
    }

    private func register(_ id: UUID, _ waiter: OneShotResult<Value>) {
        lock.lock()
        let value = outcome
        if value == nil { waiters[id] = waiter }
        lock.unlock()
        if let value { deliver(value, to: waiter) }
    }

    private func cancel(_ id: UUID, _ waiter: OneShotResult<Value>) {
        lock.lock(); waiters.removeValue(forKey: id); lock.unlock()
        waiter.fail(CancellationError())
    }

    func wait(cancellable: Bool = true) async throws -> Value {
        let id = UUID()
        let waiter = OneShotResult<Value>()
        register(id, waiter)
        if !cancellable { return try await waiter.awaitValue() }
        let value = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await waiter.awaitValue()
        }, onCancel: { self.cancel(id, waiter) })
        try Task.checkCancellation()
        return value
    }
}

struct PluginLifecycleDeadline: Sendable {
    private let end: TimeInterval

    init(seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else {
            throw PluginHostError.runtimeFailure("Maintenance timeout must be within (0, 86400] seconds")
        }
        end = ProcessInfo.processInfo.systemUptime + seconds
    }

    func remaining() throws -> TimeInterval {
        let value = end - ProcessInfo.processInfo.systemUptime
        guard value > 0 else { throw PluginHostError.timeout("settings maintenance") }
        return value
    }

    func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let seconds = try remaining()
        let result = PluginLifecycleSignal<Value>()
        let work = Task.detached {
            do { result.succeed(try await operation()) }
            catch { result.fail(bridgePluginError(error)) }
        }
        let timer = Task.detached {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            result.fail(.timeout("settings maintenance"))
        }
        defer { work.cancel(); timer.cancel() }
        return try await result.wait()
    }
}

/// Counts accepted host work, including callbacks still in a dispatcher's FIFO.
/// One reference is retained until the actual operation completes, not merely
/// until an awaited result's caller cancels its wait.
final class PluginHostActivity: @unchecked Sendable {
    let origin: UUID
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    init(origin: UUID, _ completion: @escaping @Sendable () -> Void) {
        self.origin = origin
        self.completion = completion
    }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func finish() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
    deinit { finish() }
}

final class PluginHostLifecycle: @unchecked Sendable {
    enum Stage: Equatable, Sendable { case preparing, quiescing, held, resuming, recovery }
    struct Snapshot: Sendable {
        let plugins: [Plugin]
        let wasRunning: Bool
        let resumeAllEnabled: Bool
    }
    struct Context: Sendable {
        let epoch: UUID
        var attempt: UUID
        var snapshot: Snapshot?
        var servicesStopped = false
        var managerPaused = false
    }
    enum StopDecision {
        case wait(PluginLifecycleSignal<Void>)
        case perform(Context?)
        case inProgress
        case finished
    }

    private let lock = NSLock()
    private let identity = UUID()
    private var operations = 0
    private var changes = PluginLifecycleSignal<Void>()
    private var context: Context?
    private var stage: Stage?
    private var control: UUID?
    private var stopRequested = false
    private var stopClaimed = false
    private var stopped = false

    func enter(callback: Bool = false) throws -> PluginHostActivity {
        lock.lock()
        guard !stopRequested else { lock.unlock(); throw PluginHostError.notRunning }
        guard context == nil || (callback && stage == .resuming) else {
            lock.unlock()
            throw PluginHostError.runtimeFailure("Plugin host admission is closed for settings maintenance")
        }
        operations += 1
        lock.unlock()
        return PluginHostActivity(origin: identity) { [weak self] in self?.leave() }
    }

    func owns(_ activity: PluginHostActivity) -> Bool { activity.origin == identity && activity.isActive }

    private func leave() {
        lock.lock()
        operations -= 1
        let signal = changes
        changes = PluginLifecycleSignal<Void>()
        lock.unlock()
        signal.succeed(())
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopRequested && context == nil
    }
    var permitsCallbacks: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopRequested && (context == nil || stage == .resuming)
    }
    var isMaintaining: Bool {
        lock.lock(); defer { lock.unlock() }
        // finish(true) has ended the file-mutation lease before fresh startup.
        // Its control reservation remains exclusive until startup completes.
        return context != nil && stage != .resuming && !stopped
    }
    var permitsNativeWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && (context == nil || stage == .resuming
            || (stage == .preparing && context?.managerPaused != true))
    }
    var permitsNativeCleanup: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && stage == .quiescing
    }

    func publishEventAdmission(_ body: (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(!stopRequested && context == nil)
    }

    func publishEffectAdmission(_ body: (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        // finish(true) ends the caller's file-mutation section before startup.
        // Only fresh active/loading owners can exist in this phase; preparation,
        // held leases and recovery never authorize an effect.
        body(!stopRequested && (context == nil || stage == .resuming))
    }

    func beginMaintenance() throws -> Context {
        lock.lock(); defer { lock.unlock() }
        guard !stopRequested, !stopped else { throw PluginHostError.notRunning }
        guard control == nil else {
            throw PluginHostError.runtimeFailure("Settings maintenance is already in progress")
        }
        var value = context ?? Context(epoch: UUID(), attempt: UUID())
        value.attempt = UUID()
        context = value
        stage = .preparing
        control = value.attempt
        return value
    }

    func check(_ attempt: UUID, allowStop: Bool = false) throws -> Context {
        lock.lock(); defer { lock.unlock() }
        guard let value = context, control == attempt, value.attempt == attempt else {
            throw PluginHostError.superseded("Settings maintenance lease expired")
        }
        guard allowStop || !stopRequested else { throw PluginHostError.notRunning }
        return value
    }

    private func idleStep(_ attempt: UUID) throws -> PluginLifecycleSignal<Void>? {
        lock.lock(); defer { lock.unlock() }
        guard control == attempt, !stopRequested else { throw PluginHostError.notRunning }
        return operations == 0 ? nil : changes
    }

    func waitUntilIdle(_ attempt: UUID) async throws {
        while let signal = try idleStep(attempt) { _ = try await signal.wait() }
    }

    func update(_ attempt: UUID, snapshot: Snapshot? = nil, servicesStopped: Bool? = nil,
                managerPaused: Bool? = nil, stage newStage: Stage? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard control == attempt, context?.attempt == attempt else {
            throw PluginHostError.superseded("Settings maintenance lease expired")
        }
        if let snapshot, context?.snapshot == nil { context?.snapshot = snapshot }
        if let servicesStopped { context?.servicesStopped = servicesStopped }
        if let managerPaused { context?.managerPaused = managerPaused }
        if let newStage { stage = newStage }
    }

    func hold(_ attempt: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard control == attempt, !stopRequested, operations == 0 else {
            throw PluginHostError.runtimeFailure("Settings maintenance did not quiesce the host")
        }
        stage = .held
    }

    func isBarrier(_ name: String) -> Bool {
        let prefix = "__host_maintenance_"
        // A cancelled attempt's queue waiter can complete later. Its private
        // barrier must never become a user app event after the next resume.
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    func beginFinish(_ attempt: UUID, resume: Bool) throws -> (Context, Bool) {
        lock.lock(); defer { lock.unlock() }
        guard control == attempt, let value = context, stage == .held else {
            throw PluginHostError.superseded("Settings maintenance lease is not held")
        }
        let resume = resume && !stopRequested
        if resume { stage = .resuming }
        return (value, resume)
    }

    /// On failure retain the original snapshot/manager epoch for a later retry.
    /// A new attempt gets a new capability; an old lease cannot finish that retry.
    func release(_ attempt: UUID, resume: Bool) {
        lock.lock()
        guard control == attempt else { lock.unlock(); return }
        control = nil
        if resume && !stopRequested { context = nil; stage = nil }
        else { stage = .recovery }
        let signal = changes
        changes = PluginLifecycleSignal<Void>()
        lock.unlock()
        signal.succeed(())
    }

    func requestStop() -> StopDecision {
        lock.lock()
        var oldSignal: PluginLifecycleSignal<Void>?
        if !stopRequested {
            oldSignal = changes
            stopRequested = true
            changes = PluginLifecycleSignal<Void>()
        }
        let decision: StopDecision
        if stopped { decision = .finished }
        else if stopClaimed { decision = .inProgress }
        else if control != nil { decision = .wait(changes) }
        else { stopClaimed = true; decision = .perform(context) }
        lock.unlock()
        oldSignal?.succeed(())
        return decision
    }

    func finishStop() {
        lock.lock()
        stopped = true
        context = nil
        stage = nil
        let signal = changes
        changes = PluginLifecycleSignal<Void>()
        lock.unlock()
        signal.succeed(())
    }
}

/// Tools holds this capability across snapshot/staging/commit/rollback. `false`
/// keeps admission blocked for recovery. Retry beginSettingsMaintenance to acquire
/// a fresh capability after recovery is possible. Finish is single-decision and
/// continues even if its caller stops awaiting it halfway through cleanup.
public actor PluginSettingsMaintenanceLease {
    private let finishBody: @Sendable (Bool) async throws -> Void
    private var decision: Bool?
    private var finishTask: Task<Void, Error>?

    init(finish: @escaping @Sendable (Bool) async throws -> Void) { finishBody = finish }

    public func finish(resume: Bool) async throws {
        if let decision, decision != resume {
            throw PluginHostError.superseded("Settings maintenance lease already has a finish outcome")
        }
        if let finishTask { return try await finishTask.value }
        decision = resume
        let body = finishBody
        let task = Task { try await body(resume) }
        finishTask = task
        try await task.value
    }
}
