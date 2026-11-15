import ExteralessCore
import Foundation
import PluginHost
import TelegramUI
import XCTest

private final class RecoveryFixtureEngine: CPythonEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var initializations = 0
    private var finalizations = 0
    var counts: (initialized: Int, finalized: Int) {
        lock.lock(); defer { lock.unlock() }
        return (initializations, finalizations)
    }
    var apiVersion: String { "native-recovery-fixture" }
    var isProcessInitialized: Bool { counts.initialized > counts.finalized }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        lock.lock(); initializations += 1; lock.unlock()
    }
    func finalizeProcess() throws { lock.lock(); finalizations += 1; lock.unlock() }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        throw PluginHostError.runtimeFailure("This fixture installs no plugins")
    }
    func destroyInterpreter(_ reference: InterpRef) throws { XCTFail("No plugin interpreter exists") }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        throw PluginHostError.runtimeFailure("No Python scripts may run in this fixture")
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
}

private struct RecoveryFixtureSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { XCTFail("No credentials in this fixture"); return nil }
    func set(_ data: Data?, for key: String) throws { XCTFail("No credentials in this fixture") }
}

@MainActor private final class NativeRecoveryFixture {
    let root: URL
    let directory: URL
    let clientFile: URL
    let pluginFile: URL
    let journalURL: URL
    let originalJournal: Data
    let settings: ClientSettings
    let engine = RecoveryFixtureEngine()
    let host: PluginHost
    let startup: PluginRuntimeStartupContinuation
    let restorer = ToolsBackupRestorer()
    let key = "tools.cameraStabilization"
    var accountGeneration = UUID()
    var hasAccount = true
    var recoveries = 0
    var preparations = 0
    var completions = 0

    init(root: URL) throws {
        self.root = root
        directory = root.appendingPathComponent("settings", isDirectory: true)
        clientFile = root.appendingPathComponent("client.json")
        pluginFile = directory.appendingPathComponent("probe.json")
        journalURL = root.appendingPathComponent("tools-settings-restore.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"native\":\"keep\"}".utf8).write(to: pluginFile)
        settings = try ClientSettings(storageURL: clientFile, secretStore: RecoveryFixtureSecrets())
        try settings.register([.init(key: key, title: "Fixture", section: "Fixture", defaultValue: .bool(false))])
        try settings.applyPublic([key: .bool(true)])
        originalJournal = try JSONSerialization.data(withJSONObject: [
            "version": 2, "transactionId": UUID().uuidString,
            "before": ["values": [key: false], "storedKeys": []] as [String: Any],
            "target": ["values": [key: true], "storedKeys": [key]] as [String: Any],
            "phase": "clientPending", "clientWrite": "uncertain",
        ])
        try originalJournal.write(to: journalURL)
        host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            queue: .init(dispatchTimeout: 1), storageDirectory: root, stopTimeout: 1))
        startup = PluginRuntimeStartupContinuation(host: host)
    }

    func run(scope: UUID? = nil) async throws {
        let scope = scope ?? accountGeneration
        try await startup.run(isCurrent: { self.hasAccount && self.accountGeneration == scope },
            policy: { .init(engineEnabled: true, safeMode: false) }, recoverBeforeStart: {
                self.recoveries += 1
                // The actual shipping Tools adapter, including its fresh-Host
                // lease and conservative Core recovery. No fabricated resume.
                try await ExteralessToolsHostMaintenance.recoverBeforeStart(
                    host: self.host, settingsDirectory: self.directory, settings: self.settings)
            }, prepare: { _ in self.preparations += 1 }, complete: { _ in self.completions += 1 })
    }

    func review() async throws -> ToolsBackupRecoveryInspection {
        let restorer = restorer, settings = settings
        let location = ToolsBackupPluginLocation(directory: directory, exportableFields: [:])
        let review = try await Task.detached {
            try restorer.inspectRecovery(settings: .clientSettings(settings), plugins: location)
        }.value
        return try XCTUnwrap(review)
    }

    func keepCurrent(_ review: ToolsBackupRecoveryInspection, retireAccount: Bool = false) async throws -> ToolsBackupReconciliationResult {
        let receipt = try XCTUnwrap(startup.captureMaintenance())
        let lease = try await ExteralessToolsHostMaintenance.begin(host: host, timeout: 1)
        let result: ToolsBackupReconciliationResult
        do {
            let restorer = restorer, settings = settings
            let location = ToolsBackupPluginLocation(directory: directory, exportableFields: [:])
            result = try await Task.detached {
                try restorer.reconcileKeepingCurrent(review, settings: .clientSettings(settings), plugins: location)
            }.value
        } catch {
            try await lease.finish(.needsRecovery)
            try startup.acknowledgeMaintenance(receipt, recovered: false)
            throw error
        }
        if retireAccount { hasAccount = false; accountGeneration = UUID() }
        try await lease.finish(.committed)
        try startup.acknowledgeMaintenance(receipt, recovered: true)
        return result
    }

    func shutdown() async { startup.retire(); await host.stop() }
}

