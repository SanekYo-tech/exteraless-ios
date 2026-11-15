import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

// Independent of Tools' favorite-sticker store. These preferences are inside the
// actual account Postbox, never a process-global media/file-reference cache.
private let stickerRecentKey = ValueBoxKey("exteraless.stickers.recents.v1")
private let stickerGifKey = ValueBoxKey("exteraless.stickers.local-gifs.v1")
private let maximumCollectionBytes = 16 * 1024 * 1024

private struct StickerLocalMedia: Codable {
    var version: Int = 1
    var items: [RecentMediaItem]
}

private func stickerReadMedia(_ entry: PreferencesEntry?, limit: Int) throws -> [RecentMediaItem] {
    guard let entry else { return [] }
    guard let record = entry.get(StickerLocalMedia.self), record.version == 1, record.items.count <= limit,
          Set(record.items.map { $0.media.fileId }).count == record.items.count else { throw EmojiPackError.invalidCache }
    return record.items
}

private func stickerWriteMedia(_ items: [RecentMediaItem], transaction: Transaction, key: ValueBoxKey) throws {
    let record = StickerLocalMedia(items: items)
    guard try JSONEncoder().encode(record).count <= maximumCollectionBytes,
          let entry = PreferencesEntry(record) else { throw EmojiPackError.quota }
    transaction.updatePreferencesEntry(key: key, { _ in entry })
}

/// Called in the existing add-recent transaction. The cloud operation is still
/// owned by Telegram; the extra local history survives a shorter cloud refresh.
@discardableResult func exteralessRememberRecentSticker(transaction: Transaction, file: TelegramMediaFile, settings: ClientSettings = .shared) -> Bool {
    do {
        let local = try stickerReadMedia(transaction.getPreferencesEntry(key: stickerRecentKey), limit: StickerCollectionPolicy.maximumRecentCount)
        let cloud = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudRecentStickers).compactMap { $0.contents.get(RecentMediaItem.self) }
        // Capture runs before the native cloud add in the same transaction.
        // Include that newly sent file in the authoritative prefix explicitly.
        let items = StickerCollectionPolicy.recent(local: local, cloud: [RecentMediaItem(file)] + cloud, limit: StickerPolicy(settings: settings).recentCount, id: { $0.media.fileId })
        try stickerWriteMedia(items, transaction: transaction, key: stickerRecentKey)
        return true
    } catch { return false }
}

func exteralessRemoveRecentSticker(transaction: Transaction, id: MediaId?) {
    if let id {
        guard let items = try? stickerReadMedia(transaction.getPreferencesEntry(key: stickerRecentKey), limit: StickerCollectionPolicy.maximumRecentCount) else { return }
        try? stickerWriteMedia(items.filter { $0.media.fileId != id }, transaction: transaction, key: stickerRecentKey)
    } else {
        // Explicit Clear can repair an invalid local record without decoding it.
        transaction.updatePreferencesEntry(key: stickerRecentKey, { _ in nil })
    }
}

public func exteralessRecentStickerItems(engine: TelegramEngine) -> Signal<[RecentMediaItem], NoError> {
    return _internal_exteralessRecentStickerItems(postbox: engine.account.postbox, policy: exteralessStickerPolicy())
}

/// The shipping adapter, separated from Account construction so disposable
/// Postbox fixtures exercise the real view/decoder/policy path without networking.
func _internal_exteralessRecentStickerItems(postbox: Postbox, policy: Signal<StickerPolicy, NoError>) -> Signal<[RecentMediaItem], NoError> {
    let prefKey = PostboxViewKey.preferences(keys: [stickerRecentKey])
    let cloudKey = PostboxViewKey.orderedItemList(id: Namespaces.OrderedItemList.CloudRecentStickers)
    return combineLatest(postbox.combinedView(keys: [prefKey, cloudKey]), policy)
    |> map { view, policy in
        let cloud = (view.views[cloudKey] as? OrderedItemListView)?.items.compactMap { $0.contents.get(RecentMediaItem.self) } ?? []
        let preferences = view.views[prefKey] as? PreferencesView
        let local = (try? stickerReadMedia(preferences?.values[stickerRecentKey], limit: StickerCollectionPolicy.maximumRecentCount)) ?? []
        if policy.recentCount == 20 { return Array(cloud.prefix(20)) }
        return StickerCollectionPolicy.recent(local: local, cloud: cloud, limit: policy.recentCount, id: { $0.media.fileId })
    }
}

