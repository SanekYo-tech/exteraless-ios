import Foundation

/// Original AppearanceConfig.monetStyle / monetAssetSuffix (0 is Telemone).
/// Choosing a style is deliberately independent of choosing a native theme.
public enum AppearanceMonetStyle: Int, CaseIterable, Sendable {
    case telemone = 0
    case classic = 1

    public init(setting: Int) {
        self = setting == 1 ? .classic : .telemone
    }

    public var title: String { self == .telemone ? "Telemone" : "Classic" }
    public var androidAssetSuffix: String { self == .classic ? "_gram" : "" }
}

public enum AppearanceMonetMode: String, CaseIterable, Sendable {
    case light, dark, amoled

    public var isDark: Bool { self != .light }
    public var title: String {
        switch self {
        case .light: return "Monet Light"
        case .dark: return "Monet Dark"
        case .amoled: return "Monet AMOLED"
        }
    }
}

public enum AppearanceMonetPaletteID: String, CaseIterable, Sendable {
    case primary = "a1"
    case secondary = "a2"
    case tertiary = "a3"
    case neutral = "n1"
    case neutralVariant = "n2"
}

public struct AppearanceMonetRoleTone: Equatable, Sendable {
    public let palette: AppearanceMonetPaletteID
    public let tone: Int

    public init(_ palette: AppearanceMonetPaletteID, _ tone: Int) {
        self.palette = palette
        self.tone = tone
    }
}

/// The descriptor lives in a *real, encoded native local theme*, not a second
/// enabled/mode preference. Its versioned name survives native encode/decode and
/// keeps ordinary user themes (including ones named "Monet Light") untouched.
/// The native local reference has a short display title and its own resource id.
public struct AppearanceMonetDescriptor: Equatable, Sendable {
    public let mode: AppearanceMonetMode
    public let seedRGB: UInt32
    public let renderedStyle: AppearanceMonetStyle
    public let nativeOutgoingOverride: Bool

    public init(mode: AppearanceMonetMode, seedRGB: UInt32, renderedStyle: AppearanceMonetStyle, nativeOutgoingOverride: Bool = false) {
        self.mode = mode
        self.seedRGB = seedRGB & 0x00ffffff
        self.renderedStyle = renderedStyle
        self.nativeOutgoingOverride = nativeOutgoingOverride
    }

    public var encodedThemeName: String {
        return "\(self.mode.title) [exl-monet-v1|\(self.mode.rawValue)|\(String(format: "%06X", self.seedRGB))|\(self.renderedStyle.rawValue)|\(self.nativeOutgoingOverride ? 1 : 0)]"
    }

    public init?(encodedThemeName: String) {
        guard encodedThemeName.utf8.count <= 96,
              let start = encodedThemeName.range(of: " [exl-monet-v1|"),
              encodedThemeName.hasSuffix("]") else { return nil }
        let fields = encodedThemeName[start.upperBound ..< encodedThemeName.index(before: encodedThemeName.endIndex)].split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 4, let mode = AppearanceMonetMode(rawValue: String(fields[0])),
              let seed = AppearanceMonetPolicy.parseSeed(String(fields[1])),
              let rawStyle = Int(fields[2]), let style = AppearanceMonetStyle(rawValue: rawStyle),
              fields[3] == "0" || fields[3] == "1" else { return nil }
        self.init(mode: mode, seedRGB: seed, renderedStyle: style, nativeOutgoingOverride: fields[3] == "1")
        guard self.encodedThemeName == encodedThemeName else { return nil }
    }
}

/// Platform-independent selector and Original MonetHelper role tables. Android's
/// system palette acquisition is supplied by a native HCT seed adapter on iOS.
public enum AppearanceMonetPolicy {
    public static let settingKey = "appearance.monetStyle"
    public static let definition = ClientSettingDefinition(
        key: settingKey, title: "Monet style", section: "Appearance · Themes",
        defaultValue: .integer(0), options: [
            ClientSettingOption(value: .integer(0), title: "Telemone · Material 3 roles"),
            ClientSettingOption(value: .integer(1), title: "Classic · tonal palettes")
        ],
        explanation: "Changes selected Monet themes only. Choose Monet Light, Dark or AMOLED in Monet Themes. Colors are generated from your accent; iOS does not expose Android wallpaper palettes.",
        androidSymbols: ["AppearanceConfig.monetStyle", "AppearanceConfig.monetAssetSuffix", "Theme.reloadMonetThemes", "MonetHelper.resolveRoleTone"]
    )
    public static let definitions: [ClientSettingDefinition] = [definition]

