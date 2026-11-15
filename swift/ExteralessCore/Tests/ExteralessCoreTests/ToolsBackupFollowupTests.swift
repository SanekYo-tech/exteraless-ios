import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsBackupFollowupTests: XCTestCase {
    private let key = "tools.cameraStabilization"
    private var definitions: [ClientSettingDefinition] {
        [.init(key: key, title: "Fixture", section: "Fixture", defaultValue: .bool(false))]
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-followup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store(_ root: URL) throws -> ClientSettings {
        let store = try ClientSettings(storageURL: root.appendingPathComponent("client.json"), secretStore: NoSecrets())
        try store.register(definitions)
        return store
    }
    private func inspection(plugin: Bool) throws -> ToolsBackupInspection {
        try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(.init(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture",
            clientSettings: [key: .bool(true)], pluginSettings: plugin ? [.init(path: "fixture.json", values: ["style": .string("new")])] : [])), definitions: definitions)
    }
    private static func transactionId(_ root: URL) throws -> String {
        let bytes = try Data(contentsOf: root.appendingPathComponent("tools-settings-restore.json"))
        struct Header: Decodable { let transactionId: UUID }
        return try JSONDecoder().decode(Header.self, from: bytes).transactionId.uuidString
    }
    private var original: Data { get throws { try ToolsFileSafety.encode(["style": ClientSettingValue.string("old"), "token": .string("local-only")]) } }
    private var target: Data { get throws { try ToolsFileSafety.encode(["style": ClientSettingValue.string("new"), "token": .string("local-only")]) } }
    private func prepare(_ root: URL) throws -> ToolsBackupPluginLocation {
        let directory = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try original.write(to: directory.appendingPathComponent("fixture.json"))
        return try ToolsSchemaFixture.location(directory: directory, fields: ["fixture.json": ["style"]])
    }

    func testTBF03ClientOnlyRestoreDoesNotOwnUuidNamedForeignDirectory() throws {
        let root = try self.root(), store = try self.store(root)
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterPrepared = point {
                let id = try Self.transactionId(root)
                for prefix in ["tools-settings-original-", "tools-settings-stage-"] {
                    let directory = root.appendingPathComponent(prefix + id)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    try Data([9]).write(to: directory.appendingPathComponent("foreign.bin"))
                }
            }
        })
        _ = try restorer.restore(inspection(plugin: false), settings: .clientSettings(store),
                                plugins: .init(directory: root.appendingPathComponent("settings"), exportableFields: [:]))
        let foreign = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix("tools-settings-original-") || $0.lastPathComponent.hasPrefix("tools-settings-stage-")
        }
        XCTAssertEqual(foreign.count, 2)
        for directory in foreign { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("foreign.bin")), Data([9])) }
        XCTAssertTrue(store.bool(key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
    }

    func testTBF03OldTerminalJournalsCannotInventScratchOwnership() throws {
        for version in [1, 2, 3] {
            let root = try self.root(), store = try self.store(root), id = UUID().uuidString
            for prefix in ["tools-settings-original-", "tools-settings-stage-"] {
                let folder = root.appendingPathComponent(prefix + id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try Data([9]).write(to: folder.appendingPathComponent("foreign.bin"))
            }
            var journal: [String: Any] = ["version": version, "transactionId": id]
            if version == 1 {
                journal["previousSettings"] = [String: Bool]()
                journal["includesPluginSettings"] = true
                journal["committed"] = true
            } else {
                let empty: [String: Any] = ["values": [String: Bool](), "storedKeys": [String]()]
                journal["before"] = empty
                journal["target"] = empty
                journal["originalFiles"] = [String: String]()
                journal["targetFiles"] = [String: String]()
                journal["phase"] = "committed"
                journal["clientWrite"] = "notAttempted"
            }
            let bytes = try JSONSerialization.data(withJSONObject: journal)
            let active = root.appendingPathComponent("tools-settings-restore.json")
            try bytes.write(to: active)
            let location = ToolsBackupPluginLocation(directory: root.appendingPathComponent("settings"), exportableFields: [:])
            try ToolsBackupRestorer().recover(settings: .clientSettings(store), plugins: location)
            for prefix in ["tools-settings-original-", "tools-settings-stage-"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(prefix + id).appendingPathComponent("foreign.bin")), Data([9]))
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-cleanup-debt-" + id + ".json")), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        }
    }

    #if canImport(Darwin)
    func testTBF01ChangedPreparedStageCannotBecomeLive() throws {
        for atomic in [false, true] {
            let root = try self.root(), store = try self.store(root), location = try prepare(root)
            let bad = try ToolsFileSafety.encode(["style": ClientSettingValue.bool(false)])
            let restorer = ToolsBackupRestorer(fault: { point in
                if case .afterPrepared = point {
                    let stage = root.appendingPathComponent("tools-settings-stage-" + (try Self.transactionId(root)))
                    try bad.write(to: stage.appendingPathComponent("fixture.json"), options: atomic ? .atomic : [])
                }
            })
            XCTAssertThrowsError(try restorer.restore(inspection(plugin: true), settings: .clientSettings(store), plugins: location)) { XCTAssertEqual($0 as? ToolsError, .rollbackFailed) }
            let id = try Self.transactionId(root)
            XCTAssertEqual(try Data(contentsOf: location.directory.appendingPathComponent("fixture.json")), try original)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-original-" + id).appendingPathComponent("fixture.json")), try original)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-stage-" + id).appendingPathComponent("fixture.json")), bad)
            XCTAssertFalse(store.bool(key))
            XCTAssertFalse(store.readSnapshot().storedKeys.contains(key))
            try assertNonterminal(root)
        }
    }

    func testTBF01ChangedBackupAfterClientRollbackCannotBecomeRestoredOriginal() throws {
        for atomic in [false, true] {
            let root = try self.root(), store = try self.store(root), location = try prepare(root)
            let bad = try ToolsFileSafety.encode(["style": ClientSettingValue.bool(false)])
            let restorer = ToolsBackupRestorer(fault: { point in
                if case .afterClientCommit = point { throw ToolsError.unavailable("Start a confirmed rollback") }
                if case .afterClientRollback = point {
                    let backup = root.appendingPathComponent("tools-settings-original-" + (try Self.transactionId(root)))
                    try bad.write(to: backup.appendingPathComponent("fixture.json"), options: atomic ? .atomic : [])
                }
            })
            XCTAssertThrowsError(try restorer.restore(inspection(plugin: true), settings: .clientSettings(store), plugins: location)) { XCTAssertEqual($0 as? ToolsError, .rollbackFailed) }
            let id = try Self.transactionId(root)
            XCTAssertFalse(store.bool(key), "The real client rollback reached the fault boundary")
            XCTAssertFalse(store.readSnapshot().storedKeys.contains(key))
            XCTAssertEqual(try Data(contentsOf: location.directory.appendingPathComponent("fixture.json")), try target)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-original-" + id).appendingPathComponent("fixture.json")), bad)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-stage-" + id).appendingPathComponent("fixture.json")), try original)
            try assertNonterminal(root)
        }
    }

    func testTBF03ForeignReplacementScratchSurvivesCleanupAndTerminalRetry() throws {
        let root = try self.root(), store = try self.store(root), location = try prepare(root)
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .beforeCommitMarker = point {
                let id = try Self.transactionId(root)
                for prefix in ["tools-settings-stage-", "tools-settings-original-"] {
                    let name = prefix + id
                    let directory = root.appendingPathComponent(name)
                    try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("moved-" + name))
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    try Data([9]).write(to: directory.appendingPathComponent("foreign.bin"))
                }
            }
        })
        _ = try restorer.restore(inspection(plugin: true), settings: .clientSettings(store), plugins: location)
        XCTAssertEqual(try Data(contentsOf: location.directory.appendingPathComponent("fixture.json")), try target)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let debt = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("tools-settings-cleanup-debt-") })
        let foreign = files.filter { $0.lastPathComponent.hasPrefix("tools-settings-stage-") || $0.lastPathComponent.hasPrefix("tools-settings-original-") }
        let moved = files.filter { $0.lastPathComponent.hasPrefix("moved-tools-settings-") }
        XCTAssertEqual(foreign.count, 2)
        XCTAssertEqual(moved.count, 2)
        for directory in foreign {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("foreign.bin")), Data([9]))
        }
        for directory in moved {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Held descriptors remove only our original entries")
        }
        let bytes = try Data(contentsOf: debt)
        try bytes.write(to: root.appendingPathComponent("tools-settings-restore.json"))
        try ToolsBackupRestorer().recover(settings: .clientSettings(store), plugins: location)
        XCTAssertEqual(try Data(contentsOf: debt), bytes)
        for directory in foreign {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("foreign.bin")), Data([9]))
        }
    }

    func testTBF03ForeignEntriesInsideOwnedScratchAreRetainedAsDebt() throws {
        for name in ["foreign.bin", "fixture.json"] {
            let root = try self.root(), store = try self.store(root), location = try prepare(root)
            let restorer = ToolsBackupRestorer(fault: { point in
                if case .beforeCommitMarker = point {
                    let stage = root.appendingPathComponent("tools-settings-stage-" + (try Self.transactionId(root)))
                    try Data([7]).write(to: stage.appendingPathComponent(name), options: .atomic)
                }
            })
            _ = try restorer.restore(inspection(plugin: true), settings: .clientSettings(store), plugins: location)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let stage = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("tools-settings-stage-") })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [name])
            XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(name)), Data([7]))
            XCTAssertTrue(files.contains { $0.lastPathComponent.hasPrefix("tools-settings-cleanup-debt-") })
            XCTAssertEqual(try Data(contentsOf: location.directory.appendingPathComponent("fixture.json")), try target)
        }
    }

    func testTBF01ConfirmedPreparedImagesStillCommitAndRollBackCleanly() throws {
        for rollBack in [false, true] {
            let root = try self.root(), store = try self.store(root), location = try prepare(root)
            let restorer = ToolsBackupRestorer(fault: { point in
                if rollBack, case .afterClientCommit = point { throw ToolsError.unavailable("Positive rollback control") }
            })
            if rollBack { XCTAssertThrowsError(try restorer.restore(inspection(plugin: true), settings: .clientSettings(store), plugins: location)) }
            else { _ = try restorer.restore(inspection(plugin: true), settings: .clientSettings(store), plugins: location) }
            let expected = try (rollBack ? original : target)
            XCTAssertEqual(try Data(contentsOf: location.directory.appendingPathComponent("fixture.json")), expected)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("tools-settings-") })
        }
    }

    private func assertNonterminal(_ root: URL) throws {
        struct Marker: Decodable { let version: Int; let phase: String }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: root.appendingPathComponent("tools-settings-restore.json")))
        XCTAssertEqual(marker.version, 4)
        XCTAssertEqual(marker.phase, "needsRecovery")
    }
    #endif

    private struct NoSecrets: ClientSecretStore {
        func data(for key: String) throws -> Data? { XCTFail("Public fixture must not read credentials"); return nil }
        func set(_ data: Data?, for key: String) throws { XCTFail("Public fixture must not write credentials") }
    }
}
