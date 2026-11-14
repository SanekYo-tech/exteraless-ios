import XCTest
@testable import ExteralessCore

final class PrivacyProxyPathTests: XCTestCase {
    func testAirplaneModeKeepsLastUsableDecisionThenCellularRestores() {
        var path = PrivacyProxyPathState()
        XCTAssertFalse(path.suppressesProxy(conditions: .wifi))
        path.update(isAvailable: true, mobileData: false, wifi: true)
        XCTAssertTrue(path.suppressesProxy(conditions: .wifi))
        path.update(isAvailable: false, mobileData: false, wifi: false)
        XCTAssertFalse(path.isAvailable)
        XCTAssertTrue(path.suppressesProxy(conditions: .wifi))
        path.update(isAvailable: true, mobileData: true, wifi: false)
        XCTAssertTrue(path.isAvailable)
        XCTAssertFalse(path.suppressesProxy(conditions: .wifi))
        XCTAssertTrue(path.suppressesProxy(conditions: .mobileData))
    }

    func testNewOtherRouteAndConditionResetDoNotRetainStaleWifiOrInferVPN() {
        var path = PrivacyProxyPathState()
        path.update(isAvailable: true, mobileData: false, wifi: true)
        XCTAssertFalse(path.suppressesProxy(conditions: []))
        path.update(isAvailable: true, mobileData: false, wifi: false)
        XCTAssertFalse(path.suppressesProxy(conditions: [.wifi, .mobileData, .vpn]))
        path.update(isAvailable: true, mobileData: false, wifi: true)
        XCTAssertTrue(path.suppressesProxy(conditions: .wifi))
    }

    func testUnavailableTransportFlagsCannotOverwriteLastAvailablePath() {
        var path = PrivacyProxyPathState()
        path.update(isAvailable: true, mobileData: true, wifi: false)
        path.update(isAvailable: false, mobileData: false, wifi: true)
        XCTAssertEqual(path.lastAvailableConditions, .mobileData)
        XCTAssertFalse(path.suppressesProxy(conditions: .wifi))
    }
}