    public static func parseSeed(_ text: String) -> UInt32? {
        let text = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard text.utf8.count == 6, text.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }) else { return nil }
        return UInt32(text, radix: 16)
    }

    /// MonetHelper.java:194–208. Intermediate M3 tones must be reconstructed from
    /// the palette's shade 600 (tone 40), not rounded to the nearest shade.
    public static let toneToShade: [Int: Int] = [100: 0, 99: 10, 95: 50, 90: 100, 80: 200, 70: 300, 60: 400, 50: 500, 40: 600, 30: 700, 20: 800, 10: 900, 0: 1000]
    public static let shadeToTone: [Int: Int] = Dictionary(uniqueKeysWithValues: toneToShade.map { ($0.value, $0.key) })

    public static let tonalPalettes: [String: AppearanceMonetPaletteID] = [
        "primary": .primary, "secondary": .secondary, "tertiary": .tertiary,
        "neutral": .neutral, "neutral_variant": .neutralVariant
    ]

    /// Original MonetHelper.java:210–280. n2, not n1, supplies M3 surfaces.
    public static func roleTone(_ role: String, dark: Bool) -> AppearanceMonetRoleTone? {
        if let palette = tonalPalettes[role], palette == .primary || palette == .secondary || palette == .tertiary {
            return AppearanceMonetRoleTone(palette, dark ? 80 : 40)
        }
        for (name, palette) in [("primary", AppearanceMonetPaletteID.primary), ("secondary", .secondary), ("tertiary", .tertiary)] {
            switch role {
            case "on_" + name: return AppearanceMonetRoleTone(palette, dark ? 20 : 100)
            case name + "_container": return AppearanceMonetRoleTone(palette, dark ? 30 : 90)
            case "on_" + name + "_container": return AppearanceMonetRoleTone(palette, dark ? 90 : 10)
            default: break
            }
        }
        switch role {
        case "inverse_primary": return AppearanceMonetRoleTone(.primary, dark ? 40 : 80)
        case "surface_tint": return AppearanceMonetRoleTone(.primary, dark ? 80 : 40)
        case "background", "surface": return AppearanceMonetRoleTone(.neutralVariant, dark ? 6 : 98)
        case "on_background", "on_surface": return AppearanceMonetRoleTone(.neutralVariant, dark ? 90 : 10)
        case "surface_variant": return AppearanceMonetRoleTone(.neutralVariant, dark ? 30 : 90)
        case "on_surface_variant": return AppearanceMonetRoleTone(.neutralVariant, dark ? 80 : 30)
        case "inverse_surface": return AppearanceMonetRoleTone(.neutralVariant, dark ? 90 : 20)
        case "inverse_on_surface": return AppearanceMonetRoleTone(.neutralVariant, dark ? 20 : 95)
        case "outline": return AppearanceMonetRoleTone(.neutralVariant, dark ? 60 : 50)
        case "outline_variant": return AppearanceMonetRoleTone(.neutralVariant, dark ? 30 : 80)
        case "scrim", "shadow": return AppearanceMonetRoleTone(.neutralVariant, 0)
        case "surface_bright": return AppearanceMonetRoleTone(.neutralVariant, dark ? 24 : 98)
        case "surface_dim": return AppearanceMonetRoleTone(.neutralVariant, dark ? 6 : 87)
        case "surface_container": return AppearanceMonetRoleTone(.neutralVariant, dark ? 12 : 94)
        case "surface_container_high": return AppearanceMonetRoleTone(.neutralVariant, dark ? 17 : 92)
        case "surface_container_highest": return AppearanceMonetRoleTone(.neutralVariant, dark ? 22 : 90)
        case "surface_container_low": return AppearanceMonetRoleTone(.neutralVariant, dark ? 10 : 96)
        case "surface_container_lowest": return AppearanceMonetRoleTone(.neutralVariant, dark ? 4 : 100)
        default: return nil
        }
    }

    /// Keep even the unusual on_*_fixed_dim aliases exactly as Original: tone 80.
    public static func fixedRoleTone(_ role: String) -> AppearanceMonetRoleTone? {
        for (name, palette) in [("primary", AppearanceMonetPaletteID.primary), ("secondary", .secondary), ("tertiary", .tertiary)] {
            switch role {
            case name + "_fixed": return AppearanceMonetRoleTone(palette, 90)
            case name + "_fixed_dim", "on_" + name + "_fixed_dim": return AppearanceMonetRoleTone(palette, 80)
            case "on_" + name + "_fixed": return AppearanceMonetRoleTone(palette, 10)
            case "on_" + name + "_fixed_variant": return AppearanceMonetRoleTone(palette, 30)
            default: break
            }
        }
        return nil
    }
}

