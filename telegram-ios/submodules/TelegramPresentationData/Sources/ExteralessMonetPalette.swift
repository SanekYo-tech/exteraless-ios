import ExteralessCore
import Foundation

/// Native HCT substitute for Android system_accent{1,2,3}/system_neutral{1,2}.
/// Android wallpaper/overlay APIs are not available on iOS. The input is the
/// user's selected/current native sRGB accent, never a purported wallpaper color.
///
/// Chromatic recipe: a1=max(48, seed chroma), a2=16, a3=24 at hue+60,
/// n1=4, n2=8 (legacy Material CorePalette). Neutral seeds retain their chroma
/// instead of acquiring a synthetic saturated primary. This is an iOS policy.
public struct ExteralessMonetPalette: Sendable {
    private let tones: [AppearanceMonetPaletteID: [Int: UInt32]]

    public init(seedRGB: UInt32) {
        let seed = Hct.fromInt(Int(seedRGB | 0xff000000))
        let neutral = seed.chroma < 8.0
        let specifications: [(AppearanceMonetPaletteID, Double, Double)] = [
            (.primary, seed.hue, neutral ? seed.chroma : max(48.0, seed.chroma)),
            (.secondary, seed.hue, neutral ? seed.chroma : 16.0),
            (.tertiary, neutral ? seed.hue : seed.hue + 60.0, neutral ? seed.chroma : 24.0),
            (.neutral, seed.hue, neutral ? min(4.0, seed.chroma) : 4.0),
            (.neutralVariant, seed.hue, neutral ? min(8.0, seed.chroma) : 8.0)
        ]
        var palettes: [AppearanceMonetPaletteID: [Int: UInt32]] = [:]
        for (id, hue, chroma) in specifications {
            var values: [Int: UInt32] = [:]
            for tone in AppearanceMonetPolicy.toneToShade.keys {
                values[tone] = UInt32(Hct.from(hue, chroma, Double(tone)).toInt())
            }
            palettes[id] = values
        }
        self.tones = palettes
    }

    /// Inject actual Android palette samples/reference vectors without replacing
    /// the resolver. Requires all five palettes and all thirteen system tones.
    public init?(systemTones: [AppearanceMonetPaletteID: [Int: UInt32]]) {
        guard AppearanceMonetPaletteID.allCases.allSatisfy({ palette in
            AppearanceMonetPolicy.toneToShade.keys.allSatisfy { systemTones[palette]?[$0] != nil }
        }) else { return nil }
        self.tones = systemTones
    }

    /// MonetHelper.resolveRoleTone: non-system tones are HCT projections of
    /// shade 600. Using the original seed hue/chroma here is subtly different.
    public func tone(_ palette: AppearanceMonetPaletteID, _ tone: Int) -> UInt32? {
        guard (0 ... 100).contains(tone) else { return nil }
        if AppearanceMonetPolicy.toneToShade[tone] != nil { return self.tones[palette]?[tone] }
        guard let key = self.tones[palette]?[40] else { return nil }
        return Self.setTone(key, Double(tone))
    }

    public var isAccentNeutral: Bool {
        guard let value = self.tones[.primary]?[50] else { return false }
        return Hct.fromInt(Int(value)).chroma < 8.0
    }

