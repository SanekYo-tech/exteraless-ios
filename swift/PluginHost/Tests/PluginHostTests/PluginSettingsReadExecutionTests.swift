import Foundation
import XCTest
@testable import PluginHost

final class PluginSettingsReadExecutionTests: HostLifecycleTestCase {
    private func settingsCalls(_ engine: MaintenanceTestEngine) -> [MaintenanceTestEngine.Call] {
        engine.calls.filter {
            $0.source.hasPrefix("_exteraless_runtime.dispatch_json(\"create_settings\",")
        }
    }

    private func readIsQueued(_ host: PluginHost) async -> Bool {
        await waitUntil({
            let stats = await host.events.queueStatistics()
            // Credit can exist before enqueue. Wait for actual actor admission
            // behind the blocked event, especially before cancelling the waiter.
            return stats.enqueued == 2 && stats.dispatched == 1 && stats.retainedCount == 2
        }, timeout: 1)
    }

    private func wireFields(_ source: String) throws -> [String: Any] {
        let prefix = "_exteraless_runtime.dispatch_json("
        XCTAssertTrue(source.hasPrefix(prefix))
        let arguments = "[" + String(source.dropFirst(prefix.count).dropLast()) + "]"
        let strings = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
        XCTAssertEqual(strings.count, 2)
        XCTAssertEqual(try XCTUnwrap(strings.first), "create_settings")
        let payload = try XCTUnwrap(strings.dropFirst().first)
        return try XCTUnwrap(PluginRuntimeScript.jsonValue(payload) as? [String: Any])
    }

    func testQueuedReadDoesNotRetargetAfterReloadForHostAndDirectBusCallers() async throws {
        // Explicit page owner, legacy Host call, direct bus call: all must pin at
        // admission. The serial event queue is held by a DIFFERENT interpreter.
        for route in 0..<3 {
            let entered = OneShotResult<Void>()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let engine = MaintenanceTestEngine(onScript: { reference, source in
                if reference.raw == 1, source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("hold_other") {
                    entered.succeed(())
                    try maintenanceTestBlock(release)
                }
                return nil
            })
            let f = try fixture(engine: engine, callTimeout: 10, queueLimits: .init(dispatchTimeout: 10))
            try await load(f, "beta")
            try await load(f, "alpha")
            let oldOwner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
            let blocker = Task { try await f.host.deliverAppEvent("hold_other") }
            _ = try await maintenanceTestWait(entered)
            let read = Task {
                switch route {
                case 0:
                    return try await f.host.settingsJSON(id: "alpha", account: 5, expectedOwner: oldOwner,
                                                        shouldExecute: { true })
                case 1:
                    return try await f.host.settingsJSON(id: "alpha", account: 5)
                default:
                    return try await f.host.events.requestCreateSettings(CreateSettingsPayload(pluginId: "alpha", account: 5))
                }
            }
            let queued = await readIsQueued(f.host)
            XCTAssertTrue(queued)
            try await f.host.reloadPlugin(id: "alpha")
            let fresh = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
            XCTAssertNotEqual(oldOwner, fresh)
            release.signal()
            try await blocker.value
            do {
                _ = try await read.value
                XCTFail("stale read must not enter replacement create_settings")
            } catch PluginHostError.superseded { }
            XCTAssertTrue(settingsCalls(engine).isEmpty)
            XCTAssertTrue(f.host.pluginList().first(where: { $0.id == "alpha" })?.loaded == true)
            XCTAssertNil(f.host.pluginList().first(where: { $0.id == "alpha" })?.loadError)

            let current = try await f.host.settingsJSON(id: "alpha", account: 6, expectedOwner: fresh)
            XCTAssertEqual(current, "[]")
            let calls = settingsCalls(engine)
            XCTAssertEqual(calls.count, 1)
            let call = try XCTUnwrap(calls.first)
            XCTAssertEqual(call.reference.raw, 3)
            let fields = try wireFields(call.source)
            XCTAssertEqual(Set(fields.keys), Set(["account"]))
            XCTAssertEqual(fields["account"] as? Int, 6)
        }
    }

