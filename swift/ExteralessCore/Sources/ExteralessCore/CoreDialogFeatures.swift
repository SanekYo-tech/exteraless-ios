import Foundation

/// Only live dialog preferences. DialogConfig's per-peer, tri-state forum
/// override lives in the account's native preferences, not in a global toggle.
public enum DialogFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        toggle("chats.sortByUnread", "Prioritize unread chats", "Chats · List",
            "Mentions, reactions and unmuted unread chats come first after pinned chats. Uses the original Nagram SortByUnread rule.", "NaConfig.sortByUnread"),
        toggle("chats.disableGlobalSearch", "Hide global peer search results", "Chats · Search",
            "Keeps your chats and contacts. Telegram's server search still supplies joined chats and contacts; message and hashtag search remain available.", "NaConfig.disableGlobalSearch"),
        toggle("chats.disableStories", "Disable stories", "Chats · Stories",
            "Disables story discovery, entry points and preloading on this device. Your published stories and their server privacy are not changed.", "NaConfig.disableStories"),
        toggle("appearance.hideArchive", "Hide archive folder", "Chats · Archive",
            "Removes the archive row, including its pull gesture. Archived chats remain accessible from the main menu.", "NaConfig.hideArchive"),
        toggle("chats.openArchiveOnPull", "Open archive on pull", "Chats · Archive",
            "Opens the archive when the native pull-to-reveal gesture completes. Temporarily hides the native archive row above the list; turning this off restores its previous position.", "NekoConfig.openArchiveOnPull"),
        toggle("chats.doNotUnarchiveBySwipe", "Disable swipe in archive", "Chats · Archive",
            "Keeps archived chats from being unarchived by a row swipe. The explicit unarchive menu action remains available.", "NaConfig.doNotUnarchiveBySwipe"),
        page("searchHashtagDefaultPageChat", "Hashtags in chats", "NaConfig.searchHashtagDefaultPageChat"),
        page("searchHashtagDefaultPageChannel", "Hashtags in public channels", "NaConfig.searchHashtagDefaultPageChannel"),
        toggle("chats.disableSwipeToNext", "Disable swipe to next channel", "Chats · Navigation", nil, "NekoConfig.disableSwipeToNext"),
        toggle("chats.disableSwipeToNextTopic", "Disable swipe to next topic", "Chats · Navigation", nil, "NekoConfig.disableSwipeToNextTopic"),
        toggle("chats.rememberAllBackMessages", "Remember reply navigation", "Chats · Navigation",
            "Return through visited messages instead of keeping only the latest return point. Long-press the down button to clear the return path. The path belongs to this chat or thread.", "NekoConfig.rememberAllBackMessages"),
        toggle("chats.unreadBadgeOnBackButton", "Unread badge on back button", "Chats · Navigation",
            "Uses Telegram's existing unread badge and notification-count preferences. Feed and search entry points can suppress it independently.", "NekoConfig.unreadBadgeOnBackButton"),
        toggle("chats.unlimitedPinnedDialogs", "Additional local chat pins", "Chats · List",
            "Allows root-list pins up to Telegram's archive pin limit. Pins beyond the server's root limit stay on this device; folders and topics keep their own native limits. Turning this off reconciles with the server's pin list.", "NekoConfig.unlimitedPinnedDialogs")
    ]

    public static let keys = Set(definitions.map(\.key))

    private static func toggle(_ key: String, _ title: String, _ section: String, _ explanation: String?, _ symbol: String) -> ClientSettingDefinition {
        ClientSettingDefinition(key: key, title: title, section: section, defaultValue: .bool(false), explanation: explanation, androidSymbols: [symbol])
    }

    private static func page(_ field: String, _ title: String, _ symbol: String) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "chats." + field, title: title, section: "Chats · Search", defaultValue: .integer(0), options: [
            ClientSettingOption(value: .integer(0), title: "This chat"),
            ClientSettingOption(value: .integer(1), title: "My messages"),
            ClientSettingOption(value: .integer(2), title: "Public posts")
        ], explanation: "Default for an ordinary hashtag tap. An explicitly chosen search scope takes precedence.", androidSymbols: [symbol])
    }
}
