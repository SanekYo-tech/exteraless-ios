import Foundation

public enum MapResourceError: String, Error, Sendable {
    case invalidRequest, unavailable, invalidImage, tooLarge, cancelled, configurationChanged, overloaded, timeout
}

public struct MapResourceData: Sendable {
    public let data: Data
    public let ttl: TimeInterval
    public init(data: Data, ttl: TimeInterval) { self.data = data; self.ttl = ttl.isFinite ? max(0, min(604800, ttl)) : 0 }
}

/// Bounded memory-only cache. Namespace is an account ID for message snapshots or
/// a view UUID for interactive tiles; a key can never cross those namespaces.
public final class MapResourceCache: @unchecked Sendable {
    public static let shared = MapResourceCache()
    public struct Key: Hashable, Sendable {
        public let namespace: String
        public let resource: String
        public init(namespace: String, resource: String) { self.namespace = namespace; self.resource = resource }
    }
    public typealias Completion = @Sendable (Result<MapResourceData, MapResourceError>) -> Void
    private struct Entry { let result: Result<MapResourceData, MapResourceError>; let expires: TimeInterval; let bytes: Int; let serial: UInt64 }
    private final class Flight {
        let id = UUID()
        var callbacks: [UUID: Completion] = [:]
        var token: NetworkResolverCancellation?
        var timeout: DispatchWorkItem?
        func cancel() { timeout?.cancel(); token?.cancel() }
    }
    private let queue = DispatchQueue(label: "Exteraless.MapCache", qos: .utility)
    private let now: @Sendable () -> TimeInterval
    private var entries: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private var serial: UInt64 = 0
    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    public func clear(namespace: String? = nil) {
        queue.async {
            self.entries = self.entries.filter { namespace != nil && $0.key.namespace != namespace }
            let removed = self.flights.filter { namespace == nil || $0.key.namespace == namespace }
            for (key, flight) in removed {
                self.flights.removeValue(forKey: key); flight.cancel()
                for callback in flight.callbacks.values { callback(.failure(.configurationChanged)) }
            }
        }
    }

    public func load(key: Key, start: @escaping @Sendable (@escaping Completion) -> NetworkResolverCancellation, completion: @escaping Completion) -> NetworkResolverCancellation {
        let id = UUID()
        let token = NetworkResolverCancellation { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard let flight = self.flights[key] else { return }
                flight.callbacks.removeValue(forKey: id)
                if flight.callbacks.isEmpty { self.flights.removeValue(forKey: key); flight.cancel() }
            }
        }
        queue.async {
            guard !token.isCancelled else { return }
            let callback: Completion = { result in if !token.isCancelled { completion(result) } }
            self.entries = self.entries.filter { $0.value.expires > self.now() }
            if let entry = self.entries[key] { callback(entry.result); return }
            if let flight = self.flights[key] { flight.callbacks[id] = callback; return }
            guard self.flights.count < 128 else { callback(.failure(.overloaded)); return }
            let flight = Flight(); flight.callbacks[id] = callback; self.flights[key] = flight
            let flightId = flight.id
            let timeout = DispatchWorkItem { [weak self] in self?.finish(key: key, id: flightId, result: .failure(.timeout)) }
            flight.timeout = timeout
            self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            flight.token = start { [weak self] result in
                guard let self else { return }
                self.queue.async { self.finish(key: key, id: flightId, result: result) }
            }
        }
        return token
    }

    private func finish(key: Key, id: UUID, result: Result<MapResourceData, MapResourceError>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights.removeValue(forKey: key); flight.cancel()
        var result = result
        if case let .success(resource) = result, resource.data.count > 4 * 1024 * 1024 { result = .failure(.tooLarge) }
        let size: Int, ttl: TimeInterval
        switch result {
        case let .success(resource): size = resource.data.count; ttl = resource.ttl
        case let .failure(error): size = 0; ttl = [.cancelled, .configurationChanged].contains(error) ? 0 : 2
        }
        if ttl > 0 {
            serial &+= 1
            entries[key] = Entry(result: result, expires: now() + ttl, bytes: size, serial: serial)
            while entries.count > 128 || entries.values.reduce(0, { $0 + $1.bytes }) > 8 * 1024 * 1024 {
                guard let oldest = entries.min(by: { $0.value.serial < $1.value.serial })?.key else { break }
                entries.removeValue(forKey: oldest)
            }
        }
        for callback in flight.callbacks.values { callback(result) }
    }
}
