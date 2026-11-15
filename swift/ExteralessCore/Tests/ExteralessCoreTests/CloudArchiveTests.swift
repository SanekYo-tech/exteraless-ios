import Foundation
import XCTest
@testable import ExteralessCore

final class CloudArchiveTests: XCTestCase {
    private func revision(_ data: Data) -> CloudRevision {
        let count = data.base64EncodedString().utf8.count
        return CloudRevision(version: 1, id: UUID(), parents: [], owner: CloudFixture.owner,
            createdAtMilliseconds: 1_800_000_000_000, encoding: CloudProtocol.encoding,
            chunks: (count + 2_999) / 3_000, encodedCharacters: count, sha256: ToolsSHA256.hex(data))
    }

    private func prepare(_ settings: ClientSettings, secrets: CloudFixtureSecrets, keys: Bool = false) throws -> CloudPreparedBackup {
        try CloudSettingsArchive.prepare(snapshot: settings.readSnapshot(), owner: CloudFixture.owner,
            appVersion: "fixture", includeApiKeys: keys, credentials: secrets, date: CloudFixture.date)
    }

    private func plan(_ prepared: CloudPreparedBackup, target: ClientSettings) throws -> CloudRestorePlan {
        let revision = revision(prepared.data)
        return try CloudSettingsArchive.inspect(prepared.data, revision: revision, heads: [revision.id],
            owner: CloudFixture.owner, snapshot: target.readSnapshot())
    }

