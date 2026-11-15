import Foundation

/// Android's NekoConfig.typeface is a family choice, independent of text size
/// and forceFontWeightFallback. UIKit/CoreText resource handling lives in Display.
public enum CoreAppearanceFontFamilyPolicy {
    public static let key = "appearance.useSystemFonts"

    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(
            key: "appearance.useSystemFonts", title: "Use system fonts", section: "Appearance · Text",
            defaultValue: .bool(true),
            explanation: "Uses Apple's system family for interface text. Turn off to use bundled Roboto. Text size, Dynamic Type, and explicit monospace, serif, rounded and camera designs keep their native roles.",
            androidSymbols: ["NekoConfig.typeface", "ExteraConfig.getUseSystemFonts", "ExteraConfig.setUseSystemFonts", "AndroidUtilities.getTypeface"]
        )
    ]

    public enum Role: Sendable {
        case sansSerif
        case serif
        case monospace
        case rounded
        case camera
    }

    public enum Selection: String, Sendable {
        case platformSystem
        case bundledRoboto
        case nativeRole
    }

    /// The original default is true, including before schema registration.
    public static func useSystemFonts(in settings: ClientSettings = .shared) -> Bool {
        return settings.bool(self.key, default: true)
    }

    public static func selection(useSystemFonts: Bool, role: Role) -> Selection {
        switch role {
        case .sansSerif:
            return useSystemFonts ? .platformSystem : .bundledRoboto
        case .serif, .monospace, .rounded, .camera:
            return .nativeRole
        }
    }
}
