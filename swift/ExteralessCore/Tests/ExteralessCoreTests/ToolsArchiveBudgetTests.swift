import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsArchiveBudgetTests: XCTestCase {
    func testTB06ExportStopsBeforeMaterializingNextFileWhenAggregateBudgetIsExhausted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-budget-" + UUID().uuidString)
        let directory = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<8).map { "file-\($0).json" }
        let bytes = try ToolsFileSafety.encode(["text": ClientSettingValue.string(String(repeating: "x", count: 128))])
        for path in paths { try bytes.write(to: directory.appendingPathComponent(path)) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func location(_ paths: [String]) throws -> ToolsBackupPluginLocation {
            try ToolsSchemaFixture.location(directory: directory, fields: Dictionary(uniqueKeysWithValues: paths.map { ($0, Set(["text"])) }))
        }
        let control = try ToolsBackupArchive.export(settings: [:], definitions: [], appVersion: "fixture", plugins: location(Array(paths.prefix(2))), date: date)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: control) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        let counter = Counter()
        let hooks = ToolsFileOperationHooks { point, _ in if case .afterSourceMetadata = point { counter.increment() } }
        let limits = ToolsBackupLimits(payloadBytes: payload.count + 32, archiveBytes: 2_048, pluginFileBytes: 256)
        XCTAssertThrowsError(try ToolsBackupArchive.export(settings: [:], definitions: [], appVersion: "fixture",
            plugins: location(paths), date: date, limits: limits, fileHooks: hooks)) { XCTAssertEqual($0 as? ToolsError, .sizeLimit) }
        XCTAssertEqual(counter.value, 2, "The third source JSON must not be read/materialized")
        XCTAssertEqual(try ToolsBackupArchive.inspect(control, definitions: []).pluginFileCount, 2)
    }

    func testTB06BoundedEncodingChargesEscapesAndStopsOversizedProgrammaticPayload() throws {
        var writer = ToolsBoundedJSONWriter(maximumBytes: 32)
        XCTAssertThrowsError(try writer.value(.string(String(repeating: "\"\n", count: 10))))
        XCTAssertLessThanOrEqual(writer.data.count, 32)
        let files = (0..<8).map { ToolsBackupPluginSettings(path: "file-\($0).json", values: ["text": .string(String(repeating: "x", count: 128))]) }
        let payload = ToolsBackupPayload(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture", clientSettings: [:], pluginSettings: files)
        XCTAssertThrowsError(try ToolsBackupArchive.encode(payload, limits: .init(payloadBytes: 512, archiveBytes: 1_024, pluginFileBytes: 256))) { XCTAssertEqual($0 as? ToolsError, .sizeLimit) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
