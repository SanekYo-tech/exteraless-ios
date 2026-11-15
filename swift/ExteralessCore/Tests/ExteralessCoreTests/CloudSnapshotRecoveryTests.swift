import Foundation
import XCTest
@testable import ExteralessCore

private actor CloudRecoveryTransport: CloudKeyValueTransport {
    let backing = CloudFixtureTransport()
    private(set) var requests = 0
    func keys() async throws -> [String] { requests += 1; return try await backing.keys() }
    func get(_ keys: [String]) async throws -> [String: String] { requests += 1; return try await backing.get(keys) }
    func set(key: String, value: String) async throws { requests += 1; try await backing.set(key: key, value: value) }
    func remove(_ keys: [String]) async throws { requests += 1; try await backing.remove(keys) }
    func seedLegacy() async {
        await backing.seed(["neko_settings": "1", "neko_settings_updated_at": "7",
                            "neko_settings_0": #"{"nkmrcfg":{"showSeconds":true}}"#])
    }
}

/// Only the next read can block, for at most two seconds. A preview doing I/O on
/// MainActor cannot pass the responsiveness/cancellation fixture below.
private final class CloudRecoveryReadGate: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseRead = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var expired = false
    func arm() { lock.lock(); armed = true; entered = false; expired = false; lock.unlock() }
    func release() { releaseRead.signal() }
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func data(for key: String) throws -> Data? {
        lock.lock()
        let block = armed
        armed = false
        if block { entered = true }
        lock.unlock()
        if block, releaseRead.wait(timeout: .now() + 2) == .timedOut {
            lock.lock(); expired = true; lock.unlock()
            throw ClientSettingsError.secretStorageUnavailable
        }
        return nil
    }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretStorageUnavailable }
}

@MainActor final class CloudSnapshotRecoveryTests: XCTestCase {
    private func fixture(secrets: any ClientSecretStore = CloudFixtureSecrets()) throws -> (ClientSettings, URL) {
        let file = try cloudTemporaryDirectory().appendingPathComponent("settings.json")
        let settings = try ClientSettings(storageURL: file, secretStore: secrets)
        try settings.register(CloudFixture.definitions.filter { $0.key != "ai.services" }
            + [AIFeatures.servicesDefinition]
            + AppearanceFeatures.definitions.filter { $0.key == "appearance.showSeconds" })
        return (settings, file)
    }

