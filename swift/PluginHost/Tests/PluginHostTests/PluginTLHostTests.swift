import Foundation
import XCTest
@testable import PluginHost

private final class TLHostTestOwners: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64: String] = [:]
    func put(_ reference: InterpRef, _ id: String) { lock.lock(); values[reference.raw] = id; lock.unlock() }
    func get(_ reference: InterpRef) -> String { lock.lock(); defer { lock.unlock() }; return values[reference.raw] ?? "unknown" }
}

private func tlTestArguments(_ source: String, method: String) throws -> [String]? {
    let prefix = "_exteraless_runtime.\(method)("
    guard source.hasPrefix(prefix) else { return nil }
    return try JSONDecoder().decode([String].self, from: Data(("[" + String(source.dropFirst(prefix.count).dropLast()) + "]").utf8))
}

private func tlTestLoad(_ source: String, reference: InterpRef, owners: TLHostTestOwners) throws -> String? {
    guard let args = try tlTestArguments(source, method: "load_json") else { return nil }
    let id = URL(fileURLWithPath: args[0]).deletingPathExtension().lastPathComponent
    owners.put(reference, id)
    return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"app_event\":true,\"pre_request\":true,\"post_request\":true,\"update\":true,\"updates\":true},\"has_settings\":false}"
}

final class PluginTLHostTests: HostLifecycleTestCase {
    private func payload(origin: [String] = [], active: @escaping @Sendable () -> Bool = { true },
                         normalize: @escaping @Sendable (String) throws -> String = { $0 }) -> PluginTLHostPayload {
        return PluginTLHostPayload(kind: .preRequest, account: 0, name: "TL_messages_sendMessage", canonicalName: "messages.sendMessage",
            valueJSON: "{\"value\":0}", metadataJSON: "{\"accountRecordId\":9223372036854775807}", errorJSON: nil, canCancel: true,
            originPluginIds: origin, originRootId: origin.isEmpty ? nil : "fixture-root", normalize: normalize, shouldExecute: active)
    }

