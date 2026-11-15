import ExteralessCore
import Foundation
import TelegramCore
import XCTest

/// Self-owned native metadata only. No Account/Postbox/network is constructed;
/// the projection consumes the same Tools-reconstructed files as the real picker.
final class StickerFavoritesIntegrationTests: XCTestCase {
    private func item(_ id: Int64, hash: Int64 = 1, pack: Bool = true) throws -> SavedStickerItem {
        let descriptor = ToolsFavoriteSticker(id: id, datacenterId: 1, accessHash: hash,
            fileReference: Data([UInt8(truncatingIfNeeded: hash)]), size: 128, mimeType: "image/webp",
            fileName: "fixture.webp", displayText: "😀", width: 64, height: 64,
            pack: pack ? .init(id: 42, accessHash: 84) : nil)
        return SavedStickerItem(file: try exteralessFavoriteStickerFile(descriptor), stringRepresentations: ["😀"])
    }

    func testThreeHundredFiftyLocalItemsSurviveCloudRefreshWithoutDuplicateCells() throws {
        let local = try (1...350).map { try item(Int64($0)) }
        let cloud = try (1...200).map { try item(Int64($0), hash: 2) }
        let initial = try exteralessStickerPickerFavorites(cloud: cloud, local: local)
        XCTAssertEqual(initial.count, 350)
        XCTAssertEqual(Set(initial.map { $0.item.file.fileId }).count, 350)
        XCTAssertEqual(initial.map { $0.item.file.fileId.id }, Array(1...350).map(Int64.init))
        let fresh = try XCTUnwrap(initial.first?.reference.media.resource as? CloudDocumentMediaResource)
        XCTAssertEqual(fresh.accessHash, 2)

        let refreshed = try exteralessStickerPickerFavorites(cloud: [item(10, hash: 3)], local: local)
        XCTAssertEqual(refreshed.count, 350)
        XCTAssertEqual(refreshed.first?.item.file.fileId.id, 10)
        XCTAssertEqual(Set(refreshed.map { $0.item.file.fileId }).count, 350)
        XCTAssertEqual(local.count, 350)
        XCTAssertEqual(cloud.count, 200)
    }

    func testCloudAndLocalReferencesRetainTheirActualSource() throws {
        let cloud = try item(1, hash: 3)
        let local = try item(2)
        let standalone = try item(3, pack: false)
        let result = try exteralessStickerPickerFavorites(cloud: [cloud], local: [local, standalone])
        guard case .savedSticker = result[0].reference else { return XCTFail("Cloud favorite lost native reference") }
        guard case let .stickerPack(pack, file) = result[1].reference else { return XCTFail("Local favorite falsely marked cloud-saved") }
        guard case let .id(id, hash) = pack else { return XCTFail("Stored pack reference lost") }
        XCTAssertEqual(id, 42)
        XCTAssertEqual(hash, 84)
        XCTAssertEqual(file.fileId.id, 2)
        guard case .standalone = result[2].reference else { return XCTFail("Absent pack was invented") }
    }

    func testLocalBoundAndSeparateAccountInputs() throws {
        let first = try item(1)
        XCTAssertThrowsError(try exteralessStickerPickerFavorites(cloud: [], local: Array(repeating: first, count: ToolsFavoriteStickerArchive.maximumPerAccount + 1)))
        let accountA = try exteralessStickerPickerFavorites(cloud: [], local: [first])
        let accountB = try exteralessStickerPickerFavorites(cloud: [item(2)], local: [])
        XCTAssertEqual(accountA.map { $0.item.file.fileId.id }, [1])
        XCTAssertEqual(accountB.map { $0.item.file.fileId.id }, [2])
        let descriptor = try exteralessFavoriteStickerDescriptor(file: first.file._parse())
        let archive = ToolsFavoriteStickerArchive(accounts: ["1001": [descriptor]])
        XCTAssertThrowsError(try archive.stickers(for: 1002))
        XCTAssertEqual(try archive.stickers(for: 1001).map(\.id), [1])
    }
}
