import Foundation

/// Published client data, not a synchronous Postbox accessor. A missing value is
/// explicitly not ready; it never proves that a Telegram user does not exist.
public final class NativeServiceSnapshots: @unchecked Sendable {
    public struct Scope: Hashable, Sendable {
        public let recordId: Int64
        public let generation: UUID
        public let userId: Int64
    }
    public struct Peer: Hashable, Sendable {
        public enum Kind: String, Sendable { case user, group, channel }
        public let kind: Kind
        public let id: Int64
        public init(kind: Kind, id: Int64) throws {
            guard id > 0, id <= 0x00ff_ffff_ffff_ffff else { throw BridgeFailure.malformed("Invalid cached peer id") }
            self.kind = kind
            self.id = id
        }
        public var key: String { "\(kind.rawValue):\(id)" }
    }
    public struct Publisher: Hashable, Sendable {
        public let scope: Scope
        public let peer: Peer
        public let generation: UUID
    }
    public struct Reservation: Sendable {
        public let publisher: Publisher
        public let start: Bool
        public let evicted: [Publisher]
    }
    private struct Value {
        let value: PluginJSONValue
        let source: String
        let bytes: Int
    }
    private struct PeerEntry {
        let publisher: Publisher
        var pinned: Bool
        var touched: UInt64
        var observed = false
    }
    private struct Account {
        let scope: Scope
        var peers: [Peer: PeerEntry] = [:]
        var values: [String: Value] = [:]
        var revision: UInt64 = 0
    }
    private let lock = NSLock()
    private let peerLimit: Int
    private let byteLimit: Int
    private var bytes = 0
    private var clock: UInt64 = 0
    private var accounts: [Int64: Account] = [:]

    public init(peerLimit: Int = 256, byteLimit: Int = 33_554_432) {
        self.peerLimit = max(1, min(256, peerLimit))
        self.byteLimit = max(1, min(33_554_432, byteLimit))
    }

    public func begin(recordId: Int64, userId: Int64) -> Scope {
        lock.lock(); defer { lock.unlock() }
        if let old = accounts.removeValue(forKey: recordId) { bytes -= old.values.values.reduce(0) { $0 + $1.bytes } }
        let scope = Scope(recordId: recordId, generation: UUID(), userId: userId)
        accounts[recordId] = Account(scope: scope)
        return scope
    }

    public func end(_ scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        guard accounts[scope.recordId]?.scope == scope, let old = accounts.removeValue(forKey: scope.recordId) else { return }
        bytes -= old.values.values.reduce(0) { $0 + $1.bytes }
    }

    public func scope(recordId: Int64) -> Scope? {
        lock.lock(); defer { lock.unlock() }
        return accounts[recordId]?.scope
    }

    public func isCurrent(_ scope: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return accounts[scope.recordId]?.scope == scope
    }

