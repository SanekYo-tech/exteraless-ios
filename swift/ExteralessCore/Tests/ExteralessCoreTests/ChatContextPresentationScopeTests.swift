import Foundation
import XCTest
@testable import ExteralessCore

final class ChatContextPresentationScopeTests: XCTestCase {
    private final class Screen {
        var invalidations = 0
        var windowStillAlive = true
    }

    func testSavedActionAAfterSwitchCannotCreateAOrInvalidateB() {
        let scope = ChatContextPresentationScope<String, Screen>(invalidate: { $0.invalidations += 1 })
        let a = Screen(), b = Screen()
        var factoriesA = 0
        var presentationsA = 0
        let leaseA = scope.activate("A")
        let savedActionA = {
            scope.open(identity: "A", lease: leaseA, factory: { factoriesA += 1; return a }, present: { _ in presentationsA += 1 })
        }
        XCTAssertTrue(savedActionA())
        let leaseB = scope.activate("B")
        XCTAssertTrue(scope.open(identity: "B", lease: leaseB, factory: { b }, present: { _ in }))
        XCTAssertEqual(a.invalidations, 1)
        XCTAssertTrue(a.windowStillAlive)
        for _ in 0 ..< 4 { XCTAssertFalse(savedActionA()) }
        XCTAssertEqual(factoriesA, 1, "zero new A factories after retirement")
        XCTAssertEqual(presentationsA, 1)
        XCTAssertEqual(b.invalidations, 0)
        XCTAssertEqual(scope.currentIdentity, "B")
    }

    func testClearAndReactivationOfSameIdentityCannotReviveOldLease() {
        let scope = ChatContextPresentationScope<String, Screen>(invalidate: { $0.invalidations += 1 })
        let oldLease = scope.activate("A")
        var factories = 0
        let action = { scope.open(identity: "A", lease: oldLease, factory: { factories += 1; return Screen() }, present: { _ in XCTFail("stale presentation") }) }
        scope.clear()
        XCTAssertFalse(action())
        let currentLease = scope.activate("A")
        XCTAssertFalse(action(), "identity matches but the activation epoch differs")
        XCTAssertEqual(factories, 0)
        let current = Screen()
        XCTAssertTrue(scope.open(identity: "A", lease: currentLease, factory: { current }, present: { _ in }))
        XCTAssertEqual(current.invalidations, 0)
    }

    func testAccountChangeDuringFactoryDoesNotPublishOldScreenOrInvalidateNewOne() {
        let scope = ChatContextPresentationScope<String, Screen>(invalidate: { $0.invalidations += 1 })
        let leaseA = scope.activate("A")
        let a = Screen(), b = Screen()
        let accepted = scope.open(identity: "A", lease: leaseA, factory: {
            let leaseB = scope.activate("B")
            XCTAssertTrue(scope.open(identity: "B", lease: leaseB, factory: { b }, present: { _ in }))
            return a
        }, present: { _ in XCTFail("A was retired during construction") })
        XCTAssertFalse(accepted)
        XCTAssertEqual(a.invalidations, 1)
        XCTAssertEqual(b.invalidations, 0)
        XCTAssertEqual(scope.currentIdentity, "B")
    }
}
