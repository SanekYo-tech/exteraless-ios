import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public struct ExteralessFilteredChatSummary {
    public let preview: EngineMessage?
    /// nil means incomplete local history/evaluation, displayed as an unread dot.
    public let unreadCount: Int?
    public let knownHiddenUnread: Int
    public let filteringActive: Bool
    public let hasVisibleMentions: Bool?
    public let hasVisibleReactions: Bool?
    fileprivate let projectedStates: [(MessageId.Namespace, PeerReadState)]
}

/// Read-only projection. It is never passed to setPeerReadState/applyMaxReadIndex.
/// Bounds: 4,096 inspected local messages, 20 preview candidates, 1M NFA operations.
public func exteralessFilteredChatSummary(account: PrivacyExtrasAccountIdentity, transaction: Transaction, peerId: PeerId, threadId: Int64? = nil, runtime: ExteralessFilteringRuntime = .shared) -> ExteralessFilteredChatSummary {
    var budget = FilteringWorkBudget(operations: 1_000_000)
    var remainingMessages = 4_096
    return extrasChatSummary(account: account, transaction: transaction, peerId: peerId, threadId: threadId, budget: &budget, remainingMessages: &remainingMessages, runtime: runtime)
}

private struct ExteralessSummaryCursor {
    let namespace: MessageId.Namespace
    let lowerBound: MessageIndex
    var from: MessageIndex
    let mentionCount: Int?
    let reactionCount: Int?
    var messages: [Message] = []
    var position = 0
    var exhausted = false
}

