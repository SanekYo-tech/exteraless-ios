import Foundation
import XCTest
@testable import ExteralessCore

private final class CloudCFPhaseProbe: CloudCredentialStorage, @unchecked Sendable {
    let backing: CloudFixtureSecrets
    private let lock = NSLock()
    private var readCount = 0
    private var insertionCount = 0
    init(_ backing: CloudFixtureSecrets) { self.backing = backing }
    func read(_ id: CloudCredentialID) throws -> String? {
        lock.lock(); readCount += 1; lock.unlock()
        return try backing.read(id)
    }
    func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult {
        lock.lock(); insertionCount += 1; lock.unlock()
        return try backing.insertIfAbsent(entry)
    }
    var calls: (reads: Int, insertions: Int) {
        lock.lock(); defer { lock.unlock() }
        return (readCount, insertionCount)
    }
}

final class CloudCloudflareAdmissionTests: XCTestCase {
    private let accountA = String(repeating: "a", count: 32)
    private let accountB = String(repeating: "b", count: 32)

    private func fixture(includeKeys: Bool, account: String? = nil, token: String? = nil) throws -> (ClientSettings, CloudFixtureSecrets, URL) {
        let file = try cloudTemporaryDirectory().appendingPathComponent("settings.json")
        let secrets = CloudFixtureSecrets()
        let settings = try ClientSettings(storageURL: file, secretStore: secrets)
        try settings.register(CloudFixture.definitions
            + AIFeatures.definitions.filter { ["ai.transcribeProviderCfAccountID", "ai.transcribeProviderCfApiToken"].contains($0.key) }
            + AppearanceFeatures.definitions.filter { $0.key == "appearance.showSeconds" })
        try settings.applyPublic(["cloud.includeApiKeys": .bool(includeKeys)])
        if let account { try settings.applyPublic([CloudCloudflareMetadata.accountKey: .string(account)]) }
        if let token { try settings.set(.string(token), for: CloudCloudflareMetadata.tokenKey) }
        return (settings, secrets, file)
    }

