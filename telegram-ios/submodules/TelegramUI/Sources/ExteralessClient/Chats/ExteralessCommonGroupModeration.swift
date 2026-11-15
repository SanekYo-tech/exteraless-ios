import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

/// Original common-chat request is capped at 100. Reuse the native context's 32-item
/// pages and keep its loading cache emissions out of the completed result.
private func exteralessModerationCommonGroups(context: AccountContext, authorId: EnginePeer.Id) -> Signal<[EnginePeer], NoError> {
    return Signal { subscriber in
        let groups = GroupsInCommonContext(account: context.account, peerId: authorId)
        var pages = 1
        let disposable = groups.state.start(next: { state in
            guard case let .ready(canLoadMore) = state.dataState else { return }
            if canLoadMore && state.peers.count < 100 && pages < 4 {
                pages += 1
                groups.loadMore()
                return
            }
            subscriber.putNext(state.peers.prefix(100).compactMap { $0.peer.map(EnginePeer.init) })
            subscriber.putCompletion()
        })
        return ActionDisposable { disposable.dispose(); withExtendedLifetime(groups) {} }
    }
    |> runOn(.mainQueue())
    |> timeout(12, queue: .mainQueue(), alternate: .single([]))
}

extension ChatControllerImpl {
    /// Called only from the native sheet's committed ChatResult. Report is already an
    /// author-global operation; common groups apply the selected ban/restriction/history actions.
    func exteralessApplyInCommonGroups(sourcePeerId: EnginePeer.Id, banPeers: [EnginePeer.Id], restrictions: [EnginePeer.Id: TelegramChatBannedRights], deleteAllPeers: [EnginePeer.Id]) {
        let context = self.context
        let authors = Set(banPeers).union(restrictions.keys).union(deleteAllPeers).filter {
            $0.namespace == Namespaces.Peer.CloudUser && $0 != context.account.peerId
        }.sorted()
        var operation: Signal<Never, NoError> = .complete()
        for author in authors {
            let authorOperation = exteralessModerationCommonGroups(context: context, authorId: author)
            |> mapToSignal { peers -> Signal<[EnginePeer], NoError> in
                // The native context can retain cached RenderedPeers with unchanged IDs.
                // Re-read current rights after discovery, before selecting any operation.
                context.engine.data.get(EngineDataMap(peers.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.id) }))
                |> map { current in peers.compactMap { current[$0.id] ?? nil } }
            }
            |> mapToSignal { peers -> Signal<Never, NoError> in
                var actions: Signal<Never, NoError> = .complete()
                for peer in peers where peer.id != sourcePeerId {
                    let cloudChannel: Bool
                    let canBan: Bool
                    let canDelete: Bool
                    switch peer {
                    case let .channel(channel):
                        guard case .group = channel.info, !channel.isMonoForum else { continue }
                        cloudChannel = true
                        canBan = channel.hasPermission(.banMembers)
                        canDelete = channel.hasPermission(.deleteAllMessages)
                    case let .legacyGroup(group):
                        cloudChannel = false
                        switch group.role {
                        case .creator: canBan = true
                        case let .admin(rights, _): canBan = rights.rights.contains(.canBanUsers)
                        case .member: canBan = false
                        }
                        canDelete = false
                    default: continue
                    }
                    let allowed = ChatCommonGroupModerationPolicy.allowed(ban: banPeers.contains(author), restrict: restrictions[author] != nil, clearHistory: deleteAllPeers.contains(author), cloudChannel: cloudChannel, canBan: canBan, canDelete: canDelete)
                    if allowed.contains(.clearHistory) {
                        actions = actions |> then(context.engine.messages.clearAuthorHistory(peerId: peer.id, memberId: author) |> ignoreValues)
                    }
                    if allowed.contains(.ban) {
                        actions = actions |> then(context.engine.peers.removePeerMember(peerId: peer.id, memberId: author) |> ignoreValues)
                    } else if allowed.contains(.restrict), let requested = restrictions[author] {
                        let restriction = context.engine.peers.fetchChannelParticipant(peerId: peer.id, participantId: author)
                        |> mapToSignal { participant -> Signal<Never, NoError> in
                            var rights = requested
                            if case let .member(_, _, _, banInfo, _, _)? = participant, let existing = banInfo?.rights {
                                rights = TelegramChatBannedRights(flags: requested.flags.union(existing.flags), untilDate: max(requested.untilDate, existing.untilDate))
                            }
                            return context.engine.peers.updateChannelMemberBannedRights(peerId: peer.id, memberId: author, rights: rights) |> ignoreValues
                        }
                        actions = actions |> then(restriction)
                    }
                }
                return actions
            }
            operation = operation |> then(authorOperation)
        }
        let _ = operation.startStandalone()
    }
}