// Internal for the native common-budget fixture; all production entry points use
// this same Postbox implementation, not a separate policy-only approximation.
func extrasChatSummary(account: PrivacyExtrasAccountIdentity, transaction: Transaction, peerId: PeerId, threadId: Int64?, budget: inout FilteringWorkBudget, remainingMessages: inout Int, runtime: ExteralessFilteringRuntime = .shared) -> ExteralessFilteredChatSummary {
    let policy = exteralessFilteringPolicy(account: account, transaction: transaction, runtime: runtime)
    var readStates = transaction.getPeerReadStates(peerId) ?? []
    if let threadId {
        if let data = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: threadId)?.data.get(MessageHistoryThreadData.self) {
            readStates = [(Namespaces.Message.Cloud, .idBased(maxIncomingReadId: data.maxIncomingReadId, maxOutgoingReadId: data.maxOutgoingReadId, maxKnownId: data.maxKnownMessageId, count: data.incomingUnreadCount, markedUnread: data.isMarkedUnread))]
        } else { readStates = [] }
    }
    let namespaces: [MessageId.Namespace] = peerId.namespace == Namespaces.Peer.SecretChat
        ? [Namespaces.Message.SecretIncoming, Namespaces.Message.Local] : [Namespaces.Message.Cloud]
    let configuration = policy.configuration
    let isMegagroup: Bool
    if let channel = transaction.getPeer(peerId) as? TelegramChannel, case .group = channel.info { isMegagroup = true } else { isMegagroup = false }
    let isPrivate = peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.SecretChat
    let regexApplies = (configuration.chatRules[peerId.toInt64()] ?? []).contains(where: \.enabled) || ((!isPrivate || configuration.regexFiltersEnableInChats) && configuration.sharedRules.contains(where: \.enabled))
    let active = (policy.hasSenderFilters && isMegagroup) || (configuration.regexFiltersEnabled && regexApplies && !configuration.excludedDialogs.contains(peerId.toInt64()))
    if !active {
        // The list caller returns its original item, including its existing
        // preview. An inactive projection must not fetch history at all.
        return ExteralessFilteredChatSummary(preview: nil, unreadCount: readStates.isEmpty ? nil : readStates.reduce(0, { $0 + max(0, Int($1.1.count)) }), knownHiddenUnread: 0, filteringActive: false, hasVisibleMentions: nil, hasVisibleReactions: nil, projectedStates: readStates)
    }
    let combined = CombinedPeerReadState(states: readStates)
    var cursors = namespaces.map { namespace in
        ExteralessSummaryCursor(namespace: namespace,
            lowerBound: MessageIndex.lowerBound(peerId: peerId, namespace: namespace),
            from: MessageIndex.upperBound(peerId: peerId, namespace: namespace),
            mentionCount: transaction.getMessageTagSummary(peerId: peerId, threadId: threadId, tagMask: .unseenPersonalMessage, namespace: namespace, customTag: nil).map { Int($0.count) },
            reactionCount: transaction.getMessageTagSummary(peerId: peerId, threadId: threadId, tagMask: .unseenReaction, namespace: namespace, customTag: nil).map { Int($0.count) })
    }
    var inspected = 0
    var inspectedUnread: [MessageId.Namespace: Int] = [:]
    var hidden = Set<MessageId>()
    var hiddenByNamespace: [Int32: Int] = [:]
    var preview: Message?
    var previewHasGap = false
    var incomplete = configuration.ignoreBlocked && !runtime.blockedListIsComplete(account)
    let totalUnread = readStates.reduce(0, { $0 + max(0, Int($1.1.count)) })
    let readNamespaces = Set(readStates.map(\.0))
    var inspectedMentions: [MessageId.Namespace: Int] = [:]
    var inspectedReactions: [MessageId.Namespace: Int] = [:]
    var visibleMention = false
    var visibleReaction = false

    func wantsMore() -> Bool {
        if inspected < 20 { return true }
        if readStates.contains(where: { inspectedUnread[$0.0, default: 0] < Int($0.1.count) }) { return true }
        return cursors.contains { cursor in
            inspectedMentions[cursor.namespace, default: 0] < (cursor.mentionCount ?? 0)
                || inspectedReactions[cursor.namespace, default: 0] < (cursor.reactionCount ?? 0)
        }
    }

    func loadPage(_ index: Int) {
        var cursor = cursors[index]
        guard cursor.position == cursor.messages.count, !cursor.exhausted, remainingMessages > 0 else { return }
        let limit = min(128, remainingMessages)
        let page: [Message]
        if let threadId {
            page = transaction.getMessagesWithThreadId(peerId: peerId, namespace: cursor.namespace, threadId: threadId, from: cursor.from, includeFrom: false, to: cursor.lowerBound, limit: limit)
        } else {
            page = transaction.getMessages(peerId: peerId, namespace: cursor.namespace, from: cursor.from, includeFrom: false, to: cursor.lowerBound, limit: limit)
        }
        remainingMessages -= page.count
        cursor.messages = page; cursor.position = 0
        cursor.exhausted = page.count < limit
        if let last = page.last {
            if last.index < cursor.from { cursor.from = last.index }
            else { cursor.exhausted = true }
        }
        cursors[index] = cursor
    }

    // Separate native fetches per namespace, chronological merge of their heads.
    // Local and SecretIncoming may have the same numeric id; their MessageIds and
    // cursors never alias. Both page reads and regex work share the caller's budget.
    while wantsMore() {
        for index in cursors.indices { loadPage(index) }
        if inspected < 20 && cursors.contains(where: { !$0.exhausted && $0.position == $0.messages.count }) { previewHasGap = true }
        let available = cursors.indices.filter { cursors[$0].position < cursors[$0].messages.count }
        guard let index = available.max(by: { lhs, rhs in
            cursors[lhs].messages[cursors[lhs].position].index < cursors[rhs].messages[cursors[rhs].position].index
        }) else { break }
        let message = cursors[index].messages[cursors[index].position]
        cursors[index].position += 1
        let namespace = message.id.namespace
        let group = exteralessFilteringAlbum(message: message, messages: transaction.getMessageGroup(message.id) ?? [])
        var input = exteralessFilteringMessage(account: account, message: message, group: group, regexFiltersEnabled: configuration.regexFiltersEnabled)
        if input.replySenderId == nil, let reply = message.attributes.compactMap({ $0 as? ReplyMessageAttribute }).first, let source = transaction.getMessage(reply.messageId) {
            input = FilteringMessage(account: input.account, peerId: input.peerId, senderId: input.senderId, replySenderId: source.author?.id.toInt64(), isMegagroup: input.isMegagroup, isPrivateChat: input.isPrivateChat, isOutgoing: input.isOutgoing, text: input.text)
        }
        let decision = policy.decision(input, surface: .preview, budget: &budget)
        if message.tags.contains(.unseenPersonalMessage) {
            inspectedMentions[namespace, default: 0] += 1
            visibleMention = visibleMention || !decision.isHidden
        }
        if message.tags.contains(.unseenReaction) {
            inspectedReactions[namespace, default: 0] += 1
            if let reactions = message.attributes.compactMap({ $0 as? ReactionsMessageAttribute }).first {
                visibleReaction = visibleReaction || (!decision.isHidden && exteralessFilterReactions(reactions, policy: policy, isMegagroup: input.isMegagroup).hasUnseen)
            } else { visibleReaction = true }
        }
        if inspected < 20, !previewHasGap, preview == nil, !decision.isHidden { preview = message }
        if message.flags.contains(.Incoming), !combined.isIncomingMessageIndexRead(message.index) {
            inspectedUnread[namespace, default: 0] += 1
            incomplete = incomplete || decision.incomplete || !readNamespaces.contains(namespace)
            if decision.isHidden, hidden.insert(message.id).inserted { hiddenByNamespace[namespace, default: 0] += 1 }
        }
        inspected += 1
    }
    let unreadComplete = readStates.allSatisfy { inspectedUnread[$0.0, default: 0] >= Int($0.1.count) }
    let hasHoles = !unreadComplete && namespaces.contains { namespace in
        if let threadId { return !transaction.getThreadIndexHoles(peerId: peerId, threadId: threadId, namespace: namespace).isEmpty }
        return !transaction.getHoles(peerId: peerId, namespace: namespace).isEmpty
    }
    let hiddenIds = Set(hidden.map { "\($0.namespace):\($0.id)" })
    let projection = FilteringUnreadProjection(totalUnread: totalUnread, inspectedUnread: inspectedUnread.values.reduce(0, +), hiddenUnreadIds: hiddenIds, hasHoles: hasHoles, evaluationIncomplete: incomplete || !unreadComplete || readStates.isEmpty)
    let states = readStates.map { namespace, state -> (MessageId.Namespace, PeerReadState) in
        let count: Int32 = projection.visibleCount == nil ? 0 : max(0, state.count - Int32(clamping: hiddenByNamespace[namespace] ?? 0))
        switch state {
        case let .idBased(incoming, outgoing, known, oldCount, marked):
            return (namespace, .idBased(maxIncomingReadId: incoming, maxOutgoingReadId: outgoing, maxKnownId: known, count: count, markedUnread: marked || (projection.visibleCount == nil && oldCount > 0)))
        case let .indexBased(incoming, outgoing, oldCount, marked):
            return (namespace, .indexBased(maxIncomingReadIndex: incoming, maxOutgoingReadIndex: outgoing, count: count, markedUnread: marked || (projection.visibleCount == nil && oldCount > 0)))
        }
    }
    let mentionsComplete = cursors.allSatisfy { cursor in cursor.mentionCount.map { inspectedMentions[cursor.namespace, default: 0] >= $0 } ?? false }
    let reactionsComplete = cursors.allSatisfy { cursor in cursor.reactionCount.map { inspectedReactions[cursor.namespace, default: 0] >= $0 } ?? false }
    return ExteralessFilteredChatSummary(preview: preview.map(EngineMessage.init), unreadCount: projection.visibleCount, knownHiddenUnread: projection.knownHiddenCount, filteringActive: true, hasVisibleMentions: mentionsComplete ? visibleMention : nil, hasVisibleReactions: reactionsComplete ? visibleReaction : nil, projectedStates: states)
}

