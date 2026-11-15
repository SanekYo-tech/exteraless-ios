import Foundation

/// The three sticker shape/time keys are owned by ChatFeatures. Catalog cache
/// state and the unused Android useCustomEmoji field are deliberately not rows.
public enum StickerFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(key: "chats.stickerSize", title: "Sticker and animated emoji size", section: "Chats · Stickers", defaultValue: .number(14), minimum: 4, maximum: 20, step: 1, explanation: "14 keeps Telegram's native size. Applies to standalone stickers and animated emoji, within the message's available width.", androidSymbols: ["NekoConfig.stickerSize"]),
        ClientSettingDefinition(key: "chats.maxRecentStickerCount", title: "Recent stickers", section: "Chats · Stickers", defaultValue: .integer(20), minimum: 20, maximum: 200, step: 1, explanation: "Keeps up to this many recent stickers on this device. Telegram's cloud limit is unchanged.", androidSymbols: ["NekoConfig.maxRecentStickerCount"]),
        toggle("disableChoosingSticker", "Hide choosing-sticker activity", false, "Suppresses the outgoing choosing-sticker status; the picker remains available.", "NekoConfig.disableChoosingSticker"),
        toggle("disableTrending", "Hide trending sticker and emoji packs", true, nil, "NekoConfig.disableTrending"),
        toggle("dontSendGreetingSticker", "Disable greeting-sticker tap to send", true, "The greeting remains visible. Tapping it does not send a message.", "NekoConfig.dontSendGreetingSticker"),
        toggle("hideGroupSticker", "Hide group sticker pack", false, "Hides the chat's suggested group sticker tab, without uninstalling its pack.", "NekoConfig.hideGroupSticker"),
        toggle("minimizedStickerCreator", "Compact sticker creator", false, "Moves Create Sticker from the grid into the recent-sticker header.", "NekoConfig.minimizedStickerCreator"),
        toggle("sendLockedCustomEmojiAsSticker", "Send locked emoji as stickers", true, "WebP and WebM custom emoji can be uploaded as ordinary stickers. Native chat permissions, paid-message confirmation and scheduling still apply.", "NaConfig.sendLockedCustomEmojiAsSticker"),
        toggle("unlimitedSavedGifs", "Keep additional GIFs locally", false, "Removes the cloud-count cap for this device's separate GIF library (up to 10,000 items / 16 MiB of metadata). This does not raise Telegram's server limit.", "NaConfig.unlimitedSavedGifs"),
        toggle("useSystemEmoji", "Use system emoji", false, "Uses the emoji supplied by this iOS version. Default also uses Apple's native font on iOS; a selected app font is restored when this is turned off.", "NekoConfig.useSystemEmoji"),
        toggle("downloadEmojiPacks", "Download emoji packs", false, "Enables the original nagramx_remote_metadata source and user-selected HTTPS font downloads. Downloads start only from the Emoji Packs screen.", "OpenExteraConfig.downloadEmojiPacks"),
        ClientSettingDefinition(key: "chats.emojiPack", title: "Selected emoji pack", section: "Chats · Emoji Packs", defaultValue: .string(""), explanation: "Managed by Emoji Packs. Empty/default restores the native iOS font. Missing or invalid fonts fall back to the native font.", androidSymbols: ["EmojiHelper.emojiPack"]),
        toggle("usePinnedReactionsChats", "Pinned reactions in chats", false, nil, "NaConfig.usePinnedReactionsChats"),
        toggle("usePinnedReactionsChannels", "Pinned reactions in channels", false, nil, "NaConfig.usePinnedReactionsChannels"),
        ClientSettingDefinition(key: "chats.pinnedReactionsChats", title: "Chat pinned reaction order", section: "Chats · Reactions", defaultValue: .string("[]"), explanation: "Edit with Pinned Reactions. Up to seven entries in the original emoticon/document_id JSON format.", androidSymbols: ["NaConfig.pinnedReactionsChats"]),
        ClientSettingDefinition(key: "chats.pinnedReactionsChannels", title: "Channel pinned reaction order", section: "Chats · Reactions", defaultValue: .string("[]"), explanation: "Edit with Pinned Reactions. Only reactions permitted by the current chat are offered.", androidSymbols: ["NaConfig.pinnedReactionsChannels"])
    ]

    public static let keys = Set(definitions.map(\.key))
    public static let changedNotification = Notification.Name("Exteraless.StickerFeaturesChanged")
    public static let emojiChangedNotification = Notification.Name("Exteraless.EmojiFontChanged")

    private static func toggle(_ field: String, _ title: String, _ value: Bool, _ explanation: String?, _ symbol: String) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "chats.\(field)", title: title, section: field.contains("Reaction") ? "Chats · Reactions" : "Chats · Stickers", defaultValue: .bool(value), explanation: explanation, androidSymbols: [symbol])
    }
}
