import XCTest
@testable import ExteralessCore

final class AppearanceOwnerCompletionTests: XCTestCase {
    func testExplicitNativeChoicesSurviveReopenAndResetToOriginalEffectiveDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-controls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = try ClientSettings(storageURL: url)
        try store.register(AppearanceFeatures.definitions)
        let choices: [String: ClientSettingValue] = [
            "appearance.switchStyle": .integer(0),
            "appearance.sliderStyle": .integer(0),
            "appearance.backAnimationStyle": .integer(3),
            "appearance.centerActionBarTitleType": .integer(3),
            "appearance.forceFontWeightFallback": .bool(true),
            "appearance.hideAllTab": .bool(true),
            "appearance.useSystemIconShape": .bool(true),
            "appearance.springAnimationCrossfade": .bool(false)
        ]
        for (key, value) in choices { try store.set(value, for: key) }
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(AppearanceFeatures.definitions)
        for (key, value) in choices {
            XCTAssertEqual(reopened.value(key), value, key)
            XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(key), key)
            try reopened.reset(key)
        }
        try store.reload()
        XCTAssertEqual(store.integer("appearance.switchStyle"), 2, "filled Extera is slot 2, not M3 slot 3")
        XCTAssertEqual(store.integer("appearance.sliderStyle"), 2)
        XCTAssertEqual(store.integer("appearance.backAnimationStyle"), 1, "fresh effective motion default, not raw Android declaration 0")
        XCTAssertEqual(store.integer("appearance.centerActionBarTitleType"), 1)
        XCTAssertFalse(store.bool("appearance.forceFontWeightFallback"))
        XCTAssertFalse(store.bool("appearance.hideAllTab"))
        XCTAssertFalse(store.bool("appearance.useSystemIconShape"))
        XCTAssertTrue(store.bool("appearance.springAnimationCrossfade"))
        XCTAssertTrue(store.readSnapshot().storedKeys.isDisjoint(with: choices.keys))
    }

    func testHeaderScopePreservesTheOriginalZeroAllSettingsChatsValues() {
        for scope in 0...3 {
            XCTAssertFalse(AppearanceControlPolicy.centersHeader(enabled: false, scope: scope, isSettings: false))
            XCTAssertFalse(AppearanceControlPolicy.centersHeader(enabled: false, scope: scope, isSettings: true))
        }
        XCTAssertFalse(AppearanceControlPolicy.centersHeader(enabled: true, scope: 0, isSettings: true))
        XCTAssertTrue(AppearanceControlPolicy.centersHeader(enabled: true, scope: 1, isSettings: false))
        XCTAssertTrue(AppearanceControlPolicy.centersHeader(enabled: true, scope: 2, isSettings: true))
        XCTAssertFalse(AppearanceControlPolicy.centersHeader(enabled: true, scope: 2, isSettings: false))
        XCTAssertTrue(AppearanceControlPolicy.centersHeader(enabled: true, scope: 3, isSettings: false))
        XCTAssertFalse(AppearanceControlPolicy.centersHeader(enabled: true, scope: 3, isSettings: true))
    }

    func testSwitchGeometryRetainsDistinctFilledAndMaterialSlots() {
        let off = AppearanceControlPolicy.switchMetrics(style: 2, progress: 0, pressed: false)
        let on = AppearanceControlPolicy.switchMetrics(style: 2, progress: 1, pressed: false)
        XCTAssertEqual(off.trackHeight, 26)
        XCTAssertEqual(off.thumbHeight, 14)
        XCTAssertEqual(on.thumbHeight, 18)
        XCTAssertEqual(off.outlineWidth, 0)
        XCTAssertGreaterThan(AppearanceControlPolicy.switchMetrics(style: 2, progress: 0.5, pressed: false).thumbWidth, on.thumbWidth)
        for style in [2, 3] {
            for step in 0...20 {
                for pressed in [false, true] {
                    let value = AppearanceControlPolicy.switchMetrics(style: style, progress: Double(step) / 20, pressed: pressed)
                    XCTAssertGreaterThanOrEqual(value.centerX - value.thumbWidth / 2, 0)
                    XCTAssertLessThanOrEqual(value.centerX + value.thumbWidth / 2, value.width)
                    XCTAssertLessThanOrEqual(value.thumbHeight, value.trackHeight)
                }
            }
        }
        XCTAssertEqual(AppearanceControlPolicy.switchMetrics(style: 3, progress: 0, pressed: false).outlineWidth, 2)
        XCTAssertEqual(AppearanceControlPolicy.switchMetrics(style: 3, progress: 1, pressed: true).thumbHeight, 28)
    }

    func testMaterialSliderDoesNotOverrideSpecializedNativeGeometry() {
        XCTAssertTrue(AppearanceControlPolicy.usesMaterialSlider(style: 2, explicitGeometry: false, lowerBound: 0, startValue: 0, minimumValue: nil))
        XCTAssertFalse(AppearanceControlPolicy.usesMaterialSlider(style: 0, explicitGeometry: false, lowerBound: 0, startValue: 0, minimumValue: nil))
        XCTAssertFalse(AppearanceControlPolicy.usesMaterialSlider(style: 2, explicitGeometry: true, lowerBound: 0, startValue: 0, minimumValue: nil))
        XCTAssertFalse(AppearanceControlPolicy.usesMaterialSlider(style: 2, explicitGeometry: false, lowerBound: -1, startValue: 0, minimumValue: nil))
        XCTAssertFalse(AppearanceControlPolicy.usesMaterialSlider(style: 2, explicitGeometry: false, lowerBound: 0, startValue: 0, minimumValue: 0.5))
    }

    func testAllChatsRecoveryAndNavigationReset() {
        XCTAssertTrue(AppearanceControlPolicy.hidesAllChatsChip(enabled: true, selectedIsAll: false, isReordering: false, isTransitioning: false, hasCustomFolders: true))
        XCTAssertFalse(AppearanceControlPolicy.hidesAllChatsChip(enabled: true, selectedIsAll: true, isReordering: false, isTransitioning: false, hasCustomFolders: true))
        XCTAssertFalse(AppearanceControlPolicy.hidesAllChatsChip(enabled: true, selectedIsAll: false, isReordering: true, isTransitioning: false, hasCustomFolders: true))
        XCTAssertFalse(AppearanceControlPolicy.hidesAllChatsChip(enabled: true, selectedIsAll: false, isReordering: false, isTransitioning: true, hasCustomFolders: true))
        XCTAssertFalse(AppearanceControlPolicy.hidesAllChatsChip(enabled: true, selectedIsAll: false, isReordering: false, isTransitioning: false, hasCustomFolders: false))
        XCTAssertFalse(AppearanceControlPolicy.hidesAllChatsChip(enabled: false, selectedIsAll: false, isReordering: false, isTransitioning: false, hasCustomFolders: true))
        let stock = AppearanceMotionPolicy.spring(style: 1, stockResponse: 0.3, stockDampingRatio: 0.85)
        XCTAssertEqual(stock.response, 0.3)
        XCTAssertEqual(stock.dampingRatio, 0.85)
        XCTAssertEqual(AppearanceMotionPolicy.spring(style: 0, stockResponse: 0.3, stockDampingRatio: 0.85).response, 0.22)
        XCTAssertEqual(AppearanceMotionPolicy.spring(style: 2, stockResponse: 0.3, stockDampingRatio: 0.85).dampingRatio, 1)
        XCTAssertEqual(AppearanceMotionPolicy.headerContentAlpha(disappearance: 0.25, crossfade: true), 0.75)
        XCTAssertEqual(AppearanceMotionPolicy.headerContentAlpha(disappearance: 0.25, crossfade: false), 1)
        XCTAssertEqual(AppearanceMotionPolicy.headerContentAlpha(disappearance: 0.75, crossfade: false), 0)
    }
}
