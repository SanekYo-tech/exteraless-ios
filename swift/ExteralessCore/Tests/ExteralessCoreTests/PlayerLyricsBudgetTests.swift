import Foundation
import XCTest
@testable import ExteralessCore

/// Small FPP-07 regressions. The malicious source is only 4545 bytes; no
/// megabyte/OOM stress fixture or provider request is needed to expose expansion.
final class PlayerLyricsBudgetTests: XCTestCase, @unchecked Sendable {
    private var timestamps: String { (0..<64).map { String(format: "[%02d:%02d]", $0 / 60, $0 % 60) }.joined() }

    func test4545ByteMultiTimestampExpansionIsRejectedBeforeRowAdmission() {
        let fixture = timestamps + String(repeating: "x", count: 4097)
        XCTAssertEqual(fixture.utf8.count, 4545)
        var budget = PlayerLyricsContentBudget()
        XCTAssertThrowsError(try budget.admit(textBytes: 4097, wordTextBytes: 0, words: 0, repetitions: 64)) { XCTAssertEqual($0 as? PlayerLyricsError, .responseTooLarge) }
        XCTAssertEqual(budget.lineCount, 0)
        XCTAssertEqual(budget.logicalBytes, 0)
        XCTAssertThrowsError(try PlayerLyricsDocument.parse(fixture)) { XCTAssertEqual($0 as? PlayerLyricsError, .responseTooLarge) }
    }

    func testAdjacent4544ByteBoundaryPreservesAllTimestampsAndOrdering() throws {
        let fixture = timestamps + String(repeating: "x", count: 4096)
        XCTAssertEqual(fixture.utf8.count, 4544)
        let document = try XCTUnwrap(PlayerLyricsDocument.parse(fixture))
        XCTAssertEqual(document.lines.count, 64)
        XCTAssertEqual(document.lines.map(\.time), (0..<64).map { Double($0) })
        XCTAssertEqual(try document.checkedFootprint().logicalBytes, 262_144)
        XCTAssertTrue(document.isValid)
    }

    func testEnhancedWordTextIsChargedAgainForEveryExpandedLine() throws {
        let excessive = timestamps + "<00:00>" + String(repeating: "x", count: 4096)
        XCTAssertLessThan(excessive.utf8.count, 5000)
        XCTAssertThrowsError(try PlayerLyricsDocument.parse(excessive)) { XCTAssertEqual($0 as? PlayerLyricsError, .responseTooLarge) }
        let accepted = try XCTUnwrap(PlayerLyricsDocument.parse(timestamps + "<00:00>" + String(repeating: "x", count: 2048)))
        XCTAssertEqual(accepted.lines.count, 64)
        XCTAssertEqual(try accepted.checkedFootprint().logicalBytes, 262_144)
        XCTAssertEqual(try accepted.checkedFootprint().words, 64)
    }

    func testBudgetCountsUTF8AndRejectsWholeRepeatedBatchAtomically() throws {
        var budget = PlayerLyricsContentBudget(maximumBytes: 8, maximumWords: 2)
        try budget.admit(textBytes: "é".utf8.count, wordTextBytes: "é".utf8.count, words: 1, repetitions: 2)
        XCTAssertEqual(budget.logicalBytes, 8)
        XCTAssertThrowsError(try budget.admit(textBytes: 1, wordTextBytes: 0, words: 0))
        XCTAssertEqual(budget.lineCount, 2)
        XCTAssertEqual(budget.wordCount, 2)
    }

    func testUncheckedExpandedDocumentIsRejectedBeforeWritingOverrideArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-budget-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("lyrics.json")
        let client = PlayerLyricsClient(cacheURL: cache)
        let line = PlayerLyricsDocument.Line(time: 0, text: String(repeating: "x", count: 4097))
        let invalid = PlayerLyricsDocument(lines: Array(repeating: line, count: 64), synced: true, source: .user, provider: "Fixture")
        let track = PlayerLyricsTrack(account: 1, resource: "fixture", duration: 80, query: .init(artist: "Fixture", title: "Fixture", duration: 80))
        do { try await client.setOverride(.init(lyrics: invalid), for: track); XCTFail("Expanded document was cached") }
        catch { XCTAssertEqual(error as? PlayerLyricsError, .responseTooLarge) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let counts = await client.cacheCounts()
        XCTAssertEqual(counts.overrides, 0)
    }

    func testEscapedUnicodeAndWordCuesFitThePreEncodingUpperBound() throws {
        let word = PlayerLyricsDocument.Word(time: 1.25, text: "\"\\\u{0}é👋")
        let document = PlayerLyricsDocument(lines: [.init(time: 1.25, text: word.text, words: [word])], synced: true, source: .user, provider: "Fixture \"source\"")
        let footprint = try document.checkedFootprint()
        XCTAssertEqual(footprint.logicalBytes, word.text.utf8.count * 2)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(document).count, footprint.encodedUpperBound)
    }
}