    func testKeysOffPerformsZeroKeychainReadsAndExcludesPrivateContent() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try cloudSettings(secrets: secrets)
        for key in ["ai.serviceKey.default", "ai.roles", "ai.history.fixture", "clientAPI.customAppHash"] {
            try settings.set(.string("private-fixture-only"), for: key)
        }
        secrets.resetReads()
        secrets.failReads(true)
        let prepared = try prepare(settings, secrets: secrets)
        XCTAssertTrue(secrets.readKeys().isEmpty)
        let envelope = try JSONDecoder().decode(CloudBackupEnvelope.self, from: prepared.data)
        XCTAssertFalse(envelope.includesApiKeys)
        XCTAssertTrue(envelope.credentials.isEmpty)
        let inspected = try ToolsBackupArchive.inspect(envelope.archive, definitions: settings.definitions(), secretKeys: settings.readSnapshot().secretKeys)
        XCTAssertFalse(inspected.payload.clientSettings.keys.contains { $0.hasPrefix("clientAPI.") || $0.hasPrefix("cloud.") })
        XCTAssertNil(inspected.payload.clientSettings["ai.roles"])
        XCTAssertNil(inspected.payload.clientSettings["ai.history.fixture"])
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("private-fixture-only"))
    }

    func testExplicitKeyExportReadsNativeWhitelistNotRedactedSnapshot() throws {
        let secrets = CloudFixtureSecrets()
        let settings = try cloudSettings(secrets: secrets)
        try CloudFixture.installBoundAssistantKey("assistant-fixture-key", settings: settings)
        let wholeProtectedValue = settings.string("ai.serviceKey.default")
        try settings.set(.string("deepl-fixture-key"), for: "ai.deepLTranslateKey")
        try settings.set(.string("never-cloud-role"), for: "ai.roles")
        try settings.set(.string("never-cloud-app-hash"), for: "clientAPI.customAppHash")
        XCTAssertEqual(settings.snapshot()["ai.serviceKey.default"], .null)
        secrets.resetReads()
        let prepared = try prepare(settings, secrets: secrets, keys: true)
        let envelope = try JSONDecoder().decode(CloudBackupEnvelope.self, from: prepared.data)
        XCTAssertEqual(Set(secrets.readKeys()), ["ai.deepLTranslateKey", "ai.serviceKey.default"])
        XCTAssertEqual(Set(envelope.credentials.map(\.id)), [.assistant(serviceId: "default"), .translation(.deepL)])
        XCTAssertTrue(envelope.credentials.contains { $0.withValue { $0 == wholeProtectedValue } })
        XCTAssertFalse(String(decoding: prepared.data, as: UTF8.self).contains("never-cloud"))
        XCTAssertFalse(String(describing: envelope).contains("assistant-fixture-key"))
        XCTAssertEqual(envelope.protection, "telegram-mtproto-transport")
        secrets.failReads(true)
        XCTAssertThrowsError(try prepare(settings, secrets: secrets, keys: true))
    }

    func testRestorePreservesAbsentOverridesAndUnrelatedNativeEdits() throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudSettings(secrets: sourceSecrets)
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        let prepared = try prepare(source, secrets: sourceSecrets)
        let target = try cloudSettings()
        try target.applyPublic(["appearance.fixtureCount": .integer(9)])
        try target.register([.init(key: "appearance.unrelated", title: "Other", section: "Appearance", defaultValue: .bool(false))])
        let preview = try plan(prepared, target: target)
        try target.applyPublic(["appearance.unrelated": .bool(true)])
        _ = try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: false, credentials: CloudFixtureSecrets())
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(target.integer("appearance.fixtureCount"), 2)
        XCTAssertFalse(target.readSnapshot().storedKeys.contains("appearance.fixtureCount"))
        XCTAssertTrue(target.bool("appearance.unrelated"))
    }

    func testEditedAffectedKeyRejectsPreviewBeforeCredentialImport() throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudSettings(secrets: sourceSecrets)
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        try CloudFixture.installBoundAssistantKey("cloud-fixture-key", settings: source)
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudSettings(secrets: targetSecrets)
        let preview = try plan(prepare(source, secrets: sourceSecrets, keys: true), target: target)
        try target.applyPublic(["appearance.fixtureCount": .integer(77)])
        XCTAssertThrowsError(try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: true, credentials: targetSecrets)) {
            XCTAssertEqual($0 as? CloudError, .settingsChanged)
        }
        XCTAssertFalse(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(target.integer("appearance.fixtureCount"), 77)
        XCTAssertNil(try targetSecrets.read(.assistant(serviceId: "default")))
    }

    func testRestoreOnlyAddsMissingServiceKeysAndRetainsConcurrentLocalKey() throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudSettings(secrets: sourceSecrets)
        try CloudFixture.installBoundAssistantKey("remote-assistant-fixture", settings: source)
        try source.set(.string("remote-deepl-fixture"), for: "ai.deepLTranslateKey")
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudSettings(secrets: targetSecrets)
        let preview = try plan(prepare(source, secrets: sourceSecrets, keys: true), target: target)
        try target.set(.string("new-local-fixture"), for: "ai.serviceKey.default")
        let result = try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: true, credentials: targetSecrets)
        XCTAssertEqual(result.addedCredentials, 1)
        XCTAssertEqual(result.retainedCredentials, 1)
        XCTAssertEqual(target.string("ai.serviceKey.default"), "new-local-fixture")
        XCTAssertEqual(AISettings(store: target).apiKey(for: .default), "") // Existing raw key remains unbound.
        XCTAssertEqual(target.string("ai.deepLTranslateKey"), "remote-deepl-fixture")
    }

    func testFailedOptionalKeyPhaseReportsPublicApplicationTruthfully() throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudSettings(secrets: sourceSecrets)
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        try CloudFixture.installBoundAssistantKey("remote-fixture", settings: source)
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudSettings(secrets: targetSecrets)
        let preview = try plan(prepare(source, secrets: sourceSecrets, keys: true), target: target)
        targetSecrets.failInserts(true)
        XCTAssertThrowsError(try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: true, credentials: targetSecrets)) {
            XCTAssertEqual($0 as? CloudError, .restorePartiallyApplied)
        }
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertNil(try targetSecrets.read(.assistant(serviceId: "default")))
    }

    func testUnregisteredAssistantCredentialAndWrongAccountCannotBeRestored() throws {
        let source = try cloudSettings()
        let prepared = try prepare(source, secrets: CloudFixtureSecrets())
        let envelope = try JSONDecoder().decode(CloudBackupEnvelope.self, from: prepared.data)
        let forged = CloudBackupEnvelope(format: envelope.format, version: envelope.version, owner: envelope.owner,
            archive: envelope.archive, includesApiKeys: true,
            credentials: [try CloudCredentialEntry(id: .assistant(serviceId: "unregistered"), value: "fixture")], protection: envelope.protection)
        let data = try CloudProtocol.encode(forged)
        let revision = revision(data)
        XCTAssertThrowsError(try CloudSettingsArchive.inspect(data, revision: revision, heads: [revision.id], owner: CloudFixture.owner, snapshot: source.readSnapshot())) {
            XCTAssertEqual($0 as? CloudError, .invalidCredential)
        }
        XCTAssertThrowsError(try CloudSettingsArchive.inspect(prepared.data, revision: revision, heads: [revision.id],
            owner: .init(userId: 9999, environment: .production), snapshot: source.readSnapshot())) {
            XCTAssertEqual($0 as? CloudError, .wrongAccount)
        }
    }

    func testSourcePortableServiceMetadataCannotSmuggleCredentialsInURLs() throws {
        let settings = try cloudSettings()
        let service = AIService(id: "fixture", url: "https://user:fixture-password@service.invalid/v1", model: "fixture")
        let value = try JSONDecoder().decode(ClientSettingValue.self, from: JSONEncoder().encode([service]))
        try settings.set(value, for: "ai.services")
        XCTAssertThrowsError(try prepare(settings, secrets: CloudFixtureSecrets()))
    }

    func testSharedToolsJournalHookRejectsAStaleCloudPreview() throws {
        let source = try cloudSettings()
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        let target = try cloudSettings()
        let preview = try plan(prepare(source, secrets: CloudFixtureSecrets()), target: target)
        try target.applyPublic(["appearance.fixtureCount": .integer(77)])
        let location = ToolsBackupPluginLocation(directory: try cloudTemporaryDirectory().appendingPathComponent("settings"), exportableFields: [:])
        let restorer = ToolsBackupRestorer(beforeSettingsCommit: { try preview.verifyLocalPreview(settings: target) })
        XCTAssertThrowsError(try restorer.restore(preview.publicInspection, settings: .clientSettings(target), plugins: location)) {
            XCTAssertEqual($0 as? CloudError, .settingsChanged)
        }
        XCTAssertFalse(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(target.integer("appearance.fixtureCount"), 77)
    }

    func testExplicitCloudAliasesDoNotAssignAGlobalLegacyDateToAnAccount() throws {
        let file = try cloudTemporaryDirectory().appendingPathComponent("settings.json")
        try JSONEncoder().encode(["auto_sync": ClientSettingValue.bool(true), "include_api_keys": .bool(false),
                                  "updated_at": .integer(1234)]).write(to: file)
        let settings = try ClientSettings(storageURL: file, secretStore: CloudFixtureSecrets())
        try NewCloudFeatures.migrateAndroidAliases(in: settings)
        XCTAssertTrue(settings.bool("cloud.autoSync"))
        XCTAssertFalse(settings.bool("cloud.includeApiKeys"))
        XCTAssertNil(settings.snapshot()["updated_at"])
        XCTAssertEqual(CloudLocalState(scope: CloudFixture.scope).lastSuccessfulSyncMilliseconds, -1)
    }
}
