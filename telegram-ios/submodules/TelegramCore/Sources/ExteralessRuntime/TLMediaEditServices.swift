import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

func exteralessTLReferencePhotoInput(flags: Int32, id: Api.InputPhoto, ttlSeconds: Int32?, video: Api.InputDocument?, attributes: [MessageAttribute]) -> Api.InputMedia {
    let spoiler = attributes.contains { $0 is MediaSpoilerMessageAttribute }
    let flags = spoiler ? flags | (1 << 1) : flags & ~(1 << 1)
    return .inputMediaPhoto(.init(flags: flags, id: id, ttlSeconds: ttlSeconds, video: video))
}

func exteralessTLReferenceDocumentInput(flags: Int32, id: Api.InputDocument, videoCover: Api.InputPhoto?, videoTimestamp: Int32?, ttlSeconds: Int32?, query: String?, attributes: [MessageAttribute]) -> Api.InputMedia {
    let spoiler = attributes.contains { $0 is MediaSpoilerMessageAttribute }
    let flags = spoiler ? flags | (1 << 2) : flags & ~(1 << 2)
    return .inputMediaDocument(.init(flags: flags, id: id, videoCover: videoCover, videoTimestamp: videoTimestamp, ttlSeconds: ttlSeconds, query: query))
}

/// The final edit seam checks the actual upload/reference result, not a requested
/// attribute alone. Unsupported/non-media results cannot report a caption-only win.
func exteralessTLInputMediaSpoiler(_ media: Api.InputMedia) -> Bool? {
    switch media {
    case let .inputMediaPhoto(data): return data.flags & (1 << 1) != 0
    case let .inputMediaDocument(data): return data.flags & (1 << 2) != 0
    case let .inputMediaUploadedPhoto(data): return data.flags & (1 << 2) != 0
    case let .inputMediaUploadedDocument(data): return data.flags & (1 << 5) != 0
    default: return nil
    }
}

/// Shared real resource construction for sends and editor uploads. The editor uses
/// requestEditMessage's existing upload/revalidation/cache/Updates application.
func tlStoredMediaReference(account: Account, media: ExteralessTLPreparedMedia, isSecret: Bool = false) throws -> AnyMediaReference {
    let id = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: id, size: Int64(media.data.count), isSecretRelated: isSecret)
    account.postbox.mediaBox.storeResourceData(resource.id, data: media.data, synchronous: true)
    guard let path = account.postbox.mediaBox.completedResourcePath(resource),
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          (attributes[.size] as? NSNumber)?.int64Value == Int64(media.data.count) else {
        throw ExteralessTLServiceError.local("MEDIA_RESOURCE_STORAGE_FAILED")
    }
    if media.kind == .photo, let width = media.width, let height = media.height {
        return .standalone(media: TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id),
            representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: width, height: height),
                resource: resource, progressiveSizes: [], immediateThumbnailData: nil)],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: []))
    }
    var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: media.fileName)]
    if media.kind == .audio, let duration = media.duration {
        attributes.append(.Audio(isVoice: false, duration: Int(duration), title: nil, performer: nil, waveform: nil))
    } else if media.kind == .video, let duration = media.duration, let width = media.width, let height = media.height {
        attributes.append(.Video(duration: duration, size: PixelDimensions(width: width, height: height), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil))
    }
    return .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil,
        resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
        mimeType: media.mimeType, size: Int64(media.data.count), attributes: attributes, alternativeRepresentations: []))
}

private let tlMediaEditQueue = Queue(name: "Exteraless.TLMediaEdit", qos: .utility)

func exteralessTLResolveEditText(cachedText: String, cachedEntities: TextEntitiesMessageAttribute?,
                                 caption: String?, entities: [ExteralessTLValue]?) throws -> (text: String, entities: TextEntitiesMessageAttribute?) {
    let text = caption ?? cachedText
    if let entities {
        return (text, TextEntitiesMessageAttribute(entities: try tlMediaEntities(entities, caption: text)))
    } else if caption != nil {
        return (text, TextEntitiesMessageAttribute(entities: []))
    } else {
        return (text, cachedEntities)
    }
}

