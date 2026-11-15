import Foundation
import XCTest
@testable import PluginHost

private func sendPriorityTestArguments(_ source: String, method: String) throws -> [String]? {
    let prefix = "_exteraless_runtime.\(method)("
    guard source.hasPrefix(prefix) else { return nil }
    return try JSONDecoder().decode([String].self, from: Data(("[" + String(source.dropFirst(prefix.count).dropLast()) + "]").utf8))
}

/// Only Python results are supplied by this fixture. The Host's actual queue,
/// owner workers, priority decoder, send chain and retirement guards execute.
private final class SendPriorityTestScript: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [Int64: String] = [:]
    private var priorities: [String: String] = ["alpha": "-100", "beta": "100"]
    private var strategies: [String: HookStrategy] = ["alpha": .modifyFinal, "beta": .modify]
    let queries = Recorder<String>()
    let calls = Recorder<String>()
    let mainThreadQueries = Recorder<Bool>()

    func owner(_ reference: InterpRef) -> String {
        lock.lock(); defer { lock.unlock() }
        return owners[reference.raw] ?? "unknown"
    }
    func priority(_ id: String, _ value: String?) { lock.lock(); priorities[id] = value; lock.unlock() }
    func strategy(_ id: String, _ value: HookStrategy) { lock.lock(); strategies[id] = value; lock.unlock() }
    private func values(_ id: String) -> (String, HookStrategy) {
        lock.lock(); defer { lock.unlock() }
        return (priorities[id] ?? "null", strategies[id] ?? .default)
    }

    func reply(_ reference: InterpRef, _ source: String) throws -> String? {
        if let args = try sendPriorityTestArguments(source, method: "load_json") {
            let id = URL(fileURLWithPath: args[0]).deletingPathExtension().lastPathComponent
            lock.lock(); owners[reference.raw] = id; lock.unlock()
            return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"send_message\":true},\"has_settings\":false}"
        }
        let id = owner(reference)
        let (priority, strategy) = values(id)
        if let args = try sendPriorityTestArguments(source, method: "hook_priority_json") {
            guard args == ["on_send_message_hook", "", ""] else {
                throw PluginHostError.runtimeFailure("unexpected priority query")
            }
            queries.append(id)
            mainThreadQueries.append(Thread.isMainThread)
            if priority == "throw" { throw PluginHostError.runtimeFailure("owned fixture metadata failure") }
            return priority
        }
        guard let args = try sendPriorityTestArguments(source, method: "dispatch_json"), args[0] == "on_send_message_hook" else { return nil }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any])
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        let message = try XCTUnwrap(params["message"] as? String)
        XCTAssertEqual(params["peer"] as? Int, 42)
        XCTAssertEqual(params["notify"] as? Bool, true)
        calls.append("\(id):\(message)")
        switch strategy {
        case .default, .cancel:
            return "{\"strategy\":\"\(strategy.rawValue)\"}"
        case .modify, .modifyFinal:
            return try PluginRuntimeScript.encodeJSON(["strategy": strategy.rawValue, "params": ["message": message + "|" + id]])
        }
    }
}

final class PluginSendHookPriorityTests: HostLifecycleTestCase {
    private static let native = "{\"message\":\"native\",\"peer\":42,\"notify\":true}"

    private func loadSenders(_ fixture: MaintenanceTestFixture, order: [String] = ["alpha", "beta"]) async throws {
        for id in order { try await load(fixture, id) }
        fixture.host.permissions.unsafeMode = false
        for id in order { try fixture.host.setGrantedPermissions(id: id, permissions: [.messagesSend]) }
    }

    private func send(_ fixture: MaintenanceTestFixture) async throws -> PluginSendMessageResult {
        try await fixture.host.events.preSendMessageResult(.init(account: 0, paramsJSON: Self.native))
    }

