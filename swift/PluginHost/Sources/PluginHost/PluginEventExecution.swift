import Foundation

/// Cancellation/deadline authority, independent of TL causal ancestry.
final class PluginEventRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: PluginHostError?
    private let external: @Sendable () -> Bool
    private let effectsFollowExternalAfterSuccess: Bool
    private var succeeded = false

    init(external: @escaping @Sendable () -> Bool, effectsFollowExternalAfterSuccess: Bool = true) {
        self.external = external
        self.effectsFollowExternalAfterSuccess = effectsFollowExternalAfterSuccess
    }
    @discardableResult
    func revoke(_ error: PluginHostError) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return false }
        failure = error
        return true
    }
    var error: PluginHostError? {
        lock.lock(); let failure = self.failure; lock.unlock()
        return failure ?? (external() ? nil : .superseded("Native event execution expired"))
    }
    func markSuccessful() { lock.lock(); succeeded = true; lock.unlock() }
    var permitsEffect: Bool {
        lock.lock()
        let failure = self.failure
        let needsExternal = effectsFollowExternalAfterSuccess || !succeeded
        lock.unlock()
        return failure == nil && (!needsExternal || external())
    }
}

/// Captured at native-effect creation on the actual owner worker. Consumers must
/// compose this guard with their owner/account/permission lease. It retains only
/// revocation authority, not the original event's potentially large payload.
public enum PluginNativeExecutionContext {
    private static let key = "exteraless.native.event-execution"
    static func install(_ value: PluginEventRevocation?) {
        if let value { Thread.current.threadDictionary[key] = value }
        else { Thread.current.threadDictionary.removeObject(forKey: key) }
    }
    public static func captureGuard() -> @Sendable () -> Bool {
        let value = Thread.current.threadDictionary[key] as? PluginEventRevocation
        return { value?.permitsEffect ?? true }
    }
}

/// Exact event dispatch identity. A timeout revokes this batch, never a snapshot
/// of all host interpreters. Only jobs which entered their actual mailbox appear
/// in runningHandles; queued fanout is revoked without poisoning another job.
public final class PluginEventExecution: @unchecked Sendable {
    public let id = UUID()
    let revocation: PluginEventRevocation
    private let lock = NSLock()
    private var running: [UUID: InterpreterHandle] = [:]
    private var interruption: (@Sendable (PluginHostError) -> Void)?
    private var timeoutWon = false
    private var completed = false
    private weak var retention: PluginEventRetention?

    init(retention: PluginEventRetention, shouldExecute: @escaping @Sendable () -> Bool,
         effectsFollowExternalAfterSuccess: Bool = true) {
        self.retention = retention
        revocation = PluginEventRevocation(external: shouldExecute, effectsFollowExternalAfterSuccess: effectsFollowExternalAfterSuccess)
    }
    public var isValid: Bool { revocation.error == nil }
    public func check() throws { if let error = revocation.error { throw error } }
    func revoke(_ error: PluginHostError, timeout: Bool = false) {
        lock.lock()
        if timeout && completed { lock.unlock(); return }
        let won = revocation.revoke(error)
        if won { timeoutWon = timeout }
        let notify = won ? interruption : nil
        lock.unlock()
        notify?(error)
    }
    func onInterruption(_ body: (@Sendable (PluginHostError) -> Void)?) {
        lock.lock()
        interruption = body
        let error = revocation.error
        lock.unlock()
        if let error { body?(error) }
    }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timeoutWon }
    func markSuccessful() throws {
        lock.lock(); defer { lock.unlock() }
        try check()
        completed = true
        revocation.markSuccessful()
    }
    func retainPayload() -> PluginEventRetention? { retention }

    func start(_ invocation: UUID, handle: InterpreterHandle) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isValid else { return false }
        running[invocation] = handle
        return true
    }
    func finish(_ invocation: UUID) {
        lock.lock(); running.removeValue(forKey: invocation); lock.unlock()
    }
    var runningHandles: [InterpreterHandle] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(running.values))
    }
}

/// Lives through queued/native work, including the part outliving a timed-out
/// waiter. Its deinit only updates locked Swift accounting; it never calls Python.
final class PluginInvocationRetention: @unchecked Sendable {
    let id = UUID()
    let batch: PluginEventExecution?
    private let payload: PluginEventRetention?
    private let release: @Sendable () -> Void