public func exteralessFilteredChatSummary(account: Account, peerId: EnginePeer.Id) -> Signal<ExteralessFilteredChatSummary, NoError> {
    let identity = exteralessPrivacyExtrasIdentity(account)
    return account.postbox.transaction { transaction in exteralessFilteredChatSummary(account: identity, transaction: transaction, peerId: peerId) }
}

/// Pure presentation pipeline output. There is deliberately no global per-peer
/// cache: two account/folder views cannot overwrite each other's summary. The
/// entire list transaction shares the 4,096-message and 1M-operation limits.
public func exteralessFilterChatList(account: Account, list: EngineChatList) -> Signal<EngineChatList, NoError> {
    return exteralessFilterChatList(account: exteralessPrivacyExtrasIdentity(account), postbox: account.postbox, list: list, runtime: .shared)
}

func exteralessFilterChatList(account identity: PrivacyExtrasAccountIdentity, postbox: Postbox, list: EngineChatList, runtime: ExteralessFilteringRuntime) -> Signal<EngineChatList, NoError> {
    let initial = runtime.policy(identity)
    if !initial.hasSenderFilters && !initial.configuration.regexFiltersEnabled { return .single(list) }
    return postbox.transaction { transaction -> EngineChatList in
        var budget = FilteringWorkBudget(operations: 1_000_000)
        var remainingMessages = 4_096
        func project(_ item: EngineChatList.Item) -> EngineChatList.Item {
            let peerId = item.renderedPeer.peerId
            let threadId: Int64?
            if case let .forum(id) = item.id { threadId = id } else { threadId = nil }
            let summary = extrasChatSummary(account: identity, transaction: transaction, peerId: peerId, threadId: threadId, budget: &budget, remainingMessages: &remainingMessages, runtime: runtime)
            guard summary.filteringActive else { return item }
            let counters = EnginePeerReadCounters(state: CombinedPeerReadState(states: summary.projectedStates), isMuted: item.readCounters?.isMuted ?? item.isMuted)
            return EngineChatList.Item(id: item.id, index: item.index, messages: summary.preview.map { [$0] } ?? [], readCounters: counters, isMuted: item.isMuted, draft: item.draft, threadData: item.threadData, renderedPeer: item.renderedPeer, presence: item.presence, hasUnseenMentions: item.hasUnseenMentions && (summary.hasVisibleMentions ?? true), hasUnseenReactions: item.hasUnseenReactions && (summary.hasVisibleReactions ?? true), hasUnseenPollVotes: item.hasUnseenPollVotes, forumTopicData: item.forumTopicData, topForumTopicItems: item.topForumTopicItems, hasFailed: item.hasFailed, isContact: item.isContact, autoremoveTimeout: item.autoremoveTimeout, storyStats: item.storyStats, displayAsTopicList: item.displayAsTopicList, isPremiumRequiredToMessage: item.isPremiumRequiredToMessage, mediaDraftContentType: item.mediaDraftContentType)
        }
        let items = list.items.map(project)
        let additional = list.additionalItems.map { EngineChatList.AdditionalItem(item: project($0.item), promoInfo: $0.promoInfo) }
        // Archive previews contain an actual message too; do not leave the hidden
        // original top message visible after projecting the rows inside it.
        let policy = exteralessFilteringPolicy(account: identity, transaction: transaction, runtime: runtime)
        let groups = list.groupItems.map { item -> EngineChatList.GroupItem in
            var message = item.topMessage
            if let value = message, policy.decision(exteralessFilteringMessage(account: identity, message: value._asMessage(), regexFiltersEnabled: policy.configuration.regexFiltersEnabled), surface: .preview, budget: &budget).isHidden { message = nil }
            let filteredItems = item.items.map { peer -> EngineChatList.GroupItem.Item in
                let summary = extrasChatSummary(account: identity, transaction: transaction, peerId: peer.peer.peerId, threadId: nil, budget: &budget, remainingMessages: &remainingMessages, runtime: runtime)
                return EngineChatList.GroupItem.Item(peer: peer.peer, isUnread: peer.isUnread && (summary.unreadCount.map { $0 > 0 || CombinedPeerReadState(states: summary.projectedStates).markedUnread } ?? true))
            }
            // A group reference contains only a small sample of its peers, not a
            // complete archive. Suppress the numeric badge when filtering applies.
            let showNumber = !policy.hasSenderFilters && !policy.configuration.regexFiltersEnabled
            return EngineChatList.GroupItem(id: item.id, topMessage: message, items: filteredItems, unreadCount: showNumber ? item.unreadCount : 0)
        }
        return EngineChatList(items: items, groupItems: groups, additionalItems: additional, hasEarlier: list.hasEarlier, hasLater: list.hasLater, isLoading: list.isLoading)
    }
}

