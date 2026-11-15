import Foundation
import TelegramCore

/// No Account/Network/TelegramEngine is constructed by these native orchestration fixtures.
enum FeedNativeFixtures {
    static func channel(_ id: Int64, protected: Bool = false) -> ExteralessFeedChannel {
        let peer = TelegramChannel(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(id)), accessHash: nil, title: "Fixture \(id)", username: nil, photo: [], creationDate: 0, version: 0, participationStatus: .member, info: .broadcast(TelegramChannelBroadcastInfo(flags: [])), flags: protected ? [.copyProtectionEnabled] : [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        return ExteralessFeedChannel(peer: .channel(peer), archived: false, topMessageIndex: nil, topMessageVersion: nil, readCounters: EnginePeerReadCounters(incomingReadId: 0, outgoingReadId: 0, count: 1, markedUnread: false), isMuted: false)
    }

    static func cursor(_ offset: Int) -> EngineChatList.Item.Index {
        let id = EngineMessage.Id(peerId: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(offset + 1))), namespace: Namespaces.Message.Cloud, id: Int32(offset + 1))
        return .chatList(EngineChatList.Item.Index.ChatList(pinningIndex: nil, messageIndex: EngineMessage.Index(id: id, timestamp: 10_000 - Int32(offset))))
    }

    static func message(channel: ExteralessFeedChannel, id: Int32, timestamp: Int32, version: UInt32 = 0, text: String = "Fixture", group: Int64? = nil) -> EngineMessage {
        // stableId and message number deliberately collide between peers. Only the composite
        // identity may key the feed. All references are fixtures with nil access hashes/media.
        return EngineMessage(EngineRawMessage(stableId: UInt32(id), stableVersion: version, id: EngineMessage.Id(peerId: channel.peer.id, namespace: Namespaces.Message.Cloud, id: id), globallyUniqueId: nil, groupingKey: group, groupInfo: nil, threadId: nil, timestamp: timestamp, flags: [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: channel.peer._asPeer(), text: text, attributes: [], media: [], peers: EngineSimpleDictionary([channel.peer.id: channel.peer._asPeer()]), associatedMessages: EngineSimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:]))
    }

    static func projection(_ message: EngineMessage, peer: EnginePeer? = nil) -> ExteralessFeedMessageProjection {
        ExteralessFeedMessageProjection(message: message, peer: peer ?? message.peers[message.id.peerId].map(EnginePeer.init), group: .root)
    }
}
