import Foundation

/// A receipt frontier is peer/namespace scoped, never a maximum across a mixed feed.
/// This model contains no message text or media and does not persist a second read database.
public struct FeedUnreadTracker: Sendable {
    public struct Peer: Hashable, Sendable {
        public let id: Int64
        public let namespace: Int32

        public init(id: Int64, namespace: Int32 = 0) {
            self.id = id
            self.namespace = namespace
        }

        fileprivate init(_ id: ChatFeedIdentity) {
            self.init(id: id.peerId, namespace: id.namespace)
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let peer: Peer
        public let maxReadId: Int32
        public let unreadCount: Int

        public init(peer: Peer, maxReadId: Int32, unreadCount: Int) {
            self.peer = peer
            self.maxReadId = max(0, maxReadId)
            self.unreadCount = max(0, unreadCount)
        }
    }

    public struct Batch: Equatable, Sendable {
        public let accountId: Int64
        public let generation: UInt64
        public let sequence: UInt64
        public let positions: [ChatFeedPosition]
    }

    public let accountId: Int64
    public private(set) var generation: UInt64 = 0
    public private(set) var due: TimeInterval?
    public private(set) var isActive = true
    private var sequence: UInt64 = 0
    private var included: Set<Peer> = []
    private var snapshots: [Peer: Snapshot] = [:]
    private var pending: [Peer: ChatFeedPosition] = [:]
    private var submitted: [Peer: Int32] = [:]
    private var batches: [UInt64: Batch] = [:]

    public init(accountId: Int64) { self.accountId = accountId }

    public mutating func update(included: Set<Peer>, snapshots: [Snapshot]) {
        self.included = included
        self.snapshots = self.snapshots.filter { included.contains($0.key) }
        self.pending = self.pending.filter { included.contains($0.key) }
        self.submitted = self.submitted.filter { included.contains($0.key) }
        for snapshot in snapshots where included.contains(snapshot.peer) {
            // A read arriving from another device may advance the frontier. A queued older
            // snapshot must not resurrect unread rows after our local transaction completed.
            self.snapshots[snapshot.peer] = snapshot
            if snapshot.maxReadId >= (self.submitted[snapshot.peer] ?? 0) {
                self.submitted.removeValue(forKey: snapshot.peer)
            }
            if let position = self.pending[snapshot.peer], position.identity.messageId <= snapshot.maxReadId {
                self.pending.removeValue(forKey: snapshot.peer)
            }
        }
        if self.pending.isEmpty { self.due = nil }
    }

    public func isUnread(_ id: ChatFeedIdentity) -> Bool {
        let peer = Peer(id)
        guard self.included.contains(peer), self.snapshots[peer] != nil else { return false }
        return id.messageId > self.effectiveReadId(peer)
    }

    /// Exact chat-list counters, until the local native read transaction publishes its update.
    /// Do not guess countDiff from numeric IDs: IDs contain holes and service messages.
    public var unreadCount: Int {
        return self.snapshots.values.reduce(0) { total, snapshot in
            let (sum, overflow) = total.addingReportingOverflow(snapshot.unreadCount)
            return overflow ? Int.max : sum
        }
    }

    public func oldestUnreadIndex(in entries: [ChatFeedEntry]) -> Int? {
        return entries.indices.reversed().first { self.isUnread(entries[$0].identity) }
    }

    public func countUnread(in entries: ArraySlice<ChatFeedEntry>) -> Int {
        return entries.reduce(0) { $0 + (self.isUnread($1.identity) ? 1 : 0) }
    }

    /// Only a fully displayed native post (or a post taller than the viewport) is admitted.
    /// The UI additionally gates foreground, overlays and the initial scroll restoration.
    @discardableResult
    public mutating func seen(_ position: ChatFeedPosition, now: TimeInterval) -> Bool {
        let peer = Peer(position.identity)
        guard self.isActive, self.included.contains(peer), self.snapshots[peer] != nil,
              position.identity.messageId > 0, position.identity.messageId > self.effectiveReadId(peer) else { return false }
        self.pending[peer] = position
        if self.due == nil { self.due = now + 1.0 }
        return true
    }

    /// Bound work per flush. The next batch is still due; sustained scrolling cannot
    /// postpone the first batch forever. Dispatch must capture this batch's account engine.
    public mutating func takeBatch(now: TimeInterval, force: Bool = false, limit: Int = 32) -> Batch? {
        guard self.isActive, self.batches.isEmpty, limit > 0, !self.pending.isEmpty,
              force || self.due.map({ now >= $0 }) == true else { return nil }
        let positions = self.pending.values.sorted { $0.identity.peerId < $1.identity.peerId }.prefix(limit)
        self.sequence &+= 1
        let batch = Batch(accountId: self.accountId, generation: self.generation, sequence: self.sequence, positions: Array(positions))
        for position in positions { self.pending.removeValue(forKey: Peer(position.identity)) }
        self.batches[batch.sequence] = batch
        self.due = self.pending.isEmpty ? nil : now
        return batch
    }

    @discardableResult
    public mutating func complete(_ batch: Batch, applied: Set<ChatFeedIdentity>, now: TimeInterval) -> Bool {
        guard self.isActive, batch.accountId == self.accountId, batch.generation == self.generation,
              self.batches.removeValue(forKey: batch.sequence) == batch else { return false }
        for position in batch.positions {
            let peer = Peer(position.identity)
            guard self.included.contains(peer) else { continue }
            if applied.contains(position.identity) {
                self.submitted[peer] = max(self.submitted[peer] ?? 0, position.identity.messageId)
            } else if position.identity.messageId > self.effectiveReadId(peer) {
                self.pending[peer] = position
            }
        }
        if !self.pending.isEmpty { self.due = now + 1.0 }
        return true
    }

    /// Local mark-all is acknowledged only by native read snapshots, not by a guessed top ID.
    public mutating func discardPending(for peers: Set<Peer>) {
        self.pending = self.pending.filter { !peers.contains($0.key) }
        if self.pending.isEmpty { self.due = nil }
    }

    /// Started callbacks may finish on the old account; they cannot enter a new tracker.
    public mutating func invalidate() {
        self.generation &+= 1
        self.isActive = false
        self.due = nil
        self.pending.removeAll()
        self.batches.removeAll()
        self.submitted.removeAll()
        self.snapshots.removeAll()
        self.included.removeAll()
    }

    private func effectiveReadId(_ peer: Peer) -> Int32 {
        var value = max(self.snapshots[peer]?.maxReadId ?? 0, self.submitted[peer] ?? 0)
        value = max(value, self.pending[peer]?.identity.messageId ?? 0)
        for batch in self.batches.values {
            for position in batch.positions where Peer(position.identity) == peer {
                value = max(value, position.identity.messageId)
            }
        }
        return value
    }
}
