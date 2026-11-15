import Foundation
import XCTest
@testable import ExteralessCore

private actor CloudRepairRaceTransport: CloudKeyValueTransport {
    private var values: [String: String]
    private var onSecondListing: [String: String]?
    private var listings = 0
    private(set) var removals = 0
    init(values: [String: String], onSecondListing: [String: String]? = nil) {
        self.values = values; self.onSecondListing = onSecondListing
    }
    func keys() async throws -> [String] {
        listings += 1
        if listings == 2, let addition = onSecondListing { values.merge(addition) { _, new in new }; onSecondListing = nil }
        return Array(values.keys)
    }
    func get(_ keys: [String]) async throws -> [String: String] { values.filter { keys.contains($0.key) } }
    func set(key: String, value: String) async throws { values[key] = value }
    func remove(_ keys: [String]) async throws { removals += 1; for key in keys { values.removeValue(forKey: key) } }
    func snapshot() -> [String: String] { values }
}

final class CloudReviewRemediationTests: XCTestCase, @unchecked Sendable {
    private func revision(_ data: Data) -> CloudRevision {
        let count = data.base64EncodedString().utf8.count
        return CloudRevision(version: 1, id: UUID(), parents: [], owner: CloudFixture.owner,
            createdAtMilliseconds: 1, encoding: CloudProtocol.encoding, chunks: (count + 2_999) / 3_000,
            encodedCharacters: count, sha256: ToolsSHA256.hex(data))
    }

    private func plan(_ data: Data, target: ClientSettings) throws -> CloudRestorePlan {
        let revision = revision(data)
        return try CloudSettingsArchive.inspect(data, revision: revision, heads: [revision.id], owner: CloudFixture.owner, snapshot: target.readSnapshot())
    }

    private func cloudflareSettings(_ secrets: CloudFixtureSecrets) throws -> ClientSettings {
        let settings = try cloudSettings(secrets: secrets)
        try settings.register(AIFeatures.definitions.filter {
            ["ai.transcribeProvider", "ai.transcribeProviderCfAccountID", "ai.transcribeProviderCfApiToken"].contains($0.key)
        })
        try settings.applyPublic(["cloud.includeApiKeys": .bool(true)])
        return settings
    }

    func testToolsReceivesExactlyPreviewedPublicValuesAndPresence() throws {
        let target = try cloudSettings()
        try target.register(PrivacyFeatures.definitions.filter { $0.key == "privacy.botPrivacyUserId" })
        try target.applyPublic(["appearance.fixtureCount": .integer(9)])
        let payload = ToolsBackupPayload(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture",
            clientSettings: ["appearance.fixtureFlag": .bool(true), "appearance.fixtureCount": .integer(2), "privacy.botPrivacyUserId": .integer(999)],
            clientStoredKeys: ["appearance.fixtureFlag", "privacy.botPrivacyUserId"])
        let envelope = CloudBackupEnvelope(format: "exteraless.cloud-settings", version: 1, owner: CloudFixture.owner,
            archive: try ToolsBackupArchive.encode(payload), includesApiKeys: false, credentials: [], protection: "telegram-mtproto-transport")
        let preview = try plan(CloudProtocol.encode(envelope), target: target)
        try CloudPublicRestoreProjection.validate(preview.publicInspection)
        XCTAssertEqual(Set(preview.publicInspection.payload.clientSettings.keys), ["appearance.fixtureFlag", "appearance.fixtureCount"])
        XCTAssertEqual(preview.publicInspection.payload.clientStoredKeys, ["appearance.fixtureFlag"])
        XCTAssertTrue(preview.publicInspection.ignoredKeys.contains("privacy.botPrivacyUserId"))
        try target.applyPublic(["privacy.botPrivacyUserId": .integer(77)])
        let location = ToolsBackupPluginLocation(directory: try cloudTemporaryDirectory().appendingPathComponent("settings"), exportableFields: [:])
        let result = try ToolsBackupRestorer(beforeSettingsCommit: { try preview.verifyLocalPreview(settings: target) })
            .restore(preview.publicInspection, settings: .clientSettings(target), plugins: location)
        XCTAssertEqual(result.settings, preview.settingCount)
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(target.integer("appearance.fixtureCount"), 2)
        XCTAssertFalse(target.readSnapshot().storedKeys.contains("appearance.fixtureCount"))
        XCTAssertEqual(target.integer("privacy.botPrivacyUserId"), 77)
        XCTAssertTrue(target.readSnapshot().storedKeys.contains("privacy.botPrivacyUserId"))
    }