public func exteralessSavedGifItems(engine: TelegramEngine) -> Signal<[FileMediaReference], NoError> {
    let prefKey = PostboxViewKey.preferences(keys: [stickerGifKey])
    let cloudKey = PostboxViewKey.orderedItemList(id: Namespaces.OrderedItemList.CloudRecentGifs)
    return combineLatest(engine.account.postbox.combinedView(keys: [prefKey, cloudKey]), exteralessStickerPolicy())
    |> map { view, policy in
        let cloud = (view.views[cloudKey] as? OrderedItemListView)?.items.compactMap { $0.contents.get(RecentMediaItem.self) } ?? []
        let cloudIds = Set(cloud.map { $0.media.fileId })
        let preferences = view.views[prefKey] as? PreferencesView
        let local = policy.localGifs ? (try? stickerReadMedia(preferences?.values[stickerGifKey], limit: StickerCollectionPolicy.maximumLocalGifCount)) ?? [] : []
        let items = StickerCollectionPolicy.merged(local: local, cloud: cloud, limit: StickerCollectionPolicy.maximumLocalGifCount, id: { $0.media.fileId })
        return items.map { item in
            let file = item.media._parse()
            return cloudIds.contains(file.fileId) ? .savedGif(media: file) : .standalone(media: file)
        }
    }
}

public enum ExteralessSavedGifResult {
    case local
    case cloud(SavedGifResult)
}

/// Local GIF retention never pretends to increase an account's server quota.
/// The off path uses Telegram's native cloud save; remove also removes a cloud
/// item if present. Errors are surfaced instead of displaying a success toast.
public func exteralessToggleGifSaved(engine: TelegramEngine, fileReference: FileMediaReference, saved: Bool) -> Signal<ExteralessSavedGifResult, EmojiPackError> {
    let localEnabled = StickerPolicy().localGifs
    if saved && !localEnabled {
        return toggleGifSaved(account: engine.account, fileReference: fileReference, saved: true)
        |> map { .cloud($0) }
        |> castError(EmojiPackError.self)
    }
    return engine.account.postbox.transaction { transaction -> Result<Bool, EmojiPackError> in
        do {
            let file = fileReference.media
            guard file.fileId.namespace == Namespaces.Media.CloudFile, file.resource is CloudDocumentMediaResource,
                  file.isAnimated, ["video/mp4", "image/gif"].contains(file.mimeType) else { return .failure(.invalidMedia) }
            var items = try stickerReadMedia(transaction.getPreferencesEntry(key: stickerGifKey), limit: StickerCollectionPolicy.maximumLocalGifCount)
            let wasPresent = items.contains(where: { $0.media.fileId == file.fileId })
            items.removeAll(where: { $0.media.fileId == file.fileId })
            if saved {
                guard wasPresent || items.count < StickerCollectionPolicy.maximumLocalGifCount else { return .failure(.quota) }
                items.insert(RecentMediaItem(file.withUpdatedPartialReference(fileReference.partial ?? file.partialReference)), at: 0)
            }
            try stickerWriteMedia(items, transaction: transaction, key: stickerGifKey)
            return .success(transaction.getOrderedItemListItem(collectionId: Namespaces.OrderedItemList.CloudRecentGifs, itemId: RecentMediaItemId(file.fileId).rawValue) != nil)
        } catch { return .failure((error as? EmojiPackError) ?? .storage) }
    }
    |> castError(EmojiPackError.self)
    |> mapToSignal { result -> Signal<ExteralessSavedGifResult, EmojiPackError> in
        switch result {
        case let .failure(error): return .fail(error)
        case let .success(isCloud):
            if !saved && isCloud {
                return removeSavedGif(postbox: engine.account.postbox, mediaId: fileReference.media.fileId)
                |> map { .cloud(.generic) }
                |> castError(EmojiPackError.self)
            }
            return .single(.local)
        }
    }
}

public func exteralessClearLocalGifs(engine: TelegramEngine) -> Signal<Void, NoError> {
    engine.account.postbox.transaction { transaction in
        transaction.updatePreferencesEntry(key: stickerGifKey, { _ in nil })
    }
}

public func exteralessLocalGifCount(engine: TelegramEngine) -> Signal<Int, EmojiPackError> {
    let key = PostboxViewKey.preferences(keys: [stickerGifKey])
    return engine.account.postbox.combinedView(keys: [key])
    |> castError(EmojiPackError.self)
    |> mapToSignal { view -> Signal<Int, EmojiPackError> in
        do {
            let preferences = view.views[key] as? PreferencesView
            return .single(try stickerReadMedia(preferences?.values[stickerGifKey], limit: StickerCollectionPolicy.maximumLocalGifCount).count)
        } catch { return .fail((error as? EmojiPackError) ?? .invalidCache) }
    }
}

/// Migration seam for native menus that already handle SavedGifResult. Local
/// success and storage failure have separate callbacks, never a fabricated cloud
/// result. All callbacks run on main; disposing cancels the underlying operation.
public func exteralessSaveGifReporting(engine: TelegramEngine, fileReference: FileMediaReference, localSaved: @escaping () -> Void, failed: @escaping (EmojiPackError) -> Void) -> Signal<SavedGifResult, NoError> {
    return exteralessToggleGifSaved(engine: engine, fileReference: fileReference, saved: true)
    |> deliverOnMainQueue
    |> mapToSignal { result -> Signal<SavedGifResult, EmojiPackError> in
        switch result {
        case let .cloud(value): return .single(value)
        case .local: localSaved(); return .complete()
        }
    }
    |> `catch` { error -> Signal<SavedGifResult, NoError> in
        failed(error)
        return .complete()
    }
}
