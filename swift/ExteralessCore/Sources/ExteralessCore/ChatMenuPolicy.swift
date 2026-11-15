import Foundation

public enum ChatMenuPolicy {
    public struct Preference: Sendable {
        public let field: String
        public let title: String
        public let initial: Bool
        public let source: String
        public init(_ field: String, _ title: String, _ initial: Bool, source: String = "NaConfig") {
            self.field = field; self.title = title; self.initial = initial; self.source = source
        }
    }
    public static let preferences: [Preference] = [
        .init("ActionBarButtonCopy", "Selection · Copy", true), .init("ActionBarButtonEdit", "Selection · Edit", true),
        .init("ActionBarButtonForward", "Selection · Forward", true), .init("ActionBarButtonReply", "Selection · Reply", false),
        .init("ActionBarButtonSelectBetween", "Selection · Select between", true),
        .init("chatMenuItemBoostGroup", "Chat menu · Boost", true), .init("chatMenuItemDeleteOwnMessages", "Chat menu · Delete my messages", true),
        .init("chatMenuItemGoToMessage", "Chat menu · Go to message", true), .init("chatMenuItemHideTitle", "Chat menu · Hide title", true),
        .init("chatMenuItemLinkedChat", "Chat menu · Linked chat", true), .init("chatMenuItemToBeginning", "Chat menu · Beginning", true),
        .init("deleteChatForBothSides", "Prefer delete for both in confirmations", true),
        .init("groupedMessageMenu", "Group extra message actions", true),
        .init("mediaViewerMenuItemCopyFrame", "Viewer · Copy frame", true), .init("mediaViewerMenuItemCopyPhoto", "Viewer · Copy photo", true),
        .init("mediaViewerMenuItemForward", "Viewer · Forward", true), .init("mediaViewerMenuItemNoQuoteForward", "Viewer · Forward without sender", true),
        .init("mediaViewerMenuItemScanQRCode", "Viewer · Scan QR", true), .init("mediaViewerMenuItemSetProfilePhoto", "Viewer · Set profile photo", true),
        .init("shortcutsAdministrators", "Chat menu · Administrators", false), .init("shortcutsMembers", "Chat menu · Members", false),
        .init("shortcutsPermissions", "Chat menu · Permissions", false), .init("shortcutsRecentActions", "Chat menu · Recent actions", true),
        .init("shortcutsStatistics", "Chat menu · Statistics", false),
        .init("showAddToBookmark", "Bookmark message", false), .init("showAddToFavorites", "Favorite sticker / GIF", true),
        .init("showAddToStickers", "Create sticker", false), .init("showCopyAsSticker", "Copy as sticker", false),
        .init("showCopyFrame", "Copy video frame", false), .init("showCopyLink", "Copy message link", true),
        .init("showCopyPhoto", "Copy photo", false), .init("showNoQuoteForward", "Forward without sender", false),
        .init("showReactions", "Reactions in message menu", true), .init("showRepeatAsCopy", "Repeat as copy", false),
        .init("showReplyInPrivate", "Reply privately", false), .init("showSetReminder", "Set reminder", false),
        .init("showAdminActions", "Message author · Administration", false, source: "NekoConfig"),
        .init("showChangePermissions", "Message author · Permissions", false, source: "NekoConfig"),
        .init("showDeleteDownloadedFile", "Delete downloaded media", true, source: "NekoConfig"),
        .init("showReport", "Report message", false, source: "NekoConfig"), .init("showShareMessages", "Share messages", false, source: "NekoConfig")
    ]
    public static func enabled(_ field: String, settings: ClientSettings = .shared) -> Bool {
        guard let value = preferences.first(where: { $0.field == field }) else { return false }
        return settings.bool("chats." + field, default: value.initial)
    }

    /// Native selected-message actions use the original six persisted values.
    public static func leftAction(rawValue: Int, canForward: Bool, canSelectBetween: Bool) -> Int {
        if rawValue == 4 { return canSelectBetween ? 4 : 1 }
        guard canForward else { return 1 }
        return (0 ... 5).contains(rawValue) ? rawValue : 0
    }
}
