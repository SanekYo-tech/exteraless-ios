import Foundation

public protocol NetworkResolverSystemLookup: Sendable {
    func lookup(_ question: NetworkDNSQuestion, completion: @escaping @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void) -> NetworkResolverCancellation
}

public struct NetworkResolverState: Equatable, Sendable {
    public let epoch: UInt64
    public let mode: NetworkResolverConfiguration.Mode
    public let cachedQuestions: Int
    public let inFlightQuestions: Int
    public let nativeFallbacks: UInt64
    public let emptyCustomUsesDefaults: Bool
    public let blockedConfiguration: NetworkResolverError?
}

/// App-scoped, coalescing DNS. Only query data is cached, never an account context,
/// credential, URL, authorization header or request log. All state is queue-owned.
public final class NetworkResolver: @unchecked Sendable {
    private typealias Completion = @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void
    private struct Cached { let result: Result<NetworkDNSAnswer, NetworkResolverError>; let expires: TimeInterval; let used: UInt64 }
    private final class Flight {
        let id = UUID()
        let epoch: UInt64
        var waiters: [UUID: Completion] = [:]
        var operations: [NetworkResolverCancellation] = []
        var timer: DispatchWorkItem?
        var fallbackTimer: DispatchWorkItem?
        var providersRemaining = 0
        var negative: NetworkDNSAnswer?
        var nativeStarted = false
        init(epoch: UInt64) { self.epoch = epoch }
        func cancel() { timer?.cancel(); fallbackTimer?.cancel(); operations.forEach { $0.cancel() }; operations.removeAll() }
    }
    private let queue = DispatchQueue(label: "Exteraless.NetworkResolver", qos: .utility)
    private let delivery: DispatchQueue
    private let http: any NetworkResolverHTTPTransport
    private let system: any NetworkResolverSystemLookup
    private let now: @Sendable () -> TimeInterval
    private let timeout: TimeInterval
    private var configuration: NetworkResolverConfiguration
    private var blockedConfiguration: NetworkResolverError?
    private var route: NetworkResolverRoute = .unknown
    private var epoch: UInt64 = 1
    private var serial: UInt64 = 0
    private var nativeFallbacks: UInt64 = 0
    private var cache: [NetworkDNSQuestion: Cached] = [:]
    private var flights: [NetworkDNSQuestion: Flight] = [:]

    public init(configuration: NetworkResolverConfiguration, http: any NetworkResolverHTTPTransport, system: any NetworkResolverSystemLookup, timeout: TimeInterval = 5, deliveryQueue: DispatchQueue = .global(qos: .utility), now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration; self.http = http; self.system = system; self.delivery = deliveryQueue; self.now = now
        self.timeout = timeout.isFinite ? max(0.05, min(5, timeout)) : 5
    }

    public func update(configuration: NetworkResolverConfiguration, route: NetworkResolverRoute) {
        queue.sync {
            guard self.configuration != configuration || self.route != route || self.blockedConfiguration != nil else { return }
            self.configuration = configuration; self.route = route
            self.blockedConfiguration = nil
            self.invalidateOnQueue()
        }
    }

    /// Invalid persisted custom DNS at first launch must not become public/native
    /// DNS merely because no last-valid configuration exists in this process.
    public func rejectConfiguration(_ error: NetworkResolverError) {
        queue.sync {
            self.blockedConfiguration = error
            self.invalidateOnQueue()
        }
    }

    /// Call on route identity changes even when IPv4/IPv6 capabilities are equal.
    public func invalidate() { queue.sync { self.invalidateOnQueue() } }

    private func invalidateOnQueue() {
        epoch &+= 1
        cache.removeAll()
        let previous = flights; flights.removeAll()
        for flight in previous.values {
            flight.cancel()
            for callback in flight.waiters.values { delivery.async { callback(.failure(.configurationChanged)) } }
        }
    }