    init(batch: PluginEventExecution?, release: @escaping @Sendable () -> Void) {
        self.batch = batch
        self.payload = batch?.retainPayload()
        self.release = release
    }
    func start(handle: InterpreterHandle) -> Bool { batch?.start(id, handle: handle) ?? true }
    func nativeFinished() { batch?.finish(id) }
    deinit { batch?.finish(id); release() }
}

final class PluginEventRetention: @unchecked Sendable {
    let credits: [PluginEventIngress.Credit]
    init(_ credits: [PluginEventIngress.Credit]) { self.credits = credits }
}

/// Synchronous admission before any actor/Task hop. A Credit is not returned on
/// timeout/cancel: it is returned when the last retained work reference dies.
final class PluginEventIngress: @unchecked Sendable {
    struct Snapshot: Sendable {
        let count: Int
        let bytes: Int
        let dropped: Int
    }
    final class Credit: @unchecked Sendable {
        let epoch: UUID
        private let ingress: PluginEventIngress
        private let count: Int
        private let bytes: Int
        private let tl: Bool
        init(ingress: PluginEventIngress, epoch: UUID, count: Int, bytes: Int, tl: Bool) {
            self.ingress = ingress; self.epoch = epoch; self.count = count; self.bytes = bytes; self.tl = tl
        }
        deinit { ingress.release(count: count, bytes: bytes, tl: tl) }
    }
    private let lock = NSLock()
    private var epoch = UUID()
    private var stopped = false
    private var awaitingAllowed = false
    private var maximumCount = 1024
    private var maximumBytes = 32 * 1024 * 1024
    private var count = 0
    private var bytes = 0
    private var tlCount = 0
    private var dropped = 0

    func configure(count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        maximumCount = max(1, count); maximumBytes = max(1, bytes)
        stopped = false; awaitingAllowed = true
    }
    func stop() {
        lock.lock(); stopped = true; awaitingAllowed = false; epoch = UUID(); lock.unlock()
    }
    func isCurrent(_ credit: Credit) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && credit.epoch == epoch
    }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(count: count, bytes: bytes, dropped: dropped)
    }
    func reserve(_ event: PluginEvent, awaiting: Bool) throws -> Credit {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !awaiting || awaitingAllowed else { throw PluginHostError.queueStopped }
        var units = 0
        var size = 0
        func add(_ amount: Int) throws {
            guard amount <= maximumBytes - size else { throw PluginHostError.eventQueueFull }
            size += amount
        }
        func text(_ value: String) throws { try add(value.utf8.count); try add(32) }
        func measure(_ event: PluginEvent, nesting: Int = 0) throws {
            guard nesting < 32, units < maximumCount else { throw PluginHostError.eventQueueFull }
            if case let .coalescedUpdates(key, items) = event {
                try text(key.container)
                guard !items.isEmpty else { units += 1; try add(128); return }
                for item in items { try measure(item, nesting: nesting + 1) }
                return
            }
            units += 1
            try add(128) // bounded envelope/array metadata, in addition to UTF-8 payloads
            switch event {
            case .appEvent(let p): try text(p.name)
            case .preRequest(let p): try text(p.requestName); try text(p.requestJSON)
            case .postRequest(let p):
                try text(p.requestName)
                if let value = p.responseJSON { try text(value) }
                if let value = p.errorMessage { try text(value) }
            case .update(let p): try text(p.updateName); try text(p.updateJSON)
            case .updates(let p):
                try text(p.containerName)
                for value in p.updatesJSON { try text(value) }
            case .sendMessage(let p): try text(p.paramsJSON)
            case .createSettings(let p): try text(p.pluginId)
            case .tlTransform(let p):
                try text(p.name); try text(p.canonicalName); try text(p.valueJSON); try text(p.metadataJSON)
                if let value = p.errorJSON { try text(value) }
                if let value = p.originRootId { try text(value) }
                for id in p.originPluginIds { try text(id) }
            case .coalescedUpdates: break
            }
        }
        let tl: Bool
        if case .tlTransform = event { tl = true } else { tl = false }
        do {
            try measure(event)
            guard units <= maximumCount - count, size <= maximumBytes - bytes,
                  !tl || tlCount < 256 else { throw PluginHostError.eventQueueFull }
        } catch {
            dropped += 1
            throw error
        }
        count += units; bytes += size
        if tl { tlCount += 1 }
        return Credit(ingress: self, epoch: epoch, count: units, bytes: size, tl: tl)
    }
    private func release(count: Int, bytes: Int, tl: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.count -= count; self.bytes -= bytes
        if tl { tlCount -= 1 }
    }
}
