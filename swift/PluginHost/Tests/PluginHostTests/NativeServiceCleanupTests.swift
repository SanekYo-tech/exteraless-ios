import Foundation
import XCTest
@testable import PluginHost

private final class NativeCleanupBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func change(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}

final class NativeServiceCleanupTests: XCTestCase {
    func testHiddenActiveOwnerDoesNotPreventOwnSchedulerCleanupAndCannotCancelReplacement() throws {
        let active = NativeCleanupBox(true)
        let releases = NativeCleanupBox<[Int64]>([])
        let pool = NativeServiceLeasePool<String>()
        let scheduler = NativeServiceOwnerScheduler<String>()
        func make(_ owner: String, _ token: String, _ handle: Int64) throws -> NativeServiceCallbackLease<String> {
            try pool.make(pluginId: "fixture", owner: owner, handle: handle, isCurrent: { _ in active.value },
                callback: { _, _, _, _, _ in XCTFail("long delay executed"); return false },
                release: { _, handles in releases.change { $0 += handles } }, ownerWireToken: token)
        }
        let old = try make("old", "old-token", 1)
        let oldId = try scheduler.schedule(old, delayMs: 86_400_000, queue: "PLUGINS_QUEUE")
        active.change { $0 = false } // captureOwner would now return nil
        let oldIdentity = try NativeServiceCleanupIdentity(pluginId: "fixture", ownerToken: "old-token")
        XCTAssertFalse(try scheduler.cancel(id: oldId, cleanup: NativeServiceCleanupIdentity(pluginId: "other", ownerToken: "old-token")))
        XCTAssertTrue(scheduler.cancel(id: oldId, cleanup: oldIdentity))
        XCTAssertFalse(scheduler.cancel(id: oldId, cleanup: oldIdentity))
        active.change { $0 = true }
        let replacement = try make("new", "new-token", 2)
        let newId = try scheduler.schedule(replacement, delayMs: 86_400_000, queue: "PLUGINS_QUEUE")
        XCTAssertFalse(scheduler.cancel(id: newId, cleanup: oldIdentity))
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(try scheduler.cancel(id: newId, cleanup: NativeServiceCleanupIdentity(pluginId: "fixture", ownerToken: "new-token")))
        XCTAssertEqual(releases.value, [1, 2])
        XCTAssertEqual(pool.count, 0)
    }

    func testRetiringSubscriptionCancelRevokesQueuedBodyAndReleasesCreditExactlyOnce() throws {
        let controls = NativeCleanupBox<[NativeServiceCallbackControl]>([])
        let releaseCount = NativeCleanupBox(0)
        let acknowledge = NativeCleanupBox<(@Sendable () -> Void)?>(nil)
        let pool = NativeServiceLeasePool<String>(maximumPerOwner: 1)
        let operations = NativeServiceOperations<String>()
        let lease = try pool.make(pluginId: "fixture", owner: "epoch", handle: 5, isCurrent: { _ in true },
            callback: { _, _, _, _, control in controls.change { $0.append(control) }; return true },
            release: { _, _ in XCTFail("acknowledged path required") },
            acknowledgedRelease: { _, _, done in releaseCount.change { $0 += 1 }; acknowledge.change { $0 = done } },
            ownerWireToken: "epoch-token")
        let ticket = try operations.reserve(lease: lease, accountRecordId: 7, kind: "nativeObservePeer", timeoutMs: nil, expired: { _ in XCTFail() })
        let disposed = NativeCleanupBox(0)
        operations.bindCancellation(ticket) { disposed.change { $0 += 1 } }
        XCTAssertTrue(lease.send(argumentsJSON: "[{\"id\":42},null]"))
        let control = try XCTUnwrap(controls.value.first)
        XCTAssertTrue(control.allowsExecution)
        let identity = try NativeServiceCleanupIdentity(pluginId: "fixture", ownerToken: "epoch-token")
        XCTAssertTrue(operations.cancel(id: ticket.id, cleanup: identity))
        XCTAssertFalse(operations.cancel(id: ticket.id, cleanup: identity))
        XCTAssertFalse(control.allowsExecution)
        XCTAssertEqual(disposed.value, 1)
        XCTAssertEqual(releaseCount.value, 1)
        XCTAssertEqual(pool.count, 1) // no lost budget credit while release awaits FIFO admission
        XCTAssertThrowsError(try pool.make(pluginId: "fixture", owner: "epoch", handle: 6, isCurrent: { _ in true },
            callback: { _, _, _, _, _ in true }, release: { _, _ in }))
        try XCTUnwrap(acknowledge.value)()
        XCTAssertEqual(pool.count, 0)
        XCTAssertEqual(operations.count, 0)
    }

