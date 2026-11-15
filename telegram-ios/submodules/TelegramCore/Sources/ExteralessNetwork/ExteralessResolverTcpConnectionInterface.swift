import ExteralessCore
import Foundation
import MtProtoKit

/// Happy Eyeballs at the actual MTProto socket boundary: stagger ordered IPs by
/// 250 ms, at most two in flight, keep the winning connection, close every loser.
/// No probe connection is thrown away and re-opened. The existing native socket
/// implements partial reads, MTProto byte accounting and terminal-read ordering.
@available(iOS 15.0, macOS 14.0, *)
final class ExteralessResolverTcpConnectionInterface: NSObject, MTTcpConnectionInterface {
    typealias Factory = (MTTcpConnectionInterfaceDelegate, DispatchQueue) -> MTTcpConnectionInterface

    private final class Candidate: NSObject, MTTcpConnectionInterfaceDelegate {
        let id = UUID()
        weak var owner: ExteralessResolverTcpConnectionInterface?
        var socket: MTTcpConnectionInterface!
        func connectionInterfaceDidConnect() { owner?.connected(self) }
        func connectionInterfaceDidDisconnectWithError(_ error: Error?) { owner?.failed(self) }
        func connectionInterfaceDidReadPartialData(ofLength length: UInt, tag: Int) {
            guard let owner, owner.winner === self, !owner.closed else { return }
            owner.deliver { $0.connectionInterfaceDidReadPartialData(ofLength: length, tag: tag) }
        }
        func connectionInterfaceDidRead(_ data: Data, withTag tag: Int, networkType: Int32) {
            guard let owner, owner.winner === self, !owner.closed else { return }
            owner.deliver { $0.connectionInterfaceDidRead(data, withTag: tag, networkType: networkType) }
        }
        func close() { socket.resetDelegate(); socket.disconnect(); owner = nil }
    }

    private final class Delivery {
        let lock = NSLock()
        weak var delegate: MTTcpConnectionInterfaceDelegate?
        init(_ delegate: MTTcpConnectionInterfaceDelegate) { self.delegate = delegate }
        func get() -> MTTcpConnectionInterfaceDelegate? { lock.lock(); defer { lock.unlock() }; return delegate }
        func clear() { lock.lock(); delegate = nil; lock.unlock() }
    }

    private let queue = DispatchQueue(label: "Exteraless.MTProtoConnect", qos: .utility)
    private let delegateQueue: DispatchQueue
    private let delivery: Delivery
    private let resolver: NetworkResolver
    private let factory: Factory
    private var lookup: NetworkResolverCancellation?
    private var candidates: [UUID: Candidate] = [:]
    private var winner: Candidate?
    private var addresses: [NetworkIPAddress] = []
    private var nextIndex = 0
    private var started = false
    private var closed = false
    private var port: UInt16 = 0
    private var interface: String?
    private var deadline = 0.0
    private var stagger: DispatchWorkItem?
    private var watchdog: DispatchWorkItem?
    private var usage: MTNetworkUsageCalculationInfo?
    private var logPrefix: (() -> String)?
    private var writes: [Data] = []
    private var writeBytes = 0
    private var reads: [(UInt, TimeInterval, Int)] = []
    private var policyObserver: NSObjectProtocol?

    init(delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue, resolver: NetworkResolver, factory: Factory? = nil) {
        self.delegateQueue = delegateQueue
        self.delivery = Delivery(delegate)
        self.resolver = resolver
        self.factory = factory ?? { NetworkFrameworkTcpConnectionInterface(delegate: $0, delegateQueue: $1) }
        super.init()
        policyObserver = NotificationCenter.default.addObserver(forName: MTAppNetworkResolverDidChange, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { if self.started { self.close(error: Self.connectionError) } }
        }
    }

    deinit {
        if let policyObserver { NotificationCenter.default.removeObserver(policyObserver) }
        lookup?.cancel(); stagger?.cancel(); watchdog?.cancel()
        for candidate in candidates.values { candidate.close() }
        delivery.clear()
    }

    /// MTTcpConnection must preserve hostnames for this interface (shared hunk).
    /// A WEB carrier never implements this selector and keeps its no-DNS branch.
    @objc func resolvesHostnames() -> Bool { true }

    func setGetLogPrefix(_ getLogPrefix: (() -> String)?) { queue.async { self.logPrefix = getLogPrefix } }
    func setUsageCalculationInfo(_ info: MTNetworkUsageCalculationInfo?) {
        queue.async { self.usage = info; for candidate in self.candidates.values { candidate.socket.setUsageCalculationInfo(info) } }
    }

