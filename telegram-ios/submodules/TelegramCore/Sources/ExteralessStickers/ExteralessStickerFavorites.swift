import ExteralessCore
import Foundation

/// A pure picker projection over Tools' already-validated local metadata and
/// Telegram's real cloud list. No second store, preference, transaction or RPC.
/// Cloud items keep their server ordering and current file references. Local-only
/// items keep Tools' order and use the pack reference for reference revalidation.
public func exteralessStickerPickerFavorites(cloud: [SavedStickerItem], local: [SavedStickerItem]) throws -> [(item: SavedStickerItem, reference: FileMediaReference)] {
    guard local.count <= ToolsFavoriteStickerArchive.maximumPerAccount else { throw ToolsError.sizeLimit }
    var result: [(item: SavedStickerItem, reference: FileMediaReference)] = []
    var seen = Set<EngineMedia.Id>()
    for item in cloud where seen.insert(item.file.fileId).inserted {
        result.append((item, .savedSticker(media: item.file._parse())))
    }
    for item in local where seen.insert(item.file.fileId).inserted {
        let file = item.file._parse()
        let reference: FileMediaReference
        if case let .stickerPack(pack)? = file.partialReference {
            reference = .stickerPack(stickerPack: pack, media: file)
        } else {
            reference = .standalone(media: file)
        }
        result.append((item, reference))
    }
    return result
}