    func testFileReplacementCleanupMatchesStoredGenerationUnderRegistryLock() throws {
        let pool = NativeServiceLeasePool<String>()
        let registry = NativeServiceInterceptions<String>(sites: [.chatDocument])
        let releases = NativeCleanupBox<[Int64]>([])
        func make(_ token: String, _ handle: Int64) throws -> NativeServiceCallbackLease<String> {
            try pool.make(pluginId: "fixture", owner: token, handle: handle, isCurrent: { _ in true },
                callback: { _, _, _, _, _ in true }, resultCallback: { _, _, _, _, _, _ in false },
                release: { _, values in releases.change { $0 += values } }, ownerWireToken: token)
        }
        let model = try NativeServiceFileRegistration(.object(["extension": .string("zip")]))
        let oldId = try registry.registerFile(model, lease: make("old", 1))
        let newId = try registry.registerFile(model, lease: make("new", 2))
        let old = try NativeServiceCleanupIdentity(pluginId: "fixture", ownerToken: "old")
        XCTAssertFalse(registry.remove(id: oldId, cleanup: old, file: true))
        XCTAssertFalse(registry.remove(id: newId, cleanup: old, file: true))
        XCTAssertTrue(registry.canInterceptFile(fileName: "fixture.zip"))
        XCTAssertTrue(try registry.remove(id: newId, cleanup: NativeServiceCleanupIdentity(pluginId: "fixture", ownerToken: "new"), file: true))
        XCTAssertEqual(releases.value, [1, 2])
        XCTAssertEqual(pool.count, 0)
    }

    func testCleanupRouteCannotCreateAResourceOrAcceptMissingNativeToken() throws {
        let scheduler = NativeServiceOwnerScheduler<String>()
        let operations = NativeServiceOperations<String>()
        let registry = NativeServiceInterceptions<String>(sites: [])
        func request(_ member: String, token: String?) throws -> NativeServiceRequest {
            var value: [String: PluginJSONValue] = ["op": .string("call"), "fqcn": .string("exteraless.ios.Runtime"),
                "member": .string(member), "args": .array([.string("unknown-id")])]
            value["ownerToken"] = token.map(PluginJSONValue.string)
            return try XCTUnwrap(NativeServiceRequest(json: NativeServiceWire.json(.object(value)), members: NativeServiceCleanupRoute.members.union(["postToOwner"])))
        }
        XCTAssertNil(try NativeServiceCleanupRoute.dispatch(request("postToOwner", token: "epoch"), pluginId: "fixture",
            scheduler: scheduler, operations: operations, interceptions: registry, cancelledOperation: { _ in XCTFail() }))
        XCTAssertThrowsError(try NativeServiceCleanupRoute.dispatch(request("cancelOwnerTask", token: nil), pluginId: "fixture",
            scheduler: scheduler, operations: operations, interceptions: registry, cancelledOperation: { _ in XCTFail() }))
        XCTAssertEqual(try NativeServiceCleanupRoute.dispatch(request("nativeServiceCancel", token: "epoch"), pluginId: "fixture",
            scheduler: scheduler, operations: operations, interceptions: registry, cancelledOperation: { _ in XCTFail() }), .bool(false))
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(operations.count, 0)
    }
}
