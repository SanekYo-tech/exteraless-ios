import Foundation
import Postbox
import SwiftSignalKit

/// Android getChat(id) has no namespace argument. Consult both REAL cache keys;
/// never infer group/channel from a sign or invent an all-zero peer. If both ids
/// exist, require the typed form rather than returning the wrong conversation.
public func nativeServiceCachedChat(account: Account, id: Int64) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    guard let group = try? ExteralessTLPeerReference(kind: .group, id: id),
          let channel = try? ExteralessTLPeerReference(kind: .channel, id: id) else { return .fail(.local("INVALID_CHAT_ID")) }
    return account.postbox.transaction { transaction -> [ExteralessTLPeerReference] in
        return [group, channel].filter { transaction.getPeer($0.peerId) != nil }
    }
    |> castError(ExteralessTLServiceError.self)
    |> mapToSignal { matches -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        guard matches.count <= 1 else { return .fail(.local("AMBIGUOUS_CHAT_ID_REQUIRES_PEER_TYPE")) }
        guard let peer = matches.first else { return .single(.null) }
        return exteralessTLGetPeer(account: account, reference: peer)
    }
}

/// Reuses the TL agent's authoritative partial peer projection. Subscription is a
/// local Postbox view; it does not refresh from the server or invent access hashes.
public func nativeServiceObservePeer(account: Account, peer: ExteralessTLPeerReference) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    return account.postbox.multiplePeersView([peer.peerId])
    |> castError(ExteralessTLServiceError.self)
    |> mapToSignal { view -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        guard view.peers[peer.peerId] != nil else { return .single(.null) }
        return exteralessTLGetPeer(account: account, reference: peer)
    }
    |> distinctUntilChanged
}

/// Local cached full-info *fields*, explicitly partial rather than a fabricated
/// users.UserFull/messages.ChatFull TL constructor. Missing native cache is null.
public func nativeServicePeerDetails(account: Account, peer: ExteralessTLPeerReference) -> Signal<ExteralessTLValue, NoError> {
    return account.postbox.transaction { transaction -> ExteralessTLValue in
        return nativeServicePeerDetailsValue(transaction.getPeerCachedData(peerId: peer.peerId), peer: peer)
    }
}

public func nativeServiceObservePeerDetails(account: Account, peer: ExteralessTLPeerReference) -> Signal<ExteralessTLValue, NoError> {
    let key = PostboxViewKey.cachedPeerData(peerId: peer.peerId)
    return account.postbox.combinedView(keys: [key])
    |> map { view -> ExteralessTLValue in
        return nativeServicePeerDetailsValue((view.views[key] as? CachedPeerDataView)?.cachedPeerData, peer: peer)
    }
    |> distinctUntilChanged
}

private func nativeServicePeerDetailsValue(_ cached: CachedPeerData?, peer: ExteralessTLPeerReference) -> ExteralessTLValue {
    guard let cached else { return .null }
    var value: [String: ExteralessTLValue] = ["partial": .bool(true), "peer": peer.value, "id": .integer(peer.id)]
    switch cached {
    case let user as CachedUserData:
        value["user_id"] = .integer(peer.id)
        value["about"] = user.about.map(ExteralessTLValue.string) ?? .null
        value["blocked"] = .bool(user.isBlocked)
        value["common_chats_count"] = .integer(Int64(user.commonGroupCount))
        value["phone_calls_available"] = .bool(user.voiceCallsAvailable)
        value["video_calls_available"] = .bool(user.videoCallsAvailable)
        value["pinned_message_id"] = user.pinnedMessageId.map { .integer(Int64($0.id)) } ?? .null
    case let group as CachedGroupData:
        value["about"] = group.about.map(ExteralessTLValue.string) ?? .null
        value["pinned_message_id"] = group.pinnedMessageId.map { .integer(Int64($0.id)) } ?? .null
        if let participants = group.participants {
            let admins = participants.participants.filter {
                switch $0 { case .creator, .admin: return true; case .member: return false }
            }
            value["admin_ids"] = .array(admins.prefix(256).map { .integer($0.peerId.id._internalGetInt64Value()) })
            value["admins_count"] = .integer(Int64(admins.count))
            value["admin_ids_truncated"] = .bool(admins.count > 256)
            value["participants_count"] = .integer(Int64(participants.participants.count))
            value["participants_version"] = .integer(Int64(participants.version))
        } else {
            value["admin_ids"] = .null
        }
    case let channel as CachedChannelData:
        value["about"] = channel.about.map(ExteralessTLValue.string) ?? .null
        value["pinned_message_id"] = channel.pinnedMessageId.map { .integer(Int64($0.id)) } ?? .null
        value["participants_count"] = channel.participantsSummary.memberCount.map { .integer(Int64($0)) } ?? .null
        value["admins_count"] = channel.participantsSummary.adminCount.map { .integer(Int64($0)) } ?? .null
        // CachedChannelData has the count, not a complete admin identity list.
        value["admin_ids"] = .null
        value["banned_count"] = channel.participantsSummary.bannedCount.map { .integer(Int64($0)) } ?? .null
    default:
        return .null
    }
    return .object(value)
}

