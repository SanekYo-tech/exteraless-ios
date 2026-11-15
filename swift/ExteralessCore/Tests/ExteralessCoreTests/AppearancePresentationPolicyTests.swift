import Foundation
import XCTest
@testable import ExteralessCore

final class AppearancePresentationPolicyTests: XCTestCase {
    func testSenderAvatarMatchesActualSenderSpanEligibility() {
        XCTAssertTrue(AppearancePresentationPolicy.showsSenderAvatar(enabled: true, hasName: true, hasMessage: true, isSelf: false, isDraft: false))
        for flags in [(false, true, true, false, false), (true, false, true, false, false), (true, true, false, false, false), (true, true, true, true, false), (true, true, true, false, true)] {
            XCTAssertFalse(AppearancePresentationPolicy.showsSenderAvatar(enabled: flags.0, hasName: flags.1, hasMessage: flags.2, isSelf: flags.3, isDraft: flags.4))
        }
    }

    func testTitleLaneKeepsActionsOutOfTheTitleHitArea() {
        let lane = AppearancePresentationPolicy.titleLane(width: 390, leftButtons: 52, rightButtons: 176)
        XCTAssertEqual(lane.origin, 58)
        XCTAssertEqual(lane.width, 150)
        XCTAssertLessThanOrEqual(lane.origin + lane.width, 390 - 176)
        XCTAssertEqual(AppearancePresentationPolicy.titleLane(width: 100, leftButtons: 80, rightButtons: 80).width, 0)
        XCTAssertTrue(AppearancePresentationPolicy.titleLane(width: 300, leftButtons: .nan, rightButtons: .infinity).width.isFinite)
    }

    func testComposeShapeAndElasticResetUseOriginalRatios() {
        XCTAssertEqual(AppearancePresentationPolicy.composeRadius(side: 56, square: true), 16)
        XCTAssertEqual(AppearancePresentationPolicy.composeRadius(side: 56, square: false), 28)
        XCTAssertEqual(AppearancePresentationPolicy.composeRadius(side: 44, square: true), 13)
        XCTAssertEqual(AppearancePresentationPolicy.elasticAvatarScale(stock: 1.4, enabled: false), 1)
        XCTAssertEqual(AppearancePresentationPolicy.elasticAvatarScale(stock: 0.4, enabled: false), 0.4)
        XCTAssertEqual(AppearancePresentationPolicy.elasticAvatarScale(stock: 1.4, enabled: true), 1.4)
    }

    func testNativeSearchAndPersistentTabHidingDoNotOverwriteEachOther() {
        var policy = AppearanceTabVisibilityPolicy()
        policy.nativeRequest = true
        XCTAssertTrue(policy.isHidden)
        policy.persistentRequest = true
        policy.nativeRequest = false
        XCTAssertTrue(policy.isHidden)
        policy.persistentRequest = false
        XCTAssertFalse(policy.isHidden)
        policy.nativeRequest = true
        policy.persistentRequest = false
        XCTAssertTrue(policy.isHidden)
        policy.nativeRequest = false
        XCTAssertFalse(policy.isHidden)
    }

    func testMaterialIndicatorAndStylePrecedence() {
        let chip = AppearancePresentationPolicy.materialTabIndicator(width: 80, height: 64, showsTitle: true)
        XCTAssertEqual(chip.x, 12)
        XCTAssertEqual(chip.y, 6)
        XCTAssertEqual(chip.width, 56)
        XCTAssertEqual(chip.height, 32)
        XCTAssertEqual(AppearancePresentationPolicy.materialTabIndicator(width: 40, height: 64, showsTitle: false).y, 16)
        XCTAssertEqual(AppearancePresentationPolicy.materialTabIndicator(width: 4, height: 64, showsTitle: true).width, 0)
        XCTAssertEqual(AppearancePresentationPolicy.navigationVariant(material: true, wide: true), .material)
        XCTAssertEqual(AppearancePresentationPolicy.navigationVariant(material: false, wide: true), .wide)
        XCTAssertEqual(AppearancePresentationPolicy.navigationVariant(material: false, wide: false), .floating)
        XCTAssertEqual(AppearancePresentationPolicy.activityBackend(material: true, forceCustom: true), .material)
        XCTAssertEqual(AppearancePresentationPolicy.activityBackend(material: false, forceCustom: true), .legacyCustom)
        XCTAssertEqual(AppearancePresentationPolicy.activityBackend(material: false, forceCustom: false), .system)
    }

