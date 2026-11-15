import Foundation
import XCTest
@testable import PluginHost

private final class NativeServiceReviewBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func change(_ f: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; f(&storage) }
}

/// Headless adapter of the exact production cleanup route. It does not emulate
/// SDK unload: the Host fixture explicitly dispatches these calls from its worker.
private final class NativeServiceReviewProvider: PluginBridgeExtension, @unchecked Sendable {
    let pool = NativeServiceLeasePool<PluginHost.CallbackOwner>()
    let scheduler = NativeServiceOwnerScheduler<PluginHost.CallbackOwner>()
    let operations = NativeServiceOperations<PluginHost.CallbackOwner>()
    let interceptions = NativeServiceInterceptions<PluginHost.CallbackOwner>(sites: [])
    let releases = NativeServiceReviewBox<[Int64]>([])
    let cancellations = NativeServiceReviewBox<[String]>([])
    let dispatcher: PluginCallbackDispatcher
    let exportedMethods = ["exteraless.ios.Runtime": NativeServiceCleanupRoute.members]

    init(dispatcher: PluginCallbackDispatcher) { self.dispatcher = dispatcher }
    func make(owner: PluginHost.CallbackOwner, handle: Int64,
              valid: @escaping @Sendable () -> Bool = { true }) throws -> NativeServiceCallbackLease<PluginHost.CallbackOwner> {
        let dispatcher = self.dispatcher
        let releases = self.releases
        let retirement = NativeServiceReleaseTransport.acknowledged(dispatcher)
        return try pool.make(pluginId: owner.pluginId, owner: owner, handle: handle,
            isCurrent: { dispatcher.captureOwner($0.pluginId) == $0 && valid() },
            callback: NativeServiceCallbackTransport.callback(using: dispatcher),
            resultCallback: NativeServiceCallbackTransport.result(using: dispatcher),
            release: { _, _ in XCTFail("Fixture must use acknowledged release") },
            acknowledgedRelease: { owner, handles, accepted in
                releases.change { $0 += handles }
                retirement(owner, handles, accepted)
            }, ownerWireToken: owner.wireToken)
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        guard let request = try NativeServiceRequest(json: requestJSON, members: NativeServiceCleanupRoute.members) else { return nil }
        guard let value = try NativeServiceCleanupRoute.dispatch(request, pluginId: pluginId, scheduler: scheduler,
            operations: operations, interceptions: interceptions, cancelledOperation: { id in self.cancellations.change { $0.append(id) } }) else { return nil }
        return try PluginBridgeJSON.success(value)
    }

    func releaseInstances(pluginId: String) {
        scheduler.cancelAll(pluginId: pluginId)
        for ticket in operations.takeAll(pluginId: pluginId) { ticket.lease.close() }
        pool.closeAll(pluginId: pluginId)
    }
}

final class NativeServiceRemediationTests: XCTestCase {
    private struct Fixture {
        let host: PluginHost
        let engine: MaintenanceTestEngine
        let provider: NativeServiceReviewProvider
        let owner: PluginHost.CallbackOwner
    }

