import Foundation
import XCTest
@testable import ExteralessCore

final class AppearanceMonetPolicyTests: XCTestCase {
    func testOriginalSelectorAndAllThreeModeMappings() throws {
        XCTAssertEqual(AppearanceMonetStyle(setting: 0), .telemone)
        XCTAssertEqual(AppearanceMonetStyle(setting: 1).androidAssetSuffix, "_gram")
        XCTAssertEqual(AppearanceMonetStyle(setting: -1).androidAssetSuffix, "")
        XCTAssertEqual(AppearanceMonetStyle(setting: 99), .telemone)
        XCTAssertEqual(AppearanceMonetPolicy.definitions.count, 1, "style storage must not silently opt users into Monet")
        XCTAssertEqual(AppearanceMonetPolicy.definitions[0].defaultValue, .integer(0))

        // Independently transcribed key receipts, rather than regenerating the
        // expectations by the production mapper.
        let expected: [(AppearanceMonetStyle, AppearanceMonetMode, String, String, String)] = [
            (.telemone, .light, "background_light", "surface_container_highest_light", "primary_container_light"),
            (.telemone, .dark, "background_dark", "surface_container_highest_dark", "primary_container_dark"),
            (.telemone, .amoled, "black", "surface_container_highest_dark", "primary_container_dark"),
            (.classic, .light, "mWhite", "n1_50", "a1_600"),
            (.classic, .dark, "n1_900", "n1_800", "a1_200"),
            (.classic, .amoled, "black", "n1_800", "a1_200")
        ]
        for (style, mode, background, incoming, outgoing) in expected {
            let tokens = AppearanceMonetTokens(style: style, mode: mode)
            XCTAssertEqual(tokens.background, background)
            XCTAssertEqual(tokens.incomingBubble, incoming)
            XCTAssertEqual(tokens.outgoingBubble, outgoing)
            if mode == .amoled { XCTAssertEqual(tokens.navigation, "black") }
        }
    }

    func testOriginalRoleAndShadeVectorsDoNotRoundIntermediateTones() {
        XCTAssertEqual(AppearanceMonetPolicy.toneToShade.count, 13)
        XCTAssertEqual(AppearanceMonetPolicy.toneToShade[99], 10)
        XCTAssertEqual(AppearanceMonetPolicy.shadeToTone[600], 40)
        XCTAssertNil(AppearanceMonetPolicy.toneToShade[98])
        XCTAssertEqual(AppearanceMonetPolicy.roleTone("surface", dark: false), AppearanceMonetRoleTone(.neutralVariant, 98))
        XCTAssertEqual(AppearanceMonetPolicy.roleTone("surface", dark: true), AppearanceMonetRoleTone(.neutralVariant, 6))
        XCTAssertEqual(AppearanceMonetPolicy.roleTone("surface_container_high", dark: true), AppearanceMonetRoleTone(.neutralVariant, 17))
        XCTAssertEqual(AppearanceMonetPolicy.roleTone("on_tertiary_container", dark: false), AppearanceMonetRoleTone(.tertiary, 10))
        XCTAssertEqual(AppearanceMonetPolicy.fixedRoleTone("on_primary_fixed_dim"), AppearanceMonetRoleTone(.primary, 80))
        XCTAssertNil(AppearanceMonetPolicy.roleTone("unknown_role", dark: false))
        XCTAssertNil(AppearanceMonetPolicy.shadeToTone[50_000])
    }

    func testNativeThemeDescriptorRoundTripAndOrdinaryThemeAdmission() throws {
        for mode in AppearanceMonetMode.allCases {
            for style in AppearanceMonetStyle.allCases {
                let descriptor = AppearanceMonetDescriptor(mode: mode, seedRGB: 0xff007aff, renderedStyle: style, nativeOutgoingOverride: true)
                XCTAssertEqual(try XCTUnwrap(AppearanceMonetDescriptor(encodedThemeName: descriptor.encodedThemeName)), descriptor)
                XCTAssertEqual(descriptor.seedRGB, 0x007aff)
            }
        }
        for name in ["Monet Light", "Monet Dark", "Day", "Monet Light [exl-monet-v2|light|007AFF|0|0]", "Monet Light [exl-monet-v1|dark|007AFF|0|0]", "Monet Light [exl-monet-v1|light|007AFF|2|0]", "Monet Light [exl-monet-v1|light|007AFF|0|8]"] {
            XCTAssertNil(AppearanceMonetDescriptor(encodedThemeName: name), name)
        }
        XCTAssertEqual(AppearanceMonetPolicy.parseSeed("#Ffa010"), 0xffa010)
        for seed in ["", "abc", "0xffa010", "FFFFFFFF", "-01000", "12 456", "12345g"] {
            XCTAssertNil(AppearanceMonetPolicy.parseSeed(seed))
        }
    }

    func testStyleIsRegisteredReloadedAndResetWithoutAnEnabledThemePreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let first = try ClientSettings(storageURL: url)
        try first.register(AppearanceMonetPolicy.definitions)
        try first.set(.integer(1), for: AppearanceMonetPolicy.settingKey)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(AppearanceMonetPolicy.definitions)
        XCTAssertEqual(reopened.integer(AppearanceMonetPolicy.settingKey), 1)
        XCTAssertThrowsError(try reopened.set(.integer(2), for: AppearanceMonetPolicy.settingKey))
        try reopened.reset(AppearanceMonetPolicy.settingKey)
        try first.reload()
        XCTAssertEqual(first.integer(AppearanceMonetPolicy.settingKey), 0)
        XCTAssertFalse(first.readSnapshot().storedKeys.contains(AppearanceMonetPolicy.settingKey))
        XCTAssertNil(first.value("appearance.monetEnabled"))
    }
}
