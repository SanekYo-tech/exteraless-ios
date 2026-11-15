import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public struct ExteralessFeedChannel: Equatable {
    public let peer: EnginePeer
    public let archived: Bool
    public let topMessageIndex: EngineMessage.Index?
    public let topMessageVersion: UInt32?
    public let readCounters: EnginePeerReadCounters?
    public let isMuted: Bool
    public var id: Int64 { self.peer.id.toInt64() }
    public var topMessageId: EngineMessage.Id? { self.topMessageIndex?.id }

    public init(peer: EnginePeer, archived: Bool, topMessageIndex: EngineMessage.Index?, topMessageVersion: UInt32?, readCounters: EnginePeerReadCounters?, isMuted: Bool) {
        self.peer = peer
        self.archived = archived
        self.topMessageIndex = topMessageIndex
        self.topMessageVersion = topMessageVersion
        self.readCounters = readCounters
        self.isMuted = isMuted
    }
}

public struct ExteralessFeedChannelPage {
    public let channels: [ExteralessFeedChannel]
    /// Cursor over ALL chats, including non-channels, so a page of private chats advances.
    public let oldest: EngineChatList.Item.Index?
    public let hasEarlier: Bool
    public let hasGap: Bool

    public init(channels: [ExteralessFeedChannel], oldest: EngineChatList.Item.Index?, hasEarlier: Bool, hasGap: Bool) {
        self.channels = channels
        self.oldest = oldest
        self.hasEarlier = hasEarlier
        self.hasGap = hasGap
    }
}

public func exteralessFeedChannelIsEligible(_ peer: EnginePeer) -> Bool {
    guard case let .channel(channel) = peer, case .broadcast = channel.info,
          channel.participationStatus == .member, !channel.isMonoForum else { return false }
    return true
}

public func exteralessFeedMessageIsEligible(_ message: EngineMessage) -> Bool {
    guard message.id.namespace == Namespaces.Message.Cloud, message.id.id > 0,
          message.id.peerId.namespace == Namespaces.Peer.CloudChannel,
          let peer = message.peers[message.id.peerId], exteralessFeedChannelIsEligible(EnginePeer(peer)),
          !message._asMessage().containsSecretMedia, message._asMessage().adAttribute == nil else { return false }
    return !message.media.contains { $0 is TelegramMediaAction }
}

/// Native paginated chat-list views fill their own holes and retain the real chat-list cursor.
/// No "latest 1,000" limit and no direct getDialogs request or cached-only false completion.
public func exteralessFeedChannelPage(engine: TelegramEngine, group: EngineChatList.Group, before: EngineChatList.Item.Index?, count: Int = 100) -> Signal<ExteralessFeedChannelPage, NoError> {
    let count = max(2, min(100, count))
    let view: Signal<(ChatListView, ViewUpdateType), NoError>
    if case let .chatList(index)? = before {
        view = engine.account.viewTracker.aroundChatListView(groupId: group._asGroup(), index: index, count: count * 2)
    } else if before == nil {
        view = engine.account.viewTracker.tailChatListView(groupId: group._asGroup(), count: count)
    } else {
        return .single(ExteralessFeedChannelPage(channels: [], oldest: nil, hasEarlier: true, hasGap: true))
    }
    return view |> map { view, _ in
        let list = EngineChatList(view, accountPeerId: engine.account.peerId)
        let older = list.items.filter { before == nil || $0.index < before! }.sorted { $0.index > $1.index }
        let items = Array(older.prefix(count))
        let channels = items.compactMap { item -> ExteralessFeedChannel? in
            guard let peer = item.renderedPeer.peer, exteralessFeedChannelIsEligible(peer) else { return nil }
            let top = item.messages.max { $0.index < $1.index }
            return ExteralessFeedChannel(peer: peer, archived: group == .archive, topMessageIndex: top?.index, topMessageVersion: top?.stableVersion, readCounters: item.readCounters, isMuted: item.isMuted)
        }
        return ExteralessFeedChannelPage(channels: channels, oldest: items.last?.index, hasEarlier: list.hasEarlier || older.count > items.count || list.isLoading, hasGap: list.isLoading)
    }
}

/// Account-local synchronization can change a channel below the first chat-list page.
/// Coalescing/re-enumeration belongs to the feed owner; the signal never marks anything read.
public func exteralessFeedChannelChanges(engine: TelegramEngine) -> Signal<Void, NoError> {
    let root = engine.account.viewTracker.tailChatListView(groupId: .root, count: 20) |> map { _ in () }
    let archive = engine.account.viewTracker.tailChatListView(groupId: Namespaces.PeerGroup.archive, count: 20) |> map { _ in () }
    return Signal { subscriber in
        let disposables = DisposableSet()
        disposables.add(root.start(next: { subscriber.putNext(()) }))
        disposables.add(archive.start(next: { subscriber.putNext(()) }))
        disposables.add(engine.account.stateManager.significantStateUpdateCompleted.start(next: { subscriber.putNext(()) }))
        return disposables
    }
}

public func exteralessFeedReadSnapshot(peerId: EnginePeer.Id, counters: EnginePeerReadCounters, topMessageId: EngineMessage.Id? = nil) -> FeedUnreadTracker.Snapshot {
    var maxRead: Int32 = 0
    if let states = counters._asReadCounters()?.states {
        for (namespace, state) in states where namespace == Namespaces.Message.Cloud {
            if case let .idBased(maxIncomingReadId, _, _, _, _) = state { maxRead = max(maxRead, maxIncomingReadId) }
        }
    }
    if maxRead == 0, counters.count == 0, let topMessageId, topMessageId.peerId == peerId, topMessageId.namespace == Namespaces.Message.Cloud {
        // Same fallback as FeedController.applyEnumeration: an empty unread state must not
        // draw every cached old post as new merely because it has no explicit read frontier.
        maxRead = topMessageId.id
    }
    return FeedUnreadTracker.Snapshot(peer: .init(id: peerId.toInt64(), namespace: Namespaces.Message.Cloud), maxReadId: maxRead, unreadCount: Int(counters.count))
}

/// Refresh only currently visible cloud posts. Native reaction refresh groups by real peer,
/// deduplicates requests and applies updates to the same account's native message storage.
public func exteralessFeedRefreshReactions(engine: TelegramEngine, messageIds: Set<EngineMessage.Id>) {
    let grouped = Dictionary(grouping: messageIds.filter { $0.namespace == Namespaces.Message.Cloud && $0.peerId.namespace == Namespaces.Peer.CloudChannel }, by: \.peerId)
    for peerId in grouped.keys.sorted().prefix(4) {
        engine.account.viewTracker.updateReactionsForMessageIds(messageIds: Set((grouped[peerId] ?? []).sorted().prefix(20)))
    }
}
