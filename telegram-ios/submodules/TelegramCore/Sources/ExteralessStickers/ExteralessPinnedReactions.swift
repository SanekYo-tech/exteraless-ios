import ExteralessCore
import SwiftSignalKit

/// Configuration is global as in NaConfig; document resolution and entitlement
/// are always performed by the currently requesting account. No global media cache.
public func exteralessPinnedReactionItems(engine: TelegramEngine, isChannel: Bool) -> Signal<[RecentReactionItem], NoError> {
    let pins = StickerReactionPolicy.pins(isChannel: isChannel)
    guard !pins.isEmpty else { return .single([]) }
    let ids = pins.compactMap { pin -> Int64? in if case let .custom(id) = pin { return id }; return nil }
    return combineLatest(
        engine.stickers.resolveInlineStickers(fileIds: ids),
        engine.stickers.availableReactions() |> take(1),
        engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: engine.account.peerId))
    )
    |> map { files, available, accountPeer in
        pins.compactMap { pin -> RecentReactionItem? in
            switch pin {
            case let .emoji(value):
                guard available?.reactions.contains(where: { $0.isEnabled && $0.value == .builtin(value) }) == true else { return nil }
                return RecentReactionItem(.builtin(value))
            case let .custom(id):
                guard let file = files[id], file.isCustomEmoji, accountPeer?.isPremium == true || !file.isPremiumEmoji else { return nil }
                return RecentReactionItem(.custom(TelegramMediaFile.Accessor(file)))
            }
        }
    }
}
