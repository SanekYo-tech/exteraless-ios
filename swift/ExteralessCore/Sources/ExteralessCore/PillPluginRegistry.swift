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
    private var entries: [Int: Entry] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]
    public init() {}

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
        let delivery = PillPluginDelivery()
        worker.async { [weak self] in
            guard let self, lease.isValid, !token.isCancelled, self.contains(id: request.id, identity: entry.identity) else { return }
            let child = entry.provider.start(request) { [weak self] model in
                guard let self, lease.isValid, !token.isCancelled, model.id == request.id,
                      self.contains(id: request.id, identity: entry.identity), (try? model.validate()) != nil,
                      delivery.admit() else { return }
                update(model)
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

private final class PillPluginDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -Double.greatestFiniteMagnitude
    func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let time = ProcessInfo.processInfo.systemUptime
        guard time - last >= 0.25 else { return false }
        last = time
        return true
    }
}