    func testParallaxPreservesStockAndCannotExposeAGap() {
        XCTAssertEqual(AppearancePresentationPolicy.navigationParallax(percent: 100), 0.3, accuracy: 0.00001)
        for percent in [-10, 0, 50, 100, 200, 300] {
            let factor = AppearancePresentationPolicy.navigationParallax(percent: percent)
            for step in 0...10 {
                let progress = Double(step) / 10
                let bottomRight = 390 + (progress - 1) * 390 * factor
                XCTAssertGreaterThanOrEqual(bottomRight, progress * 390 - 0.00001)
            }
        }
    }

    func testSnowIsBoundedDeterministicAndHonorsSystemConstraints() {
        let snow = AppearanceSnowPolicy.particles(width: 4000, height: 4000, maximum: 1000, reducedMotion: false, lowPower: false)
        XCTAssertEqual(snow.count, 32)
        XCTAssertEqual(snow, AppearanceSnowPolicy.particles(width: 4000, height: 4000, maximum: 1000, reducedMotion: false, lowPower: false))
        XCTAssertTrue(snow.allSatisfy { $0.duration >= 6 && $0.duration <= 14 && $0.phase >= 0 && $0.phase < 1 && $0.xFraction >= 0 && $0.xFraction < 1 })
        XCTAssertLessThanOrEqual(AppearanceSnowPolicy.particles(width: 390, height: 44, maximum: 8, reducedMotion: false, lowPower: false).count, 8)
        XCTAssertTrue(AppearanceSnowPolicy.particles(width: 390, height: 844, maximum: 32, reducedMotion: true, lowPower: false).isEmpty)
        XCTAssertTrue(AppearanceSnowPolicy.particles(width: 390, height: 844, maximum: 32, reducedMotion: false, lowPower: true).isEmpty)
        XCTAssertTrue(AppearanceSnowPolicy.particles(width: .infinity, height: 844, maximum: 32, reducedMotion: false, lowPower: false).isEmpty)
    }

    func testDrawerCancelFlingAndNarrowWindowBounds() {
        for width in [0.0, 200, 320, 390, 1024] { XCTAssertLessThanOrEqual(AppearanceDrawerPolicy.width(available: width), width) }
        XCTAssertEqual(AppearanceDrawerPolicy.progress(translation: 100, width: 0), 0)
        XCTAssertEqual(AppearanceDrawerPolicy.progress(translation: 600, width: 300), 1)
        XCTAssertFalse(AppearanceDrawerPolicy.shouldDismiss(progress: 0.9, velocity: 1000, cancelled: true))
        XCTAssertTrue(AppearanceDrawerPolicy.shouldDismiss(progress: 0.1, velocity: 650, cancelled: false))
        XCTAssertFalse(AppearanceDrawerPolicy.shouldDismiss(progress: 0.1, velocity: 0, cancelled: false))
        XCTAssertEqual(AppearanceDrawerPolicy.backdropScale(progress: 0, immersive: true), 0.96)
        XCTAssertEqual(AppearanceDrawerPolicy.backdropScale(progress: 1, immersive: true), 1)
    }

    func testMenuPreservesRoutesBeforeTheirProviderRegisters() {
        let before = AppearanceMenuLayout(rawValue: "14,105,109;106,8", availableIds: [14, 8], preserveUnavailable: true)
        XCTAssertEqual(before.visible, [14, 105, 109])
        let after = AppearanceMenuLayout(rawValue: before.rawValue, availableIds: [14, 8, 105, 109, 106], preserveUnavailable: true)
        XCTAssertEqual(after.visible, before.visible)
        XCTAssertEqual(after.hidden, before.hidden)
        let hiddenTabs = AppearanceMenuLayout(rawValue: ";8", availableIds: [8], settingsInTabs: false, preserveUnavailable: true)
        XCTAssertTrue(hiddenTabs.visible.contains(8))
        XCTAssertFalse(hiddenTabs.hidden.contains(8))
        let extensionRoute = AppearanceMenuLayout(rawValue: "14,9001;8", availableIds: [14, 8, 9001], preserveUnavailable: true)
        let unregistered = AppearanceMenuLayout(rawValue: extensionRoute.rawValue, availableIds: [14, 8], preserveUnavailable: true)
        XCTAssertEqual(unregistered.visible, extensionRoute.visible)
        XCTAssertEqual(unregistered.hidden, extensionRoute.hidden)
    }
}
