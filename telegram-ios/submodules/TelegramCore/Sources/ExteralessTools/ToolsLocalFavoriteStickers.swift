import ExteralessCore
import FlatBuffers
import FlatSerialization
import Foundation
import Postbox
import SwiftSignalKit

private let toolsLocalFavoriteKey = ValueBoxKey("exteraless.tools.local-favorite-stickers.v1")

public struct ExteralessLocalFavoriteSnapshot: Sendable {
    public let userId: Int64
    public let local: [ToolsFavoriteSticker]
    public let cloud: [ToolsFavoriteSticker]
    public let skippedCloudRecords: Int

    public var combined: [ToolsFavoriteSticker] {
        // Refresh cloud references without changing locally retained ordering.
        let cloudById = Dictionary(cloud.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let localIds = Set(local.map(\.id))
        return local.map { cloudById[$0.id] ?? $0 } + cloud.filter { !localIds.contains($0.id) }
    }
}

private func toolsReadLocalFavorites(_ entry: PreferencesEntry?, userId: Int64) throws -> [ToolsFavoriteSticker] {
    guard let entry else { return [] }
    return try exteralessDecodeLocalFavoriteStickers(entry.data, userId: userId)
}

/// Same checked boundary used by reads, imports and removals of the real preference.
public func exteralessDecodeLocalFavoriteStickers(_ data: Data, userId: Int64) throws -> [ToolsFavoriteSticker] {
    if data.first == 123 { return try ToolsFavoriteStickerStorage.decode(data, userId: userId) }
    return try ToolsFavoriteStickerStorage.decodeLegacyPostbox(data, userId: userId)
}

/// Reads the actual SavedStickerItem wire fields without invoking its unchecked
/// FlatBuffers_getRoot/_parse path. A malformed cache fails the signal as a whole;
/// it is never presented as a successful empty cloud list or written back.
public func exteralessDecodeCloudFavoriteSticker(_ data: Data) throws -> ToolsFavoriteSticker {
    let record = try ToolsFavoriteStickerStorage.decodeCloudPostbox(data)
    var buffer = ByteBuffer(data: record.fileData)
    let file: TelegramCore_TelegramMediaFile = try getCheckedRoot(byteBuffer: &buffer,
        options: VerifierOptions(maxDepth: 24, maxTableCount: 4_096, maxApparentSize: 4 * 1_024 * 1_024))
    guard file.fileId.namespace == Namespaces.Media.CloudFile, file.attributesCount <= 64, file.videoThumbnailsCount <= 32,
          file.resource.valueType == .telegrammediaresourceClouddocumentmediaresource,
          let resource = file.resource.value(type: TelegramCore_TelegramMediaResource_CloudDocumentMediaResource.self),
          resource.fileId == file.fileId.id, resource.fileReferenceCount <= 4_096 else {
        throw ToolsError.invalidArchive("Unsupported cloud favorite resource.")
    }
    var text: String?
    var name: String?
    var width: Int32?
    var height: Int32?
    var duration: Double?
    var pack: ToolsFavoriteSticker.Pack?
    var noPremium = false
    for i in 0..<file.attributesCount {
        guard let attribute = file.attributes(at: i) else { throw ToolsError.invalidArchive("Missing cached sticker attribute.") }
        switch attribute.valueType {
        case .telegrammediafileattributeFilename:
            guard let value = attribute.value(type: TelegramCore_TelegramMediaFileAttribute_FileName.self) else { throw ToolsError.invalidArchive("Invalid cached filename.") }
            name = value.fileName
        case .telegrammediafileattributeSticker:
            guard let value = attribute.value(type: TelegramCore_TelegramMediaFileAttribute_Sticker.self) else { throw ToolsError.invalidArchive("Invalid cached sticker.") }
            text = value.displayText
            if let reference = value.packReference {
                switch reference.valueType {
                case .stickerpackreferenceId:
                    guard let value = reference.value(type: TelegramCore_StickerPackReference_Id.self) else { throw ToolsError.invalidArchive("Invalid cached pack.") }
                    pack = .init(id: value.id, accessHash: value.accessHash)
                case .stickerpackreferenceName:
                    guard let value = reference.value(type: TelegramCore_StickerPackReference_Name.self) else { throw ToolsError.invalidArchive("Invalid cached pack.") }
                    pack = .init(name: value.name)
                case .none_: throw ToolsError.invalidArchive("Missing cached pack variant.")
                default: break // Same special-pack omission as native descriptor export.
                }
            }
        case .telegrammediafileattributeImagesize:
            guard let value = attribute.value(type: TelegramCore_TelegramMediaFileAttribute_ImageSize.self) else { throw ToolsError.invalidArchive("Invalid cached dimensions.") }
            width = value.width; height = value.height
        case .telegrammediafileattributeVideo:
            guard let value = attribute.value(type: TelegramCore_TelegramMediaFileAttribute_Video.self) else { throw ToolsError.invalidArchive("Invalid cached video.") }
            width = value.width; height = value.height; duration = Double(value.duration)
        case .telegrammediafileattributeNopremium: noPremium = true
        case .none_: throw ToolsError.invalidArchive("Missing cached attribute variant.")
        default: break
        }
    }
    guard let text, let width, let height else { throw ToolsError.invalidArchive("The cached document lacks sticker metadata.") }
    var premium = false
    for i in 0..<file.videoThumbnailsCount {
        guard let thumbnail = file.videoThumbnails(at: i) else { throw ToolsError.invalidArchive("Invalid cached thumbnail.") }
        if thumbnail.resource.valueType == .telegrammediaresourceClouddocumentsizemediaresource,
           let resource = thumbnail.resource.value(type: TelegramCore_TelegramMediaResource_CloudDocumentSizeMediaResource.self), resource.sizeSpec == "f" {
            premium = true
        }
    }
    let suffix = file.mimeType == "application/x-tgsticker" ? "tgs" : file.mimeType == "video/webm" ? "webm" : "webp"
    let resourceSize: Int64? = resource.size == Int64.min ? nil : resource.size
    let fileSize: Int64? = file.size == Int64.min ? nil : file.size
    let sticker = ToolsFavoriteSticker(id: resource.fileId, datacenterId: resource.datacenterId, accessHash: resource.accessHash,
        fileReference: resource.fileReferenceCount == 0 ? nil : Data(resource.fileReference), size: resourceSize ?? fileSize,
        mimeType: file.mimeType, fileName: name ?? resource.fileName ?? "\(resource.fileId).\(suffix)", displayText: text,
        width: width, height: height, pack: pack, duration: duration, premium: premium, noPremium: noPremium, aliases: record.aliases)
    try sticker.validate()
    return sticker
}

/// Reads the actual account's native cloud list plus its independent local overlay.
/// Merely observing this signal sends no request and changes no server favorites.
public func exteralessLocalFavoriteStickers(engine: TelegramEngine) -> Signal<ExteralessLocalFavoriteSnapshot, ToolsError> {
    let userId = engine.account.peerId.id._internalGetInt64Value()
    let preferencesKey = PostboxViewKey.preferences(keys: [toolsLocalFavoriteKey])
    let cloudKey = PostboxViewKey.orderedItemList(id: Namespaces.OrderedItemList.CloudSavedStickers)
    return engine.account.postbox.combinedView(keys: [preferencesKey, cloudKey])
    |> castError(ToolsError.self)
    |> mapToSignal { view -> Signal<ExteralessLocalFavoriteSnapshot, ToolsError> in
        guard let preferences = view.views[preferencesKey] as? PreferencesView,
              let cloud = view.views[cloudKey] as? OrderedItemListView else { return .fail(.unavailable("Favorite-sticker storage is not ready.")) }
        do {
            let local = try toolsReadLocalFavorites(preferences.values[toolsLocalFavoriteKey], userId: userId)
            guard cloud.items.count <= ToolsFavoriteStickerArchive.maximumPerAccount else { throw ToolsError.sizeLimit }
            var stickers: [ToolsFavoriteSticker] = []
            for item in cloud.items {
                stickers.append(try exteralessDecodeCloudFavoriteSticker(item.contents.data))
            }
            return .single(.init(userId: userId, local: local, cloud: stickers, skippedCloudRecords: 0))
        } catch { return .fail((error as? ToolsError) ?? .invalidArchive("The local favorite list could not be read.")) }
    }
}

/// One native Postbox preference transaction, local to this account. It does not
/// enqueue addSavedSticker/removeSavedSticker or use the server favorite limit.
public func exteralessImportLocalFavoriteStickers(engine: TelegramEngine, archive: ToolsFavoriteStickerArchive) -> Signal<Int, ToolsError> {
    let userId = engine.account.peerId.id._internalGetInt64Value()
    let incoming: [ToolsFavoriteSticker]
    do { incoming = try archive.stickers(for: userId) }
    catch { return .fail((error as? ToolsError) ?? .invalidArchive("Invalid favorite-sticker archive.")) }
    return engine.account.postbox.transaction { transaction -> Result<Int, ToolsError> in
        do {
            let existing = try toolsReadLocalFavorites(transaction.getPreferencesEntry(key: toolsLocalFavoriteKey), userId: userId)
            let merged = try ToolsFavoriteStickerArchive.merge(current: existing, incoming: incoming)
            let entry = PreferencesEntry(data: try ToolsFavoriteStickerStorage.encode(merged, userId: userId))
            transaction.updatePreferencesEntry(key: toolsLocalFavoriteKey, { _ in entry })
            return .success(merged.count - existing.count)
        } catch { return .failure((error as? ToolsError) ?? .invalidArchive("Local favorite stickers could not be updated.")) }
    }
    |> castError(ToolsError.self)
    |> mapToSignal { result in
        switch result { case let .success(value): return .single(value); case let .failure(error): return .fail(error) }
    }
}

public func exteralessRemoveLocalFavoriteSticker(engine: TelegramEngine, id: Int64) -> Signal<Bool, ToolsError> {
    let userId = engine.account.peerId.id._internalGetInt64Value()
    return engine.account.postbox.transaction { transaction -> Result<Bool, ToolsError> in
        do {
            let existing = try toolsReadLocalFavorites(transaction.getPreferencesEntry(key: toolsLocalFavoriteKey), userId: userId)
            let result = existing.filter { $0.id != id }
            let entry = PreferencesEntry(data: try ToolsFavoriteStickerStorage.encode(result, userId: userId))
            transaction.updatePreferencesEntry(key: toolsLocalFavoriteKey, { _ in entry })
            return .success(result.count != existing.count)
        } catch { return .failure((error as? ToolsError) ?? .invalidArchive("Local favorites are invalid.")) }
    }
    |> castError(ToolsError.self)
    |> mapToSignal { result in
        switch result { case let .success(value): return .single(value); case let .failure(error): return .fail(error) }
    }
}

public func exteralessFavoriteStickerDescriptor(file: TelegramMediaFile, aliases: [String] = []) throws -> ToolsFavoriteSticker {
    guard file.isSticker, file.fileId.namespace == Namespaces.Media.CloudFile,
          let resource = file.resource as? CloudDocumentMediaResource,
          let datacenterId = Int32(exactly: resource.datacenterId), resource.fileId == file.fileId.id else { throw ToolsError.invalidArchive("Only native cloud sticker documents are supported.") }
    var text = ""
    var width: Int32? = nil
    var height: Int32? = nil
    var pack: ToolsFavoriteSticker.Pack? = nil
    var duration: Double? = nil
    for attribute in file.attributes {
        switch attribute {
        case let .Sticker(displayText, reference, _):
            text = displayText
            if case let .id(id, hash)? = reference { pack = .init(id: id, accessHash: hash) }
            else if case let .name(name)? = reference { pack = .init(name: name) }
        case let .ImageSize(size): width = size.width; height = size.height
        case let .Video(value, size, _, _, _, _): duration = value; width = size.width; height = size.height
        default: break
        }
    }
    guard let width, let height else { throw ToolsError.invalidArchive("The native sticker has no recorded dimensions.") }
    let suffix = file.mimeType == "application/x-tgsticker" ? "tgs" : file.mimeType == "video/webm" ? "webm" : "webp"
    let result = ToolsFavoriteSticker(id: resource.fileId, datacenterId: datacenterId, accessHash: resource.accessHash,
        fileReference: resource.fileReference, size: resource.size ?? file.size, mimeType: file.mimeType,
        fileName: file.fileName ?? "\(resource.fileId).\(suffix)", displayText: text, width: width, height: height,
        pack: pack, duration: duration, premium: file.isPremiumSticker, noPremium: file.noPremium, aliases: aliases)
    try result.validate()
    return result
}

/// Shared-keyboard adapter: combine these local items with the existing cloud
/// group by fileId. Their partialReference retains the pack for reference refresh.
public func exteralessLocalFavoriteStickerItems(engine: TelegramEngine) -> Signal<[SavedStickerItem], ToolsError> {
    exteralessLocalFavoriteStickers(engine: engine)
    |> mapToSignal { snapshot -> Signal<[SavedStickerItem], ToolsError> in
        do {
            return .single(try snapshot.local.map { SavedStickerItem(file: try exteralessFavoriteStickerFile($0), stringRepresentations: $0.aliases) })
        } catch { return .fail((error as? ToolsError) ?? .invalidArchive("Invalid local favorite sticker.")) }
    }
}

public func exteralessSetLocalFavoriteSticker(engine: TelegramEngine, file: TelegramMediaFile, saved: Bool) -> Signal<Bool, ToolsError> {
    if !saved { return exteralessRemoveLocalFavoriteSticker(engine: engine, id: file.fileId.id) }
    do {
        let descriptor = try exteralessFavoriteStickerDescriptor(file: file)
        let archive = ToolsFavoriteStickerArchive(accounts: [String(engine.account.peerId.id._internalGetInt64Value()): [descriptor]])
        return exteralessImportLocalFavoriteStickers(engine: engine, archive: archive) |> map { $0 > 0 }
    } catch { return .fail((error as? ToolsError) ?? .invalidArchive("This sticker cannot be retained locally.")) }
}

/// Builds only known native resource/attribute types from already-validated data.
/// It never invokes the generic Postbox/FlatBuffer decoder on imported bytes.
public func exteralessFavoriteStickerFile(_ sticker: ToolsFavoriteSticker) throws -> TelegramMediaFile {
    try sticker.validate()
    let resource = CloudDocumentMediaResource(datacenterId: Int(sticker.datacenterId), fileId: sticker.id, accessHash: sticker.accessHash,
        size: sticker.size, fileReference: sticker.fileReference, fileName: sticker.fileName)
    let dimensions = PixelDimensions(width: sticker.width, height: sticker.height)
    let pack: StickerPackReference?
    if let id = sticker.pack?.id, let hash = sticker.pack?.accessHash { pack = .id(id: id, accessHash: hash) }
    else if let name = sticker.pack?.name { pack = .name(name) }
    else { pack = nil }
    var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: sticker.fileName), .Sticker(displayText: sticker.displayText, packReference: pack, maskData: nil), .ImageSize(size: dimensions)]
    if sticker.mimeType == "application/x-tgsticker" { attributes.append(.Animated) }
    if sticker.mimeType == "video/webm" { attributes.append(.Video(duration: sticker.duration ?? 0, size: dimensions, flags: [], preloadSize: nil, coverTime: nil, videoCodec: "vp9")) }
    if sticker.noPremium { attributes.append(.NoPremium) }
    var thumbnails: [TelegramMediaFile.VideoThumbnail] = []
    if sticker.premium {
        thumbnails.append(.init(dimensions: dimensions, resource: CloudDocumentSizeMediaResource(datacenterId: sticker.datacenterId,
            documentId: sticker.id, accessHash: sticker.accessHash, sizeSpec: "f", fileReference: sticker.fileReference)))
    }
    return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: sticker.id),
        partialReference: pack.map { .stickerPack(stickerPack: $0) }, resource: resource, previewRepresentations: [],
        videoThumbnails: thumbnails, immediateThumbnailData: nil, mimeType: sticker.mimeType, size: sticker.size,
        attributes: attributes, alternativeRepresentations: [])
}
