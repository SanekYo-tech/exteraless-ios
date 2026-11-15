import Foundation
import XCTest
@testable import ExteralessCore

final class AIReviewAllocationTests: XCTestCase, @unchecked Sendable {
    // Python zlib.compressobj(wbits=-15), independently generated for 1024 LF bytes.
    private let newlineDeflate = Data(base64Encoded: "4+IaBaNgFHCNUAAA")!

    func testNewlineDenseMultiEntryZipHasBoundedGlobalLineIndexAndRealPagination() async throws {
        let lines = Data(repeating: 10, count: 1024)
        let archive = zip((0 ..< 4).map { ("file\($0).py", lines, newlineDeflate) })
        let limits = AIPluginReviewLimits(maximumInputBytes: 2048, maximumInflatedBytes: 4096, maximumEntryBytes: 1024,
                                         maximumEntries: 4, maximumLineIndexEntries: 5, maximumBlobCount: 4,
                                         maximumBlobBytes: 1024, maximumExcerptBytes: 64)
        let tools = try AIPluginReviewTools(snapshot: snapshot([("source.zip", archive)]), limits: limits)
        let stats = tools.statistics
        XCTAssertEqual(stats.processedEntries, 4)
        XCTAssertEqual(stats.inflatedBytes, 4096)
        XCTAssertEqual(stats.sourceLines, 4 * 1025)
        XCTAssertGreaterThan(stats.lineIndexEntries, 0)
        XCTAssertLessThanOrEqual(stats.lineIndexEntries, 5)
        XCTAssertEqual(stats.blobCount, 0)
        XCTAssertEqual(stats.excerptBytes, 64)
        let page = try await tools.call("read_source", arguments: .object(["file": .string("file3.py"), "start_line": .integer(1022), "end_line": .integer(1025)]))
        XCTAssertTrue(page.contains("1025| "))
        XCTAssertTrue(page.contains("lines 1022-1025 of 1025"))
        XCTAssertTrue(page.hasSuffix("[end of file]"))
    }

    func testArchiveRemainingBudgetIsCheckedBeforeNextInflationAndAppend() throws {
        let first = Data(repeating: 65, count: 40), second = Data(repeating: 66, count: 40)
        // The second DEFLATE stream is deliberately invalid. Budget exhaustion
        // must be reported before its decoder or consumer can be reached.
        let archive = zip([("first.py", first, nil), ("second.py", second, Data([0xff]))])
        var visited: [String] = []
        XCTAssertThrowsError(try AIReviewArchive.forEachEntry(archive, maximumBytes: 60, maximumEntries: 2, maximumEntryBytes: 40) {
            visited.append($0.name); return true
        }) { XCTAssertEqual($0 as? AIError, .inputTooLarge) }
        XCTAssertEqual(visited, ["first.py"])
        XCTAssertThrowsError(try AIReviewArchive.entries(archive, maximumBytes: 39)) { XCTAssertEqual($0 as? AIError, .inputTooLarge) }
    }

    func testAggregateRemainingBudgetCrossesSeparateArchiveBoundaries() throws {
        let one = zip([("first.py", Data(repeating: 65, count: 40), nil)])
        let two = zip([("second.py", Data(repeating: 66, count: 40), Data([0xff]))])
        let limits = AIPluginReviewLimits(maximumInputBytes: 1024, maximumInflatedBytes: 60, maximumEntryBytes: 40)
        XCTAssertThrowsError(try AIPluginReviewTools(snapshot: snapshot([("one.zip", one), ("two.zip", two)]), limits: limits)) {
            XCTAssertEqual($0 as? AIError, .inputTooLarge)
        }
    }

    func testArchiveEnumerationStopsWithoutDecodingLaterEntries() throws {
        let archive = zip([("first.py", Data("first".utf8), nil), ("invalid.py", Data("second".utf8), Data([0xff]))])
        var visited: [String] = []
        try AIReviewArchive.forEachEntry(archive) { visited.append($0.name); return false }
        XCTAssertEqual(visited, ["first.py"])
        XCTAssertThrowsError(try AIReviewArchive.entries(archive)) { XCTAssertEqual($0 as? AIError, .invalidResponse) }
    }

