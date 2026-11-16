#if DEBUG
import Foundation
import Postbox

/// An explicit, short-lived render-only fixture permit. It refuses a real account before any
/// fixture data/cache write: a supplementary account under a fresh UUID-named temporary harness
/// directory AND the existing closed-loopback SOCKS transport are both required.
/// Set that transport BEFORE constructing the account (ComposerHarness/HarnessAccount.swift).
public final class ExteralessFeedOfflineFixture {
    private let engine: TelegramEngine
    private let expires: TimeInterval

    public init?(engine: TelegramEngine) {
        guard Self.isIsolated(engine) else { return nil }
        self.engine = engine
        self.expires = ProcessInfo.processInfo.systemUptime + 30.0
    }

    public func accepts(engine: TelegramEngine) -> Bool {
        return self.engine.account === engine.account && ProcessInfo.processInfo.systemUptime < self.expires && Self.isIsolated(engine)
    }

    public var remainingDuration: TimeInterval { max(0, self.expires - ProcessInfo.processInfo.systemUptime) }

    private static func isIsolated(_ engine: TelegramEngine) -> Bool {
        guard engine.account.supplementary else { return false }
        let path = URL(fileURLWithPath: engine.account.basePath).resolvingSymlinksInPath().standardizedFileURL
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.path.hasPrefix(temporary + "/"), path.pathComponents.contains(where: { component in
            for prefix in ["exteraless-feed-fixture-", "composer-harness-"] where component.hasPrefix(prefix) {
                if UUID(uuidString: String(component.dropFirst(prefix.count))) != nil { return true }
            }
            return false
        }), let proxy = engine.account.network.context.apiEnvironment.socksProxySettings,
            proxy.ip == "127.0.0.1", proxy.port == 1, proxy.secret == nil, !proxy.webProxy else { return false }
        return true
    }

    /// Six cloud-shaped fixture posts, all media local. No message is inserted into history,
    /// no read/mark-all/reaction/send operation runs, and no real peer/access hash is loaded.
    public func messages(png: Data, edited: Bool = false) -> [EngineMessage] {
        guard self.accepts(engine: self.engine), png.count <= 16 * 1024, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return [] }
        func channel(_ id: Int64, title: String, protected: Bool = false) -> TelegramChannel {
            return TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(id)), accessHash: nil, title: title, username: nil, photo: [], creationDate: 0, version: 0, participationStatus: .member, info: .broadcast(TelegramChannelBroadcastInfo(flags: [])), flags: protected ? [.copyProtectionEnabled] : [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        }
        let a = channel(9_100_001, title: "Fixture A")
        let b = channel(9_100_002, title: "Fixture B · protected", protected: true)
        let peers = SimpleDictionary<PeerId, Peer>([a.id: a, b.id: b])
        let resource = LocalFileMediaResource(fileId: 9_100_001, size: Int64(png.count))
        self.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: png, synchronous: true)
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: 9_100_001), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 160, height: 120), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        func message(_ peer: TelegramChannel, id: Int32, timestamp: Int32, text: String, group: Int64? = nil, attributes: [MessageAttribute] = [], media: [Media] = [], forward: MessageForwardInfo? = nil, replies: SimpleDictionary<MessageId, Message> = SimpleDictionary()) -> Message {
            return Message(stableId: UInt32(id) + (peer.id == a.id ? 0 : 100), stableVersion: edited ? 1 : 0, id: MessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: id), globallyUniqueId: nil, groupingKey: group, groupInfo: nil, threadId: nil, timestamp: timestamp, flags: [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: forward, author: peer, text: text, attributes: attributes, media: media, peers: peers, associatedMessages: replies, associatedMessageIds: replies.map { $0.0 }, associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
        }
        let source = message(a, id: 1, timestamp: 1_700_000_000, text: "Reply source with original identity")
        let styledText = edited ? "Bold 😀 edited\nA full native bubble, not an excerpt." : "Bold 😀 spoiler\nA full native bubble, not an excerpt."
        let styled = message(a, id: 2, timestamp: 1_700_000_100, text: styledText, attributes: [
            TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< 4, type: .Bold), MessageTextEntity(range: 8 ..< 15, type: .Spoiler)]),
            ReplyMessageAttribute(messageId: source.id, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil),
            ReactionsMessageAttribute(canViewList: false, isTags: false, reactions: [MessageReaction(value: .builtin("👍"), count: edited ? 4 : 3, chosenOrder: nil)], recentPeers: [], topPeers: [])
        ], forward: MessageForwardInfo(author: b, source: b, sourceMessageId: MessageId(peerId: b.id, namespace: Namespaces.Message.Cloud, id: 2), date: 1_700_000_000, authorSignature: nil, psaType: nil, flags: []), replies: SimpleDictionary([source.id: source]))
        return [
            EngineMessage(styled),
            EngineMessage(message(a, id: 3, timestamp: 1_700_000_101, text: "Album caption", group: 17, media: [image])),
            EngineMessage(message(a, id: 4, timestamp: 1_700_000_102, text: "", group: 17, media: [image])),
            // Same message and album IDs in another peer must not share a cell/media lease.
            EngineMessage(message(b, id: 3, timestamp: 1_700_000_101, text: "Protected channel album", group: 17, media: [image])),
            EngineMessage(message(b, id: 4, timestamp: 1_700_000_102, text: "", group: 17, media: [image])),
            EngineMessage(source)
        ]
    }
}
#endif