    private func params(_ result: PluginSendMessageResult) throws -> [String: Any] {
        let json = try XCTUnwrap(result.paramsJSON)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testDescendingPriorityChainsSparseModifyAndFinalExactlyOnce() async throws {
        let script = SendPriorityTestScript()
        let engine = MaintenanceTestEngine(onScript: { try script.reply($0, $1) })
        let f = try fixture(engine: engine)
        try await loadSenders(f)
        let owners = [f.host.callbackOwner(id: "alpha"), f.host.callbackOwner(id: "beta")]
        let result = try await send(f)
        XCTAssertEqual(result.strategy, .modifyFinal)
        XCTAssertEqual(try params(result)["message"] as? String, "native|beta|alpha")
        XCTAssertEqual(try params(result)["peer"] as? Int, 42)
        XCTAssertEqual(script.calls.values, ["beta:native", "alpha:native|beta"])
        XCTAssertEqual(script.queries.values, ["alpha", "beta"])
        XCTAssertEqual(script.mainThreadQueries.values, [false, false])
        XCTAssertEqual(owners, [f.host.callbackOwner(id: "alpha"), f.host.callbackOwner(id: "beta")])
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(") })
    }

    func testCancelAndModifyFinalStopLowerPriorityCallback() async throws {
        let script = SendPriorityTestScript()
        let f = try fixture(engine: MaintenanceTestEngine(onScript: { try script.reply($0, $1) }))
        try await loadSenders(f)
        script.strategy("beta", .cancel)
        let cancelled = try await send(f)
        XCTAssertEqual(cancelled.strategy, .cancel)
        XCTAssertEqual(script.calls.values, ["beta:native"])
        script.strategy("beta", .modifyFinal)
        let final = try await send(f)
        XCTAssertEqual(final.strategy, .modifyFinal)
        XCTAssertEqual(try params(final)["message"] as? String, "native|beta")
        XCTAssertEqual(script.calls.values, ["beta:native", "beta:native"])
    }

    func testFreshQueriesObserveLateRegistrationRemovalAndStableTies() async throws {
        let script = SendPriorityTestScript()
        script.priority("alpha", nil); script.priority("beta", nil)
        script.strategy("alpha", .modify); script.strategy("beta", .modify)
        let f = try fixture(engine: MaintenanceTestEngine(onScript: { try script.reply($0, $1) }))
        try await loadSenders(f, order: ["beta", "alpha"])
        let owners = [f.host.callbackOwner(id: "alpha"), f.host.callbackOwner(id: "beta")]
        XCTAssertTrue(f.host.events.subscribers.hasSubscribers(.sendMessage))
        let empty = try await send(f)
        XCTAssertEqual(empty.strategy, .default); XCTAssertNil(empty.paramsJSON)
        XCTAssertEqual(script.calls.count, 0)
        script.priority("alpha", "100"); script.priority("beta", "100")
        _ = try await send(f)
        XCTAssertEqual(script.calls.values, ["alpha:native", "beta:native|alpha"])
        script.priority("alpha", nil)
        let one = try await send(f)
        XCTAssertEqual(try params(one)["message"] as? String, "native|beta")
        XCTAssertEqual(script.calls.values, ["alpha:native", "beta:native|alpha", "beta:native"])
        XCTAssertEqual(owners, [f.host.callbackOwner(id: "alpha"), f.host.callbackOwner(id: "beta")])
        XCTAssertEqual(f.engine.counts.created, 2)
    }

    func testFailedOrMalformedQueriesPreserveNativeOriginalAndOtherResult() async throws {
        let script = SendPriorityTestScript()
        script.priority("beta", nil)
        let f = try fixture(engine: MaintenanceTestEngine(onScript: { try script.reply($0, $1) }))
        try await loadSenders(f)
        let owner = f.host.callbackOwner(id: "alpha")
        for bad in ["throw", "true", "\"100\"", "1.5", "2147483648", String(repeating: "9", count: 129)] {
            script.priority("alpha", bad)
            let result = try await send(f)
            XCTAssertEqual(result.strategy, .default)
            XCTAssertNil(result.paramsJSON)
        }
        XCTAssertEqual(script.calls.count, 0)
        script.priority("beta", "100")
        let changed = try await send(f)
        XCTAssertEqual(changed.strategy, .modify)
        XCTAssertEqual(try params(changed)["message"] as? String, "native|beta")
        XCTAssertEqual(script.calls.values, ["beta:native"])
        XCTAssertEqual(owner, f.host.callbackOwner(id: "alpha"))
        XCTAssertFalse(f.host.pluginList().contains { !$0.loaded || $0.notResponding })
    }

    func testRetirementDuringQueryCannotInvokeOldOrReplacementGeneration() async throws {
        let script = SendPriorityTestScript()
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if reference.raw == 1, source.hasPrefix("_exteraless_runtime.hook_priority_json(") {
                entered.succeed(()); try maintenanceTestBlock(gate)
            }
            return try script.reply(reference, source)
        })
        let f = try fixture(engine: engine)
        try await loadSenders(f)
        let old = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let waiting = Task { try await f.host.events.preSendMessageResult(.init(account: 0, paramsJSON: Self.native)) }
        _ = try await maintenanceTestWait(entered)
        let reload = Task { try await f.host.reloadPlugin(id: "alpha") }
        let retired = await waitUntil({ f.host.callbackOwner(id: "alpha") == nil }, timeout: 1)
        XCTAssertTrue(retired)
        gate.signal()
        let result = try await waiting.value
        try await reload.value
        XCTAssertEqual(try params(result)["message"] as? String, "native|beta")
        XCTAssertEqual(script.calls.values, ["beta:native"])
        XCTAssertNotEqual(old, f.host.callbackOwner(id: "alpha"))
        XCTAssertTrue(f.host.pluginList().allSatisfy { $0.loaded && !$0.notResponding })
    }

