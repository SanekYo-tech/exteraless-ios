import ExteralessCore
import Foundation

/// Final contact-card presentation. Both avatar paths consume initials from the
/// same filtered title; the associated peer remains the original photo source.
public struct ExteralessIdentityContactPresentation {
    public let name: String
    public let initials: [String]
    public let avatarPeer: EnginePeer?
}

public func exteralessIdentityContactPresentation(account: Account, contact: TelegramMediaContact, peer: EnginePeer?, fallbackName: String) -> ExteralessIdentityContactPresentation {
    exteralessIdentityContactPresentation(owner: exteralessIdentityAccountId(account),
        state: ExteralessIdentityPresentation.shared.state(account: account), contact: contact,
        peer: peer, fallbackName: fallbackName)
}

/// The shipping account entry delegates to this snapshot variant. Fixtures can
/// exercise real contact payloads and native peers without opening an Account.
public func exteralessIdentityContactPresentation(owner: IdentityAccountId, state: IdentityAccountState?, contact: TelegramMediaContact, peer: EnginePeer?, fallbackName: String) -> ExteralessIdentityContactPresentation {
    let state = state.flatMap { value -> IdentityAccountState? in
        guard value.ownerUserId == owner.userId, value.testingEnvironment == owner.testingEnvironment else { return nil }
        return value
    }
    let peerKey = contact.peerId.flatMap { id -> IdentityPeerKey? in
        guard id.namespace == Namespaces.Peer.CloudUser, id.id._internalGetInt64Value() > 0 else { return nil }
        return IdentityPeerKey(kind: .user, id: id.id._internalGetInt64Value())
    }
    let alias = peerKey.flatMap { state?.alias(for: $0) }
    let composed = IdentityNamePolicy.userName(first: contact.firstName, last: contact.lastName,
        alias: alias, order: state?.nameOrder ?? .firstLast) ?? fallbackName
    let filtered = exteralessZalgoDisplayText(composed)
    let name = filtered.isEmpty ? exteralessZalgoDisplayText(fallbackName) : filtered

    // AvatarNode retains photo/restriction/color handling. Its explicit letters
    // override receives our initials instead of the cached server name's initials.
    let avatarPeer = peer.flatMap { $0.id == contact.peerId ? $0 : nil }
    return ExteralessIdentityContactPresentation(name: name, initials: IdentityNamePolicy.initials(name), avatarPeer: avatarPeer)
}
