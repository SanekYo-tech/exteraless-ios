import Foundation

public struct PillPluginOwner: Hashable, Sendable {
    public let pluginId: String
    public let generation: UUID
    public init(pluginId: String, generation: UUID) { self.pluginId = pluginId; self.generation = generation }
}

public struct PillPluginRequest: Sendable {
    public let id: Int
    public let scope: PillAccountScope
    public init(id: Int, scope: PillAccountScope) { self.id = id; self.scope = scope }
}

public enum PillPluginAction: String, Sendable { case refresh, tap, longPress }

/// Called on a utility worker. SDK adapters enqueue owner-bound callbacks and return a cancellation lease.
/// start's lease owns selected/visible lifetime; cancelling it releases callbacks without calling retired Python.
public protocol PillPluginProvider: Sendable {
    func start(_ request: PillPluginRequest, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation
    func perform(_ action: PillPluginAction, request: PillPluginRequest)
}

public final class PillPluginRegistry: @unchecked Sendable {
    public static let shared = PillPluginRegistry()
    private final class Entry: @unchecked Sendable {
        let identity = UUID()
        let owner: PillPluginOwner
        let descriptor: PillDescriptor
        let provider: any PillPluginProvider
        var subscriptions: [UUID: PillCancellation] = [:]
        init(owner: PillPluginOwner, descriptor: PillDescriptor, provider: any PillPluginProvider) {
            self.owner = owner; self.descriptor = descriptor; self.provider = provider
        }
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "Exteraless.Pills.Plugins", qos: .utility)
    private let deliveryTiming: PillPluginDeliveryTiming
    private var entries: [Int: Entry] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]
    public convenience init() { self.init(deliveryTiming: .live) }
    init(deliveryTiming: PillPluginDeliveryTiming) { self.deliveryTiming = deliveryTiming }

    public var descriptors: [PillDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.descriptor).sorted { $0.id < $1.id }
    }
    public func observe(_ callback: @escaping @Sendable () -> Void) -> PillCancellation {
        let id = UUID()
        lock.lock(); observers[id] = callback; lock.unlock()
        return PillCancellation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.observers.removeValue(forKey: id); self.lock.unlock()
        }
    }
    /// Built-in and dynamic rate IDs cannot be replaced. The SDK maps its IDs into this portable namespace.
    public func register(owner: PillPluginOwner, descriptor: PillDescriptor, provider: any PillPluginProvider) throws -> PillCancellation {
        guard descriptor.id >= 10_000, descriptor.id <= Int(Int32.max), !descriptor.title.isEmpty, descriptor.title.count <= 128,
              descriptor.symbol.count <= 128, descriptor.interval.isFinite, descriptor.interval >= 5, descriptor.interval <= 3600,
              descriptor.pair == nil, !owner.pluginId.isEmpty else { throw PillError.invalidConfiguration }
        let entry = Entry(owner: owner, descriptor: descriptor, provider: provider)
        lock.lock()
        guard entries.count < 64, entries[descriptor.id] == nil else { lock.unlock(); throw PillError.invalidConfiguration }
        entries[descriptor.id] = entry
        let callbacks = Array(observers.values)
        lock.unlock()
        for callback in callbacks { callback() }
        return PillCancellation { [weak self] in self?.remove(id: descriptor.id, identity: entry.identity) }
    }
    public func unregister(owner: PillPluginOwner) {
        lock.lock(); let owned = entries.filter { $0.value.owner == owner }.map { ($0.key, $0.value.identity) }; lock.unlock()
        for (id, identity) in owned { remove(id: id, identity: identity) }
    }
    private func remove(id: Int, identity: UUID) {
        lock.lock()
        guard let entry = entries[id], entry.identity == identity else { lock.unlock(); return }
        entries.removeValue(forKey: id)
        let tokens = Array(entry.subscriptions.values); entry.subscriptions.removeAll()
        let callbacks = Array(observers.values)
        lock.unlock()
        for token in tokens { token.cancel() }
        for callback in callbacks { callback() }
    }
    private func contains(id: Int, identity: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return entries[id]?.identity == identity }

    public func subscribe(_ request: PillPluginRequest, lease: PillAccountLease, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation {
        let token = PillCancellation()
        guard request.scope == lease.scope, lease.isValid else { token.cancel(); return token }
        let subscriptionId = UUID()
        lock.lock()
        guard let entry = entries[request.id] else { lock.unlock(); token.cancel(); return token }
        entry.subscriptions[subscriptionId] = token
        lock.unlock()
        token.add { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.lock.lock(); entry.subscriptions.removeValue(forKey: subscriptionId); self.lock.unlock()
        }
        let identity = entry.identity
        let delivery = PillPluginDelivery(timing: self.deliveryTiming, current: { [weak self] in
            guard let self else { return false }
            return lease.isValid && !token.isCancelled && self.contains(id: request.id, identity: identity)
        }, update: update)
        token.add { delivery.cancel() }
        worker.async { [weak self] in
            guard let self, lease.isValid, !token.isCancelled, self.contains(id: request.id, identity: entry.identity) else { return }
            let child = entry.provider.start(request) { model in
                guard model.id == request.id, (try? model.validate()) != nil else { return }
                delivery.submit(model)
            }
            // Some SDK implementations require release on their own worker; cancellation stays off render/main.
            token.add { self.worker.async { child.cancel() } }
        }
        // The registry retains its inner token for unload; the caller owns this outer lease.
        return PillCancellation { token.cancel() }
    }
    public func perform(_ action: PillPluginAction, request: PillPluginRequest, lease: PillAccountLease) {
        guard request.scope == lease.scope, lease.isValid else { return }
        lock.lock(); let entry = entries[request.id]; lock.unlock()
        guard let entry else { return }
        worker.async { [weak self] in
            guard let self, lease.isValid, self.contains(id: request.id, identity: entry.identity) else { return }
            entry.provider.perform(action, request: request)
        }
    }
}