    private func session(_ settings: ClientSettings, _ transport: CloudRecoveryTransport) throws -> CloudSyncSession {
        try CloudSyncSession(scope: CloudFixture.scope, settings: settings,
            remote: CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression),
            stateStorage: CloudFixtureStateStorage(), credentials: CloudFixtureSecrets(), appVersion: "fixture", clock: { CloudFixture.date })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Bounded recovery fixture did not reach its expected state")
        throw CloudError.timedOut
    }

    func testAndroidSessionFreshPreviewRecoversCASFailureAndExternalOverrideRemoval() async throws {
        let secrets = CloudFixtureSecrets()
        let (settings, file) = try fixture(secrets: secrets)
        let external = try ClientSettings(storageURL: file, secretStore: secrets)
        try external.register(settings.definitions())
        let transport = CloudRecoveryTransport()
        await transport.seedLegacy()
        let session = try session(settings, transport)
        defer { session.clear() }
        session.restoreAndroid = { plan, keys, admission in
            try admission.beginCommit()
            do { return try CloudLegacySettingsArchive.apply(plan, settings: settings, includeApiKeys: keys, credentials: secrets) }
            catch ClientSettingsError.concurrentModification { throw CloudError.settingsChanged }
        }
        let stale = try await session.previewAndroid()
        try external.applyPublic(["appearance.showSeconds": .bool(false)])
        let beforeRejectedApply = try Data(contentsOf: file)
        do { _ = try await session.restoreAndroid(stale); XCTFail("Stale presence must conflict") }
        catch { XCTAssertEqual(error as? CloudError, .settingsChanged) }
        XCTAssertEqual(try Data(contentsOf: file), beforeRejectedApply)
        XCTAssertEqual(settings.lastError, .concurrentModification)
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
        try external.applyPublic(["appearance.fixtureCount": .integer(19)], resetting: ["appearance.showSeconds"])
        let beforePreview = try Data(contentsOf: file)
        let fresh = try await session.previewAndroid()
        XCTAssertNil(fresh.expectedSettings.lastError)
        XCTAssertEqual(fresh.expectedSettings.values["appearance.fixtureCount"], .integer(19))
        XCTAssertFalse(fresh.expectedSettings.storedKeys.contains("appearance.showSeconds"))
        XCTAssertEqual(try Data(contentsOf: file), beforePreview)
        _ = try await session.restoreAndroid(fresh)
        XCTAssertTrue(settings.bool("appearance.showSeconds"))
        XCTAssertEqual(settings.integer("appearance.fixtureCount"), 19)
        XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, 1_800_000_000_000)
    }

    func testNativePreviewAndExportAlsoRefreshTheActualStore() async throws {
        let secrets = CloudFixtureSecrets()
        let (settings, file) = try fixture(secrets: secrets)
        let transport = CloudRecoveryTransport()
        let remote = CloudRemoteStore(owner: CloudFixture.owner, transport: transport, compression: CloudFixture.compression)
        let prepared = try CloudSettingsArchive.prepare(snapshot: settings.readSnapshot(), owner: CloudFixture.owner,
            appVersion: "fixture", includeApiKeys: false, credentials: secrets, date: CloudFixture.date)
        let revision = try await remote.publish(prepared.data, expectedHeads: [], date: CloudFixture.date)
        let old = settings.readSnapshot()
        let external = try ClientSettings(storageURL: file, secretStore: secrets)
        try external.register(settings.definitions())
        try external.applyPublic(["appearance.fixtureCount": .integer(9)])
        XCTAssertThrowsError(try settings.applyPublic(["appearance.fixtureCount": .integer(4)], expected: old))
        XCTAssertEqual(settings.lastError, .concurrentModification)
        try external.applyPublic(["appearance.fixtureFlag": .bool(false)], resetting: ["appearance.fixtureCount"])
        let session = try session(settings, transport)
        defer { session.clear() }
        let preview = try await session.preview(revision, expectedHeads: [revision.id])
        XCTAssertNil(preview.expectedSettings.lastError)
        XCTAssertFalse(preview.expectedSettings.storedKeys.contains("appearance.fixtureCount"))
        XCTAssertEqual(preview.expectedSettings.values["appearance.fixtureCount"], .integer(2))
        try external.applyPublic(["appearance.fixtureFlag": .bool(true), "appearance.fixtureCount": .integer(5)])
        _ = try await session.syncNow(acknowledging: [revision.id])
        let catalog = try await remote.catalog()
        let head = try XCTUnwrap(catalog.headRevisions.first)
        let bytes = try await remote.read(head)
        let envelope = try JSONDecoder().decode(CloudBackupEnvelope.self, from: bytes)
        let exported = try ToolsBackupArchive.inspect(envelope.archive, definitions: settings.definitions())
        XCTAssertEqual(exported.settings["appearance.fixtureFlag"], .bool(true))
        XCTAssertEqual(exported.settings["appearance.fixtureCount"], .integer(5))
    }

    func testReloadRejectsInvalidStoredShapeAndUnavailableKeychainBeforeAnyRemoteRequest() async throws {
        for unavailableKeychain in [false, true] {
            let secrets = CloudFixtureSecrets()
            let (settings, file) = try fixture(secrets: secrets)
            let validBytes = try Data(contentsOf: file)
            if unavailableKeychain {
                secrets.failReads(true)
            } else {
                var envelope = try JSONDecoder().decode([String: ClientSettingValue].self, from: validBytes)
                guard case var .object(values)? = envelope["values"] else { return XCTFail("Expected native settings envelope") }
                values["ai.services"] = .array([.object(["key": .string("not-public-metadata")])])
                envelope["values"] = .object(values)
                try JSONEncoder().encode(envelope).write(to: file, options: .atomic)
            }
            let failedBytes = try Data(contentsOf: file)
            do { _ = try await CloudSettingsArchive.readLatestSnapshot(settings: settings); XCTFail("A real load error must propagate") }
            catch { XCTAssertNotNil(error as? ClientSettingsError) }
            XCTAssertNotNil(settings.lastError)
            let transport = CloudRecoveryTransport()
            let session = try session(settings, transport)
            let revision = CloudRevision(version: 1, id: UUID(), parents: [], owner: CloudFixture.owner,
                createdAtMilliseconds: 1, encoding: CloudProtocol.encoding, chunks: 1, encodedCharacters: 4, sha256: String(repeating: "a", count: 64))
            for operation in 0..<3 {
                do {
                    switch operation {
                    case 0: _ = try await session.previewAndroid()
                    case 1: _ = try await session.preview(revision, expectedHeads: [revision.id])
                    default: _ = try await session.syncNow()
                    }
                    XCTFail("Unavailable settings must stay closed")
                } catch { XCTAssertEqual(error as? CloudError, .localStorage) }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(try Data(contentsOf: file), failedBytes)
            XCTAssertNotNil(settings.lastError)
            XCTAssertEqual(session.state.lastSuccessfulSyncMilliseconds, -1)
            if unavailableKeychain { secrets.failReads(false) }
            else { try validBytes.write(to: file, options: .atomic) }
            let recovered = try await CloudSettingsArchive.readLatestSnapshot(settings: settings)
            XCTAssertNil(recovered.lastError)
            session.clear()
        }
    }

    func testReloadDoesNotBlockMainActorAndCancellationStopsBeforeRemoteRead() async throws {
        let gate = CloudRecoveryReadGate()
        let (settings, _) = try fixture(secrets: gate)
        let transport = CloudRecoveryTransport()
        await transport.seedLegacy()
        let session = try session(settings, transport)
        defer { gate.release(); session.clear() }
        gate.arm()
        let first = Task { try await session.previewAndroid() }
        try await waitUntil { gate.isWaiting }
        // MainActor can run this release while the worker's Keychain read waits.
        gate.release()
        _ = try await first.value
        XCTAssertFalse(gate.timedOut)
        let beforeCancellation = await transport.requests
        gate.arm()
        let cancelled = Task { try await session.previewAndroid() }
        try await waitUntil { gate.isWaiting }
        session.clear()
        gate.release()
        do { _ = try await cancelled.value; XCTFail("Retired context must discard the reload result") }
        catch { XCTAssertTrue(error is CancellationError || (error as? CloudError) == .contextClosed) }
        XCTAssertFalse(gate.timedOut)
        let afterCancellation = await transport.requests
        XCTAssertEqual(afterCancellation, beforeCancellation)
        XCTAssertEqual(session.status, .closed)
    }

    func testPreparationErrorInvalidationDoesNotRearmAutomaticSync() async throws {
        let secrets = CloudFixtureSecrets()
        let (settings, _) = try fixture(secrets: secrets)
        try settings.applyPublic(["cloud.autoSync": .bool(true)])
        secrets.resetReads()
        secrets.failReads(true)
        let transport = CloudRecoveryTransport()
        let session = try session(settings, transport)
        let automatic = CloudAutoSync(settings: settings, session: session, sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        session.didChange = { [weak automatic] in automatic?.sessionDidChange() }
        defer { automatic.clear(); session.clear() }
        automatic.setForeground(true)
        try await waitUntil { session.status == .failed(.localStorage) }
        let reads = secrets.readKeys().count
        XCTAssertGreaterThan(reads, 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(secrets.readKeys().count, reads)
        let requests = await transport.requests
        XCTAssertEqual(requests, 0)
        XCTAssertNotNil(settings.lastError)
    }
}