    func testQueuedAccountReadExpiresWithoutChangingInterpreter() async throws {
        let entered = OneShotResult<Void>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if reference.raw == 1, source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("hold_account") {
                entered.succeed(())
                try maintenanceTestBlock(release)
            }
            return nil
        })
        let f = try fixture(engine: engine, callTimeout: 10, queueLimits: .init(dispatchTimeout: 10))
        try await load(f, "beta")
        try await load(f, "alpha")
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let scope = MaintenanceTestFlag()
        let blocker = Task { try await f.host.deliverAppEvent("hold_account") }
        _ = try await maintenanceTestWait(entered)
        let read = Task {
            try await f.host.settingsJSON(id: "alpha", account: 5, expectedOwner: owner,
                                         shouldExecute: { scope.value })
        }
        let queued = await readIsQueued(f.host)
        XCTAssertTrue(queued)
        scope.set(false)
        release.signal()
        try await blocker.value
        do { _ = try await read.value; XCTFail("expired account read entered Python") }
        catch PluginHostError.superseded { }
        XCTAssertEqual(f.host.callbackOwner(id: "alpha"), owner)
        XCTAssertTrue(settingsCalls(engine).isEmpty)
        let freshScope = MaintenanceTestFlag()
        let current = try await f.host.settingsJSON(id: "alpha", account: 6, expectedOwner: owner,
                                                   shouldExecute: { freshScope.value })
        XCTAssertEqual(current, "[]")
        XCTAssertEqual(settingsCalls(engine).count, 1)
    }

    func testReadGuardIsRecheckedOnActualOwnerAfterMailboxWait() async throws {
        let entered = OneShotResult<Void>()
        let release = DispatchSemaphore(value: 0)
        let ownerThreads = Recorder<Thread>()
        defer { release.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(55,") {
                ownerThreads.append(Thread.current)
                entered.succeed(())
                try maintenanceTestBlock(release)
            }
            return nil
        })
        let f = try fixture(engine: engine, callTimeout: 10, queueLimits: .init(dispatchTimeout: 10))
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let prior = Task { try await f.host.invokeCallback(id: "alpha", handle: 55, method: "run", expectedOwner: owner) }
        _ = try await maintenanceTestWait(entered)
        let scope = MaintenanceTestFlag()
        let workerChecks = Recorder<Bool>()
        let read = Task {
            try await f.host.settingsJSON(id: "alpha", account: 7, expectedOwner: owner, shouldExecute: {
                if ownerThreads.values.contains(where: { $0 === Thread.current }) {
                    workerChecks.append(scope.value)
                    return scope.value
                }
                return true // Keep every off-worker guard open deliberately.
            })
        }
        let dispatched = await waitUntil({ await f.host.events.queueStatistics().dispatched == 1 }, timeout: 1)
        XCTAssertTrue(dispatched)
        scope.set(false)
        release.signal()
        try await prior.value
        do { _ = try await read.value; XCTFail("worker-scoped read must be skipped") }
        catch PluginHostError.superseded { }
        XCTAssertEqual(workerChecks.values, [false])
        XCTAssertTrue(settingsCalls(engine).isEmpty)
    }

    func testCancelledQueuedReadDoesNotRebuildCallbackRegistry() async throws {
        let entered = OneShotResult<Void>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if reference.raw == 1, source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("hold_cancel") {
                entered.succeed(())
                try maintenanceTestBlock(release)
            }
            return nil
        })
        let f = try fixture(engine: engine, callTimeout: 10, queueLimits: .init(dispatchTimeout: 10))
        try await load(f, "beta")
        try await load(f, "alpha")
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let blocker = Task { try await f.host.deliverAppEvent("hold_cancel") }
        _ = try await maintenanceTestWait(entered)
        let read = Task { try await f.host.settingsJSON(id: "alpha", account: 5, expectedOwner: owner) }
        let queued = await readIsQueued(f.host)
        XCTAssertTrue(queued)
        read.cancel()
        do { _ = try await read.value; XCTFail("expected cancelled read") }
        catch is CancellationError { }
        release.signal()
        try await blocker.value
        let drained = await waitUntil({ await f.host.events.queueStatistics().retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertTrue(settingsCalls(engine).isEmpty)
        XCTAssertEqual(f.host.callbackOwner(id: "alpha"), owner)
    }

    func testEnvelopeAuthorityIsNotWireDataAndConflictingOwnerIsRejected() async throws {
        let f = try fixture()
        try await load(f)
        let old = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let predicateCalls = Recorder<Bool>()
        let request = CreateSettingsPayload(pluginId: "alpha", account: 8, expectedOwner: old,
                                            shouldExecute: { predicateCalls.append(true); return true })
        let script = try PluginScriptBuilder.dispatch(for: .createSettings(request))
        XCTAssertTrue(predicateCalls.values.isEmpty)
        let fields = try wireFields(script)
        XCTAssertEqual(Set(fields.keys), Set(["account"]))
        XCTAssertEqual(fields["account"] as? Int, 8)
        XCTAssertFalse(script.contains(old.wireToken))
        try await f.host.reloadPlugin(id: "alpha")
        let fresh = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        do {
            _ = try await f.host.events.requestCreateSettings(request, expectedOwner: fresh)
            XCTFail("a method argument cannot overwrite a different captured owner")
        } catch PluginHostError.superseded { }
        XCTAssertTrue(settingsCalls(f.engine).isEmpty)
        XCTAssertTrue(predicateCalls.values.isEmpty)
        do {
            _ = try await f.host.events.requestCreateSettings(
                .init(pluginId: "alpha", account: 8, expectedOwner: fresh, shouldExecute: { false }),
                expectedOwner: fresh, shouldExecute: { true })
            XCTFail("a call guard cannot reopen an expired payload guard")
        } catch PluginHostError.superseded { }
        do {
            _ = try await f.host.events.requestCreateSettings(.init(pluginId: "alpha", account: 8),
                expectedOwner: fresh, shouldExecute: { false })
            XCTFail("the direct EventBus read guard must reach admission")
        } catch PluginHostError.superseded { }
        XCTAssertTrue(settingsCalls(f.engine).isEmpty)
    }
}