    public func isCurrent(_ publisher: Publisher) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return accounts[publisher.scope.recordId]?.peers[publisher.peer]?.publisher == publisher
    }

    public func pin(_ peers: Set<Peer>, scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        guard var account = accounts[scope.recordId], account.scope == scope else { return }
        for key in Array(account.peers.keys) { account.peers[key]?.pinned = peers.contains(key) }
        accounts[scope.recordId] = account
    }

    /// A new publication token also protects against eviction/re-reference of the
    /// same peer while a previous asynchronous view is still finishing.
    public func reference(_ peer: Peer, scope: Scope, pinned: Bool = false) -> Reservation? {
        lock.lock(); defer { lock.unlock() }
        guard var account = accounts[scope.recordId], account.scope == scope else { return nil }
        clock &+= 1
        if var entry = account.peers[peer] {
            entry.touched = clock
            entry.pinned = entry.pinned || pinned
            account.peers[peer] = entry
            accounts[scope.recordId] = account
            return Reservation(publisher: entry.publisher, start: false, evicted: [])
        }
        var evicted: [Publisher] = []
        if account.peers.count >= peerLimit {
            guard let victim = account.peers.values.filter({ !$0.pinned }).min(by: { $0.touched < $1.touched }) else { return nil }
            account.peers.removeValue(forKey: victim.publisher.peer)
            evicted.append(victim.publisher)
            for key in [victim.publisher.peer.key, "full:" + victim.publisher.peer.key] {
                if let value = account.values.removeValue(forKey: key) { bytes -= value.bytes }
            }
        }
        let publisher = Publisher(scope: scope, peer: peer, generation: UUID())
        account.peers[peer] = PeerEntry(publisher: publisher, pinned: pinned, touched: clock)
        accounts[scope.recordId] = account
        return Reservation(publisher: publisher, start: true, evicted: evicted)
    }

    @discardableResult
    public func publishPeer(_ value: PluginJSONValue, full: Bool = false, publisher: Publisher, source: String) throws -> Bool {
        return try publish(value, key: (full ? "full:" : "") + publisher.peer.key, scope: publisher.scope,
            source: source, publisher: publisher)
    }

    @discardableResult
    public func publish(_ value: PluginJSONValue, key: String, scope: Scope, source: String,
                        publisher: Publisher? = nil) throws -> Bool {
        let size: Int
        if value == .null { size = 0 } else { size = try NativeServiceWire.json(value).utf8.count }
        lock.lock(); defer { lock.unlock() }
        guard var account = accounts[scope.recordId], account.scope == scope else { return false }
        if let publisher, account.peers[publisher.peer]?.publisher != publisher { return false }
        if let publisher, key == publisher.peer.key { account.peers[publisher.peer]?.observed = true }
        let oldBytes = account.values[key]?.bytes ?? 0
        guard bytes - oldBytes + size <= byteLimit else { throw BridgeFailure.unavailable("Native ready-snapshot byte budget exhausted") }
        bytes = bytes - oldBytes + size
        // A local peer/full-info cache miss is unknown, not a fabricated deletion.
        if value == .null { account.values.removeValue(forKey: key) }
        else { account.values[key] = Value(value: value, source: source, bytes: size) }
        account.revision &+= 1
        accounts[scope.recordId] = account
        return true
    }

    public func read(key: String, scope: Scope, kind: String) -> PluginJSONValue {
        lock.lock(); defer { lock.unlock() }
        guard let account = accounts[scope.recordId], account.scope == scope else { return Self.notReady(kind) }
        guard let value = account.values[key] else { return Self.notReady(kind, generation: scope.generation) }
        return .object(["ready": .bool(true), "kind": .string(kind), "value": value.value,
            "source": .string(value.source), "generation": .string(scope.generation.uuidString),
            "revision": .unsignedInteger(account.revision)])
    }

    public func readyValue(key: String, scope: Scope) -> PluginJSONValue? {
        lock.lock(); defer { lock.unlock() }
        guard let account = accounts[scope.recordId], account.scope == scope else { return nil }
        return account.values[key]?.value
    }

    public func wasObserved(_ peer: Peer, scope: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return accounts[scope.recordId]?.scope == scope && accounts[scope.recordId]?.peers[peer]?.observed == true
    }

    public func forget(_ publisher: Publisher) {
        lock.lock(); defer { lock.unlock() }
        guard var account = accounts[publisher.scope.recordId], account.peers[publisher.peer]?.publisher == publisher else { return }
        account.peers.removeValue(forKey: publisher.peer)
        for key in [publisher.peer.key, "full:" + publisher.peer.key] {
            if let value = account.values.removeValue(forKey: key) { bytes -= value.bytes }
        }
        accounts[publisher.scope.recordId] = account
    }

    public static func notReady(_ kind: String, generation: UUID? = nil) -> PluginJSONValue {
        var value: [String: PluginJSONValue] = ["ready": .bool(false), "kind": .string(kind), "value": .null]
        if let generation { value["generation"] = .string(generation.uuidString) }
        return .object(value)
    }

    public var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    public func peerCount(scope: Scope) -> Int {
        lock.lock(); defer { lock.unlock() }
        return accounts[scope.recordId]?.scope == scope ? accounts[scope.recordId]?.peers.count ?? 0 : 0
    }

    public func publishers(scope: Scope) -> [Publisher] {
        lock.lock(); defer { lock.unlock() }
        guard let account = accounts[scope.recordId], account.scope == scope else { return [] }
        return account.peers.values.map(\.publisher)
    }
}
