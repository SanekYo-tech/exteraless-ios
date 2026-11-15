import Foundation

public struct StickerPolicy: Equatable, Sendable {
    public let size: Double
    public let recentCount: Int
    public let hideChoosingActivity: Bool
    public let hideTrending: Bool
    public let disableGreetingSend: Bool
    public let hideGroupPack: Bool
    public let compactCreator: Bool
    public let sendLockedEmojiAsSticker: Bool
    public let localGifs: Bool
    public let systemEmoji: Bool
    public let downloadEmojiPacks: Bool
    public let emojiPack: String

    public init(settings: ClientSettings = .shared) {
        self.init(values: settings.snapshot())
    }

    public init(values: [String: ClientSettingValue]) {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            if case let .bool(value) = values["chats.\(key)"] { return value }
            return fallback
        }
        var size: Double = 14
        if case let .number(value) = values["chats.stickerSize"] { size = value }
        else if case let .integer(value) = values["chats.stickerSize"] { size = Double(value) }
        self.size = size.isFinite ? min(20, max(4, size)) : 14
        if case let .integer(count) = values["chats.maxRecentStickerCount"] {
            self.recentCount = Int(min(200, max(20, count)))
        } else { self.recentCount = 20 }
        self.hideChoosingActivity = flag("disableChoosingSticker", false)
        self.hideTrending = flag("disableTrending", true)
        self.disableGreetingSend = flag("dontSendGreetingSticker", true)
        self.hideGroupPack = flag("hideGroupSticker", false)
        self.compactCreator = flag("minimizedStickerCreator", false)
        self.sendLockedEmojiAsSticker = flag("sendLockedCustomEmojiAsSticker", true)
        self.localGifs = flag("unlimitedSavedGifs", false)
        self.systemEmoji = flag("useSystemEmoji", false)
        self.downloadEmojiPacks = flag("downloadEmojiPacks", false)
        if case let .string(value) = values["chats.emojiPack"] { self.emojiPack = value }
        else { self.emojiPack = "" }
    }

    /// Android's relative phone/tablet zoom, with Telegram iOS's own stock bound
    /// as the baseline. 14 is exactly identity; callers keep native aspect fitting.
    public func stickerSide(stock: Double, available: Double, isTablet: Bool) -> Double {
        guard stock.isFinite, available.isFinite, stock > 0, available > 0 else { return 0 }
        let scale = 1 + (self.size - 14) / (isTablet ? 16 : 15)
        return min(available, stock * scale)
    }

    public func canUploadLockedEmoji(mimeType: String, isPremium: Bool, isSavedMessages: Bool, isGroupEmoji: Bool) -> Bool {
        self.sendLockedEmojiAsSticker && !isPremium && !isSavedMessages && !isGroupEmoji
            && ["image/webp", "video/webm"].contains(mimeType)
    }
}

public enum StickerCollectionPolicy {
    public static let maximumRecentCount = 200
    public static let maximumLocalGifCount = 10_000

    /// Local order wins; fresh cloud references replace matching old metadata.
    /// Truncation only affects this projection, never the supplied collections.
    public static func merged<Item, Id: Hashable>(local: [Item], cloud: [Item], limit: Int, id: (Item) -> Id) -> [Item] {
        let fresh = Dictionary(cloud.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Id>()
        var result: [Item] = []
        guard limit > 0 else { return result }
        for item in local + cloud {
            let key = id(item)
            if seen.insert(key).inserted { result.append(fresh[key] ?? item) }
            if result.count == limit { break }
        }
        return result
    }
}
