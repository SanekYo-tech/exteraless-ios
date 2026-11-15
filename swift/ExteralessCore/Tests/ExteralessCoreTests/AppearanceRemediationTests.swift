import Foundation
import XCTest
@testable import ExteralessCore

final class AppearanceRemediationTests: XCTestCase {
    private final class Context {}
    private final class MountedRoot {
        let context: Context
        var hidden = false
        init(_ context: Context) { self.context = context }
    }

    func testReadyReappliesAfterInitialCallbacksAndRejectsReplacedAccounts() {
        for callbacksBeforeMount in [true, false] {
            let a = Context()
            let b = Context()
            var mounted: MountedRoot?
            let application = AppearanceRootApplication<Context> { context in
                guard mounted?.context === context else { return }
                mounted?.hidden = true
            }
            application.attach(a)
            if callbacksBeforeMount {
                for _ in 0..<4 { application.applyIfCurrent(a) }
            }
            mounted = MountedRoot(a)
            // The real domain calls this again from accountPresentationDidBecomeReady.
            application.applyIfCurrent(a)
            XCTAssertTrue(mounted?.hidden == true)
            if !callbacksBeforeMount {
                for _ in 0..<4 { application.applyIfCurrent(a) }
                XCTAssertTrue(mounted?.hidden == true)
            }

            application.attach(b)
            XCTAssertFalse(application.applyIfCurrent(a))
            mounted = MountedRoot(b)
            XCTAssertFalse(application.applyIfCurrent(a), "late old ready callback")
            XCTAssertFalse(mounted?.hidden == true)
            application.applyIfCurrent(b)
            XCTAssertTrue(mounted?.hidden == true)
            application.clear()
            mounted?.hidden = false
            XCTAssertFalse(application.applyIfCurrent(b))
            XCTAssertFalse(mounted?.hidden == true)
        }
    }

    func testExcludeMutedFreshFallbackExplicitAllReopenAndReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-default-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = try ClientSettings(storageURL: url)
        let key = "appearance.ignoreUnreadCount"
        func displayedCount(_ store: ClientSettings) -> Int {
            AppearanceFolderPolicy.unreadCount(all: 30, unmuted: 7,
                mode: store.integer(key, default: AppearanceFolderPolicy.defaultUnreadMode))
        }
        XCTAssertEqual(displayedCount(store), 7, "pre-registration native fallback")
        try store.register(AppearanceFeatures.definitions)
        XCTAssertEqual(store.integer(key), 1)
        XCTAssertEqual(displayedCount(store), 7)
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(key))

        try store.set(.integer(0), for: key)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(AppearanceFeatures.definitions)
        XCTAssertEqual(reopened.integer(key), 0, "All is an explicit valid choice")
        XCTAssertEqual(displayedCount(reopened), 30)
        XCTAssertTrue(reopened.readSnapshot().storedKeys.contains(key))
        try reopened.reset(key)
        XCTAssertEqual(reopened.integer(key), 1)
        XCTAssertEqual(displayedCount(reopened), 7)
        XCTAssertFalse(reopened.readSnapshot().storedKeys.contains(key))
        try store.reload()
        XCTAssertEqual(displayedCount(store), 7, "reset survives reopening/reload")
    }

    func testExpandedProfileElasticityCoversActualViewportInBothOrientations() {
        for size in [(390.0, 488.0), (844.0, 390.0), (1024.0, 1280.0)] {
            for pull in [0.0, 50.0, 100.0] {
                let off = AppearanceProfileAvatarGeometry(width: size.0, height: size.1, contentOffset: -pull, navigationHeight: 88, elastic: false)
                XCTAssertEqual(off.scale, 1)
                XCTAssertEqual(off.centerY, size.0 / 2)
                XCTAssertEqual(off.clippingOffsetY, 0)
                XCTAssertEqual(off.photoMinY, 0, accuracy: 0.000001)
                XCTAssertEqual(off.headerHeight, size.1)
                XCTAssertEqual(off.photoMaxY, off.headerHeight, accuracy: 0.000001)

                let on = AppearanceProfileAvatarGeometry(width: size.0, height: size.1, contentOffset: -pull, navigationHeight: 88, elastic: true)
                // The actual parent-chain projection, not a scale-only assertion.
                let top = on.clippingFrameY + on.clippingContentOffsetY + on.centerY - size.0 * on.scale / 2
                let bottom = top + size.1 * on.scale
                XCTAssertLessThanOrEqual(top, 0.000001)
                XCTAssertGreaterThanOrEqual(bottom, on.headerHeight - 0.000001)
                XCTAssertEqual(on.headerHeight, size.1 + pull)
                XCTAssertEqual(on.photoMinY, top, accuracy: 0.000001)
                XCTAssertEqual(on.photoMaxY, bottom, accuracy: 0.000001)
                XCTAssertLessThanOrEqual(on.clippingFrameY, 0)
                XCTAssertGreaterThanOrEqual(on.clippingFrameY + on.clippingHeight, on.headerHeight)
                XCTAssertLessThanOrEqual(off.clippingFrameY, 0)
                XCTAssertGreaterThanOrEqual(off.clippingFrameY + off.clippingHeight, off.headerHeight)
            }
        }
    }

    func testProfileReturnToggleAndResetPreserveRestAndPositiveScroll() {
        let stock = AppearanceProfileAvatarGeometry(width: 390, height: 488, contentOffset: -100, navigationHeight: 88, elastic: true)
        XCTAssertEqual(stock.scale, 1 + 100.0 / 390.0, accuracy: 0.000001)
        XCTAssertEqual(stock.photoMinY, -25.128205128205128, accuracy: 0.000001)
        XCTAssertEqual(stock.photoMaxY, 588, accuracy: 0.000001)
        let disabled = AppearanceProfileAvatarGeometry(width: 390, height: 488, contentOffset: -100, navigationHeight: 88, elastic: false)
        XCTAssertEqual(disabled.photoMinY, 0)
        XCTAssertEqual(disabled.photoMaxY, 488)
        for offset in [0.0, 50.0, 100.0] {
            XCTAssertEqual(AppearanceProfileAvatarGeometry(width: 390, height: 488, contentOffset: offset, navigationHeight: 88, elastic: false),
                           AppearanceProfileAvatarGeometry(width: 390, height: 488, contentOffset: offset, navigationHeight: 88, elastic: true))
        }
        XCTAssertEqual(stock, AppearanceProfileAvatarGeometry(width: 390, height: 488, contentOffset: -100, navigationHeight: 88, elastic: true))
    }
}
