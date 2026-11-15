import Foundation
import TelegramCore
import XCTest

final class PillPassivePingContractsTests: XCTestCase {
    func testOnlyPositiveFiniteRecentNativePingSamplesCanRender() {
        let sampledAt = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(ExteralessPillPassivePingSample(roundTripSeconds: 0, sampledAt: sampledAt))
        XCTAssertNil(ExteralessPillPassivePingSample(roundTripSeconds: -1, sampledAt: sampledAt))
        XCTAssertNil(ExteralessPillPassivePingSample(roundTripSeconds: .nan, sampledAt: sampledAt))
        XCTAssertNil(ExteralessPillPassivePingSample(roundTripSeconds: .infinity, sampledAt: sampledAt))
        let measured = ExteralessPillPassivePingSample(roundTripSeconds: 0.0125, sampledAt: sampledAt)
        XCTAssertEqual(measured?.roundTripSeconds, 0.0125)
        XCTAssertEqual(measured?.sampledAt, sampledAt)
        XCTAssertEqual(measured?.isFresh(now: sampledAt.addingTimeInterval(60)), true)
        XCTAssertEqual(measured?.isFresh(now: sampledAt.addingTimeInterval(121)), false)
        XCTAssertEqual(measured?.isFresh(now: sampledAt.addingTimeInterval(-1)), false)
    }
}
