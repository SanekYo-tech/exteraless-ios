import Foundation
import XCTest
@testable import PluginHost

final class PluginCallbackGateTests: HostLifecycleTestCase {
    func testQueuedScopeExpiresAfterAdmissionAndPredicateRunsOnActualMailboxOwner() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source == "prior-job" {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return nil
        })
        let manager = SubinterpreterManager(engine: engine)
        addTeardownBlock { await manager.destroyAll() }
        let handle = try await manager.createInterpreter(for: "alpha", bootstrapScript: "")
        let prior = Task { try await manager.invoke(handle, script: "prior-job") }
        _ = try await maintenanceTestWait(entered)
        let live = MaintenanceTestFlag()
        let predicateThreads = Recorder<String>()
        let queued = Task {
            try await manager.invoke(handle, script: "forbidden-user-code", shouldExecute: {
                predicateThreads.append(Thread.current.name ?? "unnamed")
                return live.value
            })
        }
        let admitted = await waitUntil({ await manager.maintenanceState.pendingInvocations == 2 }, timeout: 1)
        XCTAssertTrue(admitted)
        live.set(false)
        gate.signal()
        _ = try await prior.value
        do {
            _ = try await queued.value
            XCTFail("expired UI work must not enter Python after a mailbox wait")
        } catch PluginHostError.superseded {
        }
        let ownerThread = try XCTUnwrap(engine.calls.first { $0.source == "prior-job" }?.threadName)
        XCTAssertEqual(predicateThreads.values, [ownerThread])
        XCTAssertFalse(engine.calls.contains { $0.source == "forbidden-user-code" })
    }

    func testDispatcherPropagatesGateThroughHostAndReturnsActualResultJSON() async throws {
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(7,") { return "{\"answer\":42}" }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let dispatcher = PluginCallbackDispatcher(host: f.host)
        let predicateThreads = Recorder<String>()
        let result = try await dispatcher.result(owner, 7, "__call__", "[]", shouldExecute: {
            predicateThreads.append(Thread.current.name ?? "unnamed")
            return true
        })
        XCTAssertEqual(result, "{\"answer\":42}")
        let execution = try XCTUnwrap(engine.calls.first { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(7,") })
        XCTAssertEqual(predicateThreads.values, [execution.threadName])
        do {
            _ = try await dispatcher.result(owner, 8, "__call__", "[]", shouldExecute: { false })
            XCTFail("awaited expired callback must complete with an error")
        } catch PluginHostError.superseded {
        }
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(8,") })
    }

    func testReservedTerminalLaneIsBoundedAndKeepsActionClosedReleaseFIFOOnError() async throws {
        let entered = OneShotResult<Void>()
        let released = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(1,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
                throw PluginHostError.runtimeFailure("fixture action failed")
            }
            if source.hasPrefix("_exteraless_runtime.release_handles_json(") { released.succeed(()) }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let dispatcher = PluginCallbackDispatcher(host: f.host, limits: .init(
            callbacks: 1, callbacksPerOwner: 1, callbackBytes: 64,
            controls: 2, controlsPerOwner: 2, controlBytes: 256))
        XCTAssertTrue(dispatcher.callback(owner, 1, "__call__", "[]"))
        _ = try await maintenanceTestWait(entered)
        XCTAssertFalse(dispatcher.callback(owner, 3, "__call__", "[]")) // Executing work still consumes budget.
        let oversized = "[\"" + String(repeating: "x", count: 16_384) + "\"]"
        XCTAssertFalse(dispatcher.callback(owner, 4, "__call__", oversized, guaranteed: true))
        XCTAssertTrue(dispatcher.callback(owner, 2, "__call__", "[{\"event\":\"closed\"}]", guaranteed: true))
        XCTAssertTrue(dispatcher.release(owner, [1, 2]))
        XCTAssertFalse(dispatcher.callback(owner, 5, "__call__", "[]", guaranteed: true))
        XCTAssertFalse(dispatcher.release(owner, [5]))
        gate.signal()
        _ = try await maintenanceTestWait(released)
        let work = engine.calls.map(\.source).filter {
            $0.hasPrefix("_exteraless_runtime.invoke_handle_json(") || $0.hasPrefix("_exteraless_runtime.release_handles_json(")
        }
        XCTAssertEqual(work.count, 3)
        if work.count == 3 {
            XCTAssertTrue(work[0].hasPrefix("_exteraless_runtime.invoke_handle_json(1,"))
            XCTAssertTrue(work[1].hasPrefix("_exteraless_runtime.invoke_handle_json(2,"))
            XCTAssertTrue(work[2].hasPrefix("_exteraless_runtime.release_handles_json("))
        }
    }

    func testCancelledResultKeepsItsReservationUntilFIFOReachesItAndSkipsPython() async throws {
        let entered = OneShotResult<Void>()
        let released = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(31,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            if source.hasPrefix("_exteraless_runtime.release_handles_json(") { released.succeed(()) }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let dispatcher = PluginCallbackDispatcher(host: f.host, limits: .init(callbacks: 2, callbacksPerOwner: 2))
        let first = Task { try await dispatcher.result(owner, 31, "__call__", "[]") }
        _ = try await maintenanceTestWait(entered)
        let cancelled = Task { try await dispatcher.result(owner, 32, "__call__", "[]") }
        let accepted = await waitUntil({ dispatcher.outstandingWorkCount == 2 }, timeout: 1)
        XCTAssertTrue(accepted)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(dispatcher.callback(owner, 34, "__call__", "[]"))
        XCTAssertTrue(dispatcher.callback(owner, 33, "__call__", "[{\"event\":\"closed\"}]", guaranteed: true))
        XCTAssertTrue(dispatcher.release(owner, [31, 32, 33]))
        gate.signal()
        _ = try await first.value
        _ = try await maintenanceTestWait(released)
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(32,") })
        XCTAssertTrue(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(33,") })
    }

    func testIndependentOwnersContinueInParallel() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(81,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        try await load(f, "beta")
        let dispatcher = PluginCallbackDispatcher(host: f.host)
        let alpha = try XCTUnwrap(dispatcher.captureOwner("alpha"))
        let beta = try XCTUnwrap(dispatcher.captureOwner("beta"))
        let blocked = Task { try await dispatcher.result(alpha, 81, "run", "[]") }
        _ = try await maintenanceTestWait(entered)
        let other = try await withDispatchTimeout(1) { try await dispatcher.result(beta, 82, "run", "[]") }
        XCTAssertEqual(other, "null")
        gate.signal()
        _ = try await blocked.value
    }

    func testPendingCreationPreventsMaintenanceProofAndLateOwnerIsCleanedUp() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onCreate: {
            entered.succeed(())
            try maintenanceTestBlock(gate)
        })
        let manager = SubinterpreterManager(engine: engine)
        addTeardownBlock { await manager.destroyAll() }
        let creation = Task { try await manager.createInterpreter(for: "alpha", bootstrapScript: "") }
        _ = try await maintenanceTestWait(entered)
        let epoch = UUID()
        try await manager.pauseForSettingsMaintenance(epoch)
        do { try await manager.requireSettingsQuiescence(epoch); XCTFail("creation is still in progress") }
        catch PluginHostError.runtimeFailure { }
        do { try await manager.resumeAfterSettingsMaintenance(epoch); XCTFail("resume needs the same proof") }
        catch PluginHostError.runtimeFailure { }
        gate.signal()
        do { _ = try await creation.value; XCTFail("paused manager must not publish the late interpreter") }
        catch PluginHostError.notRunning { }
        try await manager.requireSettingsQuiescence(epoch)
        XCTAssertEqual(engine.counts.live, 0)
        XCTAssertEqual(engine.counts.destroyed, 1)
        XCTAssertEqual(engine.counts.finalized, 0)
        try await manager.resumeAfterSettingsMaintenance(epoch)
    }
}