    private func fixture(onScript: (@Sendable (InterpRef, String) throws -> String?)? = nil,
                         unblock: DispatchSemaphore? = nil) async throws -> Fixture {
        let root = tempDirectory("native-services-review")
        let source = root.appendingPathComponent("native_service_review.plugin")
        try Data("# owned FakeEngine boundary fixture; no Python or account execution\n".utf8).write(to: source)
        let engine = MaintenanceTestEngine(onScript: onScript)
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 5), storageDirectory: root), unsafePermissionsMode: false)
        addTeardownBlock {
            unblock?.signal()
            await host.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await host.start(safeMode: true)
        let plugin = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "native_service_review"))
        XCTAssertTrue(plugin.loaded)
        try host.setGrantedPermissions(id: plugin.id, permissions: [.ui, .messagesRead, .files])
        let dispatcher = PluginCallbackDispatcher(host: host)
        let provider = NativeServiceReviewProvider(dispatcher: dispatcher)
        host.bridge.extensionProvider = provider
        return Fixture(host: host, engine: engine, provider: provider, owner: try XCTUnwrap(dispatcher.captureOwner(plugin.id)))
    }

    private func cleanupJSON(_ member: String, id: String, token: String) throws -> String {
        try NativeServiceWire.json(.object(["op": .string("call"), "fqcn": .string("exteraless.ios.Runtime"),
            "member": .string(member), "args": .array([.string(id)]), "kwargs": .object([:]),
            "instance": .null, "value": .null, "ownerToken": .string(token)]))
    }

    func testRetiringWorkerCanRunProductionCleanupRouteWithoutActiveOwner() async throws {
        let atUnload = NativeServiceReviewBox<(@Sendable () throws -> Void)?>(nil)
        let fixture = try await fixture(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.unload_json(") { try atUnload.value?() }
            return nil
        })
        let provider = fixture.provider
        let owner = fixture.owner
        let task = try provider.make(owner: owner, handle: 1)
        let taskId = try provider.scheduler.schedule(task, delayMs: 86_400_000, queue: "PLUGINS_QUEUE")
        let requests = try [2, 3].map { handle -> NativeServiceOperations<PluginHost.CallbackOwner>.Ticket in
            let lease = try provider.make(owner: owner, handle: Int64(handle))
            return try provider.operations.reserve(lease: lease, accountRecordId: 7,
                kind: handle == 2 ? "nativeObservePeer" : "notification:25", timeoutMs: nil, expired: { _ in XCTFail() })
        }
        let json = try [
            cleanupJSON("cancelOwnerTask", id: taskId, token: owner.wireToken),
            cleanupJSON("nativeServiceCancel", id: requests[0].id, token: owner.wireToken),
            cleanupJSON("notificationUnsubscribe", id: requests[1].id, token: owner.wireToken)
        ]
        let host = fixture.host
        let unloaded = NativeServiceReviewBox(false)
        atUnload.change { $0 = {
            guard provider.dispatcher.captureOwner(owner.pluginId) == nil else { throw BridgeFailure.invalidHandle("Host did not retire fixture owner") }
            guard !provider.dispatcher.callback(owner, 99, "run", "[]") else { throw BridgeFailure.invalidHandle("Retiring owner gained new callback admission") }
            for request in json {
                let reply = try NativeServiceWire.decode(host.bridge.dispatchJSON(request, pluginId: owner.pluginId))
                guard reply == .object(["ok": .bool(true), "value": .bool(true)]) else { throw BridgeFailure.unavailable("Own retiring cleanup was refused") }
                let repeated = try NativeServiceWire.decode(host.bridge.dispatchJSON(request, pluginId: owner.pluginId))
                guard repeated == .object(["ok": .bool(true), "value": .bool(false)]) else { throw BridgeFailure.unavailable("Cleanup was not idempotent") }
            }
            unloaded.change { $0 = true }
        } }
        defer { atUnload.change { $0 = nil } }
        let maintenance = try await host.beginSettingsMaintenance(timeout: 2)
        XCTAssertTrue(unloaded.value)
        XCTAssertEqual(provider.releases.value.sorted(), [1, 2, 3])
        XCTAssertEqual(provider.cancellations.value.count, 2)
        XCTAssertEqual(provider.scheduler.pendingCount, 0)
        XCTAssertEqual(provider.operations.count, 0)
        XCTAssertEqual(provider.pool.count, 0)
        try await maintenance.finish(resume: false)
    }

    private func blockedRevocation(accountSwap: Bool) async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        let fixture = try await fixture(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(9000,") {
                entered.succeed(())
                guard gate.wait(timeout: .now() + 4) == .success else { throw BridgeFailure.unavailable("Bounded test worker gate expired") }
            }
            return nil
        }, unblock: gate)
        let host = fixture.host
        let provider = fixture.provider
        let owner = fixture.owner
        let scopes = NativeServiceSnapshots()
        let scope = scopes.begin(recordId: 7, userId: 42)
        let blocker = Task { try await host.invokeCallback(id: owner.pluginId, handle: 9000, method: "run", expectedOwner: owner) }
        _ = try await withDispatchTimeout(2) { try await entered.awaitValue() }
        defer { gate.signal() }
        var leases: [NativeServiceCallbackLease<PluginHost.CallbackOwner>] = []
        for handle in Int64(101)...Int64(103) {
            let dispatcher = provider.dispatcher
            let lease = try provider.make(owner: owner, handle: handle, valid: {
                scopes.isCurrent(scope) && dispatcher.hasPermission(owner.pluginId, .messagesRead)
                    && (handle != 102 || dispatcher.hasPermission(owner.pluginId, .files))
            })
            leases.append(lease)
            // nativeGetUser / nativeDownload are terminal; nativeObservePeer is not.
            XCTAssertTrue(lease.send(argumentsJSON: "[{\"fixture\":true},null]", terminal: handle != 103))
        }
        if accountSwap { _ = scopes.begin(recordId: 7, userId: 43) }
        else { try host.setGrantedPermissions(id: owner.pluginId, permissions: [.ui]) }
        leases[2].close()
        gate.signal()
        _ = try await withDispatchTimeout(2) { try await blocker.value }
        let drained = await waitUntil({ provider.dispatcher.outstandingWorkCount == 0 }, timeout: 2)
        XCTAssertTrue(drained)
        for handle in Int64(101)...Int64(103) {
            XCTAssertFalse(fixture.engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(\(handle),") })
            XCTAssertEqual(fixture.engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.release_handles_json(") && $0.source.contains("[\(handle)]") }.count, 1)
        }
        XCTAssertEqual(provider.releases.value.sorted(), [101, 102, 103])
        XCTAssertEqual(provider.pool.count, 0)
    }

    func testWorkerDropsUserDownloadAndObserveBodiesAfterPermissionRevocation() async throws { try await blockedRevocation(accountSwap: false) }
    func testWorkerDropsUserDownloadAndObserveBodiesAfterAccountReplacement() async throws { try await blockedRevocation(accountSwap: true) }

    func testTerminalDeliverySurvivesNativeCloseAndLeaseDeallocation() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        let fixture = try await fixture(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(9000,") {
                entered.succeed(())
                guard gate.wait(timeout: .now() + 4) == .success else { throw BridgeFailure.unavailable("Bounded test worker gate expired") }
            }
            return nil
        }, unblock: gate)
        let host = fixture.host
        let provider = fixture.provider
        let owner = fixture.owner
        let blocker = Task { try await host.invokeCallback(id: owner.pluginId, handle: 9000, method: "run", expectedOwner: owner) }
        _ = try await withDispatchTimeout(2) { try await entered.awaitValue() }
        defer { gate.signal() }
        var lease: NativeServiceCallbackLease<PluginHost.CallbackOwner>? = try provider.make(owner: owner, handle: 201)
        weak var weakLease = lease
        XCTAssertTrue(try XCTUnwrap(lease).send(argumentsJSON: "[null,null]", terminal: true))
        lease?.close() // idempotent native-close must not revoke terminal entitlement
        lease = nil
        XCTAssertNil(weakLease)
        gate.signal()
        _ = try await withDispatchTimeout(2) { try await blocker.value }
        let drained = await waitUntil({ provider.dispatcher.outstandingWorkCount == 0 }, timeout: 2)
        XCTAssertTrue(drained)
        let work = fixture.engine.calls.map(\.source).filter {
            $0.hasPrefix("_exteraless_runtime.invoke_handle_json(201,") || ($0.hasPrefix("_exteraless_runtime.release_handles_json(") && $0.contains("[201]"))
        }
        XCTAssertEqual(work.count, 2)
        if work.count == 2 {
            XCTAssertTrue(work[0].hasPrefix("_exteraless_runtime.invoke_handle_json(201,"))
            XCTAssertTrue(work[1].hasPrefix("_exteraless_runtime.release_handles_json("))
        }
        XCTAssertEqual(provider.releases.value, [201])
        XCTAssertEqual(provider.pool.count, 0)
    }
}
