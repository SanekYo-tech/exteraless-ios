import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

private let tlMediaResourceQueue = Queue(name: "Exteraless.TLMediaResources", qos: .utility)

func exteralessTLResolvedNotificationInfo(silent: Bool) -> NotificationInfoMessageAttribute {
    return NotificationInfoMessageAttribute(flags: silent ? [.muted] : [])
}

/// Values obtained by native media inspection, not Android object placeholders.
public struct ExteralessTLPreparedMedia: Sendable {
    public enum Kind: String, Sendable { case photo, document, audio, video }
    public let kind: Kind
    public let data: Data
    public let fileName: String
    public let mimeType: String
    public let width: Int32?
    public let height: Int32?
    public let duration: Double?

    public init(kind: Kind, data: Data, fileName: String, mimeType: String,
                width: Int32? = nil, height: Int32? = nil, duration: Double? = nil) throws {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024, !fileName.isEmpty,
              fileName.utf8.count <= 255, !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0"),
              !mimeType.isEmpty, mimeType.utf8.count <= 128 else {
            throw ExteralessTLError(.malformed, "sendMedia: invalid/bounded file data or metadata")
        }
        if kind == .photo || kind == .video {
            guard let width, let height, width > 0, height > 0, width <= 32768, height <= 32768 else {
                throw ExteralessTLError(.malformed, "sendMedia: native image/video dimensions are unavailable")
            }
        }
        if kind == .audio || kind == .video {
            guard let duration, duration.isFinite, duration > 0, duration <= Double(Int32.max) else {
                throw ExteralessTLError(.malformed, "sendMedia: native audio/video duration is unavailable")
            }
        }
        self.kind = kind
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.duration = duration
    }
}

public struct ExteralessTLPreparedMessage: Sendable {
    public let media: ExteralessTLPreparedMedia?
    public let text: String
    public let entities: [ExteralessTLValue]
    public let spoiler: Bool
    public let ttlSeconds: Int32?

    public init(media: ExteralessTLPreparedMedia?, text: String, entities: [ExteralessTLValue], spoiler: Bool = false, ttlSeconds: Int32? = nil) {
        self.media = media
        self.text = text
        self.entities = entities
        self.spoiler = spoiler
        self.ttlSeconds = ttlSeconds
    }
}

/// Validates all entities before using Core's conversion (which intentionally drops
/// some receive-only types). A caller never loses formatting silently.
public func exteralessTLValidateMediaEntities(_ values: [ExteralessTLValue], caption: String) throws {
    _ = try tlMediaEntities(values, caption: caption)
}

func tlMediaEntities(_ values: [ExteralessTLValue], caption: String) throws -> [MessageTextEntity] {
    let bodies = try ExteralessTLTransformCodec.mediaEntityBodies(values, caption: caption)
    var entities: [Api.MessageEntity] = []
    for data in bodies {
        let reader = BufferReader(Buffer(data: data))
        guard let signature = reader.readInt32(), let entity = Api.parse(reader, signature: signature) as? Api.MessageEntity else {
            throw ExteralessTLError(.schema, "sendMedia: native entity parser disagrees with bridge schema")
        }
        entities.append(entity)
    }
    let converted = messageTextEntitiesFromApiEntities(entities)
    guard converted.count == entities.count else {
        throw ExteralessTLError(.unsupported, "sendMedia: native entity conversion would discard a field")
    }
    return converted
}

/// Uses local native resources and the same upload/enqueue pipeline as the composer.
/// Result ids are local Postbox ids, not server delivery receipts. Cancelling the
/// Signal after its enqueue transaction starts cannot recall that transaction.
public func exteralessTLSendMedia(account: Account, reference: ExteralessTLPeerReference,
                                  media: ExteralessTLPreparedMedia, caption: String,
                                  entities: [ExteralessTLValue], silent: Bool,
                                  replyToId: Int32?, threadId: Int64?,
                                  scheduleTime: Int32? = nil, replyToNamespace: Int32? = nil,
                                  spoiler: Bool = false, ttlSeconds: Int32? = nil,
                                  origin: ExteralessTLRequestOrigin? = nil,
                                  isCancelled: @escaping @Sendable () -> Bool = { false }) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    return tlEnqueueFromPlugin(account: account, reference: reference, media: media, caption: caption,
        entities: entities, silent: silent, replyToId: replyToId, threadId: threadId,
        disableLinkPreviews: false, scheduleTime: scheduleTime, replyToNamespace: replyToNamespace,
        spoiler: spoiler, ttlSeconds: ttlSeconds, origin: origin, isCancelled: isCancelled)
}

