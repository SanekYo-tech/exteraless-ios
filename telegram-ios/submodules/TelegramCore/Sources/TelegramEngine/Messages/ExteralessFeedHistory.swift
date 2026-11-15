import Foundation
import Postbox
import SwiftSignalKit

public struct ExteralessFeedHistoryPage {
    public let messages: [EngineMessage]
    public let oldest: EngineMessage.Index?
    public let hasEarlier: Bool
    public let isAvailable: Bool

    public init(messages: [EngineMessage], oldest: EngineMessage.Index?, hasEarlier: Bool, isAvailable: Bool = true) {
        self.messages = messages
        self.oldest = oldest
        self.hasEarlier = hasEarlier
        self.isAvailable = isAvailable
    }
}

/// A normal native history view owns hole filling, media references and cancellation. The feed
/// does not manufacture message IDs, use the parked News API, or install interactive read actions.
/// Callers bound concurrency and dispose the view on completion, timeout, or account replacement.
public func exteralessFeedHistoryPage(engine: TelegramEngine, peerId: EnginePeer.Id, before: EngineMessage.Index?, count: Int = 20) -> Signal<ExteralessFeedHistoryPage, NoError> {
    guard peerId.namespace == Namespaces.Peer.CloudChannel, before == nil || before?.id.peerId == peerId else {
        return .single(ExteralessFeedHistoryPage(messages: [], oldest: nil, hasEarlier: true, isAvailable: false))
    }
    let count = max(2, min(20, count))
    let anchor: MessageHistoryAnchorIndex = before.map(MessageHistoryAnchorIndex.message) ?? .upperBound
    return engine.account.viewTracker.aroundMessageHistoryViewForLocation(
        .peer(peerId: peerId, threadId: nil),
        index: anchor,
        anchorIndex: anchor,
        count: count * (before == nil ? 1 : 2),
        ignoreRelatedChats: true,
        fixedCombinedReadStates: nil,
        appendMessagesFromTheSameGroup: true
    )
    |> filter { view, _, _ in !view.isLoading && !view.isLoadingEarlier }
    |> take(1)
    |> map { view, _, _ in
        let older = view.entries.filter { entry in
            entry.message.id.peerId == peerId && entry.message.id.namespace == Namespaces.Message.Cloud && (before == nil || entry.message.index < before!)
        }.sorted { $0.message.index > $1.message.index }
        var entries = Array(older.prefix(count))
        if let tail = entries.last, let group = tail.message.groupingKey {
            // Native history's appendMessagesFromTheSameGroup resolves the album at the
            // page boundary. Keep at most Telegram's nine extra album members.
            for entry in older.dropFirst(entries.count).prefix(9) {
                guard entry.message.groupingKey == group else { break }
                entries.append(entry)
            }
        }
        // Advance over service messages too, or a page containing only actions loops forever.
        let oldest = entries.map { $0.message.index }.min()
        let messages = entries.compactMap { entry -> EngineMessage? in
            if !exteralessFeedMessageIsEligible(EngineMessage(entry.message)) { return nil }
            return EngineMessage(entry.message)
        }
        return ExteralessFeedHistoryPage(messages: messages, oldest: oldest, hasEarlier: view.earlierId != nil || view.holeEarlier || older.count > entries.count)
    }
}
