import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsCachedFavoriteTests: XCTestCase {
    func testTB03ElevenByteNegativeObjectLengthIsRejectedBeforeNativeDecode() {
        let bytes = Data([0x01, 0x5f, 0x05, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff])
        XCTAssertEqual(bytes.count, 11)
        XCTAssertThrowsError(try ToolsPostboxPreflight.validate(bytes, maximumBytes: 64))
    }

    func testTB03TruncatedNestedObjectAndHugeDeclaredCountHaveBoundedRejection() {
        let fixtures: [[UInt8]] = [
            [1, 95, 5, 0, 0, 0, 0, 9, 0, 0, 0],
            [1, 95, 8, 0xff, 0xff, 0xff, 0x7f],
            [1, 95, 8, 1, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff],
            [1, 95, 12, 1, 0, 0, 0, 100, 0, 0, 0],
            [255, 95, 0]
        ]
        for bytes in fixtures { XCTAssertThrowsError(try ToolsPostboxPreflight.validate(Data(bytes), maximumBytes: 64)) }
    }

    func testTB03RawPreferenceEnvelopeChecksVersionAndAccountBeforeReturningItems() throws {
        let bytes = try ToolsFavoriteStickerStorage.encode([], userId: 101)
        XCTAssertEqual(try ToolsFavoriteStickerStorage.decode(bytes, userId: 101), [])
        XCTAssertThrowsError(try ToolsFavoriteStickerStorage.decode(bytes, userId: 102))
        let badVersion = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":999").utf8)
        XCTAssertThrowsError(try ToolsFavoriteStickerStorage.decode(badVersion, userId: 101))
        XCTAssertEqual(try ToolsFavoriteStickerStorage.decode(bytes, userId: 101), [])
    }
}
