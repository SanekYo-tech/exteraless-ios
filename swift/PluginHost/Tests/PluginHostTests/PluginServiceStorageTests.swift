import Foundation
import XCTest
@testable import PluginHost

final class PluginServiceStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("service-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSettingsSurviveRecreationAndKeepNullDistinctFromMissing() throws {
        let root = try directory()
        let first = PluginServiceStorage(rootDirectory: root)
        let payload: PluginJSONValue = .object([
            "enabled": .bool(false), "name": .string("Тест 👋"),
            "items": .array([.null, .integer(Int64.max), .unsignedInteger(UInt64.max), .number(1.25)])
        ])
        try first.setSetting(pluginId: "alpha", key: "payload", value: payload)
        try first.setSetting(pluginId: "alpha", key: "nullable", value: .null)

        let second = PluginServiceStorage(rootDirectory: root)
        XCTAssertEqual(try second.getSetting(pluginId: "alpha", key: "payload", defaultValue: .null), payload)
        XCTAssertEqual(try second.getSetting(pluginId: "beta", key: "payload", defaultValue: .bool(true)), .bool(true))
        XCTAssertEqual(try second.getSetting(pluginId: "alpha", key: "nullable", defaultValue: .string("missing")), .null)
        XCTAssertTrue(try second.removeSetting(pluginId: "alpha", key: "nullable"))
        XCTAssertFalse(try second.removeSetting(pluginId: "alpha", key: "nullable"))
        XCTAssertEqual(try first.getSetting(pluginId: "alpha", key: "nullable", defaultValue: .string("missing")), .string("missing"))
        XCTAssertEqual(try second.getSetting(pluginId: "alpha", key: "payload", defaultValue: .null), payload)
        let files = try FileManager.default.contentsOfDirectory(atPath: second.settingsDirectory().path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.hasSuffix(".json"), true)
    }

    func testCorruptJSONIsNotOverwrittenBySetOrRemove() throws {
        let storage = PluginServiceStorage(rootDirectory: try directory())
        try storage.setSetting(pluginId: "alpha", key: "k", value: .null)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: storage.settingsDirectory(), includingPropertiesForKeys: nil).first)
        let corrupt = Data("{invalid json".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try storage.getSetting(pluginId: "alpha", key: "k", defaultValue: .null)) { error in
            XCTAssertEqual((error as? BridgeFailure)?.kind, "StorageError")
        }
        XCTAssertThrowsError(try storage.setSetting(pluginId: "alpha", key: "k", value: .bool(true)))
        XCTAssertThrowsError(try storage.removeSetting(pluginId: "alpha", key: "k"))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testPluginIDsCannotEscapeDirectories() throws {
        let root = try directory()
        let storage = PluginServiceStorage(rootDirectory: root)
        for id in ["../escape", "a/b", "a\\b", "/absolute", "..", "a.b", "", "9bad", "nul\0id"] {
            XCTAssertThrowsError(try storage.filesDirectory(pluginId: id))
            XCTAssertThrowsError(try storage.cacheDirectory(pluginId: id))
            XCTAssertThrowsError(try storage.setSetting(pluginId: id, key: "k", value: .null))
        }
        let files = try storage.filesDirectory(pluginId: "alpha")
        let cache = try storage.cacheDirectory(pluginId: "alpha")
        let plugins = try storage.pluginsDirectory()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(files.deletingLastPathComponent(), canonicalRoot.appendingPathComponent("files", isDirectory: true))
        XCTAssertEqual(cache.deletingLastPathComponent(), canonicalRoot.appendingPathComponent("cache", isDirectory: true))
        XCTAssertEqual(plugins, canonicalRoot.appendingPathComponent("plugins", isDirectory: true))
        XCTAssertNotEqual(files, try storage.filesDirectory(pluginId: "beta"))
    }

    func testCaseDistinctPluginIDsStayIsolatedOnCaseInsensitiveFilesystems() throws {
        let storage = PluginServiceStorage(rootDirectory: try directory())
        try storage.setSetting(pluginId: "Alpha", key: "k", value: .string("upper"))
        try storage.setSetting(pluginId: "alpha", key: "k", value: .string("lower"))
        XCTAssertEqual(try storage.getSetting(pluginId: "Alpha", key: "k", defaultValue: .null), .string("upper"))
        XCTAssertEqual(try storage.getSetting(pluginId: "alpha", key: "k", defaultValue: .null), .string("lower"))
        XCTAssertNotEqual(try storage.filesDirectory(pluginId: "Alpha").path.lowercased(),
                          try storage.filesDirectory(pluginId: "alpha").path.lowercased())
    }

    #if !os(Windows)
    func testSymlinkCannotRedirectAnOwnedDirectoryOrSettingsFile() throws {
        let root = try directory()
        let outside = try directory()
        let storage = PluginServiceStorage(rootDirectory: root)
        let files = try storage.filesDirectory(pluginId: "alpha")
        try FileManager.default.removeItem(at: files)
        try FileManager.default.createSymbolicLink(at: files, withDestinationURL: outside)
        XCTAssertThrowsError(try storage.filesDirectory(pluginId: "alpha")) { error in
            XCTAssertEqual((error as? BridgeFailure)?.kind, "SecurityError")
        }
        let outsideFile = outside.appendingPathComponent("keep.json")
        try Data("{}".utf8).write(to: outsideFile)
        try storage.setSetting(pluginId: "alpha", key: "k", value: .null)
        let settings = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: storage.settingsDirectory(), includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try storage.setSetting(pluginId: "alpha", key: "k", value: .bool(true)))
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("{}".utf8))
    }
    #endif

    func testConcurrentUpdatesDoNotLoseOtherKeys() throws {
        let storage = PluginServiceStorage(rootDirectory: try directory())
        let errors = Recorder<String>()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                try storage.setSetting(pluginId: "alpha", key: "k\(index)", value: .integer(Int64(index)))
            } catch {
                errors.append(String(describing: error))
            }
        }
        XCTAssertEqual(errors.values, [])
        for index in 0..<16 {
            XCTAssertEqual(try storage.getSetting(pluginId: "alpha", key: "k\(index)", defaultValue: .null), .integer(Int64(index)))
        }
    }

    func testFailedSerializationLeavesPreviousSettingsIntact() throws {
        let storage = PluginServiceStorage(rootDirectory: try directory())
        try storage.setSetting(pluginId: "alpha", key: "number", value: .integer(123))
        XCTAssertThrowsError(try storage.setSetting(pluginId: "alpha", key: "number", value: .number(.infinity)))
        XCTAssertEqual(try storage.getSetting(pluginId: "alpha", key: "number", defaultValue: .null), .integer(123))
        XCTAssertThrowsError(try PluginJSONValue(jsonObject: NSNumber(value: Double.nan)))
    }

    func testLogRingKeepsNewestEntriesInOrderAndBoundsUTF8() {
        let logs = PluginServiceLogBuffer(capacity: 3, maximumMessageBytes: 5)
        logs.append(pluginId: "alpha", message: "old")
        logs.append(pluginId: "beta", message: "second")
        logs.append(pluginId: "alpha", level: .warning, message: "🙂🙂🙂")
        let previous = logs.entries
        logs.append(pluginId: "alpha", level: .error, message: "last")
        XCTAssertEqual(previous.count, 3)
        XCTAssertEqual(previous.first?.message, "old")
        XCTAssertEqual(logs.entries.map(\.id), [2, 3, 4])
        XCTAssertEqual(logs.entries.map(\.message), ["secon", "🙂", "last"])
        XCTAssertEqual(logs.entries(pluginId: "alpha").count, 2)
        XCTAssertTrue(logs.entries.allSatisfy { $0.message.utf8.count <= 5 })
    }
}
