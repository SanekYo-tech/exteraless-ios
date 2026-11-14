import Foundation
import XCTest
@testable import PluginHost

private final class OwnershipEngine: CPythonEngine, @unchecked Sendable {
    struct Execution: Sendable {
        let reference: InterpRef
        let source: String
    }
    private let lock = NSLock()
    private var nextReference: Int64 = 0
    private var owners: [Int64: Thread] = [:]
    private var executions: [Execution] = []
    private var initialized = false
    private var initializationCount = 0
    private var finalizationCount = 0
    private var destructionCount = 0
    private let onInitialize: (@Sendable () throws -> Void)?
    private let onScript: (@Sendable (InterpRef, String) throws -> String?)?

    init(onInitialize: (@Sendable () throws -> Void)? = nil,
         onScript: (@Sendable (InterpRef, String) throws -> String?)? = nil) {
        self.onInitialize = onInitialize
        self.onScript = onScript
    }

    var apiVersion: String { "ownership-test" }
    var isProcessInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return initialized
    }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        lock.lock()
        initializationCount += 1
        initialized = true
        lock.unlock()
        try onInitialize?()
    }
    func finalizeProcess() throws {
        lock.lock(); defer { lock.unlock() }
        finalizationCount += 1
        initialized = false
    }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        lock.lock(); defer { lock.unlock() }
        nextReference += 1
        owners[nextReference] = Thread.current
        return InterpRef(raw: nextReference)
    }
    func destroyInterpreter(_ reference: InterpRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard owners[reference.raw] === Thread.current else {
            throw PluginHostError.runtimeFailure("destruction left the owner worker")
        }
        owners[reference.raw] = nil
        destructionCount += 1
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        try record(reference, source)
        if let output = try onScript?(reference, source) { return output }
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            return """
            {"metadata":{"id":"ownerTest"},"handles":{"app_event":true,"pre_request":false,"post_request":false,"update":false,"updates":false,"send_message":true},"has_settings":true}
            """
        }
        if source.hasPrefix("_exteraless_runtime.dispatch_json(") {
            if source.contains("create_settings") { return "[]" }
            if source.contains("on_send_message_hook") { return "{\"strategy\":\"DEFAULT\"}" }
        }
        return "null"
    }
    private func record(_ reference: InterpRef, _ source: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard owners[reference.raw] === Thread.current else {
            throw PluginHostError.runtimeFailure("execution left the owner worker")
        }
        executions.append(Execution(reference: reference, source: source))
    }
    var calls: [Execution] {
        lock.lock(); defer { lock.unlock() }
        return executions
    }
    var counts: (created: Int64, destroyed: Int, live: Int, initialized: Int, finalized: Int) {
        lock.lock(); defer { lock.unlock() }
        return (nextReference, destructionCount, owners.count, initializationCount, finalizationCount)
    }
}

private final class OwnershipHostBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: PluginHost?
    func set(_ host: PluginHost) { lock.lock(); stored = host; lock.unlock() }
    func get() -> PluginHost? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func ownershipWait<T: Sendable>(_ result: OneShotResult<T>) async throws -> T {
    try await withDispatchTimeout(2) { try await result.awaitValue() }
}

private func ownershipGate(_ gate: DispatchSemaphore) throws {
    guard gate.wait(timeout: .now() + 5) == .success else {
        throw PluginHostError.runtimeFailure("bounded ownership test gate timed out")
    }
}

final class PluginHostOwnershipTests: XCTestCase {
    private let id = "ownerTest"

