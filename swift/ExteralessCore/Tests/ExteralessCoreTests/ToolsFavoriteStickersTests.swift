import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsFavoriteStickersTests: XCTestCase {
    private func sticker(_ id: Int64, name: String = "sticker.webp") -> ToolsFavoriteSticker {
        ToolsFavoriteSticker(id: id, datacenterId: 2, accessHash: Int64.min + id, fileReference: Data([1, 2, 3]), size: 1_024,
            mimeType: "image/webp", fileName: name, displayText: "🙂", width: 512, height: 512, pack: .init(id: 123, accessHash: 456))
    }

    func testNativeAccountKeysRoundTripAndRejectOtherAccount() throws {
        let archive = ToolsFavoriteStickerArchive(accounts: ["9007199254740993": [sticker(9007199254740993)], "42": [sticker(2)]])
        let decoded = try ToolsFavoriteStickerArchive.decode(archive.encode())
        XCTAssertEqual(try decoded.stickers(for: 9007199254740993).first?.id, 9007199254740993)
        XCTAssertThrowsError(try decoded.stickers(for: 999))
    }

    func testLocalMergeRetainsOrderAndDoesNotUseServerFavoriteLimit() throws {
        let before = [sticker(1), sticker(2)]
        let imported = (2...300).map { sticker(Int64($0)) }
        let merged = try ToolsFavoriteStickerArchive.merge(current: before, incoming: imported)
        XCTAssertEqual(merged.count, 300)
        XCTAssertEqual(Array(merged.prefix(2)), before)
        XCTAssertEqual(before.count, 2, "merge cannot mutate its input on failure")
    }

    func testChecksumAndResourcePathsAreValidatedBeforeNativeConstruction() throws {
        let data = try ToolsFavoriteStickerArchive(accounts: ["42": [sticker(1)]]).encode()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        envelope["sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ToolsFavoriteStickerArchive.decode(JSONSerialization.data(withJSONObject: envelope)))
        XCTAssertThrowsError(try ToolsFavoriteStickerArchive(accounts: ["42": [sticker(1, name: "../../account.sqlite")]]).validate())
        XCTAssertThrowsError(try ToolsFavoriteStickerArchive(accounts: ["042": [sticker(1)]]).validate())
        XCTAssertThrowsError(try ToolsFavoriteStickerArchive(accounts: ["42": [sticker(1), sticker(1)]]).validate())
    }
}