/// IDs only: publishing the contacts cache must not materialize 20k TelegramUser
/// objects at startup. Pages beyond the retained prefix are explicitly not ready.
public func nativeServiceContactIDs(account: Account) -> Signal<ExteralessTLValue, NoError> {
    return Signal { subscriber in
        // MetadataTable defaults an absent remote count to zero. That is not a
        // contacts-loaded bit. An initially empty cache must remain not ready;
        // clearing a previously observed nonempty cache is a real empty snapshot.
        var observedNonempty = false
        return account.postbox.contactPeerIdsView().start(next: { view in
            let ids = view.peerIds.filter { $0.namespace == Namespaces.Peer.CloudUser }.map { $0.id._internalGetInt64Value() }.sorted()
            if !ids.isEmpty { observedNonempty = true }
            guard observedNonempty else { subscriber.putNext(.null); return }
            subscriber.putNext(.object(["ids": .array(ids.prefix(512).map(ExteralessTLValue.integer)),
                "total": .integer(Int64(ids.count)), "complete": .bool(ids.count <= 512),
                "remoteTotal": .integer(Int64(view.remoteTotalCount))]))
        }, completed: subscriber.putCompletion)
    }
    |> distinctUntilChanged
}

/// The peer's stored overrides, not an invented effective notification policy.
/// Default/inherit and absent cache stay distinct from false or zero.
public func nativeServiceNotificationSettings(account: Account, peer: ExteralessTLPeerReference) -> Signal<ExteralessTLValue, NoError> {
    return account.postbox.transaction { transaction -> ExteralessTLValue in
        guard let settings = transaction.getPeerNotificationSettings(id: peer.peerId) as? TelegramPeerNotificationSettings else { return .null }
        var value: [String: ExteralessTLValue] = ["peer": peer.value, "scope": .string("peerOverrides")]
        switch settings.muteState {
        case .default: value["mute"] = .string("inherit")
        case .unmuted: value["mute"] = .string("unmuted")
        case let .muted(until):
            value["mute"] = .string("muted")
            value["mute_until"] = .integer(Int64(until))
        }
        switch settings.displayPreviews {
        case .default: value["show_previews"] = .null
        case .show: value["show_previews"] = .bool(true)
        case .hide: value["show_previews"] = .bool(false)
        }
        return .object(value)
    }
}

/// Contact identity projection for a bounded, explicitly paged local list. Peer
/// constructors remain the TL service's responsibility (nativeServiceObservePeer).
public func nativeServiceContactPage(_ list: EngineContactList, offset: Int, limit: Int) -> ExteralessTLValue {
    let peers = list.peers.sorted { $0.id < $1.id }
    let start = min(max(0, offset), peers.count)
    let end = min(start + max(1, min(500, limit)), peers.count)
    let values: [ExteralessTLValue] = peers[start..<end].map { peer in
        var value: [String: ExteralessTLValue] = ["id": .integer(peer.id.id._internalGetInt64Value()), "title": .string(peer.debugDisplayTitle)]
        switch peer {
        case .user: value["type"] = .string("user")
        case .legacyGroup: value["type"] = .string("group")
        case .channel: value["type"] = .string("channel")
        default: value["type"] = .string("unsupported")
        }
        return .object(value)
    }
    return .object(["total": .integer(Int64(peers.count)), "offset": .integer(Int64(start)), "peers": .array(values),
        "nextOffset": end < peers.count ? .integer(Int64(end)) : .null])
}