/// Rich/plain text uses the same native outgoing path as media; raw RPC submission
/// alone would not create a pending message or apply the send's returned Updates.
public func exteralessTLSendText(account: Account, reference: ExteralessTLPeerReference,
                                 text: String, entities: [ExteralessTLValue], silent: Bool,
                                 replyToId: Int32?, threadId: Int64?,
                                 disableLinkPreviews: Bool = false, scheduleTime: Int32? = nil,
                                 replyToNamespace: Int32? = nil, ttlSeconds: Int32? = nil,
                                 origin: ExteralessTLRequestOrigin? = nil,
                                 isCancelled: @escaping @Sendable () -> Bool = { false }) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .fail(.local("TEXT_EMPTY"))
    }
    return tlEnqueueFromPlugin(account: account, reference: reference, media: nil, caption: text,
        entities: entities, silent: silent, replyToId: replyToId, threadId: threadId,
        disableLinkPreviews: disableLinkPreviews, scheduleTime: scheduleTime, replyToNamespace: replyToNamespace,
        spoiler: false, ttlSeconds: ttlSeconds, origin: origin, isCancelled: isCancelled)
}

public func exteralessTLSendAlbum(account: Account, reference: ExteralessTLPeerReference, items: [ExteralessTLPreparedMessage],
                                 silent: Bool, replyToId: Int32?, replyToNamespace: Int32? = nil, threadId: Int64?,
                                 scheduleTime: Int32? = nil, origin: ExteralessTLRequestOrigin? = nil,
                                 isCancelled: @escaping @Sendable () -> Bool = { false }) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    guard items.count >= 2, items.count <= 10, let first = items.first, items.allSatisfy({ $0.media != nil }),
          items.reduce(0, { $0 + ($1.media?.data.count ?? 0) }) <= 32 * 1024 * 1024 else { return .fail(.local("ALBUM_LIMIT_OR_EMPTY_MEDIA")) }
    let families = Set(items.compactMap { item -> String? in
        guard let media = item.media else { return nil }
        switch media.kind { case .photo, .video: return "visual"; case .audio: return "audio"; case .document: return "document" }
    })
    guard families.count == 1 else { return .fail(.local("ALBUM_MIXED_MEDIA_FAMILIES")) }
    return tlEnqueueFromPlugin(account: account, reference: reference, media: first.media, caption: first.text,
        entities: first.entities, silent: silent, replyToId: replyToId, threadId: threadId,
        disableLinkPreviews: false, scheduleTime: scheduleTime, replyToNamespace: replyToNamespace,
        spoiler: first.spoiler, ttlSeconds: first.ttlSeconds, origin: origin, additional: Array(items.dropFirst()), isCancelled: isCancelled)
}