    private func fixture(_ engine: OwnershipEngine, persisted: Bool = false,
                         callTimeout: TimeInterval = 10) throws -> (PluginHost, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("fixture.plugin")
        try Data("# bounded fake fixture; never executed by Python\n".utf8).write(to: source)
        if persisted {
            let store = try PluginStore(directory: directory)
            var plugin = Plugin(id: id)
            plugin.path = source.path
            try store.savePlugins([plugin])
        }
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: directory.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: callTimeout), queue: .init(dispatchTimeout: 10), storageDirectory: directory),
            unsafePermissionsMode: true)
        addTeardownBlock {
            await host.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        return (host, source)
    }

    private func install(_ host: PluginHost, source: URL) async throws {
        try await host.start(safeMode: true)
        let plugin = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: id))
        XCTAssertTrue(plugin.loaded, plugin.loadError ?? "not loaded")
    }

    private func bridgeValue(_ host: PluginHost, member: String, args: [Any], fqcn: String = "exteraless.ios.Runtime") throws -> Any {
        let object: [String: Any] = ["op": "call", "fqcn": fqcn, "member": member, "args": args]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let reply = host.bridge.dispatchJSON(json, pluginId: id)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, true, reply)
        return try XCTUnwrap(response["value"])
    }

    func testDelayedCallbackCannotEnterReloadedInterpreterOrConsumeItsReservation() async throws {
        let engine = OwnershipEngine()
        let (host, source) = try fixture(engine)
        try await install(host, source: source)
        let oldOwner = try XCTUnwrap(host.callbackOwner(id: id))
        let scheduled = Recorder<Int64>()
        host.bridge.onCallback = { _, handle, _, _, _ in scheduled.append(handle) }
        let runnable: [String: Any] = ["__handle__": 77, "__fqcn__": NSNull()]
        _ = try bridgeValue(host, member: "runOnUIThread", args: [runnable, 1000], fqcn: "org.telegram.messenger.AndroidUtilities")

        try await host.reloadPlugin(id: id)
        let newOwner = try XCTUnwrap(host.callbackOwner(id: id))
        XCTAssertNotEqual(oldOwner, newOwner)
        _ = try bridgeValue(host, member: "runOnUIThread", args: [runnable, 1000], fqcn: "org.telegram.messenger.AndroidUtilities")
        do {
            try await host.invokeCallback(id: id, handle: 77, method: "run", expectedOwner: oldOwner)
            XCTFail("stale callback must be rejected before Python entry")
        } catch PluginHostError.superseded {
        }
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(") })
        XCTAssertEqual(try bridgeValue(host, member: "completeCallback", args: [77]) as? Bool, true)

        try await host.invokeCallback(id: id, handle: 77, method: "run", expectedOwner: newOwner)
        try await host.invokeCallback(id: id, handle: 77, method: "run") // Unscheduled strict-probe API.
        let callbacks = engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(") }
        XCTAssertEqual(callbacks.count, 2)
        XCTAssertTrue(callbacks.allSatisfy { $0.reference.raw == 2 })
        XCTAssertEqual(scheduled.values, [77, 77])
    }

    func testOwnerTokenIsAvailableInsideOnPluginLoad() async throws {
        let box = OwnershipHostBox()
        let captured = OneShotResult<PluginHost.CallbackOwner>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = OwnershipEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                guard let owner = box.get()?.callbackOwner(id: "ownerTest") else {
                    captured.fail(PluginHostError.runtimeFailure("owner absent during on_plugin_load"))
                    return nil
                }
                captured.succeed(owner)
                try ownershipGate(gate)
            }
            return nil
        })
        let (host, source) = try fixture(engine)
        box.set(host)
        try await host.start(safeMode: true)
        let installation = Task { try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "ownerTest")) }
        let owner = try await ownershipWait(captured)
        XCTAssertFalse(host.pluginList().first?.loaded ?? true)
        XCTAssertEqual(owner, host.callbackOwner(id: id))
        let callback = Task { try await host.invokeCallback(id: "ownerTest", handle: 1, method: "run", expectedOwner: owner) }
        gate.signal()
        let installed = try await installation.value
        XCTAssertTrue(installed.loaded)
        try await callback.value
        XCTAssertEqual(engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(") }.count, 1)
    }

    func testCallbackTokenFromAnotherHostIsRejectedEvenWithIdenticalLocalIDs() async throws {
        let (first, firstSource) = try fixture(OwnershipEngine())
        let secondEngine = OwnershipEngine()
        let (second, secondSource) = try fixture(secondEngine)
        try await install(first, source: firstSource)
        try await install(second, source: secondSource)
        let foreign = try XCTUnwrap(first.callbackOwner(id: id))
        do {
            try await second.invokeCallback(id: id, handle: 1, method: "run", expectedOwner: foreign)
            XCTFail("host identity is part of the token")
        } catch PluginHostError.superseded {
        }
        XCTAssertFalse(secondEngine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(") })
        XCTAssertTrue(second.pluginList().first?.loaded == true)
    }

    func testConcurrentStartReservesStartupBeforeItsFirstSuspension() async throws {
        let initialized = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = OwnershipEngine(onInitialize: {
            initialized.succeed(())
            try ownershipGate(gate)
        })
        let (host, _) = try fixture(engine, persisted: true)
        let first = Task { try await host.start() }
        _ = try await ownershipWait(initialized)
        try await withDispatchTimeout(1) { try await host.start() }
        gate.signal()
        try await first.value
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(engine.counts.initialized, 1)
        XCTAssertEqual(engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.load_json(") }.count, 1)
        XCTAssertTrue(host.pluginList().first?.loaded == true)
        XCTAssertNil(host.pluginList().first?.loadError)
    }

    func testExecutionFailureWhileReloadOwnsRetirementDoesNotFailNewGeneration() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = OwnershipEngine(onScript: { reference, source in
            if reference.raw == 1, source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("late_failure") {
                entered.succeed(())
                try ownershipGate(gate)
                throw PluginHostError.runtimeFailure("old generation failed")
            }
            return nil
        })
        let (host, source) = try fixture(engine)
        try await install(host, source: source)
        let oldOwner = try XCTUnwrap(host.callbackOwner(id: id))
        let event = Task { try await host.deliverAppEvent("late_failure") }
        _ = try await ownershipWait(entered)
        let reload = Task { try await host.reloadPlugin(id: "ownerTest") }
        let retiring = await waitUntil({ host.callbackOwner(id: "ownerTest") == nil }, timeout: 1)
        XCTAssertTrue(retiring)
        gate.signal()
        try await reload.value
        try await event.value
        let fresh = try XCTUnwrap(host.callbackOwner(id: id))
        XCTAssertNotEqual(oldOwner, fresh)
        XCTAssertTrue(host.pluginList().first?.loaded == true)
        XCTAssertNil(host.pluginList().first?.loadError)
        XCTAssertFalse(host.pluginList().first?.notResponding ?? true)
        XCTAssertEqual(engine.counts.created, 2)
        XCTAssertEqual(engine.counts.destroyed, 1)
    }

    func testConcurrentStopDoesNotDestroyAheadOfTheFirstStopsDrain() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = OwnershipEngine(onScript: { _, source in
            if source == "_exteraless_runtime.unload()" {
                entered.succeed(())
                try ownershipGate(gate)
            }
            return nil
        })
        let (host, source) = try fixture(engine)
        try await install(host, source: source)
        let first = Task { await host.stop() }
        _ = try await ownershipWait(entered)
        try await withDispatchTimeout(1) { await host.stop() }
        XCTAssertEqual(engine.counts.destroyed, 0)
        XCTAssertNil(host.callbackOwner(id: id))
        gate.signal()
        await first.value
        XCTAssertEqual(engine.counts.destroyed, 1)
        XCTAssertEqual(engine.counts.finalized, 1)
        do {
            try await host.start()
            XCTFail("stop remains terminal")
        } catch PluginHostError.notRunning {
        }
    }

    func testInstallSendSettingsUnloadReloadRoundTrip() async throws {
        let engine = OwnershipEngine()
        let (host, source) = try fixture(engine)
        try await install(host, source: source)
        let settings = try await host.settingsJSON(id: id, account: 0)
        XCTAssertEqual(settings, "[]")
        try await host.updateSetting(id: id, key: "enabled", valueJSON: "true")
        try await host.clickSetting(id: id, callbackId: "click")
        let send = try await host.events.preSendMessageResult(.init(account: 0, paramsJSON: "{\"text\":\"fixture\"}"))
        XCTAssertEqual(send.strategy, .default)
        try await host.reloadPlugin(id: id)
        XCTAssertTrue(host.pluginList().first?.loaded == true)
        try await host.setPluginEnabled(id: id, false)
        XCTAssertNil(host.callbackOwner(id: id))
        try await host.setPluginEnabled(id: id, true)
        XCTAssertNotNil(host.callbackOwner(id: id))
        try await host.uninstallPlugin(id: id)
        XCTAssertTrue(host.pluginList().isEmpty)
        XCTAssertEqual(engine.counts.live, 0)
        XCTAssertTrue(host.events.subscribers.isIdle)
    }

    func testStopDuringRetirementBoundsTheDrainBeforeDestroyAll() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = OwnershipEngine(onScript: { _, source in
            if source == "_exteraless_runtime.unload()" {
                entered.succeed(())
                try ownershipGate(gate)
            }
            return nil
        })
        let (host, source) = try fixture(engine, callTimeout: 0.5)
        try await install(host, source: source)
        let reload = Task { try await host.reloadPlugin(id: "ownerTest") }
        _ = try await ownershipWait(entered)
        // Stop must finish while the native worker is still held, by abandoning
        // ready -> abandoned. Premature ready -> destroying would defeat abandon.
        try await withDispatchTimeout(2) { await host.stop() }
        XCTAssertFalse(host.isRunning)
        XCTAssertNil(host.callbackOwner(id: id))
        XCTAssertEqual(engine.counts.finalized, 0)
        gate.signal()
        try await reload.value
        XCTAssertFalse(host.pluginList().contains { $0.loaded })
    }

    private func activate(_ state: PluginHost.HostState, _ handle: InterpreterHandle) throws {
        if state.plugin(id: handle.pluginId) == nil { state.upsert(Plugin(id: handle.pluginId)) }
        try state.beginLoading(handle.pluginId)
        XCTAssertTrue(state.setHandle(handle))
        var plugin = try XCTUnwrap(state.plugin(id: handle.pluginId))
        plugin.loaded = true
        XCTAssertTrue(state.publishLoaded(plugin, handle: handle))
        state.endLoading(handle.pluginId)
    }

    func testOverlappingInvocationsAndOldBatchCleanupKeepCorrectGenerationVisible() throws {
        let state = PluginHost.HostState()
        let old = InterpreterHandle(id: 1, pluginId: id)
        let fresh = InterpreterHandle(id: 2, pluginId: id)
        try activate(state, old)
        try state.beginInvocation(old) // Direct setting update.
        try state.beginInvocation(old) // Callback already queued on the same worker.
        let oldBatch = state.beginBatch()
        state.endInvocation(old)
        XCTAssertEqual(state.batchInflightSnapshot(), [old])
        _ = try XCTUnwrap(state.beginUnloading(id: id, expected: old))
        XCTAssertTrue(state.finishUnloading(old, errorMessage: nil))
        try activate(state, fresh)
        try state.beginInvocation(fresh)
        state.endInvocation(old) // A delayed defer from the retired worker.
        XCTAssertEqual(state.inflightSnapshot(), [fresh])
        XCTAssertTrue(state.batchInflightSnapshot().isEmpty) // Old timeout cannot abandon the new worker.
        let newBatch = state.beginBatch()
        state.endBatch(oldBatch.id)
        XCTAssertEqual(state.batchInflightSnapshot(), [fresh])
        state.endInvocation(fresh)
        state.endBatch(newBatch.id)
        XCTAssertTrue(state.inflightSnapshot().isEmpty)
    }

    func testStaleLoadFailureWatchdogAndRetirementCannotAlterNewOwner() throws {
        let state = PluginHost.HostState()
        let old = InterpreterHandle(id: 1, pluginId: id)
        let fresh = InterpreterHandle(id: 2, pluginId: id)
        try activate(state, old)
        let prior = try XCTUnwrap(state.plugin(id: id))
        XCTAssertThrowsError(try state.beginLoading(id))
        XCTAssertEqual(state.plugin(id: id), prior)
        _ = try XCTUnwrap(state.beginUnloading(id: id, expected: old))
        XCTAssertThrowsError(try state.beginLoading(id))
        XCTAssertTrue(state.finishUnloading(old, errorMessage: nil))
        try state.beginLoading(id)
        XCTAssertTrue(state.setHandle(fresh))
        XCTAssertNotNil(state.target(id: id, expected: fresh, allowLoading: true))
        XCTAssertThrowsError(try state.beginLoading(id))
        var stale = prior
        stale.loadError = "old failure"
        XCTAssertNil(state.failLoading(stale, expected: old))
        XCTAssertNil(state.beginUnloading(id: id, expected: old))
        XCTAssertFalse(state.finishUnloading(old, errorMessage: "late cleanup"))
        XCTAssertNil(state.applyNotResponding(watchdogKey: old.hostWatchdogKey, value: true))
        XCTAssertNil(state.plugin(id: id)?.loadError)
        XCTAssertFalse(state.plugin(id: id)?.notResponding ?? true)
        var loaded = try XCTUnwrap(state.plugin(id: id))
        loaded.loaded = true
        XCTAssertTrue(state.publishLoaded(loaded, handle: fresh))
        state.endLoading(id)
        XCTAssertEqual(state.applyNotResponding(watchdogKey: fresh.hostWatchdogKey, value: true), id)
        XCTAssertNil(state.applyNotResponding(watchdogKey: old.hostWatchdogKey, value: false))
        XCTAssertTrue(state.plugin(id: id)?.notResponding == true)
    }

    func testMutationOwnsRetirementAndRejectsForeignFailureCleanup() throws {
        let state = PluginHost.HostState()
        let handle = InterpreterHandle(id: 1, pluginId: id)
        try activate(state, handle)
        try state.beginMutation(id)
        XCTAssertNil(state.beginUnloading(id: id, expected: handle))
        _ = try XCTUnwrap(state.beginUnloading(id: id, expected: handle, duringMutation: true))
        XCTAssertThrowsError(try state.beginLoading(id, duringMutation: true))
        XCTAssertNil(state.target(id: id, expected: handle, allowLoading: true))
        XCTAssertTrue(state.finishUnloading(handle, errorMessage: nil))
        state.endMutation(id)
    }
}
