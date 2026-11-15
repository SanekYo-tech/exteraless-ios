import AccountContext
import ChatHistoryEntry
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

typealias ExteralessRetentionHistoryInput = (ChatHistoryViewUpdate, Int, ChatHistoryLocationInput?, ClosedRange<Int32>?, Set<EngineMessage.Id>)
typealias ExteralessRetentionHistoryOutput = (ChatHistoryViewUpdate, Int, ChatHistoryLocationInput?, ClosedRange<Int32>?, Set<EngineMessage.Id>, [ExteralessRetentionEntry])

private func exteralessRetentionSettingsChanges() -> Signal<Void, NoError> {
    Signal { subscriber in
        let observation = ClientSettings.shared.observe { keys in
            if keys.isEmpty || !keys.isDisjoint(with: RetentionFeatures.keys) { subscriber.putNext(()) }
        }
        subscriber.putNext(())
        return ActionDisposable { observation.cancel() }
    }
}

/// Pairs a real history update with its local overlays BEFORE delivering it to the list. No
/// MessageHistoryView is manufactured: server holes, indices and read states retain their owner.
/// Coordinator connects the returned sixth tuple field only to filtered display entries.
func exteralessRetentionHistoryUpdates(context: AccountContext, location: ChatLocation, source: Signal<ExteralessRetentionHistoryInput, NoError>, enabled: Bool) -> Signal<ExteralessRetentionHistoryOutput, NoError> {
    return source |> mapToSignal { update -> Signal<ExteralessRetentionHistoryOutput, NoError> in
        func result(_ entries: [ExteralessRetentionEntry]) -> ExteralessRetentionHistoryOutput { (update.0, update.1, update.2, update.3, update.4, entries) }
        guard enabled, let peerId = location.peerId,
              case let .HistoryView(view, _, _, _, _, _, _) = update.0, !view.isLoading else { return .single(result([])) }
        let liveIds = Set(view.entries.map { $0.message.id })
        // Stay inside the loaded window whenever a server boundary/hole is present. Empty
        // complete histories may show their latest retained page through the same local adapter.
        let lower = view.holeEarlier || view.earlierId != nil ? view.entries.first?.message.index : nil
        let upper = view.holeLater || view.laterId != nil ? view.entries.last?.message.index : nil
        if view.entries.isEmpty && (view.holeEarlier || view.holeLater) { return .single(result([])) }
        return combineLatest(context.engine.messages.retentionChanges(), exteralessRetentionSettingsChanges(), ExteralessFilteringRuntime.shared.changes)
        |> mapToSignal { _ -> Signal<ExteralessRetentionHistoryOutput, NoError> in
            guard RetentionPolicy.current.saveDeleted else { return .single(result([])) }
            return context.engine.messages.retainedMessages(peerId: peerId, threadId: location.threadId, lowerBound: lower, upperBound: upper)
            |> map { page in
                guard case let .success(page) = page else { return result([]) }
                return result(page.entries.filter { entry in
                    !liveIds.contains(entry.message.id) && !update.4.contains(entry.message.id)
                        && view.namespaces.contains(entry.message.id.namespace)
                        && !(update.3?.contains(entry.message.timestamp) ?? false)
                })
            }
        }
    }
}

/// The raw history remains the server's view. Local copies exist only in the display projection,
/// are always read/nonselectable and carry their native ExteralessRetentionMessageAttribute.
func exteralessRetentionMergeDisplayEntries(_ base: [ChatHistoryEntry], retained: [ExteralessRetentionEntry], presentationData: ChatPresentationData, groupMessages: Bool, reverse: Bool, reverseGroups: Bool, historyAppearsCleared: Bool, pendingRemovedMessages: Set<EngineMessage.Id>) -> [ChatHistoryEntry] {
    guard !historyAppearsCleared, !retained.isEmpty else { return base }
    var result = base
    var ids = Set<EngineMessage.Id>()
    for entry in base {
        switch entry {
        case let .MessageEntry(message, _, _, _, _, _): ids.insert(message.id)
        case let .MessageGroupEntry(_, messages, _): for value in messages { ids.insert(value.0.id) }
        default: break
        }
    }
    for entry in retained {
        let message = entry.message._asMessage()
        guard entry.reason == .deleted, !pendingRemovedMessages.contains(message.id), ids.insert(message.id).inserted else { continue }
        let attributes = ChatMessageEntryAttributes()
        var grouped = false
        if groupMessages, let albumKey = ExteralessRetentionAlbumKey(entry.message) {
            for index in result.indices {
                switch result[index] {
                case let .MessageGroupEntry(groupId, values, data) where !values.isEmpty && values.allSatisfy({ ExteralessRetentionAlbumKey(EngineMessage($0.0)) == albumKey }):
                    var values = values
                    values.append((message, true, .none, attributes, nil))
                    values.sort { reverseGroups ? $0.0.index > $1.0.index : $0.0.index < $1.0.index }
                    result[index] = .MessageGroupEntry(groupId, values, data)
                    grouped = true
                case let .MessageEntry(other, data, isRead, location, selection, previousAttributes) where ExteralessRetentionAlbumKey(EngineMessage(other)) == albumKey:
                    var values: [(EngineRawMessage, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, EngineMessageHistoryEntryLocation?)] = [
                        (other, isRead, selection, previousAttributes, location), (message, true, .none, attributes, nil)
                    ]
                    values.sort { reverseGroups ? $0.0.index > $1.0.index : $0.0.index < $1.0.index }
                    guard let groupId = previousAttributes.groupStableId ?? entry.message.exteralessRetention?.albumStableId else { continue }
                    result[index] = .MessageGroupEntry(groupId, values, data)
                    grouped = true
                default: break
                }
                if grouped { break }
            }
        }
        if !grouped {
            var attributes = attributes
            if groupMessages, let groupId = entry.message.exteralessRetention?.albumStableId,
               !result.contains(where: { $0.stableId == (UInt64(bitPattern: groupId) | (UInt64(2) << 40)) }) {
                attributes.groupStableId = groupId
            }
            result.append(.MessageEntry(message, presentationData, true, nil, .none, attributes))
        }
    }
    result.sort()
    if reverse { result.reverse() }
    return result
}
