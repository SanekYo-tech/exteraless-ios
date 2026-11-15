import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public enum ExteralessProtectedCopyError: Error, Equatable {
    case disabled, unavailableMessage, unsupportedContent, mediaNotDownloaded
}

public func exteralessCanOfferProtectedCopy(messages: [EngineMessage], peerProtected: Bool) -> Bool {
    guard ClientSettings.shared.bool("privacy.forwardProtectedAsCopy"), !messages.isEmpty, messages.count <= 100,
          peerProtected || messages.contains(where: { $0._asMessage().isCopyProtected() }) else { return false }
    return messages.allSatisfy { extrasCopyContentSupported($0._asMessage()) }
}

private func extrasCopyContentSupported(_ message: Message) -> Bool {
    guard message.id.namespace == Namespaces.Message.Cloud, !message.id.peerId.isVerificationCodes,
          !message.containsSecretMedia, message.adAttribute == nil else { return false }
    return message.media.allSatisfy { $0 is TelegramMediaImage || $0 is TelegramMediaFile || $0 is TelegramMediaWebpage }
        && (!message.text.isEmpty || message.media.contains { $0 is TelegramMediaImage || $0 is TelegramMediaFile })
}

/// Builds NEW outgoing messages from content the owning account actually has.
/// It neither changes noforwards/ban flags nor issues messages.forwardMessages.
/// All members are validated before any caller can enqueue part of an album.
public func exteralessPrepareProtectedCopies(account: Account, ids: [EngineMessage.Id], threadId: Int64?) -> Signal<Result<[EnqueueMessage], ExteralessProtectedCopyError>, NoError> {
    return account.postbox.transaction { transaction in
        guard ClientSettings.shared.bool("privacy.forwardProtectedAsCopy") else { return .failure(.disabled) }
        guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else { return .failure(.unsupportedContent) }
        let messages = ids.compactMap { transaction.getMessage($0) }
        guard messages.count == ids.count else { return .failure(.unavailableMessage) }
        guard messages.allSatisfy(extrasCopyContentSupported) else { return .failure(.unsupportedContent) }
        var result: [EnqueueMessage] = []
        var groups: [String: Int64] = [:]
        for message in messages.sorted(by: { $0.index < $1.index }) {
            var mediaReference: AnyMediaReference?
            for media in message.media {
                if let image = media as? TelegramMediaImage {
                    guard mediaReference == nil, let representation = largestImageRepresentation(image.representations),
                          let path = account.postbox.mediaBox.completedResourcePath(representation.resource) else { return .failure(.mediaNotDownloaded) }
                    let id = Int64.random(in: Int64.min ... Int64.max)
                    let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: id)
                    let local = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id), representations: [TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: image.immediateThumbnailData, reference: nil, partialReference: nil, flags: [])
                    mediaReference = .standalone(media: local)
                } else if let file = media as? TelegramMediaFile {
                    guard mediaReference == nil else { return .failure(.unsupportedContent) }
                    if file.isSticker {
                        // Android uses the native sticker send path as well.
                        mediaReference = .standalone(media: file)
                    } else {
                        guard let path = account.postbox.mediaBox.completedResourcePath(file.resource) else { return .failure(.mediaNotDownloaded) }
                        let id = Int64.random(in: Int64.min ... Int64.max)
                        let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: id, size: file.size)
                        let local = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: [])
                        mediaReference = .standalone(media: local)
                    }
                }
                // Webpage text/URL entities survive, with no origin access hash.
            }
            var localGroup: Int64?
            if let group = message.groupingKey {
                let key = "\(message.id.peerId.toInt64()):\(group)"
                if groups[key] == nil { groups[key] = Int64.random(in: Int64.min ... Int64.max) }
                localGroup = groups[key]
            }
            let attributes = message.attributes.filter { $0 is TextEntitiesMessageAttribute || $0 is MediaSpoilerMessageAttribute || $0 is InvertMediaMessageAttribute }
            result.append(.message(text: message.text, attributes: attributes, inlineStickers: message.associatedMedia, mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: localGroup, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        }
        return .success(result)
    }
}
