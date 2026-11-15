import Foundation
import XCTest
@testable import ExteralessCore

final class AppearanceIconPackTests: XCTestCase, @unchecked Sendable {
    // Independently produced by Python zipfile (ZIP_STORED), not by this codec.
    // Two files, 418 bytes; optional author/version omitted as Android permits.
    private static let fixture = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwa6wfeYAAAAGAAAAANAAAAbWV0YWRhdGEuanNvbnsic2NoZW1hVmVyc2lvbiI6MSwicGFja0lkIjoiZml4dHVyZSIsInBhY2tOYW1lIjoiRml4dHVyZSIsImljb25zIjp7Im1zZ19kZWxldGUiOiJpY29ucy9hLnN2ZyJ9fVBLAwQUAAAAAAAAACFchztuZWQAAABkAAAACwAAAGljb25zL2Euc3ZnPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCI+PHBhdGggZD0iTTIgMiBMMjIgMiBMMjIgMjIgWiIvPjwvc3ZnPlBLAQIUABQAAAAAAAAAIVwa6wfeYAAAAGAAAAANAAAAAAAAAAAAAACAAQAAAABtZXRhZGF0YS5qc29uUEsBAhQAFAAAAAAAAAAhXIc7bmVkAAAAZAAAAAsAAAAAAAAAAAAAAIABiwAAAGljb25zL2Euc3ZnUEsFBgAAAAACAAIAdAAAABgBAAAAAA==")!

    private static func storedOnly(_ data: Data, _ size: Int) throws -> Data {
        throw AppearanceIconPackError.unsupportedCompression
    }

    func testReadsAndroidMetadataAndIndependentlyWrittenZIP() throws {
        let files = try AppearanceIconArchive.decode(Self.fixture, inflate: Self.storedOnly)
        let (pack, contents) = try AppearanceIconArchive.unpack(files)
        XCTAssertEqual(pack.packId, "fixture")
        XCTAssertEqual(pack.author, "")
        XCTAssertEqual(pack.version, "1.0")
        XCTAssertEqual(contents["icons/a.svg"]?.count, 100)
        XCTAssertEqual(AppearanceIconArchive.checksum(Data("123456789".utf8)), 0xcbf43926)
        let exported = try AppearanceIconArchive.encode(contents)
        XCTAssertEqual(try AppearanceIconArchive.decode(exported, inflate: Self.storedOnly), contents)
    }

    func testCorruptImageAndInconsistentLocalHeaderAreRejected() throws {
        var corrupted = Self.fixture
        let svg = try XCTUnwrap(corrupted.range(of: Data("<svg ".utf8)))
        corrupted[svg.lowerBound] ^= 1
        XCTAssertThrowsError(try AppearanceIconArchive.decode(corrupted, inflate: Self.storedOnly)) { error in
            XCTAssertEqual(error as? AppearanceIconPackError, .checksum)
        }
        var wrongLocalSize = Self.fixture
        wrongLocalSize[18] ^= 1
        XCTAssertThrowsError(try AppearanceIconArchive.decode(wrongLocalSize, inflate: Self.storedOnly)) { error in
            XCTAssertEqual(error as? AppearanceIconPackError, .invalidArchive)
        }
    }

    func testZIPTraversalIsRejectedBeforeExtraction() throws {
        var escaped = Self.fixture
        let original = Data("icons/a.svg".utf8)
        let replacement = Data("../esc.svgx".utf8)
        XCTAssertEqual(original.count, replacement.count)
        let centralName = try XCTUnwrap(escaped.range(of: original, options: .backwards))
        escaped.replaceSubrange(centralName, with: replacement)
        XCTAssertThrowsError(try AppearanceIconArchive.decode(escaped, inflate: Self.storedOnly)) { error in
            XCTAssertEqual(error as? AppearanceIconPackError, .unsafePath)
        }
        for path in ["/a", "a/../b", "a//b", "C:/x", "a\\b", "a/./b"] {
            XCTAssertThrowsError(try AppearanceIconArchive.validatePath(path))
        }
    }

    func testOversizedDeclarationIsRejectedWithoutInflation() throws {
        var archive = Self.fixture
        let central = try XCTUnwrap(archive.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        let offset = central.lowerBound + 24
        archive.replaceSubrange(offset..<(offset + 4), with: [0xff, 0xff, 0xff, 0x7f])
        var inflated = false
        XCTAssertThrowsError(try AppearanceIconArchive.decode(archive, inflate: { _, _ in inflated = true; return Data() }))
        XCTAssertFalse(inflated)
    }

    func testPriorityAndDisabledResetIncludingNativeAndroidAliases() {
        let high = AppearanceIconPackMetadata(packId: "high", packName: "High", icons: ["msg_delete": "a.png"])
        let low = AppearanceIconPackMetadata(packId: "low", packName: "Low", icons: ["Chat/Context Menu/Delete": "b.png", "msg_copy": "c.png"])
        let owners = AppearanceIconPackPolicy.owners(activeIds: ["missing", "high", "low"], packs: [low, high], enabled: true)
        XCTAssertEqual(owners["Chat/Context Menu/Delete"], "high")
        XCTAssertEqual(owners["Chat/Context Menu/Copy"], "low")
        XCTAssertEqual(AppearanceIconPackPolicy.owners(activeIds: ["high"], packs: [high], enabled: false), [:])
        XCTAssertEqual(AppearanceIconPackPolicy.activeIds("high, low, high,,../bad"), ["high", "low"])
        XCTAssertEqual(AppearanceIconPackPolicy.toggled("low", in: ["high"]), ["low", "high"])
    }

    func testInstallDoesNotOverwriteAndEditingExportsTheActualImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppearanceIconPackTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppearanceIconPackStore(directory: root)
        let installed = try await store.install(archive: Self.fixture, inflate: Self.storedOnly)
        XCTAssertEqual(installed.packId, "fixture")
        do {
            _ = try await store.install(archive: Self.fixture, inflate: Self.storedOnly)
            XCTFail("An existing pack must not be silently overwritten")
        } catch { XCTAssertEqual(error as? AppearanceIconPackError, .alreadyInstalled) }
        let replacement = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        try await store.replaceIcon(id: "fixture", resource: "msg_delete", data: replacement, fileExtension: "svg")
        let bytes = try await store.export(id: "fixture")
        let (metadata, files) = try AppearanceIconArchive.unpack(AppearanceIconArchive.decode(bytes, inflate: Self.storedOnly))
        let path = try XCTUnwrap(metadata.icons["msg_delete"])
        XCTAssertEqual(files[path], replacement)
        try await store.replaceIcon(id: "fixture", resource: "msg_delete", data: nil)
        let packs = try await store.list()
        XCTAssertEqual(packs.first?.icons, [:])
        try await store.remove(id: "fixture")
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }
}
