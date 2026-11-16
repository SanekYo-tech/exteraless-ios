import Foundation
import PluginHost
import TelegramCore
import XCTest
@testable import TelegramUI

private final class TLGuardBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        self.lock.lock(); defer { self.lock.unlock() }; return body(&self.value)
    }
}

private final class TLGuardScenario: @unchecked Sendable {
    typealias MainWork = @MainActor @Sendable () -> Void
    weak var host: PluginHost?
    weak var provider: PluginTLBridgeExtension?
    let names = TLGuardBox<[Int64: String]>([:])
    let work = TLGuardBox<[MainWork]>([])
    let callbacks = TLGuardBox<[@Sendable () -> Bool]>([])
    let releaseAllowed = TLGuardBox<Bool>(true)
    let releaseAttempts = TLGuardBox<Int>(0)
    let accountLookups = TLGuardBox<Int>(0)
    let sendAllowed = TLGuardBox<Bool>(true)
    let betaGate = DispatchSemaphore(value: 0)
    let betaEntered = XCTestExpectation(description: "beta entered its native worker")
    let callbackAdmitted = XCTestExpectation(description: "provider callback admitted")
    let cleanupStarted = XCTestExpectation(description: "provider release attempted")
    let blockBeta: Bool
    let sendEvent: Bool

    init(blockBeta: Bool, sendEvent: Bool) {
        self.blockBeta = blockBeta; self.sendEvent = sendEvent
        self.cleanupStarted.assertForOverFulfill = false
    }

    func script(_ reference: InterpRef, _ source: String) throws -> String? {
        for method in ["load_json", "metadata_json"] {
            let prefix = "_exteraless_runtime.\(method)("
            if source.hasPrefix(prefix) {
                let args = try JSONDecoder().decode([String].self, from: Data(("[" + String(source.dropFirst(prefix.count).dropLast()) + "]").utf8))
                let name = URL(fileURLWithPath: args[0]).deletingPathExtension().lastPathComponent
                if method == "metadata_json" { return "{\"ok\":true,\"meta\":{\"id\":\"\(name)\"}}" }
                self.names.with { $0[reference.raw] = name }
                return "{\"metadata\":{\"id\":\"\(name)\"},\"handles\":{\"app_event\":true,\"send_message\":true},\"has_settings\":false}"
            }
        }
        if source.hasPrefix("_exteraless_runtime.hook_priority_json("), source.contains("on_send_message_hook") { return "0" }
        let trigger = self.sendEvent ? source.contains("on_send_message_hook") : source.contains("tl_f01_case")
        guard source.hasPrefix("_exteraless_runtime.dispatch_json("), trigger else { return nil }
        switch self.names.with({ $0[reference.raw] }) {
        case "alpha":
            guard let host = self.host, let provider = self.provider, let owner = host.callbackOwner(id: "alpha") else {
                throw PluginHostError.runtimeFailure("fixture provider/owner missing")
            }
            let request: [String: Any] = ["op": "call", "fqcn": "exteraless.ios.Runtime", "member": "sendMedia", "ownerToken": owner.wireToken,
                "args": [["schemaVersion": 1, "account": 0, "peer": ["type": "user", "id": 1], "kind": "text", "caption": "owned fixture", "silent": false, "timeoutMs": 5000], ["__handle__": 17]]]
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            let response = try XCTUnwrap(provider.dispatch(requestJSON: encoded, pluginId: "alpha"))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            guard result["ok"] as? Bool == true else { throw PluginHostError.runtimeFailure("real provider admission failed: \(response)") }
        case "beta" where self.blockBeta:
            self.betaEntered.fulfill()
            guard self.betaGate.wait(timeout: .now() + 3) == .success else { throw PluginHostError.runtimeFailure("bounded beta fixture expired") }
        default: break
        }
        return self.sendEvent ? "{\"strategy\":\"DEFAULT\"}" : "null"
    }

    @MainActor func drainMain() {
        let pending = self.work.with { work -> [MainWork] in let value = work; work.removeAll(); return value }
        for job in pending { job() }
    }
}

