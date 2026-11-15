import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public func exteralessDialogIsUnreadPriority(_ item: EngineChatList.Item) -> Bool {
    let monoforum: Bool
    if case let .channel(channel) = item.renderedPeer.peer { monoforum = channel.flags.contains(.isMonoforum) }
    else { monoforum = false }
    return DialogOrderingPolicy.isUnreadPriority(
        unreadCount: Int(item.readCounters?.count ?? 0),
        counterMuted: item.readCounters?.isMuted ?? item.isMuted,
        hasMentions: item.hasUnseenMentions,
        hasReactions: item.hasUnseenReactions,
        isMonoforum: monoforum
    )
}

/// Same native account/filter predicate as the ordinary list. This view does not
/// invoke the network or load holes: the ordinary AccountViewTracker subscription
/// remains the sole loader. Metadata is observed for all locally known dialogs so
/// an old unread dialog outside an 80-row window can actually move to the top.
public func exteralessDialogLocalList(account: Account, group: EngineChatList.Group, filterPredicate: ChatListFilterPredicate?) -> Signal<EngineChatList, NoError> {
    return Signal { subscriber in
        let queue = Queue()
        let capacity = ValuePromise<Int>(ignoreRepeated: true)
        let lifetime = DisposableSet()
        let countRefresh = MetaDisposable()
        lifetime.add(countRefresh)
        let components = ChatListEntrySummaryComponents(components: [
            ChatListEntryMessageTagSummaryKey(tag: .unseenPersonalMessage, actionType: PendingMessageActionType.consumeUnseenPersonalMessage): .init(tagSummary: .init(namespace: Namespaces.Message.Cloud), actionsSummary: .init(namespace: Namespaces.Message.Cloud)),
            ChatListEntryMessageTagSummaryKey(tag: .unseenReaction, actionType: PendingMessageActionType.readReactionOrPollVote): .init(tagSummary: .init(namespace: Namespaces.Message.Cloud), actionsSummary: .init(namespace: Namespaces.Message.Cloud)),
            ChatListEntryMessageTagSummaryKey(tag: .unseenPollVote, actionType: PendingMessageActionType.readReactionOrPollVote): .init(tagSummary: .init(namespace: Namespaces.Message.Cloud), actionsSummary: .init(namespace: Namespaces.Message.Cloud))
        ])
        lifetime.add((capacity.get()
        |> mapToSignal { count in
            account.postbox.tailChatListView(groupId: group._asGroup(), filterPredicate: filterPredicate, count: count, summaryComponents: components)
            |> map { ($0.0, count) }
        }
        |> deliverOn(queue)).start(next: { view, count in
            if view.earlierIndex != nil {
                // Read actual local membership before growing; an unresolved
                // server hole is not a reason to invent more local records.
                countRefresh.set((account.postbox.transaction { transaction in transaction.chatListGetAllPeerIds().count }
                |> deliverOn(queue)).start(next: { known in
                    if known >= count { capacity.set(known + 64) }
                }))
            }
            // A hole does not invalidate actual entries on its other side. Keep
            // their native data and expose a continuation, never synthesize rows.
            let displaySavedAsTopics = view.displaySavedMessagesAsTopicList?.get(EngineDisplaySavedChatsAsTopics.self)?.value ?? false
            let items = view.entries.compactMap { entry in
                EngineChatList.Item(entry, accountPeerId: account.peerId, isPremium: view.accountPeer?.isPremium ?? false, displayAsTopicList: entry.index.messageIndex.id.peerId == account.peerId && displaySavedAsTopics)
            }
            let hasHoles = view.entries.contains { entry in if case .HoleEntry = entry { return true }; return false }
            subscriber.putNext(EngineChatList(items: items, groupItems: view.groupEntries.map(EngineChatList.GroupItem.init), additionalItems: view.additionalItemEntries.compactMap(EngineChatList.AdditionalItem.init), hasEarlier: view.earlierIndex != nil || hasHoles, hasLater: view.laterIndex != nil, isLoading: items.isEmpty && hasHoles))
        }))
        lifetime.add(account.postbox.transaction { transaction in max(80, transaction.chatListGetAllPeerIds().count + 64) }.start(next: { capacity.set($0) }))
        return lifetime
    }
}

/// Explicit one-way composition with Privacy Extras. No process-global transform
/// chain and no callback into the list provider. Privacy owns default exclusion
/// and the projected unread/mention/reaction data which sorting consumes.
public func exteralessDialogProjectList(account: Account, list: EngineChatList) -> Signal<EngineChatList, NoError> {
    let identity = exteralessPrivacyExtrasIdentity(account)
    guard ExteralessHiddenAccounts.shared.canSelect(identity) else {
        return .single(EngineChatList(items: [], groupItems: [], additionalItems: [], hasEarlier: false, hasLater: false, isLoading: false))
    }
    return exteralessFilterChatList(account: account, list: list)
}

/// Array order is presentation-only; every Item/Message/Thread index is kept.
/// Root/archive/filter membership and pinned indices are resolved by the native
/// source before this function is called. Forum topic ordering is not modified.
public func exteralessDialogOrderedWindow(list: EngineChatList, anchor: EngineChatList.Item.Index?, count: Int) -> EngineChatList {
    let topFirst = Array(list.items.reversed())
    let ordered = DialogOrderingPolicy.promoteUnread(topFirst, enabled: true, scope: { _ in 0 }, isFixed: { item in
        if case let .chatList(index) = item.index { return index.pinningIndex != nil }
        return true
    }, isPriority: exteralessDialogIsUnreadPriority)
    let anchorId: EngineChatList.Item.Id?
    if case let .chatList(index) = anchor { anchorId = .chatList(index.messageIndex.id.peerId) }
    else { anchorId = nil }
    let anchorIndex = anchorId.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
    let range = DialogOrderingPolicy.window(totalCount: ordered.count, count: count, anchorIndex: anchorIndex)
    return EngineChatList(items: Array(ordered[range].reversed()), groupItems: range.lowerBound == 0 ? list.groupItems : [], additionalItems: range.lowerBound == 0 ? list.additionalItems : [], hasEarlier: range.upperBound < ordered.count || list.hasEarlier, hasLater: range.lowerBound > 0 || list.hasLater, isLoading: list.isLoading)
}
