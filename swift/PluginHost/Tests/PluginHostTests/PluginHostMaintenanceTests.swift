import Foundation
import XCTest
@testable import PluginHost

final class PluginHostMaintenanceTests: HostLifecycleTestCase {
    func testDrainsAcceptedCallbacksAndResumesFreshOwnersWithOriginalEnabledFlags() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(101,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        try await load(f, "beta", enabled: false)
        let original = Dictionary(uniqueKeysWithValues: f.host.pluginList().map { ($0.id, $0.enabled) })
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let dispatcher = PluginCallbackDispatcher(host: f.host)
        XCTAssertTrue(dispatcher.callback(owner, 101, "run", "[]"))
        _ = try await maintenanceTestWait(entered)
        XCTAssertTrue(dispatcher.callback(owner, 102, "run", "[]"))
        XCTAssertTrue(dispatcher.release(owner, [101, 102]))
        let preparation = Task { try await f.host.beginSettingsMaintenance(timeout: 2) }
        let blocked = await waitUntil({ f.host.isSettingsMaintenanceActive }, timeout: 1)
        XCTAssertTrue(blocked)
        XCTAssertFalse(dispatcher.callback(owner, 103, "run", "[]"))
        XCTAssertEqual(engine.counts.destroyed, 0)
        gate.signal()
        let lease = try await preparation.value
        addTeardownBlock { try? await lease.finish(resume: false) }
        XCTAssertFalse(f.host.isRunning)
        XCTAssertNil(f.host.callbackOwner(id: "alpha"))
        XCTAssertEqual(engine.counts.live, 0)
        XCTAssertEqual(engine.counts.destroyed, 1)
        XCTAssertEqual(engine.counts.finalized, 0)
        let calls = engine.calls.map(\.source)
        let callback = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("_exteraless_runtime.invoke_handle_json(102,") })
        let release = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("_exteraless_runtime.release_handles_json(") })
        let unload = try XCTUnwrap(calls.firstIndex(of: "_exteraless_runtime.unload()"))
        XCTAssertLessThan(callback, release)
        XCTAssertLessThan(release, unload)
        // The fake Tools writer runs only after a lease was actually returned.
        try Data("restored".utf8).write(to: f.root.appendingPathComponent("settings-witness"), options: .atomic)
        try await lease.finish(resume: true)
        XCTAssertTrue(f.host.isRunning)
        XCTAssertFalse(f.host.isSettingsMaintenanceActive)
        let fresh = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        XCTAssertNotEqual(owner, fresh)
        XCTAssertNotEqual(owner.wireToken, fresh.wireToken)
        XCTAssertEqual(engine.counts.initialized, 1)
        XCTAssertEqual(engine.counts.finalized, 0)
        XCTAssertEqual(engine.counts.created, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: f.host.pluginList().map { ($0.id, $0.enabled) }), original)
        XCTAssertEqual(try PluginStore(directory: f.root).loadPlugins().first(where: { $0.id == "beta" })?.enabled, false)
        try await f.host.updateSetting(id: "alpha", key: "resumed", valueJSON: "true")
        let settings = try await f.host.settingsJSON(id: "alpha", account: 0)
        XCTAssertEqual(settings, "[]")
    }

    func testUnstartedHostMaintenanceDoesNotInitializePython() async throws {
        let f = try fixture()
        let lease = try await maintenance(f)
        XCTAssertEqual(f.engine.counts.initialized, 0)
        XCTAssertEqual(f.engine.counts.created, 0)
        try await lease.finish(resume: true)
        XCTAssertFalse(f.host.isRunning)
        XCTAssertEqual(f.engine.counts.initialized, 0)
        XCTAssertEqual(f.engine.counts.finalized, 0)
        try await f.host.start(safeMode: true)
        XCTAssertEqual(f.engine.counts.initialized, 1)
    }

    func testPendingMetadataInspectionDrainsBeforeAFileLease() async throws {
        let blockCreation = MaintenanceTestFlag(false)
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onCreate: {
            if blockCreation.value {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
        })
        let f = try fixture(engine: engine)
        try await load(f)
        blockCreation.set(true)
        let inspection = Task { try await f.host.readPluginMetadata(sourceURL: f.source("beta")) }
        _ = try await maintenanceTestWait(entered)
        let preparation = Task { try await f.host.beginSettingsMaintenance(timeout: 2) }
        let preparing = await waitUntil({ f.host.isSettingsMaintenanceActive }, timeout: 1)
        XCTAssertTrue(preparing)
        XCTAssertEqual(engine.counts.destroyed, 0)
        blockCreation.set(false)
        gate.signal()
        let metadata = try await inspection.value
        XCTAssertEqual(metadata.id, "beta")
        let lease = try await preparation.value
        addTeardownBlock { try? await lease.finish(resume: false) }
        XCTAssertEqual(engine.counts.live, 0)
        XCTAssertEqual(engine.counts.created, 2)
        XCTAssertEqual(engine.counts.destroyed, 2)
        XCTAssertEqual(f.host.pluginList().map(\.id), ["alpha"])
        try await lease.finish(resume: true)
        XCTAssertEqual(engine.counts.initialized, 1)
        XCTAssertEqual(engine.counts.created, 3)
    }

    func testResumeStartupEffectsUseFreshWireTokenButRetirementEffectsStayDenied() async throws {
        let box = MaintenanceTestHostBox()
        let tokens = Recorder<PluginHost.CallbackOwner>()
        let startupEffects = Recorder<Bool>()
        let startupMaintenance = Recorder<Bool>()
        let retirementEffects = Recorder<Bool>()
        let engine = MaintenanceTestEngine(onScript: { _, source in
            guard let host = box.get() else { return nil }
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                guard let owner = host.callbackOwner(id: "alpha") else {
                    throw PluginHostError.runtimeFailure("startup owner missing")
                }
                tokens.append(owner)
                startupEffects.append(host.bridge.effectOwnerValidator?("alpha", owner.wireToken) ?? false)
                startupMaintenance.append(host.isSettingsMaintenanceActive)
            } else if source == "_exteraless_runtime.unload()", let owner = tokens.values.last {
                retirementEffects.append(host.bridge.effectOwnerValidator?("alpha", owner.wireToken) ?? true)
            }
            return nil
        })
        let f = try fixture(engine: engine)
        box.set(f.host)
        try await load(f)
        let lease = try await maintenance(f)
        XCTAssertEqual(retirementEffects.values, [false])
        try await lease.finish(resume: true)
        XCTAssertEqual(startupEffects.values, [true, true])
        XCTAssertEqual(startupMaintenance.values, [false, false])
        XCTAssertEqual(tokens.count, 2)
        XCTAssertNotEqual(tokens.values.first, tokens.values.last)
    }

    func testRecoveryOutcomeKeepsAdmissionClosedAndRetryRetainsOriginalSnapshot() async throws {
        let f = try fixture()
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let first = try await maintenance(f)
        try await first.finish(resume: false)
        XCTAssertTrue(f.host.isSettingsMaintenanceActive)
        XCTAssertFalse(f.host.isRunning)
        do {
            try await f.host.reloadPlugin(id: "alpha")
            XCTFail("recovery must keep admission closed")
        } catch PluginHostError.runtimeFailure {
        }
        let second = try await maintenance(f)
        do {
            try await first.finish(resume: true)
            XCTFail("an old lease cannot resume a new attempt")
        } catch PluginHostError.superseded {
        }
        XCTAssertNil(f.host.callbackOwner(id: "alpha"))
        try await second.finish(resume: true)
        XCTAssertNotEqual(f.host.callbackOwner(id: "alpha"), owner)
        XCTAssertTrue(f.host.pluginList().first?.loaded == true)
        XCTAssertTrue(f.host.pluginList().first?.enabled == true)
        XCTAssertEqual(f.engine.counts.initialized, 1)
        XCTAssertEqual(f.engine.counts.created, 2)
    }

    func testResumeRetriesOriginalEnabledSetWhilePreservingSafeMode() async throws {
        for safeMode in [false, true] {
            let badSetting = MaintenanceTestFlag()
            let engine = MaintenanceTestEngine(onScript: { _, source in
                if source.hasPrefix("_exteraless_runtime.load_json("), badSetting.value {
                    throw PluginHostError.runtimeFailure("fixture setting prevents startup")
                }
                return nil
            })
            let f = try fixture(engine: engine)
            try await f.host.start(safeMode: safeMode)
            let failed = try await f.host.installPlugin(sourceURL: f.source("alpha"), metadata: Plugin(id: "alpha"))
            XCTAssertTrue(failed.enabled)
            XCTAssertFalse(failed.loaded)
            let lease = try await maintenance(f)
            badSetting.set(false) // The caller has restored its setting under the lease.
            try await lease.finish(resume: true)
            XCTAssertTrue(f.host.pluginList().first?.enabled == true)
            XCTAssertEqual(f.host.pluginList().first?.loaded, !safeMode)
            XCTAssertEqual(engine.counts.created, safeMode ? 1 : 2)
            XCTAssertEqual(engine.counts.initialized, 1)
            XCTAssertEqual(engine.counts.finalized, 0)
        }
    }

    func testFailedDestructionNeverReturnsAFileMutationLeaseOrFinalizes() async throws {
        let engine = MaintenanceTestEngine(onDestroy: { _ in
            throw PluginHostError.runtimeFailure("fixture destruction failed")
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let witness = f.root.appendingPathComponent("settings-witness")
        try Data("original".utf8).write(to: witness)
        do {
            let lease = try await f.host.beginSettingsMaintenance(timeout: 2)
            addTeardownBlock { try? await lease.finish(resume: false) }
            try Data("unexpected Tools write".utf8).write(to: witness)
            XCTFail("a retained/abandoned native interpreter is not quiescence")
        } catch PluginHostError.runtimeFailure {
        }
        XCTAssertEqual(try Data(contentsOf: witness), Data("original".utf8))
        XCTAssertTrue(f.host.isSettingsMaintenanceActive)
        XCTAssertNil(f.host.callbackOwner(id: "alpha"))
        XCTAssertEqual(engine.counts.finalized, 0)
        XCTAssertEqual(engine.counts.destroyed, 0)
        do {
            let unexpected = try await f.host.beginSettingsMaintenance(timeout: 1)
            addTeardownBlock { try? await unexpected.finish(resume: false) }
            XCTFail("abandoned interpreter must still prevent a retry from claiming quiescence")
        } catch PluginHostError.runtimeFailure {
        }
    }

    func testTimedOutDestructionKeepsItsWorkerTrackedUntilExitAndCanBeRetried() async throws {
        let destroying = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onDestroy: { reference in
            if reference.raw == 1 {
                destroying.succeed(())
                try maintenanceTestBlock(gate)
            }
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let preparation = Task { try await f.host.beginSettingsMaintenance(timeout: 1) }
        _ = try await maintenanceTestWait(destroying)
        do {
            let lease = try await preparation.value
            addTeardownBlock { try? await lease.finish(resume: false) }
            XCTFail("native destruction is still running")
        } catch PluginHostError.timeout {
        }
        XCTAssertEqual(engine.counts.live, 1)
        XCTAssertEqual(engine.counts.finalized, 0)
        XCTAssertTrue(f.host.isSettingsMaintenanceActive)
        gate.signal()
        let lease = try await maintenance(f)
        XCTAssertEqual(engine.counts.live, 0)
        XCTAssertEqual(engine.counts.destroyed, 1)
        try await lease.finish(resume: true)
        XCTAssertEqual(engine.counts.created, 2)
        XCTAssertEqual(engine.counts.initialized, 1)
    }

    func testCancelledPreparationDoesNotGrantLeaseAndDrainedHostCanRetry() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(11,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let dispatcher = PluginCallbackDispatcher(host: f.host)
        let owner = try XCTUnwrap(dispatcher.captureOwner("alpha"))
        let callback = Task { try await dispatcher.result(owner, 11, "run", "[]") }
        _ = try await maintenanceTestWait(entered)
        let preparation = Task { try await f.host.beginSettingsMaintenance(timeout: 2) }
        let preparing = await waitUntil({ f.host.isSettingsMaintenanceActive }, timeout: 1)
        XCTAssertTrue(preparing)
        preparation.cancel()
        do {
            let lease = try await preparation.value
            addTeardownBlock { try? await lease.finish(resume: false) }
            XCTFail("cancelled preparation must not grant a file mutation lease")
        } catch is CancellationError {
        }
        XCTAssertTrue(f.host.isSettingsMaintenanceActive)
        XCTAssertFalse(f.host.bridge.effectOwnerValidator?("alpha", owner.wireToken) ?? true)
        XCTAssertEqual(engine.counts.finalized, 0)
        gate.signal()
        _ = try await callback.value
        let lease = try await maintenance(f)
        try await lease.finish(resume: true)
        XCTAssertTrue(f.host.isRunning)
    }

    func testStopAbortsPreparationBeforeItCanGrantAFileLease() async throws {
        let entered = OneShotResult<Void>()
        let waitingStop = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(11,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return nil
        })
        let f = try fixture(engine: engine, log: { text in
            if text == "PluginHost: stop waiting for settings maintenance" { waitingStop.succeed(()) }
        })
        try await load(f)
        let dispatcher = PluginCallbackDispatcher(host: f.host)
        let owner = try XCTUnwrap(dispatcher.captureOwner("alpha"))
        let callback = Task { try await dispatcher.result(owner, 11, "run", "[]") }
        _ = try await maintenanceTestWait(entered)
        let preparation = Task { try await f.host.beginSettingsMaintenance(timeout: 2) }
        let preparing = await waitUntil({ f.host.isSettingsMaintenanceActive }, timeout: 1)
        XCTAssertTrue(preparing)
        let stop = Task { await f.host.stop() }
        _ = try await maintenanceTestWait(waitingStop)
        do {
            let lease = try await preparation.value
            addTeardownBlock { try? await lease.finish(resume: false) }
            XCTFail("stop owns admission before lease publication")
        } catch PluginHostError.notRunning {
        }
        gate.signal()
        _ = try? await callback.value
        await stop.value
        XCTAssertFalse(f.host.isRunning)
        XCTAssertEqual(engine.counts.live, 0)
    }

    func testStopWaitsForHeldFileLeaseAndSuppressesResume() async throws {
        let waiting = OneShotResult<Void>()
        let f = try fixture(log: { text in
            if text == "PluginHost: stop waiting for settings maintenance" { waiting.succeed(()) }
        })
        try await load(f)
        let lease = try await maintenance(f)
        let stop = Task { await f.host.stop() }
        _ = try await maintenanceTestWait(waiting)
        XCTAssertEqual(f.engine.counts.finalized, 0)
        try Data("committed while leased".utf8).write(to: f.root.appendingPathComponent("settings-witness"))
        try await lease.finish(resume: true)
        await stop.value
        XCTAssertEqual(f.engine.counts.created, 1)
        XCTAssertEqual(f.engine.counts.finalized, 1)
        XCTAssertFalse(f.host.isRunning)
        do {
            let unexpected = try await f.host.beginSettingsMaintenance()
            addTeardownBlock { try? await unexpected.finish(resume: false) }
            XCTFail("terminal host cannot grant maintenance")
        } catch PluginHostError.notRunning {
        }
    }

    func testHeldLeaseRejectsImportsMutationsCallbacksAndEventsBeforeExecution() async throws {
        let f = try fixture()
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let lease = try await maintenance(f)
        do {
            let duplicate = try await f.host.beginSettingsMaintenance(timeout: 1)
            addTeardownBlock { try? await duplicate.finish(resume: false) }
            XCTFail("a second maintenance must not supersede a held file lease")
        } catch PluginHostError.runtimeFailure {
        }
        let before = f.engine.calls.count
        let operations: [() async throws -> Void] = [
            { try await f.host.start() },
            { _ = try await f.host.readPluginMetadata(sourceURL: f.source("beta")) },
            { _ = try await f.host.importPlugin(sourceURL: f.source("beta")) },
            { _ = try await f.host.installPlugin(sourceURL: f.source("beta"), metadata: Plugin(id: "beta")) },
            { try await f.host.reloadPlugin(id: "alpha") },
            { try await f.host.uninstallPlugin(id: "alpha") },
            { try await f.host.setPluginEnabled(id: "alpha", false) },
            { _ = try await f.host.settingsJSON(id: "alpha", account: 0) },
            { try await f.host.updateSetting(id: "alpha", key: "k", valueJSON: "true") },
            { try await f.host.clickSetting(id: "alpha", callbackId: "row") },
            { try f.host.setGrantedPermissions(id: "alpha", permissions: []) },
            { try await f.host.deliverAppEvent("must-not-run") },
            { _ = try await f.host.invokeCallbackResult(id: "alpha", handle: 1, method: "run", expectedOwner: owner) },
            { try await f.host.releaseCallbackHandles([1], expectedOwner: owner) }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("maintenance admitted a new operation") }
            catch PluginHostError.runtimeFailure { }
        }
        let dispatcher = PluginCallbackDispatcher(host: f.host)
        XCTAssertFalse(dispatcher.callback(owner, 1, "run", "[]"))
        XCTAssertFalse(dispatcher.release(owner, [1]))
        XCTAssertFalse(f.host.bridge.effectOwnerValidator?("alpha", owner.wireToken) ?? true)
        XCTAssertEqual(f.engine.calls.count, before)
        XCTAssertEqual(f.engine.counts.live, 0)
        XCTAssertTrue(f.host.pluginList().first?.enabled == true)
        try await lease.finish(resume: true)
        let fresh = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        XCTAssertTrue(f.host.bridge.effectOwnerValidator?("alpha", fresh.wireToken) ?? false)
        XCTAssertFalse(f.host.bridge.effectOwnerValidator?("alpha", owner.wireToken) ?? true)
    }
}