    func testBlobEnumerationStopsInsideOneLongLineAtGlobalCountCap() async throws {
        let source = inlineBlobs(40)
        let limits = AIPluginReviewLimits(maximumLineIndexEntries: 2, maximumBlobCount: 3, maximumBlobBytes: 1024, maximumExcerptBytes: 64)
        let tools = try AIPluginReviewTools(snapshot: snapshot([("main.py", source)]), limits: limits)
        let stats = tools.statistics
        XCTAssertEqual(stats.blobCount, 3)
        XCTAssertEqual(stats.blobCandidates, 3)
        XCTAssertEqual(stats.blobBytes, 3 * 160)
        XCTAssertLessThan(stats.blobScanBytes, source.count)
        XCTAssertTrue(stats.blobLimitReached)
        let list = try await tools.call("list_blobs", arguments: .object([:]))
        XCTAssertTrue(list.contains("#2 main.py:1"))
        XCTAssertFalse(list.contains("#3 "))
        let decoded = try await tools.call("decode_base64", arguments: .object(["blob": .integer(2)]))
        XCTAssertTrue(decoded.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    func testBlobCountAndByteBudgetsAreSharedByEveryFileAndBinaryBlob() throws {
        let files = [("first.py", inlineBlobs(2)), ("second.py", inlineBlobs(2)), ("third.py", inlineBlobs(2))]
        let byCount = try AIPluginReviewTools(snapshot: snapshot(files), limits: .init(maximumBlobCount: 3, maximumBlobBytes: 1024))
        XCTAssertEqual(byCount.statistics.blobCount, 3)
        XCTAssertEqual(byCount.statistics.blobCandidates, 3)
        let byBytes = try AIPluginReviewTools(snapshot: snapshot(files), limits: .init(maximumBlobCount: 10, maximumBlobBytes: 320))
        XCTAssertEqual(byBytes.statistics.blobCount, 2)
        XCTAssertEqual(byBytes.statistics.blobCandidates, 2)
        XCTAssertEqual(byBytes.statistics.blobBytes, 320)
        let binaryFirst = try AIPluginReviewTools(snapshot: snapshot([("binary.dat", Data(repeating: 0, count: 160))] + files), limits: .init(maximumBlobCount: 10, maximumBlobBytes: 320))
        XCTAssertEqual(binaryFirst.statistics.blobCount, 2)
        XCTAssertEqual(binaryFirst.statistics.blobCandidates, 1)
        XCTAssertEqual(binaryFirst.statistics.blobBytes, 320)
    }

    func testMalformedBlobCandidatesAlsoHaveAnEarlyStopBudget() throws {
        let invalid = String(repeating: "Aa1", count: 67) // base64 length % 4 == 1
        let source = Data(("values = [\"" + Array(repeating: invalid, count: 20).joined(separator: "\",\"") + "\"]").utf8)
        let tools = try AIPluginReviewTools(snapshot: snapshot([("main.py", source)]), limits: .init(maximumBlobCandidates: 3))
        XCTAssertEqual(tools.statistics.blobCount, 0)
        XCTAssertEqual(tools.statistics.blobCandidates, 3)
        XCTAssertTrue(tools.statistics.blobLimitReached)
        XCTAssertLessThan(tools.statistics.blobScanBytes, source.count)
    }

    func testMultilineBase64IsDecodedWithinBudgetWithoutPerLineStringsInStorage() async throws {
        let encoded = blob.base64EncodedString()
        var source = ""
        var start = encoded.startIndex
        while start < encoded.endIndex {
            let end = encoded.index(start, offsetBy: 64, limitedBy: encoded.endIndex) ?? encoded.endIndex
            source += "# \"" + String(encoded[start ..< end]) + "\"\n"
            start = end
        }
        let tools = try AIPluginReviewTools(snapshot: snapshot([("main.py", Data(source.utf8))]), limits: .init(maximumLineIndexEntries: 2, maximumBlobCount: 1, maximumBlobBytes: 160))
        XCTAssertEqual(tools.statistics.blobCount, 1)
        XCTAssertEqual(tools.statistics.blobBytes, 160)
        XCTAssertEqual(tools.statistics.blobCandidates, 1)
        let decoded = try await tools.call("decode_base64", arguments: .object(["blob": .integer(0)]))
        XCTAssertTrue(decoded.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    func testLongUnicodeLineUsesBoundedScalarPrefixAndExcerpt() async throws {
        let source = Data(String(repeating: "👋", count: 4096).utf8)
        let tools = try AIPluginReviewTools(snapshot: snapshot([("main.py", source)]), limits: .init(maximumLineIndexEntries: 2, maximumBlobCount: 0, maximumExcerptBytes: 64))
        XCTAssertEqual(tools.statistics.sourceLines, 1)
        XCTAssertEqual(tools.statistics.lineIndexEntries, 0)
        XCTAssertEqual(tools.statistics.blobCandidates, 0)
        XCTAssertLessThanOrEqual(tools.statistics.excerptBytes, 64)
        let page = try await tools.call("read_source", arguments: .object([:]))
        XCTAssertTrue(page.contains("long line"))
        XCTAssertEqual(page.filter { $0 == "👋" }.count, 500)
        XCTAssertLessThan(page.utf16.count, 1300)
        let prompt = await tools.prompt(useTools: false)
        XCTAssertFalse(prompt.contains("�"))
        XCTAssertLessThan(prompt.utf8.count, 1024)
    }

    func testDisabledToolsBuildOnlyExcerptAndStopBeforeLaterInflation() async throws {
        let archive = zip([("first.py", Data(repeating: 10, count: 1024), newlineDeflate), ("invalid.py", Data(repeating: 10, count: 1024), Data([0xff]))])
        let limits = AIPluginReviewLimits(maximumInputBytes: 1024, maximumInflatedBytes: 2048, maximumEntryBytes: 1024, maximumExcerptBytes: 64)
        let input = snapshot([("source.zip", archive)])
        let tools = try AIPluginReviewTools(snapshot: input, mode: .sourceExcerpt, limits: limits)
        XCTAssertEqual(tools.statistics.processedEntries, 1)
        XCTAssertEqual(tools.statistics.inflatedBytes, 1024)
        XCTAssertEqual(tools.statistics.lineIndexEntries, 0)
        XCTAssertEqual(tools.statistics.blobCount, 0)
        XCTAssertEqual(tools.statistics.blobScanBytes, 0)
        XCTAssertEqual(tools.statistics.excerptBytes, 64)
        let prompt = await tools.prompt(useTools: false)
        XCTAssertTrue(prompt.contains("first.py"))
        XCTAssertFalse(prompt.contains("invalid.py"))
        XCTAssertThrowsError(try AIPluginReviewTools(snapshot: input, limits: limits)) { XCTAssertEqual($0 as? AIError, .invalidResponse) }
    }

    func testConstructionAndArchiveEnumerationCooperateWithCancellation() throws {
        var checks = 0
        let input = snapshot([("main.py", Data(repeating: 10, count: 32 * 1024))])
        XCTAssertThrowsError(try AIPluginReviewTools(snapshot: input, checkCancellation: {
            checks += 1
            if checks == 8 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 8)
        checks = 0
        let archive = zip([("main.py", Data(repeating: 10, count: 1024), newlineDeflate)])
        XCTAssertThrowsError(try AIReviewArchive.forEachEntry(archive, checkCancellation: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        }) { _ in XCTFail("Cancelled decoder delivered an entry"); return true }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testActualCancelledTaskCannotStartSnapshotProcessing() async {
        let input = snapshot([("main.py", inlineBlobs(4))])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AIPluginReviewTools(snapshot: input)
        }
        do { _ = try await task.value; XCTFail("A cancelled task built review state") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private var blob: Data { Data((0 ..< 160).map { UInt8($0) }) }
    private func inlineBlobs(_ count: Int) -> Data {
        Data(("payloads = [\"" + Array(repeating: blob.base64EncodedString(), count: count).joined(separator: "\",\"") + "\"]").utf8)
    }
    private func snapshot(_ files: [(String, Data)]) -> AIPluginReviewSnapshot {
        .init(descriptor: .init(id: "fixture", title: "Fixture"), revision: "fixture-revision", files: files.map { .init(name: $0.0, data: $0.1) })
    }

    /// Small in-memory ZIP fixtures. The optional compressed bytes are independent
    /// raw DEFLATE fixtures, or deliberately corrupt bytes for admission tests.
    private func zip(_ files: [(String, Data, Data?)]) -> Data {
        func words(_ values: [(Int, Int)]) -> Data {
            var data = Data()
            for (value, length) in values { for shift in 0 ..< length { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
            return data
        }
        var local = Data(), central = Data()
        for (name, plain, compressed) in files {
            let name = Data(name.utf8), stored = compressed ?? plain, method = compressed == nil ? 0 : 8
            let offset = local.count, crc = Int(AIReviewArchive.crc32(plain))
            local.append(words([(0x04034b50, 4), (20, 2), (0, 2), (method, 2), (0, 4), (crc, 4), (stored.count, 4), (plain.count, 4), (name.count, 2), (0, 2)]))
            local.append(name); local.append(stored)
            central.append(words([(0x02014b50, 4), (20, 2), (20, 2), (0, 2), (method, 2), (0, 4), (crc, 4), (stored.count, 4), (plain.count, 4), (name.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4)]))
            central.append(name)
        }
        let end = words([(0x06054b50, 4), (0, 4), (files.count, 2), (files.count, 2), (central.count, 4), (local.count, 4), (0, 2)])
        local.append(central); local.append(end)
        return local
    }
}
