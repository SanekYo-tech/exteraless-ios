import Foundation

/// App-wide display preferences only. Names, name order and local Premium data
/// belong to the owning account's encrypted Postbox, never this shared store.
public enum IdentityFeatures {
    public static let presentationChanged = Notification.Name("ExteralessIdentityPresentationChanged")

    public static let definitions: [ClientSettingDefinition] = [
        flag("dateOfForwardedMsg", "Show original forwarding date", false, "NaConfig.dateOfForwardedMsg"),
        ClientSettingDefinition(key: "identity.idDcType", title: "Profile ID and data center", section: "Identity", defaultValue: .integer(1), options: [
            .init(value: .integer(0), title: "Hidden"),
            .init(value: .integer(1), title: "Telegram API"),
            .init(value: .integer(2), title: "Bot API")
        ], androidSymbols: ["NaConfig.idDcType", "NekoConfig.showIdAndDc"]),
        flag("preferCommonGroupsTab", "Prefer groups in common to gifts", true, "NaConfig.preferCommonGroupsTab"),
        flag("showFullAbout", "Expand profile descriptions", true, "NaConfig.showFullAbout"),
        flag("showOnlineStatus", "Recent activity colors", false, "NaConfig.showOnlineStatus",
             explanation: "Color the activity indicator for visible last-seen times within the past hour."),
        flag("usePersianCalendar", "Persian calendar", false, "NekoConfig.usePersianCalendar"),
        flag("displayPersianCalendarByLatin", "Latin Persian dates", false, "NekoConfig.displayPersianCalendarByLatin"),
        flag("premiumItemEmojiStatus", "Premium status beside message authors", true, "NaConfig.premiumItemEmojiStatus", section: "Premium presentation"),
        flag("premiumItemEmojiInReplies", "Emoji patterns in replies", true, "NaConfig.premiumItemEmojiInReplies", section: "Premium presentation"),
        flag("premiumItemCustomColorInReplies", "Custom reply colors", true, "NaConfig.premiumItemCustomColorInReplies", section: "Premium presentation"),
        flag("premiumItemCustomWallpaper", "Individual chat wallpapers", true, "NaConfig.premiumItemCustomWallpaper", section: "Premium presentation"),
        flag("premiumItemVideoAvatar", "Animated profile photos", true, "NaConfig.premiumItemVideoAvatar", section: "Premium presentation"),
        flag("premiumItemStarInReactions", "Paid star reactions", true, "NaConfig.premiumItemStarInReactions", section: "Premium presentation"),
        flag("premiumItemStickerEffects", "Premium sticker effects", true, "NaConfig.premiumItemStickerEffects", section: "Premium presentation"),
        flag("premiumItemBoosts", "Boost badges beside message authors", true, "NaConfig.premiumItemBoosts", section: "Premium presentation")
    ]

    /// Used by the account-local editor; deliberately not registered in ClientSettings.
    public static let accountDefinitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(key: "identity.nameOrder", title: "Name order", section: "Identity", defaultValue: .integer(1), options: [
            .init(value: .integer(0), title: "Last name, first name"),
            .init(value: .integer(1), title: "First name, last name")
        ], androidSymbols: ["NekoConfig.nameOrder"]),
        flag("localPremium", "Local Premium presentation", false, "NekoConfig.localPremium",
             explanation: "Use a local badge, emoji status and reply/profile appearance for this account. Telegram subscription features still use your actual subscription.")
    ]

    private static func flag(_ field: String, _ title: String, _ value: Bool, _ symbol: String,
                             section: String = "Identity", explanation: String? = nil) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "identity." + field, title: title, section: section,
                                defaultValue: .bool(value), explanation: explanation, androidSymbols: [symbol])
    }

    /// Android NaConfig migrates only an explicitly disabled legacy switch, and
    /// only in the absence of its replacement. Importers use this same precedence.
    public static func migratedIdDisplay(current: Int?, legacyShowIdAndDc: Bool?) -> Int {
        if let current, (0...2).contains(current) { return current }
        return legacyShowIdAndDc == false ? 0 : 1
    }
}

public struct IdentityDisplayPolicy: Equatable, Sendable {
    public let dateOfForwardedMsg: Bool
    public let idDcType: Int
    public let preferCommonGroupsTab: Bool
    public let showFullAbout: Bool
    public let showOnlineStatus: Bool
    public let premiumItemEmojiStatus: Bool
    public let premiumItemEmojiInReplies: Bool
    public let premiumItemCustomColorInReplies: Bool
    public let premiumItemCustomWallpaper: Bool
    public let premiumItemVideoAvatar: Bool
    public let premiumItemStarInReactions: Bool
    public let premiumItemStickerEffects: Bool
    public let premiumItemBoosts: Bool
    public let calendar: IdentityDatePolicy

    public init(values: [String: ClientSettingValue] = [:]) {
        func flag(_ field: String, _ fallback: Bool) -> Bool {
            if case let .bool(value)? = values["identity." + field] { return value }
            return fallback
        }
        self.dateOfForwardedMsg = flag("dateOfForwardedMsg", false)
        if case let .integer(value)? = values["identity.idDcType"], (0...2).contains(value) {
            self.idDcType = Int(value)
        } else { self.idDcType = 1 }
        self.preferCommonGroupsTab = flag("preferCommonGroupsTab", true)
        self.showFullAbout = flag("showFullAbout", true)
        self.showOnlineStatus = flag("showOnlineStatus", false)
        self.premiumItemEmojiStatus = flag("premiumItemEmojiStatus", true)
        self.premiumItemEmojiInReplies = flag("premiumItemEmojiInReplies", true)
        self.premiumItemCustomColorInReplies = flag("premiumItemCustomColorInReplies", true)
        self.premiumItemCustomWallpaper = flag("premiumItemCustomWallpaper", true)
        self.premiumItemVideoAvatar = flag("premiumItemVideoAvatar", true)
        self.premiumItemStarInReactions = flag("premiumItemStarInReactions", true)
        self.premiumItemStickerEffects = flag("premiumItemStickerEffects", true)
        self.premiumItemBoosts = flag("premiumItemBoosts", true)
        self.calendar = IdentityDatePolicy(usePersianCalendar: flag("usePersianCalendar", false), latin: flag("displayPersianCalendarByLatin", false))
    }
}
