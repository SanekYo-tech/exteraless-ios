import Foundation
import SwiftSignalKit

/// SearchAdapterHelper's allowGlobalResults contract: keep my_results; in the
/// global partition keep contacts and joined chats. The native contacts.search
/// provider is still needed and message/hashtag providers are independent.
public func exteralessDialogRemotePeerResults(engine: TelegramEngine, source: Signal<([FoundPeer], [FoundPeer]), NoError>) -> Signal<([FoundPeer], [FoundPeer]), NoError> {
    return combineLatest(source, exteralessDialogPolicyUpdates() |> map { $0.disableGlobalSearch } |> distinctUntilChanged)
    |> mapToSignal { results, disabled -> Signal<([FoundPeer], [FoundPeer]), NoError> in
        guard disabled else { return .single(results) }
        let userIds = results.1.compactMap { found -> EnginePeer.Id? in
            if case .user = found.peer { return found.peer.id }
            return nil
        }
        return engine.data.get(EngineDataMap(userIds.map { TelegramEngine.EngineData.Item.Peer.IsContact(id: $0) }))
        |> map { contacts in
            let global = results.1.filter { found in
                switch found.peer {
                case .user: return found.peer.id == engine.account.peerId || contacts[found.peer.id] == true
                case let .legacyGroup(group): return group.membership == .Member
                case let .channel(channel): return channel.participationStatus == .member
                case .secretChat: return true
                case .community: return results.0.contains(where: { $0.peer.id == found.peer.id })
                }
            }
            return (results.0, global)
        }
    }
}
