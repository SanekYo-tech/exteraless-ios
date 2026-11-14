import Foundation

/// FeedConfig's account-local inclusion rules. Disabling automatic additions snapshots the
/// channels that exist at that instant; explicitly including a new channel also makes it known.
public struct ChatFeedConfiguration: Equatable, Sendable {
    public var includeArchived: Bool
    public private(set) var addNewChannels: Bool
    public private(set) var excludedChannels: Set<Int64>
    public private(set) var knownChannels: Set<Int64>

    public init(includeArchived: Bool = false, addNewChannels: Bool = true, excludedChannels: Set<Int64> = [], knownChannels: Set<Int64> = []) {
        self.includeArchived = includeArchived
        self.addNewChannels = addNewChannels
        self.excludedChannels = excludedChannels
        self.knownChannels = knownChannels
    }

    public func includes(_ channel: Int64, archived: Bool) -> Bool {
        return (!archived || includeArchived) && !excludedChannels.contains(channel) && (addNewChannels || knownChannels.contains(channel))
    }

    public mutating func setAddNewChannels(_ value: Bool, currentChannels: Set<Int64>) {
        guard value != addNewChannels else { return }
        addNewChannels = value
        if !value { knownChannels = currentChannels }
    }

    public mutating func setIncluded(_ channel: Int64, included: Bool) {
        if included {
            excludedChannels.remove(channel)
            if !addNewChannels { knownChannels.insert(channel) }
        } else {
            excludedChannels.insert(channel)
        }
    }

    public mutating func includeAll(_ channels: Set<Int64>) {
        excludedChannels.subtract(channels)
        if !addNewChannels { knownChannels.formUnion(channels) }
    }
}

public struct ChatFeedIdentity: Hashable, Sendable {
    public let peerId: Int64
    public let namespace: Int32
    public let messageId: Int32

    public init(peerId: Int64, namespace: Int32, messageId: Int32) {
        self.peerId = peerId
        self.namespace = namespace
        self.messageId = messageId
    }
}

/// The Android feed's (date, uid, mid) total order, with namespace retained for local identity.
public struct ChatFeedPosition: Comparable, Hashable, Sendable {
    public let timestamp: Int32
    public let identity: ChatFeedIdentity

    public init(timestamp: Int32, identity: ChatFeedIdentity) {
        self.timestamp = timestamp
        self.identity = identity
    }

    public static func < (lhs: ChatFeedPosition, rhs: ChatFeedPosition) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.identity.peerId != rhs.identity.peerId { return lhs.identity.peerId < rhs.identity.peerId }
        if lhs.identity.messageId != rhs.identity.messageId { return lhs.identity.messageId < rhs.identity.messageId }
        return lhs.identity.namespace < rhs.identity.namespace
    }
}

public struct ChatFeedEntry: Equatable, Sendable {
    public let position: ChatFeedPosition
    public let groupId: Int64?
    public let version: UInt32
    public var identity: ChatFeedIdentity { return position.identity }

    public init(position: ChatFeedPosition, groupId: Int64? = nil, version: UInt32 = 0) {
        self.position = position
        self.groupId = groupId
        self.version = version
    }
}

public enum ChatFeedPolicy {
    public struct Frontier: Sendable {
        public let oldestLoaded: ChatFeedPosition?
        public let isComplete: Bool
        public init(oldestLoaded: ChatFeedPosition?, isComplete: Bool) {
            self.oldestLoaded = oldestLoaded
            self.isComplete = isComplete
        }
    }

    private struct Album: Hashable {
        let peerId: Int64
        let groupId: Int64
    }

    /// A channel whose top page is still unknown prevents us claiming a gap-free timeline.
    /// Among incomplete channels the shallowest frontier is the safe lower bound.
    public static func safeLowerBound(_ frontiers: [Frontier]) -> (ready: Bool, position: ChatFeedPosition?) {
        if frontiers.contains(where: { !$0.isComplete && $0.oldestLoaded == nil }) { return (false, nil) }
        return (true, frontiers.filter { !$0.isComplete }.compactMap(\.oldestLoaded).max())
    }

    public static func ordered(_ entries: [ChatFeedEntry], allowedPeers: Set<Int64>, lowerBound: ChatFeedPosition? = nil, limit: Int = 500) -> [ChatFeedEntry] {
        guard limit > 0 else { return [] }
        var unique: [ChatFeedIdentity: ChatFeedEntry] = [:]
        for entry in entries where allowedPeers.contains(entry.identity.peerId) {
            if let lowerBound, entry.position < lowerBound { continue }
            if let previous = unique[entry.identity], previous.version > entry.version { continue }
            unique[entry.identity] = entry
        }
        let sorted = unique.values.sorted { $0.position > $1.position }
        var albums: [Album: [ChatFeedEntry]] = [:]
        for entry in sorted {
            if let groupId = entry.groupId {
                albums[Album(peerId: entry.identity.peerId, groupId: groupId), default: []].append(entry)
            }
        }
        var appended = Set<Album>()
        var result: [ChatFeedEntry] = []
        for entry in sorted {
            if let groupId = entry.groupId {
                let album = Album(peerId: entry.identity.peerId, groupId: groupId)
                if appended.contains(album) { continue }
                let group = albums[album] ?? [entry]
                if !result.isEmpty && result.count + group.count > limit { break }
                appended.insert(album)
                result.append(contentsOf: group)
            } else {
                if result.count >= limit { break }
                result.append(entry)
            }
        }
        return result
    }

    /// Album clustering is not a monotonic timestamp order. Advancing by the last/minimum
    /// displayed timestamp would respectively duplicate an album tail or skip an interleaved post.
    public static func remaining(after page: [ChatFeedEntry], in entries: [ChatFeedEntry]) -> [ChatFeedEntry] {
        let displayed = Set(page.map(\.identity))
        return entries.filter { !displayed.contains($0.identity) }
    }
}

/// One four-channel backfill round. All result/timeout/cancel paths consume the same generation.
/// A timed-out channel is retryable and is never confused with an empty successful history page.
public struct ChatFeedLoadRound: Sendable {
    public struct Request: Equatable, Hashable, Sendable {
        public let generation: UInt64
        public let channel: Int64
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var pending: Set<Int64> = []
    public private(set) var deadline: TimeInterval?

    public init() {}

    public mutating func begin(channels: [Int64], now: TimeInterval) -> [Request] {
        cancel()
        var seen = Set<Int64>()
        let selected = channels.filter { seen.insert($0).inserted }.prefix(4)
        pending = Set(selected)
        if !pending.isEmpty { deadline = now + 10.0 }
        return selected.map { Request(generation: generation, channel: $0) }
    }

    @discardableResult
    public mutating func complete(_ request: Request) -> Bool {
        guard request.generation == generation, pending.remove(request.channel) != nil else { return false }
        if pending.isEmpty { deadline = nil }
        return true
    }

    public mutating func expire(now: TimeInterval) -> Set<Int64> {
        guard let deadline, now >= deadline else { return [] }
        let failed = pending
        cancel()
        return failed
    }

    public mutating func cancel() {
        generation &+= 1
        pending.removeAll()
        deadline = nil
    }
}

public struct ChatFeedRefreshGate: Sendable {
    public private(set) var due: TimeInterval?
    public init() {}
    public mutating func request(now: TimeInterval) { if due == nil { due = now + 0.5 } }
    public mutating func consume(now: TimeInterval) -> Bool {
        guard let due, now >= due else { return false }
        self.due = nil
        return true
    }
    public mutating func cancel() { due = nil }
}
