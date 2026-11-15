import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsRecoveryRegressionTests: XCTestCase {
    private let key = "tools.cameraStabilization"
    private var definitions: [ClientSettingDefinition] {
        [.init(key: key, title: "Fixture", section: "Fixture", defaultValue: .bool(false))]
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store(_ url: URL) throws -> ClientSettings {
        let store = try ClientSettings(storageURL: url, secretStore: NoSecrets())
        try store.register(definitions)
        return store
    }
    private func pending(_ root: URL) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 2, "transactionId": UUID().uuidString,
            "before": ["values": [key: false], "storedKeys": []],
            "target": ["values": [key: true], "storedKeys": [key]], "phase": "clientPending", "clientWrite": "uncertain"])
        try bytes.write(to: root.appendingPathComponent("tools-settings-restore.json"))
        return bytes
    }
    private func archive() throws -> ToolsBackupInspection {
        try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(.init(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture", clientSettings: [key: .bool(true)])), definitions: definitions)
    }

    func testTB01RealCoreNativeTargetBeforeAnyForwardCallRemainsStored() throws {
        let root = try root(), file = root.appendingPathComponent("client.json")
        let store = try store(file), writer = try self.store(file)
        let bytes = try pending(root)
        try writer.applyPublic([key: .bool(true)])
        let writes = Calls()
        let core = ToolsBackupSettingsAccess.clientSettings(store)
        let access = ToolsBackupSettingsAccess(snapshot: core.snapshot, applyAtomically: { values, resetting, expected in
            writes.increment()
            try core.applyAtomically(values, resetting, expected)
        })
        let location = ToolsBackupPluginLocation(directory: root.appendingPathComponent("settings"), exportableFields: [:])
        for _ in 0..<2 {
            XCTAssertThrowsError(try ToolsBackupRestorer().recover(settings: access, plugins: location)) { XCTAssertEqual($0 as? ToolsError, .rollbackFailed) }
        }
        XCTAssertEqual(writes.value, 0, "No forward or rollback write belongs to Tools in this history")
        try store.reload()
        XCTAssertTrue(store.bool(key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(key))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-restore.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.path))
    }

    func testTB01RealCoreRepeatedRecoveryAfterRollbackMarkerCrashPreservesNativeTarget() throws {
        let root = try root(), file = root.appendingPathComponent("client.json")
        let store = try store(file), writer = try self.store(file)
        let location = ToolsBackupPluginLocation(directory: root.appendingPathComponent("settings"), exportableFields: [:])
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterClientCommit = point { throw ToolsError.unavailable("Begin confirmed in-call rollback") }
            if case .beforeRollbackMarker = point { throw ToolsError.unavailable("Crash after rollback, before terminal marker") }
        })
        XCTAssertThrowsError(try restorer.restore(archive(), settings: .clientSettings(store), plugins: location))
        try store.reload()
        XCTAssertFalse(store.bool(key))
        XCTAssertFalse(store.readSnapshot().storedKeys.contains(key), "Control: the actual Core rollback completed")
        try writer.applyPublic([key: .bool(true)])
        let journal = root.appendingPathComponent("tools-settings-restore.json")
        let retained = try Data(contentsOf: journal)
        XCTAssertThrowsError(try ToolsBackupRestorer().recover(settings: .clientSettings(store), plugins: location))
        try store.reload()
        XCTAssertTrue(store.bool(key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(key))
        XCTAssertEqual(try Data(contentsOf: journal), retained)
    }

    func testTB01RealCorePostRenameFailureCannotBecomeRestartAuthorshipProof() throws {
        let root = try self.root(), file = root.appendingPathComponent("client.json"), fault = ArmedFault()
        let store = try ClientSettings(storageURL: file, secretStore: NoSecrets(), afterFileReplace: { try fault.check() })
        try store.register(definitions)
        fault.arm()
        let location = ToolsBackupPluginLocation(directory: root.appendingPathComponent("settings"), exportableFields: [:])
        XCTAssertThrowsError(try ToolsBackupRestorer().restore(archive(), settings: .clientSettings(store), plugins: location)) { XCTAssertEqual($0 as? ToolsError, .rollbackFailed) }
        let fresh = try self.store(file)
        XCTAssertTrue(fresh.bool(key), "Control: the real Core rename committed before the injected durability error")
        let journal = root.appendingPathComponent("tools-settings-restore.json"), bytes = try Data(contentsOf: journal)
        XCTAssertThrowsError(try ToolsBackupRestorer().recover(settings: .clientSettings(fresh), plugins: location))
        XCTAssertTrue(fresh.bool(key))
        XCTAssertTrue(fresh.readSnapshot().storedKeys.contains(key))
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testTB01AlreadyBeforeConfirmationUsesNoSetter() throws {
        let root = try self.root()
        _ = try pending(root)
        let definitions = self.definitions
        let reader: @Sendable () throws -> ToolsBackupSettingsSnapshot = {
            ToolsBackupSettingsSnapshot(definitions: definitions, values: [:], storedKeys: [])
        }
        let access = ToolsBackupSettingsAccess(snapshot: reader, readCurrent: reader, applyAtomically: { _, _, _ in XCTFail("Readonly confirmation must not invoke a setter") })
        try ToolsBackupRestorer().recover(settings: access, plugins: .init(directory: root.appendingPathComponent("settings"), exportableFields: [:]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testTB01ReconciliationRetainsEvidenceRejectsChangedReviewAndUnblocksNextRestore() throws {
        let root = try root(), file = root.appendingPathComponent("client.json")
        let store = try store(file)
        try store.applyPublic([key: .bool(true)])
        let bytes = try pending(root)
        let location = ToolsBackupPluginLocation(directory: root.appendingPathComponent("settings"), exportableFields: [:])
        let restorer = ToolsBackupRestorer()
        let review = try XCTUnwrap(restorer.inspectRecovery(settings: .clientSettings(store), plugins: location))
        XCTAssertFalse(review.observationIsFresh)
        try store.applyPublic([key: .bool(false)])
        XCTAssertThrowsError(try restorer.reconcileKeepingCurrent(review, settings: .clientSettings(store), plugins: location))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tools-settings-restore.json")), bytes)
        let updated = try XCTUnwrap(restorer.inspectRecovery(settings: .clientSettings(store), plugins: location))
        let result = try restorer.reconcileKeepingCurrent(updated, settings: .clientSettings(store), plugins: location)
        XCTAssertEqual(try Data(contentsOf: result.evidenceURL), bytes)
        XCTAssertFalse(store.bool(key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(key))
        _ = try restorer.restore(archive(), settings: .clientSettings(store), plugins: location)
        XCTAssertTrue(store.bool(key))
        XCTAssertEqual(try Data(contentsOf: result.evidenceURL), bytes)
    }

    #if canImport(Darwin)
    func testTB02PreSwapNativeExactTargetAndThirdImagesNeverBelongToTools() throws {
        for exactTarget in [true, false] {
            let root = try root(), directory = root.appendingPathComponent("settings")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let original = try ToolsFileSafety.encode(["style": ClientSettingValue.string("old")])
            let target = try ToolsFileSafety.encode(["style": ClientSettingValue.string(exactTarget ? "new" : "native-third")])
            for name in ["a.json", "b.json"] { try original.write(to: directory.appendingPathComponent(name)) }
            let store = try store(root.appendingPathComponent("client.json")), writes = Calls()
            let core = ToolsBackupSettingsAccess.clientSettings(store)
            let access = ToolsBackupSettingsAccess(snapshot: core.snapshot, applyAtomically: { values, resetting, expected in
                writes.increment(); try core.applyAtomically(values, resetting, expected)
            })
            let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(.init(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture", clientSettings: [key: .bool(true)],
                pluginSettings: ["a.json", "b.json"].map { .init(path: $0, values: ["style": .string("new")]) })), definitions: definitions)
            let restorer = ToolsBackupRestorer(fault: { point in
                if case .afterPrepared = point {
                    for name in ["a.json", "b.json"] { try target.write(to: directory.appendingPathComponent(name), options: .atomic) }
                }
            })
            let location = try ToolsSchemaFixture.location(directory: directory, fields: ["a.json": ["style"], "b.json": ["style"]])
            XCTAssertThrowsError(try restorer.restore(imported, settings: access, plugins: location)) {
                XCTAssertEqual($0 as? ToolsError, .rollbackFailed, "The actual lease outcome is needsRecovery")
            }
            XCTAssertEqual(writes.value, 0)
            let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("tools-settings-original-") })
            for name in ["a.json", "b.json"] {
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), target)
                XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(name)), original)
            }
        }
    }
    #endif

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private final class ArmedFault: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        func arm() { lock.lock(); armed = true; lock.unlock() }
        func check() throws {
            lock.lock(); let armed = armed; lock.unlock()
            if armed { throw ToolsBackupWriteFailure.durability("Self-owned fixture after Core rename") }
        }
    }
    private struct NoSecrets: ClientSecretStore {
        func data(for key: String) throws -> Data? { XCTFail("No credential reads in public fixtures"); return nil }
        func set(_ data: Data?, for key: String) throws { XCTFail("No credential writes in public fixtures") }
    }
}