public func exteralessTLEditMedia(account: Account, reference: ExteralessTLPeerReference, messageId: Int32, namespace: Int32,
                                 media: ExteralessTLPreparedMedia?, caption: String?, entities: [ExteralessTLValue]?,
                                 spoiler: Bool?, disableLinkPreviews: Bool, scheduleTime: Int32?,
                                 origin: ExteralessTLRequestOrigin? = nil,
                                 isCancelled: @escaping @Sendable () -> Bool) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    guard reference.kind != .secret, messageId > 0, [Namespaces.Message.Cloud, Namespaces.Message.ScheduledCloud].contains(namespace) else {
        return .fail(.local("EDIT_MESSAGE_TARGET_UNSUPPORTED"))
    }
    if origin != nil, media == nil, spoiler != nil {
        return .fail(.local("EDIT_HOOK_REFERENCE_UPLOAD_UNSUPPORTED"))
    }
    let id = MessageId(peerId: reference.peerId, namespace: namespace, id: messageId)
    return account.postbox.transaction { transaction -> Message? in
        guard !isCancelled(), let message = transaction.getMessage(id), let peer = transaction.getPeer(id.peerId) else { return nil }
        if message.flags.contains(.Incoming), (peer as? TelegramChannel)?.hasPermission(.editAllMessages) != true { return nil }
        return message
    }
    |> castError(ExteralessTLServiceError.self)
    |> deliverOn(tlMediaEditQueue)
    |> mapToSignal { message -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        guard !isCancelled(), let message else { return .fail(.local("EDIT_MESSAGE_NOT_CACHED_OR_RESTRICTED")) }
        guard !message.attributes.contains(where: { $0 is RichTextMessageAttribute }),
              !message.media.contains(where: { $0 is TelegramMediaPaidContent }) else { return .fail(.local("EDIT_RICH_OR_PAID_MEDIA_UNSUPPORTED")) }
        do {
            let resolvedText = try exteralessTLResolveEditText(cachedText: message.text,
                cachedEntities: message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first,
                caption: caption, entities: entities)
            let text = resolvedText.text
            let textEntities = resolvedText.entities
            let isSpoiler = spoiler ?? message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })
            let replacement: RequestEditMessageMedia
            if let media {
                guard !isCancelled() else { return .fail(.local("EDIT_CANCELLED")) }
                replacement = .update(try tlStoredMediaReference(account: account, media: media))
            } else if spoiler != nil {
                guard let originalMedia = message.media.first(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile }) else {
                    return .fail(.local("EDIT_SPOILER_REQUIRES_MEDIA"))
                }
                if let image = originalMedia as? TelegramMediaImage, image.video != nil {
                    return .fail(.local("EDIT_REFERENCE_LIVE_PHOTO_UNSUPPORTED"))
                }
                if let file = originalMedia as? TelegramMediaFile, file.videoCover != nil {
                    return .fail(.local("EDIT_REFERENCE_VIDEO_COVER_UNSUPPORTED"))
                }
                let reference = MessageReference(message)
                guard reference.id == id else { return .fail(.local("EDIT_REFERENCE_MESSAGE_UNAVAILABLE")) }
                replacement = .update(.message(message: reference, media: originalMedia))
            } else {
                replacement = .keep
            }
            guard !isCancelled() else { return .fail(.local("EDIT_CANCELLED")) }
            var mediaAttributes: [MessageAttribute] = isSpoiler ? [MediaSpoilerMessageAttribute()] : []
            mediaAttributes.append(contentsOf: message.attributes.filter { $0 is AutoclearTimeoutMessageAttribute })
            // Coordinator's small additive mediaAttributes hunk carries spoiler
            // intent into the SAME upload helper used by the stock edit pipeline.
            return _internal_requestEditMessage(account: account, messageId: id, text: text, media: replacement,
                entities: textEntities, richText: nil, inlineStickers: [:], webpagePreviewAttribute: nil,
                disableUrlPreview: disableLinkPreviews,
                scheduleInfoAttribute: scheduleTime.map { OutgoingScheduleInfoMessageAttribute(scheduleTime: $0, repeatPeriod: nil) },
                invertMediaAttribute: nil, mediaAttributes: mediaAttributes, requireMediaUpload: true, tlOrigin: origin, tlIsCancelled: isCancelled)
            |> mapError { error -> ExteralessTLServiceError in
                switch error {
                case .generic: return .local("EDIT_FAILED")
                case .restricted: return .local("EDIT_RESTRICTED")
                case .textTooLong: return .local("EDIT_TEXT_TOO_LONG")
                case .invalidGrouping: return .local("EDIT_INVALID_GROUPING")
                }
            }
            |> mapToSignal { result -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
                switch result {
                case .progress: return .complete()
                case let .done(changed):
                    guard changed else { return .fail(.local("EDIT_NOT_APPLIED")) }
                    return .single(.object(["status": .string("edited"), "messageId": .object([
                        "peerId": .integer(id.peerId.toInt64()), "namespace": .integer(Int64(id.namespace)), "id": .integer(Int64(id.id))])]))
                }
            }
        } catch let error as ExteralessTLServiceError {
            return .fail(error)
        } catch let error as ExteralessTLError {
            return .fail(.local("EDIT_\(error.kind.rawValue): \(error.message)"))
        } catch {
            return .fail(.local("EDIT_PREPARATION_FAILED"))
        }
    }
}