private final class TLGuardEngine: CPythonEngine, @unchecked Sendable {
    let scenario: TLGuardScenario
    private let owners = TLGuardBox<(next: Int64, threads: [Int64: Thread])>((0, [:]))
    init(_ scenario: TLGuardScenario) { self.scenario = scenario }
    var apiVersion: String { "tl-guard-canned" }
    var isProcessInitialized: Bool { true }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {}
    func finalizeProcess() throws {}
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        self.owners.with { value in value.next += 1; value.threads[value.next] = Thread.current; return InterpRef(raw: value.next) }
    }
    func destroyInterpreter(_ reference: InterpRef) throws { _ = self.owners.with { $0.threads.removeValue(forKey: reference.raw) } }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        guard self.owners.with({ $0.threads[reference.raw] === Thread.current }) else { throw PluginHostError.runtimeFailure("fixture left owner worker") }
        return try self.scenario.script(reference, source) ?? "null"
    }
}

/// Real provider dispatch/captured ticket + the exact predicate its startText
/// passes to Core. A manual main queue and Core commit gate avoid constructing
/// Account/Network or submitting any RPC. Python is the bounded canned engine.
final class PluginTLExecutionGuardTests: XCTestCase {
    private struct Fixture: Sendable {
        let host: PluginHost
        let provider: PluginTLBridgeExtension
        let scenario: TLGuardScenario
    }
    private func fixture(blockBeta: Bool, sendEvent: Bool = false) async throws -> Fixture {
        let scenario = TLGuardScenario(blockBeta: blockBeta, sendEvent: sendEvent)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tl-execution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try PluginHost(engine: TLGuardEngine(scenario), configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 2), queue: .init(dispatchTimeout: sendEvent ? 2 : 0.75), storageDirectory: root, stopTimeout: 0.5), unsafePermissionsMode: true)
        let provider = PluginTLBridgeExtension(storage: PluginServiceStorage(rootDirectory: root),
            hasPermission: { _, _ in true }, captureOwner: { [weak host] in host?.callbackOwner(id: $0) },
            callback: { _, _, _, _, predicate in
                scenario.callbacks.with { $0.append(predicate) }; scenario.callbackAdmitted.fulfill(); return true
            }, release: { _, _ in
                scenario.releaseAttempts.with { $0 += 1 }; scenario.cleanupStarted.fulfill()
                return scenario.releaseAllowed.with { $0 }
            }, accountLookup: { _ in 1 }, resolveAccount: { _ in scenario.accountLookups.with { $0 += 1 }; return nil }, diagnostic: { _ in },
            scheduleStart: { job in scenario.work.with { $0.append(job) } })
        scenario.host = host; scenario.provider = provider
        addTeardownBlock {
            scenario.betaGate.signal()
            scenario.releaseAllowed.with { $0 = true }
            await scenario.drainMain()
            await host.stop()
            provider.releaseInstances(pluginId: "alpha")
            try? FileManager.default.removeItem(at: root)
        }
        try await host.start(safeMode: true)
        for id in ["alpha", "beta"] {
            let source = root.appendingPathComponent(id + ".plugin")
            try Data("# owned canned fixture\n".utf8).write(to: source)
            let loaded = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: id))
            XCTAssertTrue(loaded.loaded, loaded.loadError ?? "fixture did not load")
        }
        return Fixture(host: host, provider: provider, scenario: scenario)
    }
    private func waitForRelease(_ provider: PluginTLBridgeExtension) async throws {
        let deadline = Date().addingTimeInterval(1)
        while provider.registry.count != 0 && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(provider.registry.count, 0)
    }
    private func checkRevoked(_ f: Fixture) async throws {
        XCTAssertNotNil(f.host.callbackOwner(id: "alpha"))
        let ticket = try XCTUnwrap(f.provider.registry.runningTickets.first)
        XCTAssertTrue(f.provider.registry.contains(ticket))
        XCTAssertFalse(ticket.permitsExecution)
        let cancelled = f.provider.nativeCancellation(ticket)
        let commit = ExteralessTLEnqueueCommit(canCommit: { !cancelled() }, cancelProvisional: {})
        var writes = 0
        if commit.allowsContinuation(), commit.beginCommit() { writes += 1 }
        XCTAssertEqual(writes, 0) // held bot authorization completes after parent revocation
        f.scenario.releaseAllowed.with { $0 = false }
        await f.scenario.drainMain() // execute the real provider's deferred start
        await fulfillment(of: [f.scenario.cleanupStarted], timeout: 1)
        XCTAssertEqual(f.scenario.accountLookups.with { $0 }, 0)
        XCTAssertTrue(f.scenario.callbacks.with { $0.isEmpty })
        XCTAssertTrue(f.provider.registry.completionPending(ticket))
        XCTAssertEqual(f.provider.registry.count, 1) // cleanup backpressure retains ownership
        f.scenario.releaseAllowed.with { $0 = true }
        try await waitForRelease(f.provider)
    }

    func testRealProviderTicketRevokesAfterBTimeoutAlthoughAOwnerRemainsLoaded() async throws {
        let f = try await fixture(blockBeta: true)
        let batch = Task { try await f.host.deliverAppEvent("tl_f01_case") }
        await fulfillment(of: [f.scenario.betaEntered], timeout: 1)
        do { try await batch.value; XCTFail("expected timeout") } catch PluginHostError.timeout {}
        try await checkRevoked(f)
        f.scenario.betaGate.signal()
    }

    func testRealProviderTicketRevokesOnCancelledParentSend() async throws {
        let f = try await fixture(blockBeta: true, sendEvent: true)
        let batch = Task {
            try await f.host.events.preSendMessageResult(.init(account: 0, paramsJSON: "{}"), shouldExecute: { f.scenario.sendAllowed.with { $0 } })
        }
        await fulfillment(of: [f.scenario.betaEntered], timeout: 1)
        f.scenario.sendAllowed.with { $0 = false }
        batch.cancel()
        do { _ = try await batch.value; XCTFail("expected cancellation") } catch is CancellationError {}
        try await checkRevoked(f)
        f.scenario.betaGate.signal()
    }

    func testSuccessfulBatchKeepsActualCommitAndReleasedCallbackGuardValid() async throws {
        let f = try await fixture(blockBeta: false)
        try await f.host.deliverAppEvent("tl_f01_case")
        let ticket = try XCTUnwrap(f.provider.registry.runningTickets.first)
        let cancelled = f.provider.nativeCancellation(ticket)
        let commit = ExteralessTLEnqueueCommit(canCommit: { !cancelled() }, cancelProvisional: {})
        XCTAssertTrue(commit.allowsContinuation())
        XCTAssertTrue(commit.beginCommit())
        XCTAssertEqual(commit.complete(track: { _ in }), true)
        f.provider.finish(ticket, response: .object(["status": .string("enqueued")]))
        await fulfillment(of: [f.scenario.callbackAdmitted], timeout: 1)
        try await waitForRelease(f.provider)
        XCTAssertTrue(try XCTUnwrap(f.scenario.callbacks.with { $0.first })())
    }

    func testCallbackAlreadyAdmittedIsStillRevocableOnItsEventualWorkerEntry() async throws {
        let f = try await fixture(blockBeta: true)
        let batch = Task { try await f.host.deliverAppEvent("tl_f01_case") }
        await fulfillment(of: [f.scenario.betaEntered], timeout: 1)
        let ticket = try XCTUnwrap(f.provider.registry.runningTickets.first)
        f.provider.finish(ticket, response: .object(["status": .string("enqueued")]))
        await fulfillment(of: [f.scenario.callbackAdmitted], timeout: 1)
        let predicate = try XCTUnwrap(f.scenario.callbacks.with { $0.first })
        do { try await batch.value; XCTFail("expected timeout") } catch PluginHostError.timeout {}
        XCTAssertFalse(predicate())
        XCTAssertNotNil(f.host.callbackOwner(id: "alpha"))
        try await waitForRelease(f.provider)
        f.scenario.betaGate.signal()
    }
}
