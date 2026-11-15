import Foundation
import XCTest
@testable import PluginHost

@MainActor private final class StartupContinuationFixture {
    let startup: PluginRuntimeStartupContinuation
    var accountGeneration = UUID()
    var hasAccount = true
    var policy = PluginRuntimeStartupContinuation.Policy(engineEnabled: true, safeMode: false)
    var ambiguous = true
    var recoveries = 0
    var preparations = 0
    var completions: [PluginRuntimeStartupContinuation.Started] = []
    var prepareEntered: OneShotResult<Void>?
    var prepareRelease: PluginLifecycleSignal<Void>?
    var policyAfterPreparation: PluginRuntimeStartupContinuation.Policy?

    init(host: PluginHost) { startup = PluginRuntimeStartupContinuation(host: host) }

    func run(scope: UUID? = nil) async throws {
        let scope = scope ?? accountGeneration
        try await startup.run(isCurrent: { self.hasAccount && self.accountGeneration == scope }, policy: { self.policy },
            recoverBeforeStart: {
                self.recoveries += 1
                let lease = try await self.startup.host.beginSettingsMaintenance(timeout: 1)
                do {
                    if self.ambiguous { throw PluginHostError.runtimeFailure("Ambiguous cold-start journal") }
                    try await lease.finish(resume: true)
                } catch {
                    try? await lease.finish(resume: false)
                    throw error
                }
            }, prepare: { _ in
                self.preparations += 1
                self.prepareEntered?.succeed(())
                if let release = self.prepareRelease {
                    _ = try await withDispatchTimeout(2) { try await release.wait(cancellable: false) }
                }
                if let policy = self.policyAfterPreparation { self.policy = policy }
            }, complete: { self.completions.append($0) })
    }

    func reconcile(recovered: Bool, beforeFinish: () -> Void = {}) async throws {
        let receipt = try XCTUnwrap(startup.captureMaintenance())
        let lease = try await startup.host.beginSettingsMaintenance(timeout: 1)
        beforeFinish()
        try await lease.finish(resume: recovered)
        if recovered { ambiguous = false }
        try startup.acknowledgeMaintenance(receipt, recovered: recovered)
    }

    func expectRecoveryBlock() async throws {
        do { try await run(); XCTFail("ambiguous journal must block startup") }
        catch PluginHostError.runtimeFailure { }
        XCTAssertEqual(startup.phase, .recoveryBlocked)
        XCTAssertNotNil(startup.failure)
        XCTAssertFalse(startup.host.isRunning)
        XCTAssertTrue(startup.host.isSettingsMaintenanceActive)
    }
}

private final class FailingStartupEngine: CPythonEngine, @unchecked Sendable {
    let entries = Recorder<String>()
    var apiVersion: String { "failing-startup-fixture" }
    var isProcessInitialized: Bool { false }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        entries.append("initialize")
        throw PluginHostError.runtimeFailure("fixture initialization failed")
    }
    func finalizeProcess() throws { entries.append("finalize") }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        throw PluginHostError.runtimeFailure("unexpected fixture interpreter")
    }
    func destroyInterpreter(_ reference: InterpRef) throws { entries.append("destroy") }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        throw PluginHostError.runtimeFailure("unexpected fixture Python entry")
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
}

final class PluginRuntimeStartupContinuationTests: HostLifecycleTestCase {
    func testOwnedRecoveryStartsTheSameHostAndRemainingStagesExactlyOnce() async throws {
        let f = try fixture()
        try await Task { @MainActor in
            let flow = StartupContinuationFixture(host: f.host)
            try await flow.expectRecoveryBlock()
            XCTAssertEqual(f.engine.counts.initialized, 0)
            try await flow.reconcile(recovered: true)
            XCTAssertFalse(f.host.isRunning) // wasRunning=false: actual lease did not start Python.
            XCTAssertFalse(f.host.isSettingsMaintenanceActive)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            let entered = OneShotResult<Void>()
            let release = PluginLifecycleSignal<Void>()
            defer { release.succeed(()) }
            flow.prepareEntered = entered
            flow.prepareRelease = release
            let first = Task { try await flow.run() }
            _ = try await maintenanceTestWait(entered)
            let second = Task { try await flow.run() }
            release.succeed(())
            try await first.value
            try await second.value
            try await flow.run()
            XCTAssertTrue(flow.startup.host === f.host)
            XCTAssertEqual(flow.startup.phase, .ready)
            XCTAssertNil(flow.startup.failure)
            XCTAssertTrue(f.host.isRunning)
            XCTAssertEqual(flow.recoveries, 2)
            XCTAssertEqual(flow.preparations, 1)
            XCTAssertEqual(flow.completions.count, 1)
            XCTAssertEqual(f.engine.counts.initialized, 1)
            XCTAssertEqual(f.engine.counts.finalized, 0)
            // Actual Host manager operations work after continuation, not merely
            // a Core flag permitting a future restore.
            let plugin = try await f.host.installPlugin(sourceURL: f.source("alpha"), metadata: Plugin(id: "alpha"))
            XCTAssertTrue(plugin.loaded, plugin.loadError ?? "plugin did not load")
            let settings = try await f.host.settingsJSON(id: "alpha", account: 0)
            XCTAssertEqual(settings, "[]")
            XCTAssertEqual(f.engine.counts.initialized, 1)
            XCTAssertEqual(f.engine.counts.created, 1)
        }.value
    }