    public func state() -> NetworkResolverState {
        queue.sync {
            self.cache = self.cache.filter { $0.value.expires > self.now() }
            return NetworkResolverState(epoch: epoch, mode: configuration.mode, cachedQuestions: cache.count, inFlightQuestions: flights.count, nativeFallbacks: nativeFallbacks, emptyCustomUsesDefaults: configuration.emptyCustomUsesDefaults, blockedConfiguration: blockedConfiguration)
        }
    }

    /// Remaining native TTL for the Rust bridge's secondary cache. Zero means
    /// uncached; it must not substitute the backend's fixed five-minute lifetime.
    public func remainingTTL(host: String) -> TimeInterval {
        queue.sync {
            var expiries: [TimeInterval] = []
            for type in [NetworkDNSRecordType.a, .aaaa] {
                // An uncached (TTL=0) family must not inherit the other family's TTL.
                guard let key = try? NetworkDNSQuestion(name: host, type: type), let entry = cache[key] else { return 0 }
                expiries.append(max(0, entry.expires - now()))
            }
            return expiries.min() ?? 0
        }
    }

    public func resolve(host: String, completion: @escaping @Sendable (Result<[NetworkIPAddress], NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
        if let literal = NetworkIPAddress(host) {
            let token = NetworkResolverCancellation()
            delivery.async { if !token.isCancelled { completion(.success([literal])) } }
            return token
        }
        let name: String
        do { name = try NetworkDNSQuestion.canonicalName(host) } catch {
            delivery.async { completion(.failure(.invalidHostname)) }
            return NetworkResolverCancellation()
        }
        let options = queue.sync { (self.route, self.configuration.preferIPv6) }
        // Ask both families. On DNS64 paths the native AAAA fallback can synthesize
        // a route for an A-only name. The connect racer, not a random choice, wins.
        let join = NetworkResolverAddressJoin(route: options.0, preferIPv6: options.1, completion: completion)
        for type in [NetworkDNSRecordType.a, .aaaa] {
            guard let question = try? NetworkDNSQuestion(name: name, type: type) else { continue }
            join.add(lookup(question) { result in join.receive(result) })
        }
        return NetworkResolverCancellation { join.cancel() }
    }

    public func lookup(_ question: NetworkDNSQuestion, completion: @escaping @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
        let waiter = UUID()
        let token = NetworkResolverCancellation { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard let flight = self.flights[question] else { return }
                flight.waiters.removeValue(forKey: waiter)
                if flight.waiters.isEmpty { self.flights.removeValue(forKey: question); flight.cancel() }
            }
        }
        queue.async {
            guard !token.isCancelled else { return }
            if let error = self.blockedConfiguration {
                self.delivery.async { if !token.isCancelled { completion(.failure(error)) } }
                return
            }
            let requestEpoch = self.epoch
            let callback: Completion = { [weak self] result in
                guard !token.isCancelled, let self else { return }
                let current = self.queue.sync { self.epoch }
                completion(current == requestEpoch ? result : .failure(.configurationChanged))
            }
            if let cached = self.cache[question], cached.expires > self.now() {
                self.serial &+= 1
                self.cache[question] = Cached(result: cached.result, expires: cached.expires, used: self.serial)
                self.delivery.async { callback(cached.result) }; return
            }
            if let flight = self.flights[question] { flight.waiters[waiter] = callback; return }
            guard self.flights.count < 128 else { self.delivery.async { callback(.failure(.overloaded)) }; return }
            let flight = Flight(epoch: self.epoch)
            flight.waiters[waiter] = callback
            self.flights[question] = flight
            let id = flight.id
            let timer = DispatchWorkItem { [weak self] in self?.finish(question, id: id, result: .failure(.timeout)) }
            flight.timer = timer
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timer)
            if question.isLocalName || (!self.configuration.usesDoH && question.type != .txt) {
                self.startNative(question, flight: flight, isFallback: false)
            } else {
                // Stock bootstrap is DNS-JSON GET; explicit NagramX/custom uses
                // the original wire POST provider list. No Host header spoofing.
                let endpoints = self.configuration.usesDoH ? self.configuration.endpoints : ((try? NetworkDoHEndpoint("https://dns.google/resolve")).map { [$0] } ?? [])
                self.startProviders(question, flight: flight, endpoints: endpoints)
            }
        }
        return token
    }

    private func startProviders(_ question: NetworkDNSQuestion, flight: Flight, endpoints: [NetworkDoHEndpoint]) {
        flight.providersRemaining = endpoints.count
        let id = flight.id
        let phase = DispatchWorkItem { [weak self] in
            guard let self, let current = self.flights[question], current.id == id else { return }
            self.startNative(question, flight: current, isFallback: true)
        }
        flight.fallbackTimer = phase
        queue.asyncAfter(deadline: .now() + timeout * 0.7, execute: phase)
        for endpoint in endpoints {
            let operation = NetworkResolverProviderLookup(http: http, endpoint: endpoint, timeout: timeout * 0.7)
            flight.operations.append(operation.start(question) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard let current = self.flights[question], current.id == id else { return }
                    current.providersRemaining -= 1
                    if case let .success(answer) = result {
                        if answer.negative == nil { self.finish(question, id: id, result: .success(answer)); return }
                        current.negative = answer
                    }
                    if current.providersRemaining == 0 { self.startNative(question, flight: current, isFallback: true) }
                }
            })
        }
        if endpoints.isEmpty { startNative(question, flight: flight, isFallback: true) }
    }

    private func startNative(_ question: NetworkDNSQuestion, flight: Flight, isFallback: Bool) {
        guard !flight.nativeStarted else { return }
        flight.nativeStarted = true
        flight.fallbackTimer?.cancel()
        if isFallback { nativeFallbacks &+= 1 }
        let id = flight.id
        if question.type == .txt, !question.isLocalName, isFallback, configuration.usesDoH,
           let endpoint = try? NetworkDoHEndpoint("https://dns.google/resolve") {
            // Original DnsTxtLoadTask falls back to Google's DNS-JSON task.
            let operation = NetworkResolverProviderLookup(http: http, endpoint: endpoint, timeout: timeout * 0.3)
            flight.operations.append(operation.start(question) { [weak self] result in
                guard let self else { return }
                self.queue.async { self.finish(question, id: id, result: result) }
            })
            return
        }
        flight.operations.append(system.lookup(question) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard let current = self.flights[question], current.id == id else { return }
                if case .failure = result, let negative = current.negative { self.finish(question, id: id, result: .success(negative)) }
                else { self.finish(question, id: id, result: result) }
            }
        })
    }

    private func finish(_ question: NetworkDNSQuestion, id: UUID, result: Result<NetworkDNSAnswer, NetworkResolverError>) {
        guard let flight = flights[question], flight.id == id, flight.epoch == epoch else { return }
        flights.removeValue(forKey: question)
        flight.cancel()
        let ttl: TimeInterval
        switch result {
        case let .success(answer): ttl = answer.ttl
        case let .failure(error): ttl = [.cancelled, .configurationChanged, .overloaded].contains(error) ? 0 : 2
        }
        if ttl > 0 {
            if cache.count >= 256, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache.removeValue(forKey: oldest) }
            serial &+= 1
            cache[question] = Cached(result: result, expires: now() + ttl, used: serial)
        }
        for callback in flight.waiters.values { delivery.async { callback(result) } }
    }
}