final class RuntimeRecoveryContinuationTests: XCTestCase {
    private func fixture() async throws -> NativeRecoveryFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-runtime-recovery-\(UUID().uuidString)")
        let fixture = try await MainActor.run { try NativeRecoveryFixture(root: root) }
        addTeardownBlock { await fixture.shutdown(); try? FileManager.default.removeItem(at: root) }
        return fixture
    }

    func testRealKeepCurrentRetiresJournalAndStartsExistingHostOnce() async throws {
        let f = try await fixture()
        try await Task { @MainActor in
            let clientBefore = try Data(contentsOf: f.clientFile)
            let pluginBefore = try Data(contentsOf: f.pluginFile)
            do { try await f.run(); XCTFail("ambiguous journal must block cold launch") }
            catch { XCTAssertEqual(error as? ToolsError, .rollbackFailed) }
            XCTAssertEqual(f.startup.phase, .recoveryBlocked)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            let review = try await f.review()
            let result = try await f.keepCurrent(review)
            XCTAssertEqual(try Data(contentsOf: result.evidenceURL), f.originalJournal)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journalURL.path))
            XCTAssertFalse(f.host.isRunning) // Real fresh-Host lease is data-only.
            XCTAssertEqual(f.engine.counts.initialized, 0)
            try await f.run()
            try await f.run()
            XCTAssertTrue(f.startup.host === f.host)
            XCTAssertTrue(f.host.isRunning)
            XCTAssertEqual(f.startup.phase, .ready)
            XCTAssertNil(f.startup.failure)
            XCTAssertEqual(f.recoveries, 2)
            XCTAssertEqual(f.preparations, 1)
            XCTAssertEqual(f.completions, 1)
            XCTAssertEqual(f.engine.counts.initialized, 1)
            XCTAssertEqual(f.engine.counts.finalized, 0)
            XCTAssertEqual(try Data(contentsOf: f.clientFile), clientBefore)
            XCTAssertEqual(try Data(contentsOf: f.pluginFile), pluginBefore)
            // The already-started manager now performs normal nonterminal
            // maintenance; no second initialization is hidden in that resume.
            let managerLease = try await ExteralessToolsHostMaintenance.begin(host: f.host, timeout: 1)
            try await managerLease.finish(.committed)
            XCTAssertTrue(f.host.isRunning)
            XCTAssertEqual(f.engine.counts.initialized, 1)
            XCTAssertEqual(f.engine.counts.finalized, 0)
        }.value
    }

    func testFailedReviewAndAccountRetirementNeverInitializePython() async throws {
        let f = try await fixture()
        try await Task { @MainActor in
            do { try await f.run(); XCTFail("expected ambiguous journal") }
            catch { XCTAssertEqual(error as? ToolsError, .rollbackFailed) }
            let stale = try await f.review()
            try f.settings.applyPublic([f.key: .bool(false)]) // own native change after review
            do { _ = try await f.keepCurrent(stale); XCTFail("stale review cannot reconcile") }
            catch { XCTAssertEqual(error as? ToolsError, .rollbackFailed) }
            XCTAssertEqual(f.startup.phase, .recoveryBlocked)
            XCTAssertEqual(try Data(contentsOf: f.journalURL), f.originalJournal)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            XCTAssertEqual(f.preparations, 0)
            let scope = f.accountGeneration
            let fresh = try await f.review()
            _ = try await f.keepCurrent(fresh, retireAccount: true)
            do { try await f.run(scope: scope); XCTFail("retired Runtime account cannot start") }
            catch PluginHostError.superseded { }
            XCTAssertFalse(f.host.isRunning)
            XCTAssertFalse(f.startup.hasAttemptedStart)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            XCTAssertEqual(f.engine.counts.finalized, 0)
            XCTAssertEqual(f.completions, 0)
            XCTAssertFalse(f.settings.bool(f.key))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journalURL.path))
        }.value
    }
}
