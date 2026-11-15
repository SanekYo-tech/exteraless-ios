import ExteralessCore
import Foundation
import TelegramCore
import XCTest

/// Real native preference/ordered-list encoders and the production cache boundary;
/// no account, database, favorites RPC or generic imported-media decoder is used.
final class ToolsFavoriteStorageNativeTests: XCTestCase {
    private struct Legacy: Codable {
        // The release v1 encoder wrote this Int as Int32. Use that wire type
        // directly: its debug encode(Int) overload intentionally asserts.
        let version: Int32
        let userId: Int64
        let stickers: [ToolsFavoriteSticker]
    }
    private struct CachedCloud: Codable { let fd: Data; let sr: [String] }
    private struct LegacyWire<Value: Encodable>: Encodable {
        let version: Int32 = 1
        let userId: Int64 = 101
        let stickers: Value
    }
    private struct ObjectInsteadOfArray: Encodable { let text = "x" }
    private struct CloudWire<File: Encodable, Strings: Encodable>: Encodable { let fd: File; let sr: Strings }
    private struct StickerWire<Aliases: Encodable>: Encodable {
        let id: Int64 = 42
        let datacenterId: Int32 = 1
        let accessHash: Int64 = 84
        let mimeType = "image/webp"
        let fileName = "fixture.webp"
        let displayText = "x"
        let width: Int32 = 64
        let height: Int32 = 64
        let premium = false
        let noPremium = false
        let aliases: Aliases
    }
    private var sticker: ToolsFavoriteSticker {
        .init(id: 42, datacenterId: 1, accessHash: 84, fileReference: Data([1, 2]), size: 128,
              mimeType: "image/webp", fileName: "fixture.webp", displayText: "😀", width: 64, height: 64,
              pack: .init(id: 123, accessHash: 456), aliases: ["😀"])
    }

    func testTB03MalformedNativePreferenceErrorsAndRetainsOriginalBytes() throws {
        let bytes = Data([1, 95, 5, 0, 0, 0, 0, 255, 255, 255, 255])
        let entry = EnginePreferencesEntry(data: bytes)
        XCTAssertThrowsError(try exteralessDecodeLocalFavoriteStickers(entry.data, userId: 101))
        XCTAssertEqual(entry.data, bytes)
    }

    func testTB03RealLegacyPreferenceMigratesToRawEnvelopeWithoutGenericMediaDecode() throws {
        let entry = try XCTUnwrap(EnginePreferencesEntry(Legacy(version: 1, userId: 101, stickers: [sticker])))
        let decoded = try exteralessDecodeLocalFavoriteStickers(entry.data, userId: 101)
        XCTAssertEqual(decoded, [sticker])
        XCTAssertThrowsError(try exteralessDecodeLocalFavoriteStickers(entry.data, userId: 102))
        let upgraded = EnginePreferencesEntry(data: try ToolsFavoriteStickerStorage.encode(decoded, userId: 101))
        XCTAssertEqual(try exteralessDecodeLocalFavoriteStickers(upgraded.data, userId: 101), [sticker])
    }

    func testTB03CloudFavoriteUsesThrowingFlatBufferVerification() throws {
        let item = SavedStickerItem(file: try exteralessFavoriteStickerFile(sticker), stringRepresentations: sticker.aliases)
        let entry = try XCTUnwrap(EngineCodableEntry(item))
        XCTAssertEqual(try exteralessDecodeCloudFavoriteSticker(entry.data), sticker)
        let corrupt = try XCTUnwrap(EngineCodableEntry(CachedCloud(fd: Data([255, 255, 255, 127]), sr: [])))
        let retained = corrupt.data
        XCTAssertThrowsError(try exteralessDecodeCloudFavoriteSticker(corrupt.data))
        XCTAssertEqual(corrupt.data, retained)
        XCTAssertThrowsError(try exteralessDecodeCloudFavoriteSticker(Data([1, 95, 5, 0, 0, 0, 0, 255, 255, 255, 255])))
    }

