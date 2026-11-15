import Foundation
import XCTest
@testable import ExteralessCore

private final class CloudFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CloudFixture.date
    private var intervals: [UInt64] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value.addTimeInterval(100); lock.unlock() }
    func recordSleep(_ value: UInt64) { lock.lock(); intervals.append(value); lock.unlock() }
    func sleepIntervals() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return intervals }
}

@MainActor final class CloudSyncLifecycleTests: XCTestCase {
    private func session(settings: ClientSettings, transport: CloudFixtureTransport,
                         storage: CloudFixtureStateStorage = CloudFixtureStateStorage(),
                         secrets: CloudFixtureSecrets = CloudFixtureSecrets(),
                         scope: CloudAccountScope = CloudFixture.scope, clock: CloudFixtureClock = CloudFixtureClock()) throws -> CloudSyncSession {
        try CloudSyncSession(scope: scope, settings: settings,
            remote: CloudRemoteStore(owner: scope.owner, transport: transport, compression: CloudFixture.compression),
            stateStorage: storage, credentials: secrets, appVersion: "fixture", clock: { clock.now() })
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Bounded fixture did not reach its expected state")
        throw CloudError.timedOut
    }

    func testDeduplicatedSyncAndUnchangedForegroundDoNotInventNewSuccessDates() async throws {
        let settings = try cloudSettings()
        let transport = CloudFixtureTransport()
        await transport.setWriteDelay(5_000_000)
        let clock = CloudFixtureClock()
        let session = try session(settings: settings, transport: transport, clock: clock)
        let first = Task { try await session.syncNow() }
        let second = Task { try await session.syncNow() }
        let results = try await [first.value, second.value]
        XCTAssertTrue(results.allSatisfy(\.uploaded))
        let catalog = try await session.loadCatalog()
        XCTAssertEqual(catalog.revisions.count, 1)
        let date = session.state.lastSuccessfulSyncMilliseconds
        XCTAssertEqual(date, 1_800_000_000_000)
        clock.advance()
        let unchanged = try await session.syncNow()
        XCTAssertFalse(unchanged.uploaded)
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, date)
        session.clear()
    }

    func testFailedRPCAndFailedStateWriteNeverRecordAttemptAsSuccess() async throws {
        let settings = try cloudSettings()
        let transport = CloudFixtureTransport()
        await transport.failKeyRequests(true)
        let storage = CloudFixtureStateStorage()
        let session = try session(settings: settings, transport: transport, storage: storage)
        do { _ = try await session.syncNow(); XCTFail("Injected RPC failure") } catch { XCTAssertEqual(error as? CloudError, .network) }
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        await transport.failKeyRequests(false)
        storage.failSaves(true)
        do { _ = try await session.syncNow(); XCTFail("Injected state failure") } catch { XCTAssertEqual(error as? CloudError, .localStorage) }
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        XCTAssertEqual(try storage.load(scope: CloudFixture.scope).lastSuccessfulSyncMilliseconds, -1)
        let catalog = try await session.loadCatalog()
        XCTAssertEqual(catalog.heads.count, 1) // Remote commit happened; do not claim a local receipt.
        session.clear()
    }

    func testAccountUnloadCancelsPendingUploadAndLateWorkCannotPublishToAnotherScope() async throws {
        let settings = try cloudSettings()
        let transport = CloudFixtureTransport()
        await transport.setWriteDelay(100_000_000)
        let storage = CloudFixtureStateStorage()
        let old = try session(settings: settings, transport: transport, storage: storage)
        let work = Task { () -> Bool in
            do { _ = try await old.syncNow(); return true } catch { return false }
        }
        try await waitUntil { await transport.calls().writes > 0 }
        old.clear()
        let succeeded = await work.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(old.status, .closed)
        let otherScope = CloudAccountScope(recordId: 43, userId: 4002, environment: .production)
        let next = try session(settings: settings, transport: CloudFixtureTransport(), storage: storage, scope: otherScope)
        XCTAssertEqual(next.state.lastSuccessfulSyncMilliseconds, -1)
        XCTAssertEqual(try storage.load(scope: CloudFixture.scope).lastSuccessfulSyncMilliseconds, -1)
        let writes = await transport.writes()
        XCTAssertFalse(writes.contains { $0.hasPrefix(CloudProtocol.nativePrefix + "r.") })
        next.clear()
    }

    func testAutoSyncRequiresOptInAndForegroundAndDebouncesChanges() async throws {
        let settings = try cloudSettings()
        let transport = CloudFixtureTransport()
        let session = try session(settings: settings, transport: transport)
        let clock = CloudFixtureClock()
        let scheduler = CloudAutoSync(settings: settings, session: session, sleep: { interval in
            clock.recordSleep(interval)
            try await Task.sleep(nanoseconds: 20_000_000)
        })
        session.didChange = { [weak scheduler] in scheduler?.sessionDidChange() }
        try settings.applyPublic(["appearance.fixtureFlag": .bool(true)])
        scheduler.setForeground(true)
        try await Task.sleep(nanoseconds: 30_000_000)
        let disabledCalls = await transport.calls()
        XCTAssertEqual(disabledCalls.keys, 0)
        scheduler.setForeground(false)
        try settings.applyPublic(["cloud.autoSync": .bool(true)])
        try await Task.sleep(nanoseconds: 30_000_000)
        let backgroundCalls = await transport.calls()
        XCTAssertEqual(backgroundCalls.keys, 0)
        scheduler.setForeground(true)
        for value in 0..<5 { try settings.applyPublic(["appearance.fixtureCount": .integer(Int64(value))]) }
        try await waitUntil { session.state.lastSuccessfulSyncMilliseconds > 0 }
        let catalog = try await session.loadCatalog()
        XCTAssertEqual(catalog.revisions.count, 1)
        XCTAssertTrue(clock.sleepIntervals().allSatisfy { $0 == 1_200_000_000 })
        XCTAssertFalse(clock.sleepIntervals().isEmpty)
        scheduler.clear()
        session.clear()
    }

    func testAutomaticFailureHasNoPollingLoopButARealForegroundEventCanRetry() async throws {
        let settings = try cloudSettings()
        try settings.applyPublic(["cloud.autoSync": .bool(true)])
        let transport = CloudFixtureTransport()
        await transport.failKeyRequests(true)
        let session = try session(settings: settings, transport: transport)
        let scheduler = CloudAutoSync(settings: settings, session: session, sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        session.didChange = { [weak scheduler] in scheduler?.sessionDidChange() }
        scheduler.setForeground(true)
        try await waitUntil { session.status == .failed(.network) }
        try await Task.sleep(nanoseconds: 40_000_000)
        let firstCalls = await transport.calls()
        XCTAssertEqual(firstCalls.keys, 1)
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        try await waitUntil { await transport.calls().keys == 2 }
        scheduler.clear()
        session.clear()
    }

    func testTurningOffKeyInclusionCancelsAnAlreadyPreparedManualUpload() async throws {
        let secrets = CloudFixtureSecrets()
        let settings = try cloudSettings(secrets: secrets)
        try CloudFixture.installBoundAssistantKey("fixture-key", settings: settings)
        try settings.applyPublic(["cloud.includeApiKeys": .bool(true)])
        let transport = CloudFixtureTransport()
        await transport.setWriteDelay(100_000_000)
        let session = try session(settings: settings, transport: transport, secrets: secrets)
        let scheduler = CloudAutoSync(settings: settings, session: session)
        let work = Task { () -> Bool in do { _ = try await session.syncNow(); return true } catch { return false } }
        try await waitUntil { await transport.calls().writes > 0 }
        try settings.applyPublic(["cloud.includeApiKeys": .bool(false)])
        let succeeded = await work.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        let writes = await transport.writes()
        XCTAssertFalse(writes.contains { $0.hasPrefix(CloudProtocol.nativePrefix + "r.") })
        scheduler.clear()
        session.clear()
    }

    func testMetadataRestartsAreScopedAndCannotCarryPayloadOrCredentials() throws {
        let root = try cloudTemporaryDirectory()
        let storage = try CloudFileStateStorage(directory: root)
        let state = CloudLocalState(scope: CloudFixture.scope, acceptedHeads: [UUID()], lastSuccessfulSyncMilliseconds: 1_800_000_000_000,
                                   uploadedContentDigest: String(repeating: "a", count: 64))
        try storage.save(state)
        let restarted = try CloudFileStateStorage(directory: root)
        XCTAssertEqual(try restarted.load(scope: CloudFixture.scope), state)
        let other = CloudAccountScope(recordId: 42, userId: 4001, environment: .test)
        XCTAssertEqual(try restarted.load(scope: other).lastSuccessfulSyncMilliseconds, -1)
        let data = try Data(contentsOf: root.appendingPathComponent(CloudFixture.scope.stateFileName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(Set(stored.keys), ["scope", "acceptedHeads", "lastSuccessfulSyncMilliseconds", "uploadedContentDigest"])
    }

    func testRestoreRecordsSuccessOnlyAfterActualPublicApplyAndKeyPhase() async throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudSettings(secrets: sourceSecrets)
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        let prepared = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner,
            appVersion: "fixture", includeApiKeys: false, credentials: sourceSecrets, date: CloudFixture.date)
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let revision = try await remote.publish(prepared.data, expectedHeads: [], date: CloudFixture.date)
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudSettings(secrets: targetSecrets)
        let session = try session(settings: target, transport: transport, secrets: targetSecrets)
        let plan = try await session.preview(revision, expectedHeads: [revision.id])
        session.restore = { plan, keys, admission in
            try admission.beginCommit()
            return try CloudSettingsArchive.apply(plan, settings: target, includeApiKeys: keys, credentials: targetSecrets)
        }
        _ = try await session.restore(plan)
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(session.state.acceptedHeads, [revision.id])
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, 1_800_000_000_000)
        session.clear()
    }

    func testFailedKeyRestoreDoesNotProduceASuccessDateAfterPublicCommit() async throws {
        let sourceSecrets = CloudFixtureSecrets()
        let source = try cloudSettings(secrets: sourceSecrets)
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        try CloudFixture.installBoundAssistantKey("restore-fixture-key", settings: source)
        let prepared = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner,
            appVersion: "fixture", includeApiKeys: true, credentials: sourceSecrets, date: CloudFixture.date)
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let revision = try await remote.publish(prepared.data, expectedHeads: [], date: CloudFixture.date)
        let targetSecrets = CloudFixtureSecrets()
        let target = try cloudSettings(secrets: targetSecrets)
        try target.applyPublic(["cloud.includeApiKeys": .bool(true)])
        let session = try session(settings: target, transport: transport, secrets: targetSecrets)
        let plan = try await session.preview(revision, expectedHeads: [revision.id])
        targetSecrets.failInserts(true)
        session.restore = { plan, keys, admission in
            try admission.beginCommit()
            return try CloudSettingsArchive.apply(plan, settings: target, includeApiKeys: keys, credentials: targetSecrets)
        }
        do { _ = try await session.restore(plan); XCTFail("Expected additive key phase failure") }
        catch { XCTAssertEqual(error as? CloudError, .restorePartiallyApplied) }
        XCTAssertTrue(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        session.clear()
    }

    func testWaitingForMaintenanceRemainsCancellableBeforeCommitAdmission() async throws {
        let source = try cloudSettings()
        try source.applyPublic(["appearance.fixtureFlag": .bool(true)])
        let prepared = try CloudSettingsArchive.prepare(snapshot: source.readSnapshot(), owner: CloudFixture.owner,
            appVersion: "fixture", includeApiKeys: false, credentials: CloudFixtureSecrets(), date: CloudFixture.date)
        let transport = CloudFixtureTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let revision = try await remote.publish(prepared.data, expectedHeads: [], date: CloudFixture.date)
        let target = try cloudSettings()
        let session = try session(settings: target, transport: transport)
        let plan = try await session.preview(revision, expectedHeads: [revision.id])
        session.restore = { plan, keys, admission in
            try await Task.sleep(nanoseconds: 100_000_000)
            try admission.beginCommit()
            return try CloudSettingsArchive.apply(plan, settings: target, includeApiKeys: keys, credentials: CloudFixtureSecrets())
        }
        let work = Task { () -> Bool in do { _ = try await session.restore(plan); return true } catch { return false } }
        try await waitUntil { session.status == .restoring }
        XCTAssertTrue(session.canCancel)
        session.cancel()
        let succeeded = await work.value
        XCTAssertFalse(succeeded)
        XCTAssertFalse(target.bool("appearance.fixtureFlag"))
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        session.clear()
    }

    func testAndroidRestoreRechecksFingerprintAndOnlyRecordsActualApplyTime() async throws {
        let settings = try cloudSettings()
        try settings.register(AppearanceFeatures.definitions.filter { $0.key == "appearance.showSeconds" })
        let transport = CloudFixtureTransport()
        await transport.seed(["neko_settings": "1", "neko_settings_updated_at": "7",
            "neko_settings_0": #"{"nkmrcfg":{"showSeconds":true}}"#])
        let session = try session(settings: settings, transport: transport)
        session.restoreAndroid = { plan, keys, admission in
            try admission.beginCommit()
            return try CloudLegacySettingsArchive.apply(plan, settings: settings, includeApiKeys: keys, credentials: CloudFixtureSecrets())
        }
        let stale = try await session.previewAndroid()
        await transport.replace(key: "neko_settings_0", value: #"{"nkmrcfg":{"showSeconds":false}}"#)
        do { _ = try await session.restoreAndroid(stale); XCTFail("Changed legacy payload must conflict") }
        catch { XCTAssertEqual(error as? CloudError, .conflict) }
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        let fresh = try await session.previewAndroid()
        _ = try await session.restoreAndroid(fresh)
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, 1_800_000_000_000)
        XCTAssertNotEqual(session.state.lastSuccessfulSyncMilliseconds, fresh.reportedUpdatedAtMilliseconds)
        XCTAssertTrue(session.state.acceptedHeads.isEmpty)
        let calls = await transport.calls()
        XCTAssertEqual(calls.writes, 0)
        session.clear()
    }

    func testSkippedOnlyAndroidArchiveDoesNotCreateASuccessReceipt() async throws {
        let settings = try cloudSettings()
        let transport = CloudFixtureTransport()
        await transport.seed(["neko_settings": "1", "neko_settings_0": #"{"nkmrcfg":{"DisableSystemAccount":true}}"#])
        let session = try session(settings: settings, transport: transport)
        session.restoreAndroid = { _, _, _ in XCTFail("Skipped-only preview must not acquire a restore lease"); throw CloudError.nothingToRestore }
        let plan = try await session.previewAndroid()
        XCTAssertEqual(plan.settingCount, 0)
        do { _ = try await session.restoreAndroid(plan); XCTFail("No-op restore must not claim success") }
        catch { XCTAssertEqual(error as? CloudError, .nothingToRestore) }
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        session.clear()
    }
}