    func testFailedReconciliationLeavesTheNeverInitializedHostBlocked() async throws {
        let f = try fixture()
        try await Task { @MainActor in
            let flow = StartupContinuationFixture(host: f.host)
            try await flow.expectRecoveryBlock()
            try await flow.reconcile(recovered: false)
            try await flow.expectRecoveryBlock()
            XCTAssertEqual(flow.recoveries, 1)
            XCTAssertEqual(flow.preparations, 0)
            XCTAssertTrue(flow.completions.isEmpty)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            XCTAssertEqual(f.engine.counts.finalized, 0)
        }.value
    }

    func testAccountRetirementDuringReconciliationCannotAuthorizeAStart() async throws {
        let f = try fixture()
        try await Task { @MainActor in
            let flow = StartupContinuationFixture(host: f.host)
            try await flow.expectRecoveryBlock()
            let scope = flow.accountGeneration
            try await flow.reconcile(recovered: true, beforeFinish: {
                flow.hasAccount = false
                flow.accountGeneration = UUID()
            })
            do { try await flow.run(scope: scope); XCTFail("retired account cannot initialize Python") }
            catch PluginHostError.superseded { }
            XCTAssertEqual(flow.startup.phase, .pendingRecovery)
            XCTAssertFalse(flow.startup.hasAttemptedStart)
            XCTAssertEqual(flow.preparations, 0)
            XCTAssertTrue(flow.completions.isEmpty)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            // Reusing a currently available account cannot revive the old scope.
            flow.hasAccount = true
            do { try await flow.run(scope: scope); XCTFail("old account generation must remain retired") }
            catch PluginHostError.superseded { }
            XCTAssertEqual(f.engine.counts.initialized, 0)
            XCTAssertEqual(f.engine.counts.finalized, 0)
        }.value
    }

    func testCurrentManagerPolicyIsRecheckedAfterPreparationWithoutRepeatingStages() async throws {
        let f = try fixture()
        try await Task { @MainActor in
            let flow = StartupContinuationFixture(host: f.host)
            try await flow.expectRecoveryBlock()
            try await flow.reconcile(recovered: true)
            flow.policy = .init(engineEnabled: false, safeMode: false)
            try await flow.run()
            XCTAssertEqual(flow.preparations, 0)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            flow.policy = .init(engineEnabled: true, safeMode: false)
            flow.policyAfterPreparation = .init(engineEnabled: false, safeMode: true)
            try await flow.run()
            XCTAssertEqual(flow.preparations, 1)
            XCTAssertFalse(flow.startup.hasAttemptedStart)
            XCTAssertEqual(f.engine.counts.initialized, 0)
            flow.policy = .init(engineEnabled: true, safeMode: true)
            try await flow.run()
            XCTAssertEqual(flow.completions.map(\.safeMode), [true])
            XCTAssertEqual(flow.preparations, 1)
            XCTAssertEqual(flow.recoveries, 2)
            XCTAssertTrue(f.host.isRunning)
            XCTAssertEqual(f.engine.counts.initialized, 1)
            XCTAssertEqual(f.engine.counts.created, 0)
            XCTAssertEqual(f.engine.counts.finalized, 0)
        }.value
    }

    func testForeignPrematureAndReplayedMaintenanceCannotUnlockOrReblockStartup() async throws {
        let f = try fixture(), other = try fixture()
        try await Task { @MainActor in
            let flow = StartupContinuationFixture(host: f.host)
            let foreign = StartupContinuationFixture(host: other.host)
            try await flow.expectRecoveryBlock()
            try await foreign.expectRecoveryBlock()
            let receipt = try XCTUnwrap(flow.startup.captureMaintenance())
            XCTAssertThrowsError(try foreign.startup.acknowledgeMaintenance(receipt, recovered: true))
            XCTAssertThrowsError(try flow.startup.acknowledgeMaintenance(receipt, recovered: true)) // real lease still closed
            XCTAssertEqual(flow.startup.phase, .recoveryBlocked)
            try await flow.reconcile(recovered: true)
            XCTAssertThrowsError(try flow.startup.acknowledgeMaintenance(receipt, recovered: false))
            XCTAssertEqual(flow.startup.phase, .pendingRecovery)
            try await flow.run()
            XCTAssertEqual(flow.startup.phase, .ready)
            XCTAssertEqual(f.engine.counts.initialized, 1)
            XCTAssertEqual(other.engine.counts.initialized, 0)
        }.value
    }

    func testOrdinaryStartFailureIsPublishedAndCannotBeRetriedAsRecovery() async throws {
        let root = tempDirectory("cold-start-failure")
        let engine = FailingStartupEngine()
        let host = try PluginHost(engine: engine, configuration: .init(storageDirectory: root))
        addTeardownBlock { await host.stop(); try? FileManager.default.removeItem(at: root) }
        try await Task { @MainActor in
            let flow = StartupContinuationFixture(host: host)
            try await flow.expectRecoveryBlock()
            try await flow.reconcile(recovered: true)
            for _ in 0..<2 {
                do { try await flow.run(); XCTFail("ordinary initialization must fail") }
                catch PluginHostError.runtimeFailure { }
            }
            XCTAssertEqual(flow.startup.phase, .failed)
            XCTAssertTrue(flow.startup.hasAttemptedStart)
            XCTAssertTrue(String(describing: flow.startup.failure).contains("fixture initialization failed"))
            XCTAssertNil(flow.startup.captureMaintenance())
            XCTAssertFalse(flow.startup.canContinue)
            XCTAssertTrue(flow.completions.isEmpty)
            XCTAssertEqual(flow.preparations, 1)
            XCTAssertEqual(engine.entries.values, ["initialize"])
        }.value
    }
}