    private func sourceBackup() throws -> Data {
        let (source, secrets, _) = try fixture(includeKeys: true, account: accountA, token: "fixture-A")
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        return try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner,
            appVersion: "fixture", includeApiKeys: true, credentials: secrets).data
    }

    private func nativePlan(_ bytes: Data, settings: ClientSettings) throws -> CloudRestorePlan {
        let encodedCount = bytes.base64EncodedString().utf8.count
        let revision = CloudRevision(version: 1, id: UUID(), parents: [], owner: CloudFixture.owner, createdAtMilliseconds: 1,
            encoding: CloudProtocol.encoding, chunks: (encodedCount + 2_999) / 3_000,
            encodedCharacters: encodedCount, sha256: ToolsSHA256.hex(bytes))
        return try CloudSettingsArchive.inspect(bytes, revision: revision, heads: [revision.id],
            owner: CloudFixture.owner, snapshot: settings.readSnapshot())
    }

    private func publicHostPhase(_ inspection: ToolsBackupInspection, settings: ClientSettings,
                                 verify: @escaping @Sendable () throws -> Void) throws -> ToolsBackupRestoreResult {
        try CloudPublicRestoreProjection.validate(inspection)
        let location = ToolsBackupPluginLocation(directory: try cloudTemporaryDirectory().appendingPathComponent("settings"), exportableFields: [:])
        return try ToolsBackupRestorer(beforeSettingsCommit: verify).restore(inspection, settings: .clientSettings(settings), plugins: location)
    }

    func testNativeRetainPlanRejectsRemovedTokenBeforeCoreAndHostPublicApply() throws {
        let source = try sourceBackup()
        let (target, secrets, file) = try fixture(includeKeys: true, account: accountB, token: "fixture-B")
        let plan = try nativePlan(source, settings: target)
        XCTAssertNil(plan.publicInspection.settings[CloudCloudflareMetadata.accountKey])
        try target.reset(CloudCloudflareMetadata.tokenKey)
        let before = try Data(contentsOf: file)
        let probe = CloudCFPhaseProbe(secrets)
        XCTAssertThrowsError(try CloudSettingsArchive.apply(plan, settings: target, includeApiKeys: true, credentials: probe)) {
            XCTAssertEqual($0 as? CloudError, .settingsChanged)
        }
        XCTAssertThrowsError(try publicHostPhase(plan.publicInspection, settings: target, verify: {
            try plan.verifyCredentialTarget(includeApiKeys: true, storage: probe)
            try plan.verifyLocalPreview(settings: target)
        })) { XCTAssertEqual($0 as? CloudError, .settingsChanged) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(probe.calls.insertions, 0)
        XCTAssertEqual(target.string(CloudCloudflareMetadata.accountKey), accountB)
        XCTAssertNil(try secrets.read(.translation(.cloudflareAudio)))
    }

    func testNativeHostKeyPhaseDoesNotTurnRetainIntoAddAfterPublicCommit() throws {
        let (target, secrets, _) = try fixture(includeKeys: true, account: accountB, token: "fixture-B")
        let plan = try nativePlan(sourceBackup(), settings: target)
        let probe = CloudCFPhaseProbe(secrets)
        _ = try publicHostPhase(plan.publicInspection, settings: target, verify: {
            try plan.verifyCredentialTarget(includeApiKeys: true, storage: probe)
            try plan.verifyLocalPreview(settings: target)
        })
        try target.reset(CloudCloudflareMetadata.tokenKey) // Between the real host's two phases.
        XCTAssertThrowsError(try CloudSettingsArchive.restoreMissingCredentials(plan, settings: target, includeApiKeys: true, credentials: probe)) {
            XCTAssertEqual($0 as? CloudError, .restorePartiallyApplied)
        }
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(probe.calls.insertions, 0)
        XCTAssertEqual(target.string(CloudCloudflareMetadata.accountKey), accountB)
        XCTAssertNil(try secrets.read(.translation(.cloudflareAudio)))
    }

    func testLegacyCoreAndHostKeepCapturedRetainDecisionWhenTokenIsRemoved() throws {
        let (target, secrets, file) = try fixture(includeKeys: true, account: accountB, token: "fixture-B")
        let bytes = try CloudProtocol.encode(["nkmrcfg": ClientSettingValue.object([
            "showSeconds": .bool(true), "TranscribeProviderCfAccountID": .string(accountA), "TranscribeProviderCfApiToken": .string("fixture-A")
        ])])
        let remote = CloudLegacyRemoteSnapshot(owner: CloudFixture.owner, fingerprint: ToolsSHA256.hex(bytes), reportedUpdatedAtMilliseconds: 1, data: bytes)
        let plan = try CloudLegacySettingsArchive.inspect(remote, snapshot: target.readSnapshot(), includeApiKeys: true)
        let probe = CloudCFPhaseProbe(secrets)
        try target.reset(CloudCloudflareMetadata.tokenKey)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try CloudLegacySettingsArchive.apply(plan, settings: target, includeApiKeys: true, credentials: probe)) {
            XCTAssertEqual($0 as? CloudError, .settingsChanged)
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        try target.set(.string("independent-fixture-B"), for: CloudCloudflareMetadata.tokenKey)
        // A replacement that retains presence is not overwritten by the backup.
        _ = try publicHostPhase(plan.publicInspection, settings: target, verify: {
            try plan.verifyCredentialTarget(includeApiKeys: true, storage: probe)
            try plan.verifyLocalPreview(settings: target)
        })
        try target.reset(CloudCloudflareMetadata.tokenKey)
        XCTAssertThrowsError(try CloudLegacySettingsArchive.restoreMissingCredentials(plan, settings: target, includeApiKeys: true, credentials: probe)) {
            XCTAssertEqual($0 as? CloudError, .restorePartiallyApplied)
        }
        XCTAssertEqual(probe.calls.insertions, 0)
        XCTAssertEqual(target.string(CloudCloudflareMetadata.accountKey), accountB)
        XCTAssertNil(try secrets.read(.translation(.cloudflareAudio)))
    }

    func testNativeOptOutRestoresExactPublicProjectionWithZeroOptionalCredentialIO() throws {
        let (target, secrets, _) = try fixture(includeKeys: false)
        try target.applyPublic(["appearance.fixtureCount": .integer(9)])
        let plan = try nativePlan(sourceBackup(), settings: target)
        XCTAssertFalse(plan.includedApiKeys)
        XCTAssertEqual(plan.credentialCount, 0)
        XCTAssertNil(plan.publicInspection.payload.clientSettings[CloudCloudflareMetadata.accountKey])
        XCTAssertFalse(plan.publicInspection.resetting.contains(CloudCloudflareMetadata.accountKey))
        XCTAssertFalse(plan.publicInspection.admittedKeys.contains("cloud.includeApiKeys"))
        let beforePermissionPresence = target.readSnapshot().storedKeys.contains("cloud.includeApiKeys")
        let probe = CloudCFPhaseProbe(secrets)
        secrets.resetReads()
        let result = try publicHostPhase(plan.publicInspection, settings: target, verify: {
            try plan.verifyCredentialTarget(includeApiKeys: false, storage: probe)
            try plan.verifyLocalPreview(settings: target)
        })
        let keyResult = try CloudSettingsArchive.restoreMissingCredentials(plan, settings: target, includeApiKeys: false, credentials: probe)
        XCTAssertEqual(result.settings, plan.settingCount)
        XCTAssertEqual(keyResult.settings, plan.settingCount)
        XCTAssertEqual(keyResult.addedCredentials, 0)
        XCTAssertEqual(keyResult.retainedCredentials, 0)
        XCTAssertEqual(probe.calls.reads, 0)
        XCTAssertEqual(probe.calls.insertions, 0)
        XCTAssertTrue(secrets.readKeys().isEmpty)
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(target.integer("appearance.fixtureCount"), 2)
        XCTAssertFalse(target.readSnapshot().storedKeys.contains("appearance.fixtureCount"))
        XCTAssertEqual(target.string(CloudCloudflareMetadata.accountKey), "")
        XCTAssertEqual(target.string(CloudCloudflareMetadata.tokenKey), "")
        XCTAssertFalse(target.bool("cloud.includeApiKeys"))
        XCTAssertEqual(target.readSnapshot().storedKeys.contains("cloud.includeApiKeys"), beforePermissionPresence)
    }

    func testOptOutPreviewDoesNotGainCredentialPermissionAfterLocalEnablement() throws {
        let (target, secrets, _) = try fixture(includeKeys: false)
        let plan = try nativePlan(sourceBackup(), settings: target)
        try target.applyPublic(["cloud.includeApiKeys": .bool(true)])
        let probe = CloudCFPhaseProbe(secrets)
        let result = try CloudSettingsArchive.apply(plan, settings: target, includeApiKeys: true, credentials: probe)
        XCTAssertEqual(result.addedCredentials, 0)
        XCTAssertEqual(result.retainedCredentials, 0)
        XCTAssertEqual(probe.calls.reads, 0)
        XCTAssertEqual(probe.calls.insertions, 0)
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertTrue(target.bool("cloud.includeApiKeys"))
        XCTAssertEqual(target.string(CloudCloudflareMetadata.accountKey), "")
        XCTAssertEqual(target.string(CloudCloudflareMetadata.tokenKey), "")
    }

    func testRetainKeepsIndependentLocalReplacementWithoutInvokingInsertion() throws {
        let (target, secrets, _) = try fixture(includeKeys: true, account: accountB, token: "fixture-B")
        let plan = try nativePlan(sourceBackup(), settings: target)
        try target.set(.string("independent-native-fixture"), for: CloudCloudflareMetadata.tokenKey)
        let probe = CloudCFPhaseProbe(secrets)
        let result = try CloudSettingsArchive.apply(plan, settings: target, includeApiKeys: true, credentials: probe)
        XCTAssertEqual(result.addedCredentials, 0)
        XCTAssertEqual(result.retainedCredentials, 1)
        XCTAssertEqual(probe.calls.insertions, 0)
        XCTAssertEqual(target.string(CloudCloudflareMetadata.accountKey), accountB)
        XCTAssertEqual(target.string(CloudCloudflareMetadata.tokenKey), "independent-native-fixture")
    }
}
