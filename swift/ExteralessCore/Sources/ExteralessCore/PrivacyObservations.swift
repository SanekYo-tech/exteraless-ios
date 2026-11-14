import Foundation

/// Locally observed data, encoded in the owning account's encrypted Postbox by the adapter.
/// This never changes a peer's authoritative server presence or message read state.
public struct PrivacyObservations: Codable, Equatable, Sendable {
    public struct Read: Codable, Equatable, Sendable {
        public var readAt: Int32?
        public var playedAt: Int32?
        public init(readAt: Int32? = nil, playedAt: Int32? = nil) { self.readAt = readAt; self.playedAt = playedAt }
    }
    public private(set) var lastSeen: [Int64: Int32] = [:]
    public private(set) var reads: [String: Read] = [:]
    public static let lastSeenRetention: Int32 = 7 * 24 * 60 * 60
    public static let maximumActivityRecords = 50_000
    public static let maximumReadRecords = 50_000
    public init() {}

    public mutating func observeActivity(peerId: Int64, timestamp: Int32, now: Int32) {
        observeActivities([peerId: timestamp], now: now)
    }

    /// Batch updates avoid filtering/sorting the whole store once for every message.
    public mutating func observeActivities(_ activities: [Int64: Int32], now: Int32) {
        let cutoff = Int64(now) - Int64(Self.lastSeenRetention)
        for (peerId, timestamp) in activities where timestamp > 0 && timestamp <= now && Int64(timestamp) >= cutoff {
            lastSeen[peerId] = max(lastSeen[peerId] ?? 0, timestamp)
        }
        pruneActivity(now: now)
    }

    /// Also called when loading the store, so expiry does not depend on a new event.
    @discardableResult public mutating func pruneActivity(now: Int32, maximumRecords: Int = PrivacyObservations.maximumActivityRecords) -> Bool {
        let originalCount = lastSeen.count
        let cutoff = Int64(now) - Int64(Self.lastSeenRetention)
        lastSeen = lastSeen.filter { $0.value > 0 && Int64($0.value) >= cutoff }
        let limit = max(0, min(Self.maximumActivityRecords, maximumRecords))
        if lastSeen.count > limit {
            let ordered = lastSeen.sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }
            for entry in ordered.prefix(lastSeen.count - limit) { lastSeen.removeValue(forKey: entry.key) }
        }
        return originalCount != lastSeen.count
    }

    public func observedActivity(peerId: Int64, now: Int32) -> Int32? {
        guard let value = lastSeen[peerId], value <= now, Int64(value) >= Int64(now) - Int64(Self.lastSeenRetention) else { return nil }
        return value
    }

    public static func messageKey(peerId: Int64, namespace: Int32, id: Int32) -> String { "\(peerId):\(namespace):\(id)" }

    public mutating func observeRead(peerId: Int64, namespace: Int32, id: Int32, timestamp: Int32, played: Bool) {
        observeReadMessages(peerId: peerId, namespace: namespace, ids: [id], timestamp: timestamp, played: played)
    }

    public mutating func observeReadMessages(peerId: Int64, namespace: Int32, ids: [Int32], timestamp: Int32, played: Bool) {
        guard timestamp > 0 else { return }
        for id in ids {
            let key = Self.messageKey(peerId: peerId, namespace: namespace, id: id)
            var value = reads[key] ?? Read()
            // The first observed date is retained when an update is replayed.
            if played { value.playedAt = value.playedAt ?? timestamp } else { value.readAt = value.readAt ?? timestamp }
            reads[key] = value
        }
        pruneReadRecords()
    }

    @discardableResult public mutating func pruneReadRecords(maximumRecords: Int = PrivacyObservations.maximumReadRecords) -> Bool {
        let limit = max(0, min(Self.maximumReadRecords, maximumRecords))
        guard reads.count > limit else { return false }
        let ordered = reads.sorted { lhs, rhs in
            let left = min(lhs.value.readAt ?? Int32.max, lhs.value.playedAt ?? Int32.max)
            let right = min(rhs.value.readAt ?? Int32.max, rhs.value.playedAt ?? Int32.max)
            return left == right ? lhs.key < rhs.key : left < right
        }
        for entry in ordered.prefix(reads.count - limit) { reads.removeValue(forKey: entry.key) }
        return true
    }

    public mutating func clear() { lastSeen.removeAll(); reads.removeAll() }
}

/// Per-store admission epoch for queued observation work. It holds no account,
/// peer or message data. A clear invalidates old captured batches; cancellation
/// affects one subscription, not every subscriber sharing the same epoch.
public final class PrivacyObservationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    public init() {}
    public func capture() -> UUID { lock.lock(); defer { lock.unlock() }; return generation }
    public func invalidate() { lock.lock(); generation = UUID(); lock.unlock() }
    fileprivate func isCurrent(_ generation: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return self.generation == generation }
    public func makeWork(capturedGeneration: UUID? = nil) -> PrivacyObservationWork {
        PrivacyObservationWork(epoch: self, generation: capturedGeneration ?? capture())
    }
}

public final class PrivacyObservationWork: @unchecked Sendable {
    private let epoch: PrivacyObservationEpoch
    private let generation: UUID
    private let lock = NSLock()
    private var cancelled = false
    fileprivate init(epoch: PrivacyObservationEpoch, generation: UUID) { self.epoch = epoch; self.generation = generation }
    public var isCurrent: Bool {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        return !cancelled && epoch.isCurrent(generation)
    }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
