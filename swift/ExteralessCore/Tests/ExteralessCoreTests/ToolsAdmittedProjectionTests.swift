import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsAdmittedProjectionTests: XCTestCase {
    private let portable = ClientSettingDefinition(key: "tools.cameraStabilization", title: "Fixture", section: "Fixture",
        defaultValue: .bool(false), androidSymbols: ["ChatsConfig.cameraStabilization"])
    private let bot = ClientSettingDefinition(key: "privacy.botPrivacyUserId", title: "Bot", section: "Fixture",
        defaultValue: .integer(0), androidSymbols: ["GeneralConfig.botPrivacyUserId"])
    private let future = ClientSettingDefinition(key: "tools.futureFlag", title: "Later", section: "Fixture", defaultValue: .bool(false))

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-admitted-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func oldArchive(_ payload: ToolsBackupPayload, version: Int = 2) throws -> Data {
        // Deliberately builds an OLD input envelope. New encode() must refuse these managed keys.
        let bytes = try ToolsFileSafety.encode(payload)
        return try JSONSerialization.data(withJSONObject: ["format": "exteraless.settings", "version": version,
            "payload": bytes.base64EncodedString(), "sha256": ToolsSHA256.hex(bytes)])
    }

    func testCA01CloudExcludedBotAndNewDefinitionNeverReenterRealToolsWriteSet() throws {
        let root = try self.root(), file = root.appendingPathComponent("client.json"), secrets = Secrets([:])
        let store = try ClientSettings(storageURL: file, secretStore: secrets)
        try store.register([portable, bot])
        let payload = ToolsBackupPayload(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture",
            clientSettings: [portable.key: .bool(true), bot.key: .integer(123), future.key: .bool(false)],
            clientStoredKeys: [portable.key, bot.key])
        let cloudSnapshot = try CloudArchivePolicy.snapshot(store.readSnapshot())
        let preview = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload), definitions: cloudSnapshot.definitions)
        XCTAssertEqual(preview.admittedKeys, [portable.key])
        XCTAssertEqual(preview.settingCount, 1)
        try store.register([future])
        let writer = try ClientSettings(storageURL: file, secretStore: secrets)
        try writer.register([portable, bot, future])
        try writer.applyPublic([bot.key: .integer(999), future.key: .bool(false)])
        secrets.resetCounts()
        let result = try ToolsBackupRestorer().restore(preview, settings: .clientSettings(store),
            plugins: .init(directory: root.appendingPathComponent("settings"), exportableFields: [:]))
        XCTAssertEqual(result.settings, 1)
        XCTAssertTrue(store.bool(portable.key))
        XCTAssertEqual(store.integer(bot.key), 999)
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(bot.key))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains(future.key), "A newly registered absent-source key must not become a reset")
        XCTAssertEqual(secrets.counts.reads, 0)
        XCTAssertEqual(secrets.counts.writes, 0)
    }

    func testCA01ProjectionPreservesAdmittedSetterVersusResetAndReportsActualCounts() throws {
        let payload = ToolsBackupPayload(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture",
            clientSettings: [portable.key: .bool(false), future.key: .bool(true)], clientStoredKeys: [])
        let preview = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload), definitions: [portable])
        XCTAssertEqual(preview.resetting, [portable.key])
        let checked = try ToolsBackupArchive.revalidate(preview, definitions: [portable, future])
        XCTAssertEqual(checked.resetting, [portable.key])
        XCTAssertTrue(checked.settings.isEmpty)
        XCTAssertEqual(checked.payload.clientStoredKeys, [])
        XCTAssertEqual(Set(checked.payload.clientSettings.keys), [portable.key])
        XCTAssertEqual(checked.settingCount, preview.settingCount)
    }

    func testCA02GeneralExportAndOldArchivesPreserveLocalApiTuplePinsAndKeyPermission() throws {
        let rootA = try root(), rootB = try root()
        let hashA = try ToolsFileSafety.encode(ClientSettingValue.string(String(repeating: "a", count: 32)))
        let hashB = try ToolsFileSafety.encode(ClientSettingValue.string(String(repeating: "b", count: 32)))
        let secretsA = Secrets(["clientAPI.customAppHash": hashA, "clientAPI.accountIdentity.production.fixture": Data("pin-a".utf8)])
        let secretsB = Secrets(["clientAPI.customAppHash": hashB, "clientAPI.accountIdentity.production.fixture": Data("pin-b".utf8)])
        let auto = ClientSettingDefinition(key: "cloud.autoSync", title: "Sync", section: "Fixture", defaultValue: .bool(false))
        let include = ClientSettingDefinition(key: "cloud.includeApiKeys", title: "Native consent", section: "Fixture", defaultValue: .bool(false))
        let definitions = ClientAPIFeatures.definitions + [portable, auto, include]
        let local = try ClientSettings(storageURL: rootA.appendingPathComponent("client.json"), secretStore: secretsA)
        let source = try ClientSettings(storageURL: rootB.appendingPathComponent("client.json"), secretStore: secretsB)
        try local.register(definitions); try source.register(definitions)
        try local.applyPublic(["clientAPI.customApi": .integer(3), "clientAPI.customAppId": .integer(101), include.key: .bool(false)])
        try source.applyPublic(["clientAPI.customApi": .integer(3), "clientAPI.customAppId": .integer(202), include.key: .bool(true), auto.key: .bool(true)])
        let retained = secretsA.bytes
        secretsA.resetCounts(); secretsB.resetCounts()
        let exported = try ToolsBackupArchive.export(snapshot: source.readSnapshot(), appVersion: "fixture")
        let exportedInspection = try ToolsBackupArchive.inspect(exported, definitions: definitions)
        XCTAssertFalse(exportedInspection.payload.clientSettings.keys.contains { $0.hasPrefix("clientAPI.") })
        XCTAssertNil(exportedInspection.payload.clientSettings[include.key])
        XCTAssertEqual(secretsB.counts.reads, 0)
        for version in [1, 2] {
            let payload = ToolsBackupPayload(createdAt: "2026-11-15T00:00:00Z", appVersion: "old fixture",
                clientSettings: [portable.key: .bool(true), auto.key: .bool(true), include.key: .bool(true),
                    "clientAPI.customApi": .integer(3), "clientAPI.customAppId": .integer(202),
                    "clientAPI.customAppHash": .string(String(repeating: "b", count: 32))],
                clientStoredKeys: version == 1 ? nil : [portable.key, auto.key])
            XCTAssertThrowsError(try ToolsBackupArchive.encode(payload))
            let preview = try ToolsBackupArchive.inspect(oldArchive(payload, version: version), definitions: definitions)
            XCTAssertEqual(preview.admittedKeys, [portable.key, auto.key])
            let result = try ToolsBackupRestorer().restore(preview, settings: .clientSettings(local),
                plugins: .init(directory: rootA.appendingPathComponent("settings"), exportableFields: [:]))
            XCTAssertEqual(result.settings, 2)
            XCTAssertEqual(local.integer("clientAPI.customApi"), 3)
            XCTAssertEqual(local.integer("clientAPI.customAppId"), 101)
            XCTAssertTrue(local.readSnapshot().storedKeys.contains("clientAPI.customAppId"))
            XCTAssertFalse(local.bool(include.key))
            XCTAssertTrue(local.readSnapshot().storedKeys.contains(include.key))
            XCTAssertTrue(local.bool(auto.key))
        }
        XCTAssertEqual(secretsA.bytes, retained)
        XCTAssertEqual(secretsA.counts.reads, 0)
        XCTAssertEqual(secretsA.counts.writes, 0)
        XCTAssertTrue(try CloudCredentials.export(snapshot: local.readSnapshot(), includeApiKeys: local.bool(include.key), storage: NoCloudSecrets()).isEmpty)
        // There is no transport/account in this fixture or in the Tools restorer API.
    }

    func testCA02LegacyAliasesAreCheckedAtTheirCanonicalDestination() throws {
        let forbiddenAlias = ClientSettingDefinition(key: "clientAPI.cameraStabilization", title: "Alias fixture", section: "Fixture", defaultValue: .bool(false))
        let allowed = ClientSettingDefinition(key: "tools.staticZoom", title: "Allowed", section: "Fixture", defaultValue: .bool(false))
        let bytes = Data("{\"exteraconfig\":{\"cameraStabilization\":true,\"staticZoom\":true}}".utf8)
        let preview = try ToolsBackupArchive.inspect(bytes, definitions: [forbiddenAlias, allowed])
        XCTAssertEqual(preview.settings, [allowed.key: .bool(true)])
        for key in ["clientAPI.test.customAppId", "clientAPI.accountIdentity.production.1", "clientapi.mode", "cloud.includeApiKeys"] {
            XCTAssertFalse(ToolsBackupPolicy.isPortableClientKey(key))
        }
    }

    private final class Secrets: ClientSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data]
        private var reads = 0
        private var writes = 0
        init(_ values: [String: Data]) { self.values = values }
        func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; reads += 1; return values[key] }
        func set(_ data: Data?, for key: String) throws { lock.lock(); values[key] = data; writes += 1; lock.unlock() }
        func resetCounts() { lock.lock(); reads = 0; writes = 0; lock.unlock() }
        var bytes: [String: Data] { lock.lock(); defer { lock.unlock() }; return values }
        var counts: (reads: Int, writes: Int) { lock.lock(); defer { lock.unlock() }; return (reads, writes) }
    }
    private struct NoCloudSecrets: CloudCredentialStorage {
        func read(_ id: CloudCredentialID) throws -> String? { XCTFail("Key opt-out must remain in force"); return nil }
        func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult { XCTFail("General backup never restores service keys"); return .alreadyPresent }
    }
}
