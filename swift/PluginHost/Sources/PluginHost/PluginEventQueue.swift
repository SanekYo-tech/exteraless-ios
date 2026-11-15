import Foundation

/// Bounded event ingress and serial dispatch. Every path reserves count/bytes
/// before its actor hop. Drop-newest for observations; awaiting callers receive
/// eventQueueFull. Credits remain attached to retained/worker work after timeout.
public actor PluginEventQueue {
    public struct Stats: Equatable, Sendable {
        public var enqueued = 0
        public var dispatched = 0
        public var coalescedIntoBatches = 0
        public var droppedStale = 0
        public var droppedOverflow = 0
        public var timedOut = 0
        public var retainedCount = 0
        public var retainedBytes = 0
        public init() {}
    }

    public struct Limits: Sendable {
        public var dispatchTimeout: TimeInterval
        public var maxCoalescedPerKey: Int
        /// Includes pre-actor, queued, executing and still-retained terminal work.
        public var maxQueueDepth: Int
        public var maxQueueBytes: Int
        public init(dispatchTimeout: TimeInterval = 5, maxCoalescedPerKey: Int = 512,
                    maxQueueDepth: Int = 1024, maxQueueBytes: Int = 32 * 1024 * 1024) {
            self.dispatchTimeout = dispatchTimeout.isFinite ? max(0, min(86_400, dispatchTimeout)) : 5
            self.maxCoalescedPerKey = max(1, maxCoalescedPerKey)
            self.maxQueueDepth = max(1, maxQueueDepth)
            self.maxQueueBytes = max(1, maxQueueBytes)
        }
    }

    public typealias Handler = @Sendable (PluginEvent) async throws -> PluginEventResult
    public typealias TimeoutObserver = @Sendable (PluginEvent) async -> Void
    public typealias ControlledHandler = @Sendable (PluginEvent, PluginEventExecution) async throws -> PluginEventResult
    public typealias ControlledTimeoutObserver = @Sendable (PluginEvent, PluginEventExecution) async -> Void

    private final class Reply: @unchecked Sendable {
        let value = OneShotResult<PluginEventResult>()
    }
    private struct Envelope: Sendable {
        let event: PluginEvent
        let reply: Reply?
        let retention: PluginEventRetention
        let execution: PluginEventExecution
        var sequence: Int = 0
    }
    private struct Bucket {
        var items: [Envelope] = []
        var sequence = 0
    }

    nonisolated private let ingress = PluginEventIngress()
    private var handler: ControlledHandler?
    private var onTimeout: ControlledTimeoutObserver?
    private var limits = Limits()
    private var counters = Stats()
    private var stopped = false
    private var generation = UUID()
    private var uiSettings: [Envelope] = []
    private var sends: [Envelope] = []
    private var requests: [Envelope] = []
    private var coalesced: [CoalesceKey: Bucket] = [:]
    private var active: [UUID: (PluginEventExecution, Reply?)] = [:]
    private var nextSequence = 0
    private var loopTask: Task<Void, Never>?

    public var stats: Stats {
        var result = counters
        let retained = ingress.snapshot
        result.retainedCount = retained.count
        result.retainedBytes = retained.bytes
        result.droppedOverflow += retained.dropped
        return result
    }

    public func start(handler: @escaping Handler, onTimeout: @escaping TimeoutObserver = { _ in },
                      limits: Limits = Limits()) {
        startControlled(handler: { event, _ in try await handler(event) },
                        onTimeout: { event, _ in await onTimeout(event) }, limits: limits)
    }

    public func startControlled(handler: @escaping ControlledHandler,
                                onTimeout: @escaping ControlledTimeoutObserver = { _, _ in },
                                limits: Limits = Limits()) {
        self.handler = handler
        self.onTimeout = onTimeout
        self.limits = Limits(dispatchTimeout: limits.dispatchTimeout, maxCoalescedPerKey: limits.maxCoalescedPerKey,
                             maxQueueDepth: limits.maxQueueDepth, maxQueueBytes: limits.maxQueueBytes)
        ingress.configure(count: self.limits.maxQueueDepth, bytes: self.limits.maxQueueBytes)
        stopped = false
        ensureLoop()
    }

    public func stop() {
        stopped = true
        ingress.stop()
        generation = UUID()
        loopTask?.cancel()
        loopTask = nil
        for envelope in uiSettings + sends + requests + coalesced.values.flatMap(\.items) {
            envelope.execution.revoke(.queueStopped)
            envelope.reply?.value.fail(PluginHostError.queueStopped)
        }
        for (execution, reply) in active.values {
            execution.revoke(.queueStopped)
            reply?.value.fail(PluginHostError.queueStopped)
        }
        uiSettings.removeAll(); sends.removeAll(); requests.removeAll(); coalesced.removeAll()
        // Running handlers/mailboxes retain their own credits; stop cannot reset them.
    }

    @discardableResult
    public nonisolated func submit(_ event: PluginEvent) async -> Bool {
        guard let envelope = try? prepare(event, awaiting: false, shouldExecute: { true }) else { return false }
        await enqueue(envelope)
        return true
    }

    /// The reservation happens on the caller, before creating this Task.
    @discardableResult
    public nonisolated func submitAsync(_ event: PluginEvent) -> Bool {
        guard let envelope = try? prepare(event, awaiting: false, shouldExecute: { true }) else { return false }
        Task { await self.enqueue(envelope) }
        return true
    }

    public nonisolated func submitAwaiting(_ event: PluginEvent,
                                          shouldExecute: @escaping @Sendable () -> Bool = { true }) async throws -> PluginEventResult {
        try Task.checkCancellation()
        let envelope = try prepare(event, awaiting: true, shouldExecute: shouldExecute)
        guard let reply = envelope.reply else { throw PluginHostError.internalInconsistency("Missing event reply") }
        return try await withTaskCancellationHandler(operation: {
            await self.enqueue(envelope)
            let value = try await reply.value.awaitValue()
            try Task.checkCancellation()
            return value
        }, onCancel: {
            envelope.execution.revoke(.superseded("Event waiter cancelled"))
            reply.value.fail(CancellationError())
        })
    }

    private nonisolated func prepare(_ event: PluginEvent, awaiting: Bool,
                                     shouldExecute: @escaping @Sendable () -> Bool) throws -> Envelope {
        guard shouldExecute() else { throw PluginHostError.superseded("Native event execution expired") }
        let credit = try ingress.reserve(event, awaiting: awaiting)
        let retention = PluginEventRetention([credit])
        // TL's current adapter closes its isActive scope even after a successful
        // reply. That is not cancellation of already-valid effects. Native send
        // supplies a cancellation-only guard which remains meaningful afterwards.
        let followExternalAfterSuccess: Bool
        if case .tlTransform = event { followExternalAfterSuccess = false }
        else { followExternalAfterSuccess = true }
        let execution = PluginEventExecution(retention: retention, shouldExecute: shouldExecute,
                                             effectsFollowExternalAfterSuccess: followExternalAfterSuccess)
        return Envelope(event: event, reply: awaiting ? Reply() : nil, retention: retention, execution: execution)
    }

    private func enqueue(_ value: Envelope) {
        guard !stopped, value.retention.credits.allSatisfy({ ingress.isCurrent($0) }) else {
            value.execution.revoke(.queueStopped)
            value.reply?.value.fail(PluginHostError.queueStopped)
            return
        }
        guard value.execution.isValid else {
            value.reply?.value.fail(PluginHostError.superseded("Event cancelled before enqueue"))
            counters.droppedStale += 1
            return
        }
        var envelope = value
        envelope.sequence = nextSequence
        nextSequence += 1
        counters.enqueued += 1
        if case .createSettings(let incoming) = envelope.event, envelope.reply != nil,
           let index = uiSettings.firstIndex(where: {
               if case .createSettings(let old) = $0.event { return old.pluginId == incoming.pluginId }
               return false
           }) {
            let old = uiSettings.remove(at: index)
            old.execution.revoke(.superseded(incoming.pluginId))
            old.reply?.value.fail(PluginHostError.superseded(incoming.pluginId))
            counters.droppedStale += 1
        }
        // Awaited observations keep their individual result/cancellation channel.
        if envelope.reply == nil, let key = envelope.event.coalesceKey {
            var bucket = coalesced[key] ?? Bucket()
            if bucket.items.count == limits.maxCoalescedPerKey {
                let old = bucket.items.removeFirst()
                old.execution.revoke(.superseded("Coalesced bucket limit"))
                counters.droppedOverflow += 1
            }
            bucket.items.append(envelope)
            bucket.sequence = envelope.sequence
            coalesced[key] = bucket
        } else {
            switch envelope.event.priority {
            case .uiSettings: uiSettings.append(envelope)
            case .sendMessage: sends.append(envelope)
            case .request, .lifecycle, .updates: requests.append(envelope)
            }
        }
        ensureLoop()
    }

    private func ensureLoop() {
        guard loopTask == nil, handler != nil, !stopped else { return }
        let current = generation
        loopTask = Task { await self.runLoop(current) }
    }

    private func runLoop(_ current: UUID) async {
        while !stopped, generation == current, let envelope = popNext() { await dispatch(envelope) }
        if generation == current { loopTask = nil }
    }

    private func popNext() -> Envelope? {
        if !uiSettings.isEmpty { return uiSettings.removeFirst() }
        if !sends.isEmpty { return sends.removeFirst() }
        if let oldest = coalesced.min(by: { $0.value.sequence < $1.value.sequence }) {
            coalesced.removeValue(forKey: oldest.key)
            let items = oldest.value.items
            counters.coalescedIntoBatches += items.count
            let retention = PluginEventRetention(items.flatMap { $0.retention.credits })
            return Envelope(event: .coalescedUpdates(oldest.key, items.map(\.event)), reply: nil,
                            retention: retention, execution: PluginEventExecution(retention: retention, shouldExecute: { true }),
                            sequence: oldest.value.sequence)
        }
        if !requests.isEmpty { return requests.removeFirst() }
        return nil
    }

    private func dispatch(_ envelope: Envelope) async {
        guard let handler, envelope.execution.isValid else {
            envelope.reply?.value.fail(PluginHostError.superseded("Event dispatch expired"))
            return
        }
        let execution = envelope.execution
        active[execution.id] = (execution, envelope.reply)
        defer { active.removeValue(forKey: execution.id); execution.onInterruption(nil) }
        counters.dispatched += 1
        let outcome = PluginLifecycleSignal<PluginEventResult>()
        execution.onInterruption { outcome.fail($0) }
        let event = envelope.event
        let retention = envelope.retention
        let work = Task.detached {
            defer { withExtendedLifetime(retention) {} }
            do {
                try execution.check()
                let result = try await handler(event, execution)
                try execution.check()
                outcome.succeed(result)
            } catch { outcome.fail(bridgePluginError(error)) }
        }
        let timeout = limits.dispatchTimeout
        let timer: Task<Void, Never>? = timeout > 0 ? Task.detached { [weak execution] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }
            execution?.revoke(.timeout("event dispatch"), timeout: true)
        } : nil
        defer { timer?.cancel(); withExtendedLifetime(retention) {}; _ = work }
        do {
            let result = try await outcome.wait(cancellable: false)
            try execution.markSuccessful()
            envelope.reply?.value.succeed(result)
        } catch {
            let failure = bridgePluginError(error)
            execution.revoke(failure)
            if execution.didTimeOut {
                counters.timedOut += 1
                if let onTimeout { await onTimeout(event, execution) }
            }
            envelope.reply?.value.fail(failure)
        }
    }
}

// MARK: - Per-invocation timeout (native work is never forcibly terminated)

func withDispatchTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    if seconds <= 0 { return try await operation() }
    let outcome = OneShotResult<T>()
    let operationTask = Task.detached {
        do { outcome.succeed(try await operation()) }
        catch { outcome.fail(bridgePluginError(error)) }
    }
    let timerTask = Task.detached {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch { return }
        outcome.fail(DispatchTimeoutError())
    }
    defer { timerTask.cancel(); _ = operationTask }
    return try await outcome.awaitValue()
}

struct DispatchTimeoutError: Error, Sendable {}