/// The actual iOS surface-to-token mapping. Classic's Light/Dark source tokens
/// are the pinned exteraGram assets, NOT the absent Original *_gram assets.
/// Telemone's surface mapping and AMOLED's black planes are native adaptations.
/// Provenance and the exact Android-key crosswalk: docs/wave-2/monet-parity.md.
public struct AppearanceMonetTokens: Equatable, Sendable {
    public let background: String
    public let surface: String
    public let raisedSurface: String
    public let navigation: String
    public let primaryText: String
    public let secondaryText: String
    public let accent: String
    public let onAccent: String
    public let separator: String
    public let incomingBubble: String
    public let incomingText: String
    public let incomingLink: String
    public let outgoingBubble: String
    public let outgoingText: String
    public let outgoingLink: String
    public let serviceFill: String
    public let serviceText: String
    public let inputFill: String
    public let link: String

    public init(style: AppearanceMonetStyle, mode: AppearanceMonetMode) {
        let dark = mode.isDark
        if style == .telemone {
            let suffix = dark ? "_dark" : "_light"
            self.background = mode == .amoled ? "black" : "background" + suffix
            self.surface = "surface_container_low" + suffix
            self.raisedSurface = "surface_container_high" + suffix
            self.navigation = mode == .amoled ? "black" : "surface" + suffix
            self.primaryText = "on_surface" + suffix
            self.secondaryText = "on_surface_variant" + suffix
            self.accent = "primary" + suffix
            self.onAccent = "on_primary" + suffix
            self.separator = "outline_variant" + suffix
            self.incomingBubble = "surface_container_highest" + suffix
            self.incomingText = "on_surface" + suffix
            self.incomingLink = "primary" + suffix
            self.outgoingBubble = "primary_container" + suffix
            self.outgoingText = "on_primary_container" + suffix
            self.outgoingLink = "primary" + suffix
            self.serviceFill = "secondary_container" + suffix
            self.serviceText = "on_secondary_container" + suffix
            self.inputFill = "surface_container_highest" + suffix
            self.link = "primary" + suffix
        } else {
            self.background = mode == .amoled ? "black" : (dark ? "n1_900" : "mWhite")
            self.surface = dark ? "n1_900" : "mWhite"
            self.raisedSurface = dark ? "n2_800" : "a1_10"
            self.navigation = self.background
            self.primaryText = dark ? "n1_50" : "mBlack"
            self.secondaryText = dark ? "n1_300" : "n1_600"
            self.accent = dark ? "a1_200" : "a1_600"
            self.onAccent = dark ? "a1_800" : "a1_100"
            // Native separator treatment: a subtle tonal outline, rather than
            // upstream's high-contrast windowBackgroundWhiteGrayLine text token.
            self.separator = dark ? "n2_700" : "n1_100"
            self.incomingBubble = dark ? "n1_800" : "n1_50"
            self.incomingText = dark ? "n1_50" : "mBlack"
            self.incomingLink = dark ? "a3_100" : "a3_600"
            self.outgoingBubble = dark ? "a1_200" : "a1_600"
            self.outgoingText = dark ? "n1_900" : "n1_50"
            self.outgoingLink = dark ? "a3_600" : "a3_200"
            self.serviceFill = dark ? "n2_800" : "n2_100"
            self.serviceText = dark ? "n2_100" : "n2_800"
            self.inputFill = dark ? "n2_800" : "n1_50"
            self.link = dark ? "a3_200" : "a3_600"
        }
    }
}
