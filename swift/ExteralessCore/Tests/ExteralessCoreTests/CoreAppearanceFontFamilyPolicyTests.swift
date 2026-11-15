import Foundation
import XCTest
@testable import ExteralessCore

final class CoreAppearanceFontFamilyPolicyTests: XCTestCase {
    func testFamilyChoicePersistsReloadsAndResetsWithoutChangingOtherTextPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("font-family-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = try ClientSettings(storageURL: url)
        let key = CoreAppearanceFontFamilyPolicy.key
        XCTAssertTrue(CoreAppearanceFontFamilyPolicy.useSystemFonts(in: store), "pre-registration uses the Android true default")
        let weightDefinition = try XCTUnwrap(AppearanceAdditionalFeatures.definitions.first { $0.key == "appearance.forceFontWeightFallback" })
        try store.register(CoreAppearanceFontFamilyPolicy.definitions + [weightDefinition])
        XCTAssertTrue(CoreAppearanceFontFamilyPolicy.useSystemFonts(in: store))
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(key))
        try store.set(.bool(true), for: weightDefinition.key)
        try store.setPublic(.bool(false), for: key)

        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(CoreAppearanceFontFamilyPolicy.definitions + [weightDefinition])
        XCTAssertFalse(CoreAppearanceFontFamilyPolicy.useSystemFonts(in: reopened))
        XCTAssertTrue(reopened.bool(weightDefinition.key))
        XCTAssertEqual(reopened.value(key), .bool(false))
        XCTAssertThrowsError(try reopened.setPublic(.integer(0), for: key))
        XCTAssertFalse(CoreAppearanceFontFamilyPolicy.useSystemFonts(in: reopened))

        try reopened.reset(key)
        try store.reload()
        XCTAssertTrue(CoreAppearanceFontFamilyPolicy.useSystemFonts(in: store))
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(key))
        XCTAssertTrue(store.bool(weightDefinition.key))
        XCTAssertNil(store.value("useSystemFont"), "native text-size preference is not a family alias")
        let exported = try ClientSettingValue.decodeJSON(store.exportJSON())
        guard case let .object(values) = exported else { return XCTFail("settings export is not an object") }
        XCTAssertEqual(values[key], .bool(true))
    }

    func testNativeRolesAndCanonicalSDKSymbol() throws {
        let definition = try XCTUnwrap(CoreAppearanceFontFamilyPolicy.definitions.first)
        XCTAssertEqual(definition.defaultValue, .bool(true))
        XCTAssertTrue(definition.androidSymbols.contains("NekoConfig.typeface"))
        XCTAssertEqual(CoreAppearanceFontFamilyPolicy.selection(useSystemFonts: true, role: .sansSerif), .platformSystem)
        XCTAssertEqual(CoreAppearanceFontFamilyPolicy.selection(useSystemFonts: false, role: .sansSerif), .bundledRoboto)
        let roles: [CoreAppearanceFontFamilyPolicy.Role] = [.serif, .monospace, .rounded, .camera]
        for role in roles {
            for system in [true, false] {
                XCTAssertEqual(CoreAppearanceFontFamilyPolicy.selection(useSystemFonts: system, role: role), .nativeRole)
            }
        }
    }
}
