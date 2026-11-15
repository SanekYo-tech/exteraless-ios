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

    func testTBF02GrammarValidWrongArraysAreRejectedByTheTypedLegacyReader() throws {
        let variants: [(UInt8, Data)] = [
            (12, i32(1) + string("x")),
            (6, i32(1) + i32(42)),
            (7, i32(1) + i64(42)),
            (5, object(field("text", 4, string("x"))))
        ]
        for (type, payload) in variants {
            let bytes = legacy(type, payload)
            try ToolsPostboxPreflight.validate(bytes, maximumBytes: 1_024)
            XCTAssertThrowsError(try ToolsFavoriteStickerStorage.decodeLegacyPostbox(bytes, userId: 101))
        }
        XCTAssertEqual(try ToolsFavoriteStickerStorage.decodeLegacyPostbox(legacy(6, i32(0)), userId: 101), [])
    }

    func testTBF02WrongAliasShapeDoesNotReachAGenericArrayCast() throws {
        let fields: [Data] = [field("id", 1, i64(42)), field("datacenterId", 0, i32(1)), field("accessHash", 1, i64(84)),
            field("mimeType", 4, string("image/webp")), field("fileName", 4, string("fixture.webp")),
            field("displayText", 4, string("x")), field("width", 0, i32(64)), field("height", 0, i32(64)),
            field("premium", 2, Data([0])), field("noPremium", 2, Data([0]))]
        let base = fields.reduce(into: Data()) { $0.append($1) }
        for (type, value) in [(UInt8(6), i32(1) + i32(1)), (UInt8(5), object(field("text", 4, string("x"))))] {
            let bytes = legacy(8, i32(1) + object(base + field("aliases", type, value)))
            try ToolsPostboxPreflight.validate(bytes, maximumBytes: 2_048)
            XCTAssertThrowsError(try ToolsFavoriteStickerStorage.decodeLegacyPostbox(bytes, userId: 101))
        }
        let valid = legacy(8, i32(1) + object(base + field("aliases", 6, i32(0))))
        let stickers = try ToolsFavoriteStickerStorage.decodeLegacyPostbox(valid, userId: 101)
        XCTAssertEqual(stickers.first?.id, 42)
        XCTAssertEqual(stickers.first?.aliases, [])
    }

    func testTBF02CloudWrapperRequiresBytesAndStringArrayWireTypes() throws {
        let fd = Data([1, 2, 3, 4])
        let good = field("_", 5, object(field("fd", 10, i32(4) + fd) + field("sr", 12, i32(1) + string("x"))))
        XCTAssertEqual(try ToolsFavoriteStickerStorage.decodeCloudPostbox(good).fileData, fd)
        let badFile = field("_", 5, object(field("fd", 4, string(fd.base64EncodedString())) + field("sr", 6, i32(0))))
        let badStrings = field("_", 5, object(field("fd", 10, i32(4) + fd) + field("sr", 7, i32(1) + i64(1))))
        for data in [badFile, badStrings] {
            try ToolsPostboxPreflight.validate(data, maximumBytes: 1_024)
            XCTAssertThrowsError(try ToolsFavoriteStickerStorage.decodeCloudPostbox(data))
        }
    }

    // Literal little-endian Postbox fixtures; these helpers never invoke its unsafe
    // generic decoder. Native tests separately use the real engine encoders.
    private func i32(_ value: Int32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> ($0 * 8)) }) }
    private func i64(_ value: Int64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: value) >> ($0 * 8)) }) }
    private func string(_ value: String) -> Data { i32(Int32(value.utf8.count)) + Data(value.utf8) }
    private func field(_ name: String, _ type: UInt8, _ value: Data) -> Data { Data([UInt8(name.utf8.count)]) + Data(name.utf8) + Data([type]) + value }
    private func object(_ value: Data) -> Data { i32(0) + i32(Int32(value.count)) + value }
    private func legacy(_ type: UInt8, _ value: Data) -> Data {
        field("_", 5, object(field("version", 0, i32(1)) + field("userId", 1, i64(101)) + field("stickers", type, value)))
    }
}
