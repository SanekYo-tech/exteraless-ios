import Foundation
import XCTest

/// Compile with ExteralessPillSettingsAction.swift. No Account, network or UI construction.
final class PillSettingsEntryContractsTests: XCTestCase {
    @MainActor func testCurrentAccountFactoryRunsForEmptyInvalidAndDormantLayouts() {
        final class Context {}
        let context = Context()
        var factories = 0
        var presentations = 0
        for layout in ["", "invalid layout", "900001,900002"] {
            XCTAssertTrue(ExteralessPillSettingsActionGate.open(requested: context, current: context, active: true,
                make: { factories += 1; return layout }, present: { _ in presentations += 1 }))
        }
        XCTAssertEqual(factories, 3)
        XCTAssertEqual(presentations, 3)
    }

    @MainActor func testSavedActionCannotRecreateRetiredAccountAfterSwitchOrClear() {
        final class Context {}
        let a = Context(); let b = Context()
        var current: Context? = a
        var factories = 0
        var presentations = 0
        let oldAction = {
            ExteralessPillSettingsActionGate.open(requested: a, current: current, active: current != nil,
                make: { factories += 1; return a }, present: { _ in presentations += 1 })
        }
        XCTAssertTrue(oldAction())
        current = b
        XCTAssertFalse(oldAction())
        XCTAssertTrue(current === b)
        current = nil
        XCTAssertFalse(oldAction())
        XCTAssertNil(current)
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(ExteralessPillSettingsActionGate.open(requested: b, current: b, active: false,
            make: { XCTFail("Retired lease evaluated its factory"); return b }, present: { _ in XCTFail("Retired lease presented a screen") }))
    }
}
