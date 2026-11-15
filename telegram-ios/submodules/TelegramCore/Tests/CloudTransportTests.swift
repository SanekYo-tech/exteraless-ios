import ExteralessCore
import Foundation
import XCTest
@testable import TelegramCore

final class CloudTransportTests: XCTestCase {
    func testActualNativeGzipMatchesOriginalEnvelopeEncodingAndEnforcesInflationLimit() throws {
        let codec = ExteralessCloudTransport.compression
        let original = Data(repeating: 65, count: 65_536)
        let compressed = try codec.compress(original)
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(try codec.decompress(compressed, original.count), original)
        XCTAssertThrowsError(try codec.decompress(compressed, 1_024))
        XCTAssertThrowsError(try codec.decompress(Data([1, 2, 3]), 1_024))
    }
}