    func testRepairPreservesHealthyBackupBesideMalformedManifest() async throws {
        let base = CloudFixtureTransport()
        let original = CloudRemoteStore(owner: CloudFixture.owner, transport: base, compression: CloudFixture.compression)
        let healthy = try await original.publish(Data("healthy".utf8), expectedHeads: [], date: CloudFixture.date)
        let goodBytes = await base.snapshot()
        let bad = UUID()
        var input = goodBytes
        input[CloudProtocol.manifestKey(bad)] = "{broken"
        input[CloudProtocol.chunkKey(bad, 0)] = "abandoned"
        input["unrelated"] = "retained"
        let transport = CloudRepairRaceTransport(values: input)
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        try await remote.deleteDamagedNativeData()
        let result = await transport.snapshot()
        for (key, value) in goodBytes { XCTAssertEqual(result[key], value) }
        XCTAssertNil(result[CloudProtocol.manifestKey(bad)])
        XCTAssertNil(result[CloudProtocol.chunkKey(bad, 0)])
        XCTAssertEqual(result["unrelated"], "retained")
        let restored = try await remote.read(healthy)
        XCTAssertEqual(restored, Data("healthy".utf8))
    }

    func testRepairSecondListingCannotAdmitNewConcurrentRevision() async throws {
        let base = CloudFixtureTransport()
        let first = CloudRemoteStore(owner: CloudFixture.owner, transport: base, compression: CloudFixture.compression)
        _ = try await first.publish(Data("first".utf8), expectedHeads: [], date: CloudFixture.date)
        var input = await base.snapshot()
        input[CloudProtocol.manifestKey(UUID())] = "malformed"
        let other = CloudFixtureTransport()
        _ = try await CloudRemoteStore(owner: CloudFixture.owner, transport: other, compression: CloudFixture.compression)
            .publish(Data("concurrent".utf8), expectedHeads: [], date: CloudFixture.date)
        let addition = await other.snapshot()
        let transport = CloudRepairRaceTransport(values: input, onSecondListing: addition)
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        do { try await remote.deleteDamagedNativeData(); XCTFail("Changed captured set must invalidate repair") }
        catch { XCTAssertEqual(error as? CloudError, .conflict) }
        let result = await transport.snapshot()
        XCTAssertEqual(result, input.merging(addition) { _, new in new })
        let removals = await transport.removals
        XCTAssertEqual(removals, 0)
    }

    func testRepairRejectsNeededBrokenParentAndUnprovenOrphan() async throws {
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let parent = try await remote.publish(Data("parent".utf8), expectedHeads: [], date: CloudFixture.date)
        _ = try await remote.publish(Data("child".utf8), expectedHeads: [parent.id], date: CloudFixture.date)
        await transport.replace(key: CloudProtocol.manifestKey(parent.id), value: "malformed")
        let before = await transport.snapshot()
        do { try await remote.deleteDamagedNativeData(); XCTFail("A required parent cannot be deleted") }
        catch { XCTAssertEqual(error as? CloudError, .conflict) }
        let after = await transport.snapshot()
        XCTAssertEqual(after, before)
        let orphan = [CloudProtocol.chunkKey(UUID(), 0): "possibly-in-flight"]
        await transport.seed(orphan)
        do { try await remote.deleteDamagedNativeData(); XCTFail("Unknown uploader is not abandonment proof") }
        catch { XCTAssertEqual(error as? CloudError, .conflict) }
        let retained = await transport.snapshot()
        XCTAssertEqual(retained, orphan)
    }

    func testRepairCanRemoveOnlyItsOwnProvenFailedUploadChunks() async throws {
        let transport = CloudFixtureTransport()
        let orphan = [CloudProtocol.chunkKey(UUID(), 0): "other-uploader"]
        await transport.seed(orphan)
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        await transport.failWrite(at: 2)
        do { _ = try await remote.publish(Data(repeating: 65, count: 6_000), expectedHeads: []); XCTFail("Injected chunk failure") } catch {}
        try await remote.deleteDamagedNativeData()
        let remaining = await transport.snapshot()
        XCTAssertEqual(remaining, orphan)
    }