private final class NetworkResolverAddressJoin: @unchecked Sendable {
    private let lock = NSLock()
    private let route: NetworkResolverRoute
    private let preferIPv6: Bool
    private var completion: (@Sendable (Result<[NetworkIPAddress], NetworkResolverError>) -> Void)?
    private var tokens: [NetworkResolverCancellation] = []
    private var addresses: [NetworkIPAddress] = []
    private var remaining = 2
    private var error = NetworkResolverError.noRecords
    init(route: NetworkResolverRoute, preferIPv6: Bool, completion: @escaping @Sendable (Result<[NetworkIPAddress], NetworkResolverError>) -> Void) {
        self.route = route; self.preferIPv6 = preferIPv6; self.completion = completion
    }
    func add(_ token: NetworkResolverCancellation) {
        lock.lock(); let active = completion != nil; if active { tokens.append(token) }; lock.unlock()
        if !active { token.cancel() }
    }
    func receive(_ result: Result<NetworkDNSAnswer, NetworkResolverError>) {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        if case let .failure(error) = result, error == .configurationChanged || error == .cancelled {
            let callback = completion, tokens = self.tokens
            completion = nil; self.tokens.removeAll(); addresses.removeAll()
            lock.unlock()
            tokens.forEach { $0.cancel() }; callback?(.failure(error))
            return
        }
        switch result {
        case let .success(answer): addresses += answer.addresses; if let negative = answer.negative { error = negative }
        case let .failure(value): error = value
        }
        remaining -= 1
        let callback = remaining == 0 ? completion : nil
        if remaining == 0 { completion = nil; tokens.removeAll() }
        let values = route.ordered(addresses, preferIPv6: preferIPv6), failure = error
        lock.unlock()
        callback?(values.isEmpty ? .failure(failure) : .success(values))
    }
    func cancel() {
        lock.lock(); completion = nil; let tokens = self.tokens; self.tokens.removeAll(); lock.unlock()
        tokens.forEach { $0.cancel() }
    }
}

