import Foundation
import XCTest
@testable import PluginHost

final class PluginNativeEffectTests: XCTestCase {
    func testCancelledTicketsCannotConsumeNewLifetimeOrAnotherPluginsBudget() throws {
        let budget = PluginNativeEffectBudget(maximumPerPlugin: 1, maximumTotal: 2, maximumBytes: 12)
        let old = try budget.reserve(pluginId: "alpha", bytes: 4)
        let other = try budget.reserve(pluginId: "beta", bytes: 4)
        XCTAssertThrowsError(try budget.reserve(pluginId: "alpha", bytes: 1))
        budget.cancel(pluginId: "alpha")
        XCTAssertFalse(old.isActive)
        XCTAssertTrue(other.isActive)
        let next = try budget.reserve(pluginId: "alpha", bytes: 4)
        old.finish()
        old.finish()
        XCTAssertTrue(next.isActive)
        XCTAssertThrowsError(try budget.reserve(pluginId: "gamma", bytes: 1))
        budget.cancelAll()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(other.isActive)
        let restored = try budget.reserve(pluginId: "gamma", bytes: 12)
        XCTAssertTrue(restored.isActive)
    }

    func testByteAdmissionAndReleaseOnDeinit() throws {
        let budget = PluginNativeEffectBudget(maximumBytes: 8)
        var ticket: PluginNativeEffectBudget.Ticket? = try budget.reserve(pluginId: "alpha", bytes: 8)
        XCTAssertTrue(try XCTUnwrap(ticket).isActive)
        XCTAssertThrowsError(try budget.reserve(pluginId: "beta", bytes: 1))
        XCTAssertThrowsError(try budget.reserve(pluginId: "beta", bytes: -1))
        ticket = nil
        let next = try budget.reserve(pluginId: "beta", bytes: 8)
        XCTAssertTrue(next.isActive)
        XCTAssertThrowsError(try budget.reserve(pluginId: "gamma", bytes: Int.max))
    }

    func testLeaseRechecksItsScopeAtExecution() throws {
        let budget = PluginNativeEffectBudget()
        let ticket = try budget.reserve(pluginId: "alpha", bytes: 0)
        let lease = PluginNativeCallLease { ticket.isActive }
        try lease.check()
        budget.cancel(pluginId: "alpha")
        XCTAssertFalse(lease.isCurrent)
        XCTAssertThrowsError(try lease.check())
    }
}