    func testCloudflareOptInRoundTripCarriesValidatedAccountAndBuildsSameRequestURL() throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudflareSettings(sourceSecrets)
        let account = String(repeating: "a", count: 32)
        try source.applyPublic(["ai.transcribeProvider": .integer(Int64(AITranscriptionProvider.workersAI.rawValue)), "ai.transcribeProviderCfAccountID": .string(account)])
        try source.set(.string("cf-source-fixture"), for: "ai.transcribeProviderCfApiToken")
        let prepared = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner, appVersion: "fixture", includeApiKeys: true, credentials: sourceSecrets)
        let envelope = try JSONDecoder().decode(CloudBackupEnvelope.self, from: prepared.data)
        let entry = try XCTUnwrap(envelope.credentials.first { $0.id == .translation(.cloudflareAudio) })
        XCTAssertEqual(entry.cloudflareAccountID, account)
        let publicArchive = try ToolsBackupArchive.inspect(envelope.archive, definitions: source.definitions())
        XCTAssertNil(publicArchive.payload.clientSettings["ai.transcribeProviderCfAccountID"])
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudflareSettings(targetSecrets)
        let preview = try plan(prepared.data, target: target)
        try CloudPublicRestoreProjection.validate(preview.publicInspection)
        _ = try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: true, credentials: targetSecrets)
        let audio = try AIWaveFile.encode(pcm: Data([0, 0]), sampleRate: 16_000)
        let before = try AITranscriptionRequest.build(audio: audio, configuration: AITranscriptionConfiguration(settings: AISettings(store: source)))
        let after = try AITranscriptionRequest.build(audio: audio, configuration: AITranscriptionConfiguration(settings: AISettings(store: target)))
        XCTAssertEqual(after.url, before.url)
        XCTAssertEqual(after.value(forHTTPHeaderField: "Authorization"), before.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(after.url?.path.contains("/accounts/" + account + "/") == true)
    }

    func testCloudflareOptOutAndExistingTargetPairArePreserved() throws {
        let secrets = CloudFixtureSecrets()
        let source = try cloudflareSettings(secrets)
        try source.applyPublic(["ai.transcribeProviderCfAccountID": .string(String(repeating: "a", count: 32))])
        try source.set(.string("incoming-cf-fixture"), for: "ai.transcribeProviderCfApiToken")
        secrets.resetReads()
        let off = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner, appVersion: "fixture", includeApiKeys: false, credentials: secrets)
        XCTAssertTrue(secrets.readKeys().isEmpty)
        let offEnvelope = try JSONDecoder().decode(CloudBackupEnvelope.self, from: off.data)
        XCTAssertTrue(offEnvelope.credentials.isEmpty)
        XCTAssertNil(try ToolsBackupArchive.inspect(offEnvelope.archive, definitions: source.definitions()).payload.clientSettings["ai.transcribeProviderCfAccountID"])
        let on = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner, appVersion: "fixture", includeApiKeys: true, credentials: secrets)
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudflareSettings(targetSecrets)
        let retainedAccount = String(repeating: "b", count: 32)
        try target.applyPublic(["ai.transcribeProviderCfAccountID": .string(retainedAccount)])
        try target.set(.string("existing-cf-fixture"), for: "ai.transcribeProviderCfApiToken")
        let preview = try plan(on.data, target: target)
        XCTAssertNil(preview.publicInspection.settings["ai.transcribeProviderCfAccountID"])
        _ = try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: true, credentials: targetSecrets)
        XCTAssertEqual(target.string("ai.transcribeProviderCfAccountID"), retainedAccount)
        XCTAssertEqual(target.string("ai.transcribeProviderCfApiToken"), "existing-cf-fixture")
    }

    func testCloudflareCredentialAppearingAfterPreviewRejectsAccountWrite() throws {
        let secrets = CloudFixtureSecrets()
        let source = try cloudflareSettings(secrets)
        try source.applyPublic(["ai.transcribeProviderCfAccountID": .string(String(repeating: "a", count: 32))])
        try source.set(.string("source-fixture"), for: "ai.transcribeProviderCfApiToken")
        let data = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner, appVersion: "fixture", includeApiKeys: true, credentials: secrets).data
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudflareSettings(targetSecrets)
        let preview = try plan(data, target: target)
        try target.set(.string("new-local-fixture"), for: "ai.transcribeProviderCfApiToken")
        XCTAssertThrowsError(try CloudSettingsArchive.apply(preview, settings: target, includeApiKeys: true, credentials: targetSecrets)) {
            XCTAssertEqual($0 as? CloudError, .settingsChanged)
        }
        XCTAssertEqual(target.string("ai.transcribeProviderCfAccountID"), "")
        XCTAssertEqual(target.string("ai.transcribeProviderCfApiToken"), "new-local-fixture")
    }

    func testCloudflareDoesNotRetargetAnExistingDestinationWithoutAToken() throws {
        let secrets = CloudFixtureSecrets()
        let source = try cloudflareSettings(secrets)
        try source.applyPublic(["ai.transcribeProviderCfAccountID": .string(String(repeating: "a", count: 32))])
        try source.set(.string("source-fixture"), for: "ai.transcribeProviderCfApiToken")
        let data = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner, appVersion: "fixture", includeApiKeys: true, credentials: secrets).data
        let target = try cloudflareSettings(CloudFixtureSecrets())
        let previous = String(repeating: "b", count: 32)
        try target.applyPublic(["ai.transcribeProviderCfAccountID": .string(previous)])
        XCTAssertThrowsError(try plan(data, target: target)) { XCTAssertEqual($0 as? CloudError, .credentialDestinationConflict) }
        XCTAssertEqual(target.string("ai.transcribeProviderCfAccountID"), previous)
        XCTAssertEqual(target.string("ai.transcribeProviderCfApiToken"), "")
    }
}