private final class NetworkResolverProviderLookup: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Exteraless.DoHProvider", qos: .utility)
    private let http: any NetworkResolverHTTPTransport
    private let endpoint: NetworkDoHEndpoint
    private let timeout: TimeInterval
    private var completion: (@Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void)?
    private var request: NetworkResolverCancellation?
    private var seen = Set<String>()
    private var expiresAt = Double.greatestFiniteMagnitude
    private var deadline = 0.0
    init(http: any NetworkResolverHTTPTransport, endpoint: NetworkDoHEndpoint, timeout: TimeInterval) { self.http = http; self.endpoint = endpoint; self.timeout = timeout }
    func start(_ question: NetworkDNSQuestion, completion: @escaping @Sendable (Result<NetworkDNSAnswer, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
        queue.async { self.completion = completion; self.deadline = ProcessInfo.processInfo.systemUptime + self.timeout; self.next(question) }
        return NetworkResolverCancellation { self.queue.async { self.completion = nil; self.request?.cancel(); self.request = nil } }
    }
    private func next(_ question: NetworkDNSQuestion) {
        guard completion != nil else { return }
        guard seen.count < 8, seen.insert(question.name).inserted else { finish(.failure(.cnameLoop)); return }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { finish(.failure(.timeout)); return }
        let id = UInt16.random(in: UInt16.min...UInt16.max)
        do {
            let request = try NetworkDoHRequest.make(endpoint: endpoint, question: question, id: id, timeout: remaining)
            self.request = http.send(request) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard self.completion != nil else { return }
                    do {
                        let response = try result.get()
                        let answer = try NetworkDoHRequest.decode(response, endpoint: self.endpoint, question: question, id: id)
                        self.expiresAt = min(self.expiresAt, ProcessInfo.processInfo.systemUptime + answer.ttl)
                        if answer.records.isEmpty, answer.negative == nil, answer.canonicalName != question.name {
                            self.next(try NetworkDNSQuestion(name: answer.canonicalName, type: question.type))
                        } else {
                            self.finish(.success(.init(records: answer.records, canonicalName: answer.canonicalName, ttl: max(0, self.expiresAt - ProcessInfo.processInfo.systemUptime), negative: answer.negative)))
                        }
                    } catch { self.finish(.failure(error as? NetworkResolverError ?? .malformedResponse)) }
                }
            }
        } catch { finish(.failure(error as? NetworkResolverError ?? .invalidEndpoint)) }
    }
    private func finish(_ result: Result<NetworkDNSAnswer, NetworkResolverError>) {
        let callback = completion; completion = nil; request = nil; callback?(result)
    }
}