private func tlEnqueueFromPlugin(account: Account, reference: ExteralessTLPeerReference,
                                 media: ExteralessTLPreparedMedia?, caption: String,
                                 entities: [ExteralessTLValue], silent: Bool,
                                 replyToId: Int32?, threadId: Int64?,
                                 disableLinkPreviews: Bool, scheduleTime: Int32?,
                                 replyToNamespace: Int32?, spoiler: Bool, ttlSeconds: Int32?,
                                 origin: ExteralessTLRequestOrigin?,
                                 additional: [ExteralessTLPreparedMessage] = [],
                                 isCancelled: @escaping @Sendable () -> Bool) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    if let scheduleTime, scheduleTime <= 0 { return .fail(.local("SCHEDULE_INVALID")) }
    let items = [ExteralessTLPreparedMessage(media: media, text: caption, entities: entities, spoiler: spoiler, ttlSeconds: ttlSeconds)] + additional
    let prepared: [(ExteralessTLPreparedMessage, [MessageTextEntity])]
    do {
        prepared = try items.map { ($0, try tlMediaEntities($0.entities, caption: $0.text)) }
    } catch let error as ExteralessTLError {
        return .fail(.local("MEDIA_\(error.kind.rawValue): \(error.message)"))
    } catch {
        return .fail(.local("MEDIA_ENTITY_ERROR"))
    }
    let peerId = reference.peerId
    let isSecret = peerId.namespace == Namespaces.Peer.SecretChat
    let replyNamespace = replyToNamespace ?? Namespaces.Message.Cloud
    if isSecret, replyToId != nil, replyToNamespace == nil { return .fail(.local("SECRET_REPLY_REQUIRES_NAMESPACE")) }
    if isSecret, threadId != nil || scheduleTime != nil { return .fail(.local("SECRET_THREAD_OR_SCHEDULE_UNSUPPORTED")) }
    return account.postbox.transaction { transaction -> ExteralessTLServiceError? in
        if isCancelled() { return .local("MEDIA_CANCELLED") }
        guard let peer = transaction.getPeer(peerId), (isSecret ? apiInputSecretChat(peer) != nil : apiInputPeerOrSelf(peer, accountPeerId: account.peerId) != nil) else {
            return .local("PEER_NOT_CACHED")
        }
        guard canSendMessagesToPeer(EnginePeer(peer)) else { return .local("MEDIA_PEER_SEND_RESTRICTED") }
        for (item, textEntities) in prepared {
            let bannedPermission: TelegramChatBannedRightsFlags
            switch item.media?.kind {
            case .photo: bannedPermission = .banSendPhotos
            case .document: bannedPermission = .banSendFiles
            case .audio: bannedPermission = .banSendMusic
            case .video: bannedPermission = .banSendVideos
            case .none: bannedPermission = .banSendText
            }
            if let group = peer as? TelegramGroup, group.hasBannedPermission(bannedPermission) { return .local("MEDIA_KIND_SEND_RESTRICTED") }
            if let channel = peer as? TelegramChannel, channel.hasBannedPermission(bannedPermission) != nil { return .local("MEDIA_KIND_SEND_RESTRICTED") }
            if item.spoiler && (item.media == nil || isSecret) { return .local("MEDIA_SPOILER_UNSUPPORTED_FOR_TARGET") }
            if let ttl = item.ttlSeconds {
                if ttl <= 0 { return .local("MEDIA_TTL_INVALID") }
                if isSecret {
                    if ttl > 604800 { return .local("SECRET_TTL_OUT_OF_RANGE") }
                } else if peerId.namespace != Namespaces.Peer.CloudUser || peerId == account.peerId || items.count > 1
                    || !(item.media?.kind == .photo || item.media?.kind == .video) || (ttl > 60 && ttl != viewOnceTimeout) {
                    return .local("MEDIA_TTL_REQUIRES_SINGLE_PRIVATE_PHOTO_OR_VIDEO")
                }
            }
            if isSecret, !textEntities.isEmpty {
                guard let secretState = transaction.getPeerChatState(peerId) as? SecretChatState,
                      case let .sequenceBasedLayer(sequence) = secretState.embeddedState,
                      sequence.layerNegotiationState.activeLayer.rawValue >= 144 else { return .local("SECRET_ENTITIES_REQUIRE_LAYER_144") }
                for entity in textEntities {
                    switch entity.type {
                    case .TextMention, .PhoneNumber, .BankCard, .TonAddress, .FormattedDate, .Custom: return .local("SECRET_ENTITY_NOT_REPRESENTABLE")
                    case let .Pre(language): if let language, !language.isEmpty { return .local("SECRET_PRE_LANGUAGE_NOT_REPRESENTABLE") }
                    case let .BlockQuote(collapsed): if collapsed { return .local("SECRET_COLLAPSED_QUOTE_NOT_REPRESENTABLE") }
                    default: break
                    }
                }
            }
            for entity in textEntities {
                if case let .TextMention(id) = entity.type {
                    guard let mentioned = transaction.getPeer(id), apiInputUser(mentioned) != nil else { return .local("MEDIA_MENTION_USER_NOT_CACHED") }
                }
            }
        }
        if let user = peer as? TelegramUser {
            let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedUserData
            if user.flags.contains(.requireStars) && cached?.sendPaidMessageStars == nil {
                return .local("MEDIA_PAID_PRICE_UNAVAILABLE")
            }
            if let stars = cached?.sendPaidMessageStars, stars > .zero { return .local("MEDIA_PAID_SEND_UNSUPPORTED") }
            if threadId != nil { return .local("MEDIA_THREAD_UNSUPPORTED_FOR_USER") }
        } else if let channel = peer as? TelegramChannel {
            if !channel.flags.contains(.isCreator), channel.adminRights == nil {
                let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData
                if let stars = cached?.sendPaidMessageStars ?? channel.sendPaidMessageStars, stars > .zero {
                    return .local("MEDIA_PAID_SEND_UNSUPPORTED")
                }
            }
            if channel.flags.contains(.isMonoforum) { return .local("MEDIA_MONOFORUM_UNSUPPORTED") }
            if channel.flags.contains(.isForum) {
                guard let threadId, threadId > 0, threadId <= Int64(Int32.max),
                      let thread = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: threadId)?.data.get(MessageHistoryThreadData.self),
                      !thread.isClosed, !thread.isHidden else {
                    return .local("MEDIA_FORUM_THREAD_UNAVAILABLE")
                }
            } else if threadId != nil {
                return .local("MEDIA_THREAD_UNSUPPORTED_FOR_CHANNEL")
            }
        } else if threadId != nil {
            return .local("MEDIA_THREAD_UNSUPPORTED_FOR_GROUP")
        }
        if isSecret, items.count > 1 {
            guard let secretState = transaction.getPeerChatState(peerId) as? SecretChatState,
                  case let .sequenceBasedLayer(sequence) = secretState.embeddedState,
                  sequence.layerNegotiationState.activeLayer.rawValue >= 73 else { return .local("SECRET_ALBUM_REQUIRES_LAYER_73") }
        }
        if let replyToId {
            guard replyToId > 0, (isSecret ? [Namespaces.Message.Local, Namespaces.Message.SecretIncoming].contains(replyNamespace) : replyNamespace == Namespaces.Message.Cloud),
                  let message = transaction.getMessage(MessageId(peerId: peerId, namespace: replyNamespace, id: replyToId)) else {
                return .local("MEDIA_REPLY_NOT_CACHED")
            }
            if let threadId, message.threadId != threadId { return .local("MEDIA_REPLY_THREAD_MISMATCH") }
            if isSecret, message.globallyUniqueId == nil { return .local("SECRET_REPLY_HAS_NO_RANDOM_ID") }
        }
        return nil
    }
    |> castError(ExteralessTLServiceError.self)
    |> deliverOn(tlMediaResourceQueue)
    |> mapToSignal { error -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        if let error { return .fail(error) }
        if isCancelled() { return .fail(.local("MEDIA_CANCELLED")) }
        // The caller has pinned account/owner before subscribing. All retained
        // bytes are bounded, and become a normal MediaBox resource before enqueue.
        let groupingKey: Int64? = prepared.count > 1 ? Int64.random(in: Int64.min ... Int64.max) : nil
        var messages: [EnqueueMessage] = []
        for (item, textEntities) in prepared {
            guard !isCancelled() else { return .fail(.local("MEDIA_CANCELLED")) }
            let mediaReference: AnyMediaReference?
            do {
                mediaReference = try item.media.map { try tlStoredMediaReference(account: account, media: $0, isSecret: isSecret) }
            } catch let error as ExteralessTLServiceError {
                return .fail(error)
            } catch {
                return .fail(.local("MEDIA_RESOURCE_STORAGE_FAILED"))
            }
            if isCancelled() {
                return .fail(.local("MEDIA_CANCELLED"))
            }
            var attributes: [MessageAttribute] = []
            attributes.append(exteralessTLResolvedNotificationInfo(silent: silent))
            if !textEntities.isEmpty { attributes.append(TextEntitiesMessageAttribute(entities: textEntities)) }
            if item.spoiler { attributes.append(MediaSpoilerMessageAttribute()) }
            if let ttl = item.ttlSeconds { attributes.append(AutoremoveTimeoutMessageAttribute(timeout: ttl, countdownBeginTime: nil)) }
            if disableLinkPreviews { attributes.append(OutgoingContentInfoMessageAttribute(flags: [.disableLinkPreviews])) }
            if let scheduleTime { attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: nil)) }
            let replyId = replyToId ?? threadId.flatMap(Int32.init(exactly:))
            let reply = replyId.map { EngineMessageReplySubject(messageId: MessageId(peerId: peerId, namespace: replyNamespace, id: $0), quote: nil, innerSubject: nil) }
            let message = EnqueueMessage.message(text: item.text, attributes: attributes, inlineStickers: [:],
                mediaReference: mediaReference, threadId: threadId, replyToMessageId: reply, replyToStoryId: nil,
                localGroupingKey: groupingKey, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            messages.append(message)
        }
        if isCancelled() {
            return .fail(.local("MEDIA_CANCELLED"))
        }
        return exteralessTLEnqueueMessages(account: account, peerId: peerId, messages: messages, origin: origin, isCancelled: isCancelled)
        |> mapToSignal { ids -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
            let actualIds = ids.compactMap { $0 }
            guard !actualIds.isEmpty else {
                return .fail(.local("MEDIA_ENQUEUE_EMPTY"))
            }
            return .single(.object(["status": .string(actualIds.count == prepared.count ? "enqueued" : "partiallyEnqueued"), "messageIds": .array(ids.map {
                guard let id = $0 else { return .null }
                return .object(["peerId": .integer(id.peerId.toInt64()), "namespace": .integer(Int64(id.namespace)), "id": .integer(Int64(id.id))])
            })]))
        }
    }
}
