import Foundation

public final class PillCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var actions: [@Sendable () -> Void] = []
    public init(_ action: (@Sendable () -> Void)? = nil) { if let action { actions.append(action) } }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func add(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); action() } else { actions.append(action); lock.unlock() }
    }
    public func add(_ child: PillCancellation) { add { child.cancel() } }
    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = actions; actions.removeAll()
        lock.unlock()
        for action in pending { action() }
    }
    deinit { cancel() }
}

public struct PillRequestKey: Hashable, Sendable {
    public let scope: PillAccountScope
    public let domain: String
    public let selection: String
    public init(scope: PillAccountScope, domain: String, selection: String) {
        self.scope = scope; self.domain = domain; self.selection = selection
    }
}

/// One producer per immutable account generation / domain / selection. The last subscriber cancels it.
public final class PillRequestPool<Value: Sendable>: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<Value, PillError>) -> Void
    private final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: Completion?
        init(_ completion: @escaping Completion) { self.completion = completion }
        func cancel() { lock.lock(); completion = nil; lock.unlock() }
        func finish(_ value: Result<Value, PillError>) {
            lock.lock(); let completion = self.completion; self.completion = nil; lock.unlock()
            completion?(value)
        }
    }
    private final class Flight {
        let identity = UUID()
        var callbacks: [UUID: Callback] = [:]
        var work: PillCancellation?
    }
    private let lock = NSLock()
    private var flights: [PillRequestKey: Flight] = [:]
    public init() {}

    public func request(key: PillRequestKey, start: @escaping @Sendable (@escaping Completion) -> PillCancellation,
                        completion: @escaping Completion) -> PillCancellation {
        let id = UUID()
        let callback = Callback(completion)
        lock.lock()
        let existing = flights[key]
        let flight = existing ?? Flight()
        flight.callbacks[id] = callback
        flights[key] = flight
        let identity = flight.identity
        lock.unlock()
        let token = PillCancellation { [weak self, callback] in
            callback.cancel()
            self?.remove(key: key, identity: identity, id: id)
        }
        if existing == nil {
            let work = start { [weak self] result in self?.finish(key: key, identity: identity, result: result) }
            lock.lock()
            if flights[key]?.identity == identity {
                flights[key]?.work = work
                lock.unlock()
            } else {
                lock.unlock()
                work.cancel() // Also handles a producer that completes synchronously in start().
            }
        }
        return token
    }

    public func cancel(scope: PillAccountScope) {
        lock.lock()
        let removed = flights.filter { $0.key.scope == scope }
        for key in removed.keys { flights.removeValue(forKey: key) }
        lock.unlock()
        for flight in removed.values {
            for callback in flight.callbacks.values { callback.cancel() }
            flight.work?.cancel()
        }
    }

    private func remove(key: PillRequestKey, identity: UUID, id: UUID) {
        lock.lock()
        guard let flight = flights[key], flight.identity == identity else { lock.unlock(); return }
        flight.callbacks.removeValue(forKey: id)
        let empty = flight.callbacks.isEmpty
        if empty { flights.removeValue(forKey: key) }
        lock.unlock()
        if empty { flight.work?.cancel() }
    }
    private func finish(key: PillRequestKey, identity: UUID, result: Result<Value, PillError>) {
        lock.lock()
        guard let flight = flights[key], flight.identity == identity else { lock.unlock(); return }
        flights.removeValue(forKey: key)
        lock.unlock()
        for callback in flight.callbacks.values { callback.finish(result) }
    }
}
