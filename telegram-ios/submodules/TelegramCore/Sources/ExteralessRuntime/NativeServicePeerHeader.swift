import Foundation
import Postbox

/// Cache/controller header, deliberately NOT an Api.User/Chat constructor. Fields
/// below come from immutable native Peer snapshots; no flags/pts/access hashes are
/// fabricated to satisfy an Android TL constructor. TL request codecs remain separate.
public func nativeServicePeerHeader(_ peer: EnginePeer, accountUserId: Int64) -> ExteralessTLValue {
    let id = peer.id.id._internalGetInt64Value()
    var fields: [String: ExteralessTLValue] = ["id": .integer(id)]
    let kind: String
    switch peer {
    case let .user(user):
        kind = "user"
        fields["first_name"] = user.firstName.map(ExteralessTLValue.string) ?? .null
        fields["last_name"] = user.lastName.map(ExteralessTLValue.string) ?? .null
        fields["username"] = user.username.map(ExteralessTLValue.string) ?? .null
        fields["phone"] = user.phone.map(ExteralessTLValue.string) ?? .null
        fields["access_hash"] = user.accessHash.map { .integer($0.value) } ?? .null
        fields["self"] = .bool(id == accountUserId)
        fields["bot"] = .bool(user.botInfo != nil)
        fields["deleted"] = .bool(user.isDeleted)
        fields["verified"] = .bool(user.flags.contains(.isVerified))
        fields["premium"] = .bool(user.flags.contains(.isPremium))
        fields["mutual_contact"] = .bool(user.flags.contains(.mutualContact))
    case let .legacyGroup(group):
        kind = "group"
        fields["title"] = .string(group.title)
        fields["participants_count"] = .integer(Int64(group.participantCount))
        fields["date"] = .integer(Int64(group.creationDate))
        fields["version"] = .integer(Int64(group.version))
        switch group.role { case .creator: fields["creator"] = .bool(true); default: fields["creator"] = .bool(false) }
    case let .channel(channel):
        kind = "channel"
        fields["title"] = .string(channel.title)
        fields["username"] = channel.username.map(ExteralessTLValue.string) ?? .null
        fields["access_hash"] = channel.accessHash.map { .integer($0.value) } ?? .null
        fields["date"] = .integer(Int64(channel.creationDate))
        fields["creator"] = .bool(channel.flags.contains(.isCreator))
        fields["forum"] = .bool(channel.flags.contains(.isForum))
        switch channel.info {
        case .broadcast: fields["broadcast"] = .bool(true); fields["megagroup"] = .bool(false)
        case .group: fields["broadcast"] = .bool(false); fields["megagroup"] = .bool(true)
        }
    default:
        return .null
    }
    return .object(["partial": .bool(true), "peer": .object(["type": .string(kind), "id": .integer(id)]),
        "cached": .object(fields), "title": .string(peer.debugDisplayTitle),
        "source": .string("EnginePeer/native-cache-header-v1")])
}

public func nativeServicePeerReference(_ id: EnginePeer.Id) -> ExteralessTLPeerReference? {
    let kind: ExteralessTLPeerReference.Kind
    switch id.namespace {
    case Namespaces.Peer.CloudUser: kind = .user
    case Namespaces.Peer.CloudGroup: kind = .group
    case Namespaces.Peer.CloudChannel: kind = .channel
    default: return nil
    }
    return try? ExteralessTLPeerReference(kind: kind, id: id.id._internalGetInt64Value())
}