/// Internal timing seam lets the native-provider regression exercise the exact 250ms deadline.
/// A scheduler must enqueue its callback, never invoke it inline while scheduling.
struct PillPluginDeliveryTiming: Sendable {
    let now: @Sendable () -> UInt64
    let schedule: @Sendable (UInt64, @escaping @Sendable () -> Void) -> PillCancellation
    private static let queue = DispatchQueue(label: "Exteraless.Pills.PluginDelivery", qos: .utility)
    static let live = PillPluginDeliveryTiming(now: { DispatchTime.now().uptimeNanoseconds }, schedule: { deadline, callback in
        let work = PillPluginScheduledDelivery(callback)
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work.item)
        return PillCancellation { work.item.cancel() }
    })
}

private final class PillPluginScheduledDelivery: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ callback: @escaping @Sendable () -> Void) { self.item = DispatchWorkItem(block: callback) }
}

/// One latest pending model and one trailing timer per subscription. No phase bypasses 4Hz.
private final class PillPluginDelivery: @unchecked Sendable {
    private static let interval: UInt64 = 250_000_000
    private let lock = NSLock()
    private let timing: PillPluginDeliveryTiming
    private var current: (@Sendable () -> Bool)?
    private var update: (@Sendable (PillModel) -> Void)?
    private var latest: PillModel?
    private var last: UInt64?
    private var delivering = false
    private var cancelled = false
    private var timer: PillCancellation?
    private var timerId: UUID?

    init(timing: PillPluginDeliveryTiming, current: @escaping @Sendable () -> Bool, update: @escaping @Sendable (PillModel) -> Void) {
        self.timing = timing; self.current = current; self.update = update
    }
    private func isCurrent() -> Bool {
        self.lock.lock(); let current = self.current; self.lock.unlock()
        // Account/registry locks must not be acquired under the delivery lock.
        return current?() == true
    }
    func submit(_ model: PillModel) {
        guard self.isCurrent() else { self.cancel(); return }
        self.lock.lock()
        guard !self.cancelled else { self.lock.unlock(); return }
        self.latest = model
        guard !self.delivering, self.timerId == nil else { self.lock.unlock(); return }
        let now = self.timing.now()
        if let deadline = self.nextDeadline(), deadline > now {
            self.scheduleLocked(deadline)
            self.lock.unlock()
        } else {
            self.latest = nil; self.delivering = true
            self.lock.unlock()
            self.deliver(model)
        }
    }
    private func nextDeadline() -> UInt64? {
        guard let last else { return nil }
        let sum = last.addingReportingOverflow(Self.interval)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
    private func scheduleLocked(_ deadline: UInt64) {
        let id = UUID()
        self.timerId = id
        self.timer = self.timing.schedule(deadline) { [weak self] in self?.fire(id) }
    }
    private func fire(_ id: UUID) {
        self.lock.lock()
        guard !self.cancelled, self.timerId == id else { self.lock.unlock(); return }
        let timer = self.timer
        defer { timer?.cancel() }
        self.timer = nil; self.timerId = nil
        let now = self.timing.now()
        if let deadline = self.nextDeadline(), deadline > now {
            self.scheduleLocked(deadline)
            self.lock.unlock()
            return
        }
        guard let model = self.latest else { self.lock.unlock(); return }
        self.latest = nil; self.delivering = true
        self.lock.unlock()
        self.deliver(model)
    }
    private func deliver(_ model: PillModel) {
        guard self.isCurrent() else { self.cancel(); return }
        self.lock.lock()
        guard !self.cancelled, let update = self.update else { self.lock.unlock(); return }
        self.last = self.timing.now()
        self.lock.unlock()
        update(model)
        self.lock.lock()
        self.delivering = false
        if !self.cancelled, self.latest != nil, self.timerId == nil {
            self.scheduleLocked(max(self.timing.now(), self.nextDeadline() ?? self.timing.now()))
        }
        self.lock.unlock()
    }
    func cancel() {
        self.lock.lock()
        let retained = (self.current, self.update, self.latest)
        self.cancelled = true; self.latest = nil; self.current = nil; self.update = nil
        self.timerId = nil
        let timer = self.timer; self.timer = nil
        self.lock.unlock()
        // Releasing a client closure or cancelling a scheduler can run deinit/client code.
        withExtendedLifetime(retained) { timer?.cancel() }
    }
}