    func testPermissionRevokedAfterQuerySkipsThatCallback() async throws {
        let script = SendPriorityTestScript()
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if reference.raw == 2, source.hasPrefix("_exteraless_runtime.hook_priority_json(") {
                entered.succeed(()); try maintenanceTestBlock(gate)
            }
            return try script.reply(reference, source)
        })
        let f = try fixture(engine: engine)
        try await loadSenders(f)
        let owner = f.host.callbackOwner(id: "beta")
        let waiting = Task { try await f.host.events.preSendMessageResult(.init(account: 0, paramsJSON: Self.native)) }
        _ = try await maintenanceTestWait(entered)
        try f.host.setGrantedPermissions(id: "beta", permissions: [])
        gate.signal()
        let result = try await waiting.value
        XCTAssertEqual(try params(result)["message"] as? String, "native|alpha")
        XCTAssertEqual(script.calls.values, ["alpha:native"])
        XCTAssertEqual(owner, f.host.callbackOwner(id: "beta"))
    }

    func testRetiredCallbackCannotPublishItsReplacement() async throws {
        let script = SendPriorityTestScript()
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if reference.raw == 2, source.hasPrefix("_exteraless_runtime.dispatch_json(") {
                entered.succeed(()); try maintenanceTestBlock(gate)
            }
            return try script.reply(reference, source)
        })
        let f = try fixture(engine: engine)
        try await loadSenders(f)
        let waiting = Task { try await f.host.events.preSendMessageResult(.init(account: 0, paramsJSON: Self.native)) }
        _ = try await maintenanceTestWait(entered)
        let unload = Task { try await f.host.setPluginEnabled(id: "beta", false) }
        let retired = await waitUntil({ f.host.callbackOwner(id: "beta") == nil }, timeout: 1)
        XCTAssertTrue(retired)
        gate.signal()
        let result = try await waiting.value
        try await unload.value
        XCTAssertEqual(try params(result)["message"] as? String, "native|alpha")
        XCTAssertEqual(script.calls.values, ["beta:native", "alpha:native"])
    }

    func testCancellationDuringQueryRetainsReadCreditUntilWorkerFinishes() async throws {
        let script = SendPriorityTestScript()
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") {
                entered.succeed(()); try maintenanceTestBlock(gate)
            }
            return try script.reply(reference, source)
        })
        let f = try fixture(engine: engine)
        try await loadSenders(f)
        let waiting = Task { try await f.host.events.preSendMessageResult(.init(account: 0, paramsJSON: Self.native)) }
        _ = try await maintenanceTestWait(entered)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("cancelled native send must not publish a decision") }
        catch is CancellationError { }
        let retained = await f.host.events.queueStatistics()
        XCTAssertEqual(retained.retainedCount, 1)
        XCTAssertEqual(script.calls.count, 0)
        gate.signal()
        let drained = await waitUntil({ await f.host.events.queueStatistics().retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertEqual(script.calls.count, 0)
        XCTAssertFalse(f.host.pluginList().contains { $0.notResponding })
    }
}