    /// Original M3/fixed roles, tonal aliases, named colors and s/l/a/t/c
    /// modifiers used by MonetHelper. Unknown/missing Android resource colors
    /// return nil, never a plausible black. Parsing is bounded and has no I/O.
    public func color(_ token: String, forLink: Bool = false) -> UInt32? {
        guard token.utf8.count <= 192 else { return nil }
        var raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var modifiers: [String: Int] = [:]
        if let bracket = raw.firstIndex(of: "(") {
            var params = String(raw[raw.index(after: bracket)...])
            if params.hasSuffix(")") { params.removeLast() }
            raw = String(raw[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            for param in params.split(separator: ",") {
                let pair = param.split(separator: "=", omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                if let value = Int(pair[1].trimmingCharacters(in: .whitespaces)) {
                    modifiers[pair[0].trimmingCharacters(in: .whitespaces)] = value
                }
            }
        }
        guard var value = self.resolve(raw, depth: 0) else { return nil }
        let tone = modifiers["t"].map { max(0, min(100, $0)) }
        let chroma = max(0, min(400, modifiers["c"] ?? 100))
        if tone != nil || chroma != 100 {
            let hct = Hct.fromInt(Int(value))
            value = UInt32(Hct.from(hct.hue, hct.chroma * Double(chroma) / 100.0, tone.map(Double.init) ?? hct.tone).toInt())
        }
        for (key, base) in [("s", UInt32(0xffffffff)), ("l", UInt32(0xff000000))] {
            let amount = modifiers[key] ?? 100
            // Malformed external tokens do not overflow integer/color channels.
            guard (0 ... 100).contains(amount) else { return nil }
            if amount != 100 { value = Self.blend(base, value, Float(amount) / 100.0) }
        }
        let alpha = modifiers["a"] ?? 100
        guard (0 ... 100).contains(alpha) else { return nil }
        if alpha != 100 {
            // Java's (int)(alpha * 2.55f), including its truncation, is intentional.
            value = (value & 0x00ffffff) | (UInt32(Float(alpha) * 2.55) << 24)
        }
        if forLink && Self.isAccentToken(raw) && self.isAccentNeutral {
            let hct = Hct.fromInt(Int(value))
            let colored = UInt32(Hct.from(250.0, 70.0, hct.tone).toInt())
            value = (colored & 0x00ffffff) | (value & 0xff000000)
        }
        return value
    }

    /// MonetHelper.harmonizeColor uses a1_600, not the accent's current tone.
    public func harmonize(_ value: UInt32) -> UInt32 {
        guard let accent = self.tones[.primary]?[40] else { return value }
        return UInt32(Blend.harmonize(Int(value), Int(accent)))
    }

    private func resolve(_ token: String, depth: Int) -> UInt32? {
        guard depth <= 8 else { return nil }
        if token.hasPrefix("monet_") { return self.resolve(String(token.dropFirst(6)), depth: depth + 1) }
        if let value = Self.constants[token] { return value }
        if let value = Self.harmonized[token] { return self.harmonize(value) }
        if token.hasSuffix("_light") || token.hasSuffix("_dark") {
            let dark = token.hasSuffix("_dark")
            let name = String(token.dropLast(dark ? 5 : 6))
            if let role = AppearanceMonetPolicy.roleTone(name, dark: dark) { return self.tone(role.palette, role.tone) }
        }
        if let role = AppearanceMonetPolicy.fixedRoleTone(token) { return self.tone(role.palette, role.tone) }
        guard let separator = token.lastIndex(of: "_") else { return nil }
        let prefix = String(token[..<separator])
        let suffix = token[token.index(after: separator)...]
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (48 ... 57).contains($0) }), let number = Int(suffix) else { return nil }
        if let palette = AppearanceMonetPaletteID(rawValue: prefix) {
            guard let tone = AppearanceMonetPolicy.shadeToTone[number] else { return nil }
            return self.tones[palette]?[tone]
        }
        if let palette = AppearanceMonetPolicy.tonalPalettes[prefix] {
            guard AppearanceMonetPolicy.toneToShade[number] != nil else { return nil }
            return self.tones[palette]?[number]
        }
        if let seed = Self.customSeeds[prefix], (0 ... 100).contains(number), let accent = self.tones[.primary]?[50] {
            let source = Hct.fromInt(Blend.harmonize(Int(seed), Int(accent)))
            let target = Hct.fromInt(Int(accent))
            let matched = Hct.from(source.hue, target.chroma * 0.9, source.tone)
            return UInt32(Hct.from(matched.hue, matched.chroma, Double(number)).toInt())
        }
        if let base = self.resolve(prefix, depth: depth + 1) { return Self.darken(base, percent: number) }
        return nil
    }

    private static func isAccentToken(_ raw: String) -> Bool {
        var token = raw
        if token.hasPrefix("monet_") { token = String(token.dropFirst(6)) }
        if token.hasPrefix("on_") { token = String(token.dropFirst(3)) }
        return ["a1_", "a2_", "a3_", "primary", "secondary", "tertiary", "inverse_primary", "surface_tint"].contains { token.hasPrefix($0) }
    }

    private static func setTone(_ value: UInt32, _ tone: Double) -> UInt32 {
        if tone < 0.0001 || tone > 99.9999 { return UInt32(ColorUtils.argbFromLstar(tone)) }
        let hct = Hct.fromInt(Int(value))
        return UInt32(Hct.from(hct.hue, hct.chroma, tone).toInt())
    }

    private static func blend(_ from: UInt32, _ to: UInt32, _ amount: Float) -> UInt32 {
        var value: UInt32 = 0
        for shift in [0, 8, 16, 24] {
            let a = Float((from >> shift) & 255), b = Float((to >> shift) & 255)
            value |= UInt32((1 - amount) * a + amount * b) << shift
        }
        return value
    }

    private static func darken(_ value: UInt32, percent: Int) -> UInt32 {
        let percent = max(1, min(100, percent))
        if percent == 100 { return value }
        let rgb = [16, 8, 0].map { Double((value >> $0) & 255) / 255.0 }
        let maximum = rgb.max()!, minimum = rgb.min()!
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2.0
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue = 0.0
        if delta != 0 {
            if maximum == rgb[0] { hue = ((rgb[1] - rgb[2]) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == rgb[1] { hue = (rgb[2] - rgb[0]) / delta + 2 }
            else { hue = (rgb[0] - rgb[1]) / delta + 4 }
        }
        if hue < 0 { hue += 6 }
        let adjusted = lightness * Double(percent) / 100.0
        let c = (1 - abs(2 * adjusted - 1)) * saturation
        let x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let m = adjusted - c / 2
        let channels: [Double]
        switch Int(hue) {
        case 0: channels = [c, x, 0]
        case 1: channels = [x, c, 0]
        case 2: channels = [0, c, x]
        case 3: channels = [0, x, c]
        case 4: channels = [x, 0, c]
        default: channels = [c, 0, x]
        }
        var result = value & 0xff000000
        for (channel, shift) in zip(channels, [16, 8, 0]) {
            result |= UInt32(max(0, min(255, ((channel + m) * 255).rounded()))) << shift
        }
        return result
    }

    public static func contrast(_ foreground: UInt32, _ background: UInt32) -> Double {
        let a = ColorUtils.xyzFromArgb(Int(foreground))[1] / 100.0
        let b = ColorUtils.xyzFromArgb(Int(background))[1] / 100.0
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Native text adaptation after token resolution: retain hue/chroma and move
    /// only tone when an upstream color pair misses 4.5:1 (e.g. Classic links).
    /// This correction is not claimed as an Android asset color.
    public static func readable(_ foreground: UInt32, on background: UInt32) -> UInt32 {
        if self.contrast(foreground, background) >= 4.5 { return foreground }
        let source = Hct.fromInt(Int(foreground))
        let end = self.contrast(0xff000000, background) > self.contrast(0xffffffff, background) ? 0.0 : 100.0
        var lower = 0.0, upper = 1.0
        var best = UInt32(Hct.from(source.hue, source.chroma, end).toInt())
        for _ in 0 ..< 12 {
            let fraction = (lower + upper) / 2
            let candidate = UInt32(Hct.from(source.hue, source.chroma, source.tone + (end - source.tone) * fraction).toInt())
            if self.contrast(candidate, background) >= 4.5 { best = candidate; upper = fraction }
            else { lower = fraction }
        }
        return best
    }

    private static let constants: [String: UInt32] = [
        "white": 0xffffffff, "black": 0xff000000, "transparent": 0x00000000,
        "mWhite": 0xffffffff, "mBlack": 0xff000000,
        "error_light": 0xffb3261e, "on_error_light": 0xffffffff,
        "error_container_light": 0xfff9dedc, "on_error_container_light": 0xff410e0b,
        "error_dark": 0xfff2b8b5, "on_error_dark": 0xff601410,
        "error_container_dark": 0xff8c1d18, "on_error_container_dark": 0xfff9dedc
    ]
    private static let harmonized: [String: UInt32] = [
        "monetYellow": 0xffffb74d, "monetGreen": 0xff4caf50,
        "monetCodeKeyword": 0xffe05356, "monetCodeOperator": 0xff4dbbff,
        "monetCodeConstant": 0xff7f79f3, "monetCodeString": 0xff37c123,
        "monetCodeNumber": 0xff327fe5, "monetCodeFunction": 0xfff28c39,
        "mRed200": 0xffef9a9a, "mRed500": 0xfff44336, "mRed800": 0xffc62828,
        "mGreen200": 0xffa5d6a7, "mGreen500": 0xff4caf50, "mGreen800": 0xff2e7d32
    ]
    private static let customSeeds: [String: UInt32] = [
        "blue": 0xff0000ff, "red": 0xffff0000, "green": 0xff00ff00,
        "orange": 0xffffaa00, "violet": 0xffeb00ff, "pink": 0xffff32ac, "cyan": 0xff14aaac
    ]
}
