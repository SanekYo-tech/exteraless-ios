import Foundation
import XCTest
@testable import ExteralessCore

final class EmojiPackTests: XCTestCase, @unchecked Sendable {
    func testLicensedFixtureAndNativeFormatAdmission() throws {
        let font = try EmojiFontInspection.inspect(EmojiFontFixture.data, fileExtension: "ttf", expectedSHA256: EmojiFontFixture.sha256)
        XCTAssertEqual(font.byteCount, 936)
        XCTAssertEqual(font.postScriptName, "ExteralessEmojiFixture")
        XCTAssertTrue(font.license?.contains("CC0-1.0") == true)
        XCTAssertThrowsError(try EmojiFontInspection.inspect(EmojiFontFixture.data, fileExtension: "xml"))
        XCTAssertThrowsError(try EmojiFontInspection.inspect(Data("wOF2".utf8) + EmojiFontFixture.data.dropFirst(4), fileExtension: "ttf"))
        XCTAssertThrowsError(try EmojiFontInspection.inspect(EmojiFontFixture.data, fileExtension: "ttf", expectedSHA256: String(repeating: "0", count: 64)))
        // Structural admission intentionally cannot replace a real drawing probe.
        XCTAssertNoThrow(try EmojiFontInspection.inspect(EmojiFontFixture.blank, fileExtension: "ttf"))
    }

    func testTruncationOverlapAndOverflowAreRejectedBeforeFontParsing() {
        for count in [0, 4, 11, 171, 800] {
            XCTAssertThrowsError(try EmojiFontInspection.inspect(Data(EmojiFontFixture.data.prefix(count)), fileExtension: "ttf"))
        }
        var overlap = EmojiFontFixture.data
        EmojiFontFixture.put32(172, at: 12 + 16 + 8, in: &overlap)
        XCTAssertThrowsError(try EmojiFontInspection.inspect(overlap, fileExtension: "ttf"))
        var overflow = EmojiFontFixture.data
        EmojiFontFixture.put32(UInt32.max, at: 12 + 8, in: &overflow)
        XCTAssertThrowsError(try EmojiFontInspection.inspect(overflow, fileExtension: "ttf"))
        var androidBitmapOnly = EmojiFontFixture.data
        androidBitmapOnly.replaceSubrange((12 + 2 * 16)..<(16 + 2 * 16), with: Data("CBDT".utf8))
        XCTAssertThrowsError(try EmojiFontInspection.inspect(androidBitmapOnly, fileExtension: "ttf"))
    }

    func testPrivateRegistrationNamesKeepOriginalSourcePinAndLicense() throws {
        let original = EmojiFontFixture.data
        let inspection = try EmojiFontInspection.inspect(original, fileExtension: "ttf")
        let registered = try EmojiFontRegistration.data(original, inspection: inspection)
        let changed = try EmojiFontInspection.inspect(registered, fileExtension: "ttf")
        XCTAssertEqual(changed.postScriptName, EmojiFontRegistration.privateName(sha256: EmojiFontFixture.sha256))
        XCTAssertEqual(changed.license, inspection.license)
        XCTAssertEqual(EmojiFontFixture.checksum(registered), 0xb1b0afba)
        XCTAssertEqual(ToolsSHA256.hex(original), EmojiFontFixture.sha256)
        XCTAssertNotEqual(changed.sha256, inspection.sha256)
    }

    func testOriginalCatalogBoundsDuplicateIdAndFailedRefreshPreserveCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmojiPackStore(root: root, accountId: 1)
        let catalog = try EmojiCatalog.parse(message: #"#emojiv2 {"emojis":[{"id":"fixture","name":"Fixture","version":1,"file":11,"preview":12}]}"#, now: Date(timeIntervalSince1970: 100))
        try await store.saveCatalog(catalog)
        XCTAssertThrowsError(try EmojiCatalog.parse(message: #"#emojiv2 {"emojis":[{"id":"../escape","name":"Bad","version":1,"file":11}]}"#))
        XCTAssertThrowsError(try EmojiCatalog(source: EmojiCatalog.source, fetchedAt: Date(), entries: catalog.entries + catalog.entries))
        let cached = try await store.catalog()
        XCTAssertEqual(cached, catalog)
        let recreated = EmojiPackStore(root: root, accountId: 1)
        let persisted = try await recreated.catalog()
        XCTAssertEqual(persisted, catalog)
    }

    func testPackRecreationTamperAccountIsolationAndAtomicUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmojiPackStore(root: root, accountId: 7)
        let pack = try await store.store(data: EmojiFontFixture.data, name: "Fixture", fileExtension: "ttf", origin: .imported)
        let restored = EmojiPackStore(root: root, accountId: 7)
        let bytes = try await restored.fontData(for: pack)
        XCTAssertEqual(bytes, EmojiFontFixture.data)
        do { _ = try await EmojiPackStore(root: root, accountId: 8).list(); XCTFail("Cross-account cache accepted") }
        catch { XCTAssertEqual(error as? EmojiPackError, .invalidCache) }
        do {
            _ = try await store.store(data: Data("not a font".utf8), name: "Bad", fileExtension: "ttf", origin: .imported)
            XCTFail("Invalid replacement accepted")
        } catch {}
        let intact = try await store.list()
        XCTAssertEqual(intact, [pack])
        try Data("tampered".utf8).write(to: root.appendingPathComponent(pack.sha256 + ".ttf"))
        do { _ = try await restored.fontData(for: pack); XCTFail("Tampered font loaded") } catch {}
        let stillListed = try await store.list()
        XCTAssertEqual(stillListed, [pack])
        try await store.remove(id: pack.id)
        let empty = try await store.list()
        XCTAssertTrue(empty.isEmpty)
    }

    func testBundledPinRequiredAndClearingDownloadsKeepsImportedAndSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmojiPackStore(root: root, accountId: 2)
        do {
            _ = try await store.store(data: EmojiFontFixture.data, name: "Unpinned", fileExtension: "ttf", origin: .bundled(source: "fixture", license: "CC0-1.0"))
            XCTFail("Unpinned bundle accepted")
        } catch { XCTAssertEqual(error as? EmojiPackError, .checksumMismatch) }
        let imported = try await store.store(data: EmojiFontFixture.data, name: "Imported", fileExtension: "ttf", origin: .imported)
        let entry = EmojiCatalogEntry(id: "remote", name: "Remote", version: 1, file: 10)
        let remote = try await store.store(data: EmojiFontFixture.data, name: "Remote", fileExtension: "ttf", origin: .telegram(source: EmojiCatalog.source, messageId: 10), catalogEntry: entry)
        try await store.clearUnusedDownloads(selectedId: remote.id)
        let both = try await store.list()
        XCTAssertEqual(both.count, 2)
        try await store.clearUnusedDownloads(selectedId: "")
        let left = try await store.list()
        XCTAssertEqual(left, [imported])
        let bytes = try await store.fontData(for: imported)
        XCTAssertEqual(bytes, EmojiFontFixture.data)
    }
}