    func testTBF02ValidWireWrongStickerAndAliasShapesThrowBeforeNativeConstruction() throws {
        try rejectLegacy(LegacyWire(stickers: ["x"]))
        try rejectLegacy(LegacyWire(stickers: [Int32(1)]))
        try rejectLegacy(LegacyWire(stickers: [Int64(1)]))
        try rejectLegacy(LegacyWire(stickers: ObjectInsteadOfArray()))
        try rejectLegacy(LegacyWire(stickers: [StickerWire(aliases: [Int32(1)])]))
        try rejectLegacy(LegacyWire(stickers: [StickerWire(aliases: [Int64(1)])]))
        try rejectLegacy(LegacyWire(stickers: [StickerWire(aliases: ObjectInsteadOfArray())]))
        try rejectLegacy(LegacyWire(stickers: [StickerWire(aliases: "not-an-array")]))
    }

    func testTBF02ValidWireWrongCloudFdAndSrShapesThrowAndPreserveBytes() throws {
        let item = SavedStickerItem(file: try exteralessFavoriteStickerFile(sticker), stringRepresentations: sticker.aliases)
        let entry = try XCTUnwrap(EngineCodableEntry(item))
        let valid = try ToolsFavoriteStickerStorage.decodeCloudPostbox(entry.data)
        try rejectCloud(CloudWire(fd: valid.fileData.base64EncodedString(), sr: valid.aliases))
        try rejectCloud(CloudWire(fd: [Int32(1)], sr: valid.aliases))
        try rejectCloud(CloudWire(fd: ObjectInsteadOfArray(), sr: valid.aliases))
        try rejectCloud(CloudWire(fd: valid.fileData, sr: ObjectInsteadOfArray()))
        try rejectCloud(CloudWire(fd: valid.fileData, sr: [Int32(1)]))
        try rejectCloud(CloudWire(fd: valid.fileData, sr: [Int64(1)]))
        try rejectCloud(CloudWire(fd: valid.fileData, sr: Data([1])))
    }

    func testTBF02ActualEncoderEmptyArrayRepresentationStillMigrates() throws {
        let empty = try XCTUnwrap(EnginePreferencesEntry(Legacy(version: 1, userId: 101, stickers: [])))
        XCTAssertEqual(try exteralessDecodeLocalFavoriteStickers(empty.data, userId: 101), [])
        let aliasesEmpty = try XCTUnwrap(EnginePreferencesEntry(LegacyWire(stickers: [StickerWire(aliases: [String]())])))
        XCTAssertEqual(try exteralessDecodeLocalFavoriteStickers(aliasesEmpty.data, userId: 101).first?.aliases, [])
        let raw = try ToolsFavoriteStickerStorage.encode(exteralessDecodeLocalFavoriteStickers(aliasesEmpty.data, userId: 101), userId: 101)
        XCTAssertEqual(try exteralessDecodeLocalFavoriteStickers(raw, userId: 101).first?.id, 42)
    }

    private func rejectLegacy<Value: Encodable>(_ value: Value) throws {
        let entry = try XCTUnwrap(EnginePreferencesEntry(value))
        let original = entry.data
        try ToolsPostboxPreflight.validate(original, maximumBytes: 16_384)
        XCTAssertThrowsError(try exteralessDecodeLocalFavoriteStickers(original, userId: 101))
        XCTAssertEqual(entry.data, original)
    }

    private func rejectCloud<Value: Encodable>(_ value: Value) throws {
        let entry = try XCTUnwrap(EngineCodableEntry(value))
        let original = entry.data
        try ToolsPostboxPreflight.validate(original, maximumBytes: 16_384)
        XCTAssertThrowsError(try ToolsFavoriteStickerStorage.decodeCloudPostbox(original))
        XCTAssertThrowsError(try exteralessDecodeCloudFavoriteSticker(original))
        XCTAssertEqual(entry.data, original)
    }
}