    func testPriorityChainingValidatesBetweenPluginsAndRetainsFinal() async throws {
        let owners = TLHostTestOwners()
        let observed = Recorder<String>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            let id = owners.get(reference)
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") { return id == "beta" ? "20" : "10" }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" {
                let arguments = try JSONSerialization.jsonObject(with: Data(args[1].utf8)) as! [String: Any]
                let snapshot = arguments["request"] as! [String: Any]
                let value = (snapshot["tl"] as! [String: Any])["value"] as! Int
                observed.append("\(id):\(value)")
                return id == "beta" ? "{\"strategy\":\"MODIFY\",\"request\":{\"value\":1}}" : "{\"strategy\":\"MODIFY_FINAL\",\"request\":{\"value\":2}}"
            }
            return nil
        })
        let fixture = try self.fixture(engine: engine)
        try await load(fixture, "alpha")
        try await load(fixture, "beta")
        let normalized = Recorder<String>()
        let result = try await fixture.host.events.transformTL(payload(normalize: { json in normalized.append(json); return json }))
        XCTAssertEqual(result.strategy, .modifyFinal)
        XCTAssertEqual(result.valueJSON, "{\"value\":2}")
        XCTAssertEqual(observed.values, ["beta:0", "alpha:1"])
        XCTAssertEqual(normalized.count, 2)
    }

    func testPriorityInspectionFailureDoesNotUnloadOrReplaceOwner() async throws {
        let owners = TLHostTestOwners()
        let called = Recorder<String>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            let id = owners.get(reference)
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") {
                if id == "alpha" { throw PluginHostError.runtimeFailure("fixture priority inspection failed") }
                return "0"
            }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" {
                called.append(id); return "{\"strategy\":\"DEFAULT\"}"
            }
            return nil
        })
        let fixture = try self.fixture(engine: engine)
        try await load(fixture, "alpha")
        try await load(fixture, "beta")
        let before = fixture.host.callbackOwner(id: "alpha")
        _ = try await fixture.host.events.transformTL(payload())
        XCTAssertEqual(before, fixture.host.callbackOwner(id: "alpha"))
        XCTAssertTrue(fixture.host.pluginList().first(where: { $0.id == "alpha" })?.loaded == true)
        XCTAssertEqual(called.values, ["beta"])
    }

    func testInvalidReplacementKeepsPreviousValueWithoutRetiringOwner() async throws {
        let owners = TLHostTestOwners()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") { return "0" }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" { return "{\"strategy\":\"MODIFY\",\"request\":{\"retarget\":true}}" }
            return nil
        })
        let fixture = try self.fixture(engine: engine)
        try await load(fixture)
        let owner = fixture.host.callbackOwner(id: "alpha")
        let value = try await fixture.host.events.transformTL(payload(normalize: { _ in throw PluginHostError.runtimeFailure("readonly fixture") }))
        XCTAssertEqual(value.strategy, .default)
        XCTAssertEqual(owner, fixture.host.callbackOwner(id: "alpha"))
    }

    func testCancellationAfterPriorityStopsHookAtMailboxBoundary() async throws {
        let owners = TLHostTestOwners()
        let started = OneShotResult<Bool>()
        let blocked = DispatchSemaphore(value: 0)
        let active = MaintenanceTestFlag()
        let hooks = Recorder<String>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") {
                started.succeed(true); try maintenanceTestBlock(blocked); return "0"
            }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" { hooks.append(source); return "{\"strategy\":\"DEFAULT\"}" }
            return nil
        })
        defer { blocked.signal() }
        let fixture = try self.fixture(engine: engine)
        try await load(fixture)
        let request = payload(active: { active.value })
        let task = Task { try await fixture.host.events.transformTL(request) }
        _ = try await maintenanceTestWait(started)
        active.set(false)
        blocked.signal()
        let result = try await task.value
        XCTAssertEqual(result.strategy, .default)
        XCTAssertEqual(hooks.count, 0)
    }

    func testAncestrySkipsOnlyAncestorAndPreservesOtherPlugin() async throws {
        let owners = TLHostTestOwners()
        let hooks = Recorder<String>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") { return "0" }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" {
                hooks.append(owners.get(reference)); return "{\"strategy\":\"DEFAULT\"}"
            }
            return nil
        })
        let fixture = try self.fixture(engine: engine)
        try await load(fixture, "alpha")
        try await load(fixture, "beta")
        _ = try await fixture.host.events.transformTL(payload(origin: ["alpha"]))
        XCTAssertEqual(hooks.values, ["beta"])
        _ = try await fixture.host.events.transformTL(payload())
        XCTAssertEqual(hooks.values, ["beta", "alpha", "beta"])
    }

    func testOriginCapturedOnWorkerSurvivesItsOwnCallbackOnly() async throws {
        let owners = TLHostTestOwners()
        let hostBox = MaintenanceTestHostBox()
        let captured = Recorder<[String]>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") { return "0" }
            guard let host = hostBox.get(), let owner = host.callbackOwner(id: owners.get(reference)) else { return nil }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" {
                let origin = try PluginTLNativeOrigin.capture(owner: owner, callbackHandle: 17)
                captured.append(origin?.pluginIds ?? [])
                return "{\"strategy\":\"DEFAULT\"}"
            }
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(") {
                captured.append(try PluginTLNativeOrigin.capture(owner: owner)?.pluginIds ?? [])
                return "null"
            }
            return nil
        })
        let fixture = try self.fixture(engine: engine)
        hostBox.set(fixture.host)
        try await load(fixture)
        _ = try await fixture.host.events.transformTL(payload())
        let owner = try XCTUnwrap(fixture.host.callbackOwner(id: "alpha"))
        _ = try await fixture.host.invokeCallbackResult(id: "alpha", handle: 17, method: "run", expectedOwner: owner)
        _ = try await fixture.host.invokeCallbackResult(id: "alpha", handle: 18, method: "run", expectedOwner: owner)
        XCTAssertEqual(captured.values, [["alpha"], ["alpha"], []])
        try await fixture.host.releaseCallbackHandles([17], expectedOwner: owner)
    }

    func testPriorityPredicateIsRevalidatedOnTheActualOwnerWorker() async throws {
        let owners = TLHostTestOwners()
        let ownerThreads = Recorder<Thread>()
        let queries = Recorder<String>()
        let workerChecks = Recorder<Bool>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) {
                ownerThreads.append(Thread.current)
                return loaded
            }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") { queries.append(source); return "0" }
            return nil
        })
        let fixture = try self.fixture(engine: engine)
        try await load(fixture)
        let owner = fixture.host.callbackOwner(id: "alpha")
        let result = try await fixture.host.events.transformTL(payload(active: {
            // Model a scope that expires in the mailbox. Admission away from the
            // interpreter is deliberately allowed; only its worker sees expiry.
            if ownerThreads.values.contains(where: { $0 === Thread.current }) {
                workerChecks.append(true)
                return false
            }
            return true
        }))
        XCTAssertEqual(result.strategy, .default)
        XCTAssertEqual(queries.count, 0)
        XCTAssertEqual(workerChecks.count, 1)
        XCTAssertEqual(owner, fixture.host.callbackOwner(id: "alpha"))
    }

    func testMaintenanceWaitsForTLBatchAndLeavesNoTransformEntryUnderLease() async throws {
        let owners = TLHostTestOwners()
        let entered = OneShotResult<Void>()
        let blocked = DispatchSemaphore(value: 0)
        let hooks = Recorder<String>()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let loaded = try tlTestLoad(source, reference: reference, owners: owners) { return loaded }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") {
                entered.succeed(())
                try maintenanceTestBlock(blocked)
                return "0"
            }
            if let args = try tlTestArguments(source, method: "dispatch_json"), args[0] == "pre_request_hook" {
                hooks.append(source)
                return "{\"strategy\":\"DEFAULT\"}"
            }
            return nil
        })
        defer { blocked.signal() }
        let fixture = try self.fixture(engine: engine)
        try await load(fixture)
        let request = payload()
        let transform = Task { try await fixture.host.events.transformTL(request) }
        _ = try await maintenanceTestWait(entered)
        let preparation = Task { try await fixture.host.beginSettingsMaintenance(timeout: 2) }
        let maintaining = await waitUntil({ fixture.host.isSettingsMaintenanceActive }, timeout: 1)
        XCTAssertTrue(maintaining)
        XCTAssertEqual(engine.counts.destroyed, 0)
        blocked.signal()
        _ = try await transform.value
        let lease = try await preparation.value
        addTeardownBlock { try? await lease.finish(resume: false) }
        XCTAssertEqual(engine.counts.live, 0)
        let before = engine.calls.count
        let underLease = try await fixture.host.events.transformTL(payload())
        XCTAssertEqual(underLease.strategy, .default)
        XCTAssertEqual(engine.calls.count, before)
        XCTAssertEqual(hooks.count, 1)
    }
}