    func connect(toHost host: String, onPort port: UInt16, viaInterface interface: String?, withTimeout timeout: TimeInterval, error errPtr: NSErrorPointer) -> Bool {
        guard port != 0, timeout.isFinite, timeout > 0 else { errPtr?.pointee = Self.connectionError; return false }
        queue.async {
            guard !self.started, !self.closed else { return }
            self.started = true; self.port = port; self.interface = interface
            self.deadline = ProcessInfo.processInfo.systemUptime + min(20, timeout)
            let watchdog = DispatchWorkItem { [weak self] in self?.close(error: Self.connectionError) }
            self.watchdog = watchdog
            self.queue.asyncAfter(deadline: .now() + min(20, timeout), execute: watchdog)
            self.lookup = self.resolver.resolve(host: host) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard !self.closed else { return }
                    self.lookup = nil
                    switch result {
                    case let .success(addresses): self.addresses = addresses; self.startNext()
                    case .failure: self.close(error: Self.connectionError)
                    }
                }
            }
        }
        return true
    }

    private static var connectionError: NSError { NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost) }

    private func startNext() {
        guard !closed, winner == nil, candidates.count < 2, nextIndex < addresses.count else { return }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { close(error: Self.connectionError); return }
        let address = addresses[nextIndex]; nextIndex += 1
        let candidate = Candidate()
        candidate.owner = self
        candidate.socket = factory(candidate, queue)
        candidates[candidate.id] = candidate
        candidate.socket.setUsageCalculationInfo(usage)
        candidate.socket.setGetLogPrefix(logPrefix)
        var error: NSError?
        // When a name has more than two addresses, two blackholed candidates
        // must release their slots before the overall watchdog ends the race.
        let attemptTimeout = addresses.count > 2 ? min(4, remaining) : remaining
        if !candidate.socket.connect(toHost: address.string, onPort: port, viaInterface: interface, withTimeout: attemptTimeout, error: &error) || error != nil {
            failed(candidate)
        }
        stagger?.cancel()
        if nextIndex < addresses.count, winner == nil, candidates.count < 2 {
            let stagger = DispatchWorkItem { [weak self] in self?.startNext() }
            self.stagger = stagger
            queue.asyncAfter(deadline: .now() + 0.25, execute: stagger)
        }
    }

    private func connected(_ candidate: Candidate) {
        guard !closed, winner == nil, candidates[candidate.id] === candidate else { candidate.close(); return }
        winner = candidate
        stagger?.cancel(); stagger = nil
        watchdog?.cancel(); watchdog = nil
        for other in candidates.values where other !== candidate { other.close() }
        candidates = [candidate.id: candidate]
        deliver { $0.connectionInterfaceDidConnect() }
        let writes = self.writes, reads = self.reads
        self.writes.removeAll(); self.reads.removeAll(); writeBytes = 0
        for data in writes { candidate.socket.write(data) }
        for (length, timeout, tag) in reads { candidate.socket.readData(toLength: length, withTimeout: timeout, tag: tag) }
    }

    private func failed(_ candidate: Candidate) {
        guard !closed, candidates.removeValue(forKey: candidate.id) != nil else { return }
        candidate.close()
        if winner === candidate { close(error: Self.connectionError); return }
        if nextIndex < addresses.count { startNext() }
        else if candidates.isEmpty { close(error: Self.connectionError) }
    }

    func write(_ data: Data) {
        queue.async {
            guard !self.closed else { return }
            if let winner = self.winner { winner.socket.write(data) }
            else if data.count <= 4 * 1024 * 1024 - self.writeBytes { self.writes.append(data); self.writeBytes += data.count }
            else { self.close(error: Self.connectionError) }
        }
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        queue.async {
            guard !self.closed else { return }
            if let winner = self.winner { winner.socket.readData(toLength: length, withTimeout: timeout, tag: tag) }
            else if self.reads.count < 64 { self.reads.append((length, timeout, tag)) }
            else { self.close(error: Self.connectionError) }
        }
    }

    private func deliver(_ callback: @escaping (MTTcpConnectionInterfaceDelegate) -> Void) {
        let delivery = self.delivery
        delegateQueue.async { if let delegate = delivery.get() { callback(delegate) } }
    }

    private func close(error: NSError?) {
        guard !closed else { return }
        closed = true
        lookup?.cancel(); lookup = nil
        stagger?.cancel(); stagger = nil; watchdog?.cancel(); watchdog = nil
        for candidate in candidates.values { candidate.close() }
        candidates.removeAll(); winner = nil
        writes.removeAll(); reads.removeAll(); writeBytes = 0
        deliver { $0.connectionInterfaceDidDisconnectWithError(error) }
    }

    func disconnect() { queue.async { self.close(error: nil) } }
    func resetDelegate() { delivery.clear() }
}
