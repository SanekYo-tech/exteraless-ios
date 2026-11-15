import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

/// Converts a user-chosen locked WebP/WebM emoji to a *local upload*, rather
/// than relabeling its premium cloud document. Sending remains the chat's native
/// sendSticker operation, so permissions/slow mode/reply/schedule/fees are kept.
public func exteralessPrepareEmojiSticker(engine: TelegramEngine, peerId: EnginePeer.Id, file: TelegramMediaFile) -> Signal<TelegramMediaFile, EmojiPackError> {
    guard ["image/webp", "video/webm"].contains(file.mimeType), file.isCustomEmoji,
          let dimensions = file.dimensions, dimensions.width > 0, dimensions.height > 0,
          dimensions.width <= 512, dimensions.height <= 512 else { return .fail(.invalidMedia) }
    let reference = FileMediaReference.standalone(media: file)
    // A group-authorized emoji may be selected through Recents/Search as well as
    // the group tab. Check its actual set, not just the picker group identifier.
    return engine.account.postbox.transaction { transaction -> Bool in
        guard let packId = (transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData)?.emojiPack?.id.id else { return false }
        return file.attributes.contains { attribute in
            if case let .CustomEmoji(_, _, _, reference) = attribute, case let .id(id, _)? = reference { return id == packId }
            return false
        }
    }
    |> castError(EmojiPackError.self)
    |> mapToSignal { isGroupEmoji -> Signal<Data, EmojiPackError> in
        guard !isGroupEmoji, StickerPolicy().sendLockedEmojiAsSticker else { return .fail(.invalidMedia) }
        return exteralessStickerResourceData(engine: engine, file: reference, maximumBytes: 4 * 1024 * 1024)
    }
    |> mapToSignal { data -> Signal<TelegramMediaFile, EmojiPackError> in
        let header = [UInt8](data.prefix(12))
        let valid: Bool
        if file.mimeType == "image/webp" {
            valid = header.count == 12 && Array(header[0..<4]) == Array("RIFF".utf8) && Array(header[8..<12]) == Array("WEBP".utf8)
        } else { valid = Array(header.prefix(4)) == [0x1a, 0x45, 0xdf, 0xa3] }
        guard valid else { return .fail(.invalidMedia) }
        var text = "", duration: Double = 0
        for attribute in file.attributes {
            if case let .CustomEmoji(_, _, displayText, _) = attribute { text = displayText }
            if case let .Video(value, _, _, _, _, _) = attribute { duration = value }
        }
        guard text.utf16.count <= 64, duration.isFinite, duration >= 0, duration <= 3.1 else { return .fail(.invalidMedia) }
        let id = Int64.random(in: 1..<Int64.max)
        let resource = LocalFileMediaResource(fileId: id)
        engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data, synchronous: true)
        var attributes: [TelegramMediaFileAttribute] = [
            .FileName(fileName: file.mimeType == "video/webm" ? "sticker.webm" : "sticker.webp"),
            .Sticker(displayText: text, packReference: nil, maskData: nil), .ImageSize(size: dimensions)
        ]
        if file.mimeType == "video/webm" {
            attributes.append(.Animated)
            attributes.append(.Video(duration: duration, size: dimensions, flags: [], preloadSize: nil, coverTime: nil, videoCodec: "vp9"))
        }
        let uploaded = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: Int64(data.count), attributes: attributes, alternativeRepresentations: [])
        return .single(uploaded)
    }
}
