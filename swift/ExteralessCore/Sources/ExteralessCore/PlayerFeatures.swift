import Foundation

/// Player appearance is owned here, not by ChatFeatures/AppearanceFeatures. The
/// Android field names are retained so backup and parity identities stay stable.
public enum PlayerFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        toggle("md3Player", "Modern music player", "Player", true,
            "Native adaptive artwork, controls and lyrics. Off uses Telegram's classic player."),
        toggle("md3MiniPlayer", "Modern mini player", "Mini player", true),
        toggle("profileMusicCard", "Profile music card", "Player", true,
            "Show saved music in profile headers, including My Profile. The saved-music library remains available."),
        toggle("lrclibAllowed", "Online lyrics", "Player · Lyrics", false,
            "Send track title, artist, album and duration to LRCLIB; LRCMUX is a fallback. Local lyrics work offline."),
        choice("playerCoverStyle", "Artwork style", "Player · Artwork", 0, ["Card", "Wide", "Full background", "Disc"]),
        range("playerCoverSize", "Artwork size (%)", "Player · Artwork", 100, 60, 100),
        range("playerCoverRadius", "Artwork corner radius", "Player · Artwork", 28, 0, 48),
        toggle("playerDiscSpin", "Rotate disc while playing", "Player · Artwork", true),
        toggle("playerCoverSwipe", "Swipe artwork to change track", "Player · Artwork", true),
        toggle("playerCoverExtend", "Extend background artwork", "Player · Artwork", true),
        choice("playerTitleAlign", "Title alignment", "Player · Layout", 0, ["Leading", "Centered"]),
        choice("playerTitleSize", "Title size", "Player · Layout", 1, ["Small", "Medium", "Large"]),
        toggle("playerTitleAbove", "Title above artwork", "Player · Layout", false),
        .init(key: "appearance.playerOrder", title: "Player block order", section: "Player · Layout", defaultValue: .string(""),
            options: [
                .init(value: .string(""), title: "Progress · Controls · Actions"),
                .init(value: .string("0,2,1"), title: "Progress · Actions · Controls"),
                .init(value: .string("1,0,2"), title: "Controls · Progress · Actions"),
                .init(value: .string("1,2,0"), title: "Controls · Actions · Progress"),
                .init(value: .string("2,0,1"), title: "Actions · Progress · Controls"),
                .init(value: .string("2,1,0"), title: "Actions · Controls · Progress")
            ], androidSymbols: ["AppearanceConfig.playerOrder", "PlayerStyle.order"]),
        toggle("playerShowActions", "Show lyrics, queue and speed buttons", "Player · Controls", true),
        toggle("playerShowModes", "Show shuffle and repeat", "Player · Controls", true),
        toggle("playerShowLike", "Show save-to-profile button", "Player · Controls", true),
        toggle("playerShowSource", "Show track source", "Player · Controls", true),
        toggle("playerWavy", "Wavy progress", "Player · Controls", true),
        choice("playerControlsSize", "Playback control size", "Player · Controls", 1, ["Small", "Medium", "Large"]),
        choice("playerActionsStyle", "Action buttons", "Player · Controls", 0, ["Separate buttons", "Island"]),
        choice("playerColors", "Player colors", "Player · Colors", 0, ["From artwork", "Telegram theme"]),
        choice("playerBackground", "Player background", "Player · Colors", 0, ["Solid", "Gradient", "Blurred artwork"]),
        choice("playerMiniCover", "Mini artwork", "Mini player", 0, ["Rounded", "Circle", "Hidden"]),
        choice("playerMiniShape", "Mini shape", "Mini player", 0, ["Rounded", "Pill", "Square"]),
        choice("playerMiniProgress", "Mini progress", "Mini player", 0, ["Play-button ring", "Line", "Hidden", "Border"]),
        choice("playerMiniColors", "Mini colors", "Mini player", 1, ["From artwork", "Telegram theme"]),
        toggle("playerMiniCompact", "Compact mini player", "Mini player", false),
        toggle("playerMiniArtist", "Show artist", "Mini player", true),
        toggle("playerMiniPrevious", "Show previous track", "Mini player", false),
        toggle("playerMiniNext", "Show next track", "Mini player", true),
        toggle("playerMiniClose", "Show close button", "Mini player", true),
        toggle("playerMiniTop", "Mini player at top", "Mini player", false,
            "On the main tabs, choose the top accessory or a floating panel above the tab bar. Chat accessories stay at the top.")
    ]

    /// Register alongside the exact Gallery gesture hook supplied in player.md.
    public static let galleryDefinitions: [ClientSettingDefinition] = [
        .init(key: "chats.swipeToPip", title: "Swipe video into Picture in Picture", section: "Chats · Playback", defaultValue: .bool(false),
            explanation: "A downward gallery dismissal enters native Picture in Picture when the current video supports it.", androidSymbols: ["ChatsConfig.swipeToPip"])
    ]

    public static func owns(_ key: String) -> Bool {
        key.hasPrefix("appearance.player") || ["appearance.md3Player", "appearance.md3MiniPlayer", "appearance.profileMusicCard", "appearance.lrclibAllowed"].contains(key)
    }

    private static func toggle(_ field: String, _ title: String, _ section: String, _ value: Bool, _ explanation: String? = nil) -> ClientSettingDefinition {
        .init(key: "appearance." + field, title: title, section: section, defaultValue: .bool(value), explanation: explanation, androidSymbols: ["AppearanceConfig." + field])
    }

    private static func choice(_ field: String, _ title: String, _ section: String, _ value: Int64, _ options: [String]) -> ClientSettingDefinition {
        .init(key: "appearance." + field, title: title, section: section, defaultValue: .integer(value), options: options.enumerated().map { .init(value: .integer(Int64($0.offset)), title: $0.element) }, androidSymbols: ["AppearanceConfig." + field])
    }

    private static func range(_ field: String, _ title: String, _ section: String, _ value: Int64, _ minimum: Double, _ maximum: Double) -> ClientSettingDefinition {
        .init(key: "appearance." + field, title: title, section: section, defaultValue: .integer(value), minimum: minimum, maximum: maximum, step: 1, androidSymbols: ["AppearanceConfig." + field])
    }
}
