import Foundation

/// NaConfig/AyuSavePreferences, rather than the compatibility ExteraConfig getters.
/// Message contents and per-peer exceptions are held by the account's Postbox, never here.
public enum RetentionFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        flag("enableSaveDeletedMessages", "Keep received deleted messages", false),
        flag("enableSaveEditsHistory", "Keep message edit history", false),
        mode("saveDeletedExceptionsMode", "Deleted-message exceptions"),
        mode("saveEditedExceptionsMode", "Edit-history exceptions"),
        flag("saveDeletedInPrivateChats", "Keep deleted messages in private chats", true),
        flag("saveDeletedInGroups", "Keep deleted messages in groups", true),
        flag("saveDeletedInChannels", "Keep deleted messages in channels", true),
        flag("saveInArchivedChats", "Keep history in archived chats", true),
        flag("saveDeletedMessageForBot", "Keep deleted messages in bot chats", false,
             "Ayu's fallback for messages without a known user sender. Messages from a known bot use the next control."),
        flag("saveDeletedMessageForBotUser", "Keep deleted messages from bots", false),
        flag("messageSavingSaveMedia", "Keep locally received media", true,
             "Retains available files with account-owned encrypted copies. Files the client never received remain unavailable."),
        flag("saveMediaInPrivateChats", "Keep media in private chats", true),
        flag("saveMediaInPublicChannels", "Keep media in public channels", true),
        flag("saveMediaInPrivateChannels", "Keep media in private channels", true),
        flag("saveMediaInPublicGroups", "Keep media in public groups", true),
        flag("saveMediaInPrivateGroups", "Keep media in private groups", true),
        flag("translucentDeletedMessages", "Translucent deleted messages", true, prefix: "chats"),
        flag("useDeletedIcon", "Use a deleted-message icon", true, prefix: "chats"),
        flag("useEditedIcon", "Use an edited-message icon", true, prefix: "chats"),
        flag("replyToDeletedAsQuote", "Reply to deleted messages as a quote", true,
             "Adds a local text quote and keeps the real thread target; does not send a deleted message ID as a server reply.", prefix: "chats"),
        ClientSettingDefinition(key: "chats.showMessageHide", title: "Hide message in context menu", section: "Retained messages", defaultValue: .bool(false),
            explanation: "Hides selected messages for the current chat session, matching the original local hide flag.", androidSymbols: ["NekoConfig.showMessageHide"]),
        ClientSettingDefinition(key: "chats.showViewHistory", title: "Sender history in group message menu", section: "Retained messages", defaultValue: .bool(false),
            explanation: "Opens the native group search filtered by the message author. This is separate from edit history.", androidSymbols: ["NekoConfig.showViewHistory", "ChatActivity.nkbtn_view_history"]),
        ClientSettingDefinition(key: "chats.customEditedMessage", title: "Edited-message label", section: "Retained messages", defaultValue: .string(""),
            explanation: "Empty uses the default edited label. Used when the edited icon is off.", androidSymbols: ["NaConfig.customEditedMessage", "TimeStringHelper.createEditedString"]),
        ClientSettingDefinition(key: "chats.customDeletedMark", title: "Deleted-message label", section: "Retained messages", defaultValue: .string(""),
            explanation: "Empty uses the default label. Used when the deleted icon is off.", androidSymbols: ["NaConfig.customDeletedMark", "TimeStringHelper.createDeletedString"]),
        ClientSettingDefinition(key: "chats.deletedMarkColor", title: "Deleted-message label color (ARGB)", section: "Retained messages", defaultValue: .integer(0), minimum: Double(Int32.min), maximum: Double(UInt32.max), step: 1,
            explanation: "0 follows the theme. Accepts Android signed ARGB and unsigned 32-bit ARGB.", androidSymbols: ["NaConfig.deletedMarkColor", "TimeStringHelper.createDeletedString"]),
        flag("chatMenuItemViewDeleted", "View deleted messages in chat menu", true, prefix: "chats"),
        flag("chatMenuItemClearDeleted", "Clear retained history in chat menu", true, prefix: "chats"),
        ClientSettingDefinition(key: "privacy.retentionDays", title: "Keep retained history for (days)", section: "Retained messages", defaultValue: .integer(30), minimum: 1, maximum: 365, step: 1,
            explanation: "iOS storage bound: counted from first local capture, including media. Replayed updates do not renew it."),
        ClientSettingDefinition(key: "privacy.retentionMessageLimit", title: "Maximum retained messages per account", section: "Retained messages", defaultValue: .integer(5000), minimum: 100, maximum: 20000, step: 100,
            explanation: "Oldest captures are removed first. At most 32 versions of each message and 32 MiB of metadata are retained."),
        ClientSettingDefinition(key: "privacy.retentionMediaMegabytes", title: "Maximum retained media per account (MiB)", section: "Retained messages", defaultValue: .integer(512), minimum: 16, maximum: 2048, step: 16,
            explanation: "Encrypted and native full-file copies share this bound. A file can use at most 128 MiB. Derived thumbnails use Telegram's cache budget; unavailable or oversized files are identified in the archive.")
    ]

    public static let keys = Set(definitions.map(\.key))

    private static func flag(_ field: String, _ title: String, _ value: Bool, _ explanation: String? = nil, prefix: String = "privacy") -> ClientSettingDefinition {
        ClientSettingDefinition(key: "\(prefix).\(field)", title: title, section: "Retained messages", defaultValue: .bool(value), explanation: explanation, androidSymbols: ["NaConfig.\(field)"])
    }

    private static func mode(_ field: String, _ title: String) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "privacy.\(field)", title: title, section: "Retained messages", defaultValue: .integer(0), options: [
            ClientSettingOption(value: .integer(0), title: "Keep except marked chats or senders"),
            ClientSettingOption(value: .integer(1), title: "Keep only marked chats or senders")
        ], explanation: "Marks are edited in Retention for a chat and belong to the current account.", androidSymbols: ["NaConfig.\(field)", "AyuSavePreferences"])
    }
}
