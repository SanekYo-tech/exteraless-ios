import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

public func nativeServiceCachedMessageValue(account: Account, id: EngineMessage.Id) -> Signal<ExteralessTLValue, NoError> {
    return account.postbox.transaction { transaction -> ExteralessTLValue in
        guard let message = transaction.getMessage(id) else { return .null }
        return (try? nativeServiceMessageValue(message, accountUserId: account.peerId.id._internalGetInt64Value(), transaction: transaction)) ?? .null
    }
}

/// Portable MessageObject payload. It contains real native fields and carries an
/// explicit partial marker; it is not an all-default TLRPC.Message emulation.
func nativeServiceMessageValue(_ message: EngineRawMessage, accountUserId: Int64,
                                      transaction: Transaction? = nil) throws -> ExteralessTLValue {
    guard let peer = nativeServicePeerReference(message.id.peerId) else {
        throw ExteralessTLError(.unsupported, "Message peer namespace has no portable dialog id")
    }
    let dialogId = peer.kind == .user ? peer.id : -peer.id
    var fields: [String: ExteralessTLValue] = [
        "id": .integer(Int64(message.id.id)), "date": .integer(Int64(message.timestamp)),
        "message": .string(message.text), "out": .bool(!message.flags.contains(.Incoming)),
        "peer_id": try nativeServiceMessagePeer(message.id.peerId),
        "grouped_id": message.groupingKey.map(ExteralessTLValue.integer) ?? .null
    ]
    if let author = message.author { fields["from_id"] = try nativeServiceMessagePeer(author.id) }
    if let state = transaction?.getCombinedPeerReadState(message.id.peerId) {
        fields["unread"] = .bool(!state.isIncomingMessageIndexRead(message.index))
    }
    var entities: [ExteralessTLValue] = []
    for attribute in message.attributes {
        if let attribute = attribute as? TextEntitiesMessageAttribute {
            entities = try apiTextAttributeEntities(attribute, associatedPeers: message.peers).map(exteralessTLNativeSnapshot)
        } else if let attribute = attribute as? ReplyMessageAttribute {
            var reply: [String: ExteralessTLValue] = ["reply_to_msg_id": .integer(Int64(attribute.messageId.id))]
            if let top = attribute.threadMessageId { reply["reply_to_top_id"] = .integer(Int64(top.id)) }
            fields["reply_to"] = .object(reply)
        }
    }
    fields["entities"] = .array(entities)
    let media = message.effectiveMedia.map(nativeServiceMessageMediaValue)
    fields["media"] = media.isEmpty ? .null : (media.count == 1 ? media[0] : .object(["native_items": .array(media), "partial": .bool(true)]))
    return .object(["nativeType": .string("MessageObject"), "partial": .bool(true),
        "messageOwner": .object(fields), "dialogId": .integer(dialogId),
        "namespace": .integer(Int64(message.id.namespace)), "isForwarded": .bool(message.forwardInfo != nil),
        "source": .string("Postbox.Message/native-message-v1")])
}

private func nativeServiceMessagePeer(_ id: PeerId) throws -> ExteralessTLValue {
    let value = id.id._internalGetInt64Value()
    let peer: Api.Peer
    switch id.namespace {
    case Namespaces.Peer.CloudUser: peer = .peerUser(.init(userId: value))
    case Namespaces.Peer.CloudGroup: peer = .peerChat(.init(chatId: value))
    case Namespaces.Peer.CloudChannel: peer = .peerChannel(.init(channelId: value))
    default: throw ExteralessTLError(.unsupported, "Unsupported portable message peer")
    }
    return try exteralessTLNativeSnapshot(peer)
}

private func nativeServiceMessageMediaValue(_ media: Media) -> ExteralessTLValue {
    if let file = media as? TelegramMediaFile {
        var document: [String: ExteralessTLValue] = ["id": .integer(file.fileId.id), "mime_type": .string(file.mimeType),
                "size": file.size.map(ExteralessTLValue.integer) ?? .null,
                "file_name": file.fileName.map(ExteralessTLValue.string) ?? .null,
                "resourceId": .string(file.resource.id.stringRepresentation),
                "isVideo": .bool(file.isVideo), "isVoice": .bool(file.isVoice), "isMusic": .bool(file.isMusic)]
        if let resource = file.resource as? CloudDocumentMediaResource {
            document["access_hash"] = .integer(resource.accessHash)
            document["file_reference"] = resource.fileReference.map(ExteralessTLValue.bytes) ?? .null
            document["dc_id"] = .integer(Int64(resource.datacenterId))
        }
        return .object(["nativeType": .string("file"), "partial": .bool(true), "document": .object(document)])
    }
    if let image = media as? TelegramMediaImage {
        var photo: [String: ExteralessTLValue] = ["id": image.id.map { .integer($0.id) } ?? .null,
                "representations": .array(image.representations.map { representation in
                    .object(["width": .integer(Int64(representation.dimensions.width)), "height": .integer(Int64(representation.dimensions.height)),
                        "resourceId": .string(representation.resource.id.stringRepresentation)])
                })]
        if case let .cloud(id, hash, reference)? = image.reference {
            photo["id"] = .integer(id)
            photo["access_hash"] = .integer(hash)
            photo["file_reference"] = reference.map(ExteralessTLValue.bytes) ?? .null
        }
        return .object(["nativeType": .string("image"), "partial": .bool(true), "photo": .object(photo)])
    }
    return .object(["nativeType": .string(String(describing: type(of: media))), "partial": .bool(true), "unsupportedFields": .bool(true)])
}
