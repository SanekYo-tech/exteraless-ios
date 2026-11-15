import Foundation
import XCTest
@testable import ExteralessCore

final class AppearanceLayoutModePolicyTests: XCTestCase {
    func testRawSelectionPersistsThroughFallbackReopenAndReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = try ClientSettings(storageURL: url)
        let key = AppearanceLayoutModePolicy.settingKey
        try store.register(AppearanceLayoutModePolicy.definitions)
        XCTAssertEqual(store.integer(key), 0)
        for raw in [1, 2, 0, 1] {
            try store.set(.integer(Int64(raw)), for: key)
            let reopened = try ClientSettings(storageURL: url)
            try reopened.register(AppearanceLayoutModePolicy.definitions)
            XCTAssertEqual(reopened.integer(key), raw)
        }
        let narrow = AppearanceLayoutModePolicy.Viewport(width: 390, height: 844, top: 47, bottom: 34)
        XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: narrow, hasMaster: true).root, .single)
        XCTAssertEqual(store.integer(key), 1, "a viewport fallback must not rewrite the stored tablet choice")
        XCTAssertThrowsError(try store.set(.integer(3), for: key))
        XCTAssertThrowsError(try store.set(.bool(true), for: key))
        XCTAssertEqual(store.integer(key), 1)
        try store.reset(key)
        let reset = try ClientSettings(storageURL: url)
        try reset.register(AppearanceLayoutModePolicy.definitions)
        XCTAssertEqual(reset.integer(key), 0)
        XCTAssertFalse(reset.readSnapshot().storedKeys.contains(key))
    }

    func testPanesRemainAccessibleAcrossWindowAndKeyboardBounds() {
        for width in [310.0, 390, 620, 680, 744, 844, 1024, 1366] {
            for height in [320.0, 390, 700, 1024] {
                for keyboard in [0.0, 216, 500] {
                    let viewport = AppearanceLayoutModePolicy.Viewport(width: width, height: height, left: 44, top: 24, right: 21, bottom: 20, keyboardHeight: keyboard)
                    let result = AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true)
                    if case let .split(master) = result.root {
                        XCTAssertGreaterThanOrEqual(master - 44, 320)
                        XCTAssertGreaterThanOrEqual(width - master - 21, 360)
                        XCTAssertGreaterThanOrEqual(height - 24 - max(20, keyboard), 180)
                        XCTAssertTrue(master.isFinite)
                    }
                    if let frame = result.sheetFrame {
                        XCTAssertGreaterThanOrEqual(frame.width, 320)
                        XCTAssertGreaterThanOrEqual(frame.height, 320)
                        XCTAssertGreaterThanOrEqual(frame.x, 44)
                        XCTAssertGreaterThanOrEqual(frame.y, 24)
                        XCTAssertLessThanOrEqual(frame.x + frame.width, width - 21)
                        XCTAssertLessThanOrEqual(frame.y + frame.height, height - max(20, keyboard))
                    }
                    XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .phone, viewport: viewport, hasMaster: true).root, .single)
                    XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .automatic, viewport: viewport, hasMaster: true).root, .stock)
                }
            }
        }
    }

    func testActualDividerMasterRoleAndMinimizedStackConstrainSplitting() {
        var viewport = AppearanceLayoutModePolicy.Viewport(width: 1024, height: 744, left: 24, right: 24, dividerX: 490, dividerWidth: 18, allowsSheets: false)
        XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true).root, .split(masterWidth: 490))
        XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: false).root, .single)
        XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true, hasMinimizedStack: true).root, .single)
        XCTAssertFalse(AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true).largeModals)
        viewport.dividerX = 260
        XCTAssertEqual(AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true).root, .single, "do not move a real hinge to manufacture two usable columns")
    }

    func testSheetsFitAboveKeyboardAndOversizedPreferredContent() throws {
        var viewport = AppearanceLayoutModePolicy.Viewport(width: 1024, height: 1366, left: 20, top: 44, right: 32, bottom: 24, keyboardHeight: 500)
        let large = AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true, preferredSheetWidth: 10000, preferredSheetHeight: 10000)
        let frame = try XCTUnwrap(large.sheetFrame)
        XCTAssertTrue(large.largeModals)
        XCTAssertLessThanOrEqual(frame.x + frame.width, 1024 - 32)
        XCTAssertLessThanOrEqual(frame.y + frame.height, 1366 - 500)
        viewport.keyboardHeight = 1100
        let covered = AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: viewport, hasMaster: true)
        XCTAssertTrue(covered.largeModals, "keyboard does not regroup an already navigation-managed modal")
        XCTAssertNil(covered.sheetFrame, "insufficient visible space chooses a full-screen modal")
        for dimension in [Double.nan, .infinity, -1, 0] {
            let invalid = AppearanceLayoutModePolicy.resolve(mode: .tablet, viewport: .init(width: dimension, height: 744), hasMaster: true)
            XCTAssertEqual(invalid.root, .single)
            XCTAssertNil(invalid.sheetFrame)
        }
    }
}