/// nil means the OS numeric badge must be hidden, not that Telegram has zero
/// unread messages. Uses native muted/category data and a bounded local view of
/// both root and archive. Missing dialogs or unread history are never fabricated.
public func exteralessFilteredAccountBadge(account: Account, countChats: Bool, includeTags: EnginePeerSummaryCounterTags) -> Signal<Int32?, NoError> {
    let identity = exteralessPrivacyExtrasIdentity(account)
    guard ExteralessHiddenAccounts.shared.shouldNotify(identity) else { return .single(0) }
    return combineLatest(account.postbox.tailChatListView(groupId: .root, count: 512, summaryComponents: ChatListEntrySummaryComponents()), account.postbox.tailChatListView(groupId: Namespaces.PeerGroup.archive, count: 512, summaryComponents: ChatListEntrySummaryComponents()))
    |> mapToSignal { root, archive -> Signal<Int32?, NoError> in
        guard root.0.earlierIndex == nil, archive.0.earlierIndex == nil,
              !(root.0.entries + archive.0.entries).contains(where: { if case .HoleEntry = $0 { return true }; return false }) else { return .single(nil) }
        let entries = root.0.entries + archive.0.entries
        return account.postbox.transaction { transaction -> Int32? in
            var budget = FilteringWorkBudget(operations: 1_000_000)
            var remainingMessages = 4_096
            var seen = Set<PeerId>()
            var total = 0
            for entry in entries {
                guard case let .MessageEntry(data) = entry, !data.isRemovedFromTotalUnreadCount, seen.insert(data.renderedPeer.peerId).inserted else { continue }
                let tag: EnginePeerSummaryCounterTags
                switch data.renderedPeer.peer {
                case let user as TelegramUser: tag = user.botInfo == nil ? (data.isContact ? .contact : .nonContact) : .bot
                case let channel as TelegramChannel: if case .group = channel.info { tag = .group } else { tag = .channel }
                case is TelegramGroup: tag = .group
                default: tag = data.isContact ? .contact : .nonContact
                }
                guard !includeTags.intersection(tag).isEmpty else { continue }
                guard let state = data.readState, state.state.isUnread else { continue }
                let summary = extrasChatSummary(account: identity, transaction: transaction, peerId: data.renderedPeer.peerId, threadId: nil, budget: &budget, remainingMessages: &remainingMessages)
                if summary.filteringActive, let channel = data.renderedPeer.peer as? TelegramChannel, channel.isForumOrMonoForum {
                    // Native forum totals may count unread threads. A bounded
                    // peer-history sample cannot prove that aggregate's value.
                    return nil
                }
                guard let unread = summary.unreadCount else { return nil }
                if countChats { total += unread > 0 || state.state.markedUnread ? 1 : 0 }
                else { total += max(unread, state.state.markedUnread ? 1 : 0) }
            }
            return Int32(clamping: total)
        }
    }
}
