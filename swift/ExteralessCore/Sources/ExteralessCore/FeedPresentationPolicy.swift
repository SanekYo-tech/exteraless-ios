import Foundation

/// UI/cache identity only; it never replaces a Telegram message ID on disk or on the wire.
public enum FeedPostIdentity: Hashable, Sendable {
    case message(ChatFeedIdentity)
    case album(peerId: Int64, namespace: Int32, groupId: Int64)

    public init(_ entry: ChatFeedEntry) {
        if let groupId = entry.groupId {
            self = .album(peerId: entry.identity.peerId, namespace: entry.identity.namespace, groupId: groupId)
        } else {
            self = .message(entry.identity)
        }
    }
}

public enum FeedPresentationPolicy {
    public static func posts(_ ordered: [ChatFeedEntry]) -> [[ChatFeedEntry]] {
        var indices: [FeedPostIdentity: Int] = [:]
        var result: [[ChatFeedEntry]] = []
        for entry in ordered {
            let id = FeedPostIdentity(entry)
            if let index = indices[id] { result[index].append(entry) }
            else { indices[id] = result.count; result.append([entry]) }
        }
        return result
    }

    /// In the descending feed, the unread separator follows the complete oldest unread album.
    public static func unreadBoundary(posts: [[ChatFeedEntry]], isUnread: (ChatFeedIdentity) -> Bool) -> Int? {
        return posts.indices.reversed().first { posts[$0].contains { isUnread($0.identity) } }.map { $0 + 1 }
    }

    public static func admitsReceipt(visibleHeight: Double, postHeight: Double, viewportHeight: Double, active: Bool, positioned: Bool, unobscured: Bool) -> Bool {
        guard active, positioned, unobscured, visibleHeight.isFinite, postHeight.isFinite,
              viewportHeight.isFinite, postHeight > 0, viewportHeight > 0 else { return false }
        return visibleHeight >= min(postHeight, viewportHeight) - 1.0
    }

    public struct Retention: Sendable {
        public let identities: Set<ChatFeedIdentity>
        public let rewind: [Int64: ChatFeedPosition]
    }

    /// At most a 500-message window plus 29 messages (one page and album tail) per source.
    /// Eviction rewinds only that source, so no unread/unshown history disappears behind a cursor.
    public static func retention(entries: [ChatFeedEntry], windowLimit: Int = 500, lookahead: Int = 29) -> Retention {
        let peers = Set(entries.map { $0.identity.peerId })
        let window = ChatFeedPolicy.ordered(entries, allowedPeers: peers, limit: max(1, windowLimit))
        var retained = Set(window.map(\.identity))
        var rewind: [Int64: ChatFeedPosition] = [:]
        for (peer, source) in Dictionary(grouping: entries, by: { $0.identity.peerId }) {
            let remaining = source.filter { !retained.contains($0.identity) }
            let tail = ChatFeedPolicy.ordered(remaining, allowedPeers: [peer], limit: max(1, lookahead))
            retained.formUnion(tail.map(\.identity))
            if remaining.count > tail.count {
                rewind[peer] = source.filter { retained.contains($0.identity) }.map(\.position).min()
            }
        }
        return Retention(identities: retained, rewind: rewind)
    }
}

/// A queued native bubble layout/media completion is accepted only by the cell that requested it.
public struct FeedRenderLease: Sendable {
    public struct Token: Equatable, Sendable {
        public let accountId: Int64
        public let post: FeedPostIdentity
        public let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var current: Token?
    public init() {}

    public mutating func begin(accountId: Int64, post: FeedPostIdentity) -> Token {
        self.generation &+= 1
        let token = Token(accountId: accountId, post: post, generation: self.generation)
        self.current = token
        return token
    }

    public func accepts(_ token: Token) -> Bool { self.current == token }
    public mutating func cancel() { self.generation &+= 1; self.current = nil }
}

/// A page's end is evidence, never an inference from a timeout or an empty filtered page.
public enum FeedPageProgress: Equatable, Sendable {
    case more
    case end
    case retry

    public static func evaluate(hasEarlier: Bool, hasGap: Bool, advanced: Bool, succeeded: Bool) -> Self {
        if !succeeded || hasGap { return .retry }
        if !hasEarlier { return .end }
        return advanced ? .more : .retry
    }
}
