import Foundation
import XCTest
@testable import PluginHost

private final class NativePhase2Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func change(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}

private final class NativePhase2Results: @unchecked Sendable {
    struct Call: Sendable {
        let json: String
        let control: NativeServiceCallbackControl
        let complete: @Sendable (NativeServiceCallbackResult) -> Void
    }
    private let calls = NativePhase2Box<[Call]>([])
    private let ready = DispatchSemaphore(value: 0)
    var callback: NativeServiceResultCallback<String> {
        { [self] _, _, _, json, control, completion in
            calls.change { $0.append(Call(json: json, control: control, complete: completion)) }
            ready.signal()
            return true
        }
    }
    func next() throws -> Call {
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
        var result: Call?
        calls.change { if !$0.isEmpty { result = $0.removeFirst() } }
        return try XCTUnwrap(result)
    }
}

final class NativeServicePhase2Tests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return condition()
    }

    func testCacheMissIsNotReadyAndOldAccountEpochCannotPublish() throws {
        let cache = NativeServiceSnapshots()
        let scope = cache.begin(recordId: 71, userId: 900)
        let peer = try NativeServiceSnapshots.Peer(kind: .user, id: 42)
        let token = try XCTUnwrap(cache.reference(peer, scope: scope)).publisher
        XCTAssertTrue(try cache.publishPeer(.null, publisher: token, source: "real-local-miss"))
        XCTAssertTrue(cache.wasObserved(peer, scope: scope))
        XCTAssertNil(cache.readyValue(key: peer.key, scope: scope))
        guard case let .object(miss) = cache.read(key: peer.key, scope: scope, kind: "user") else { return XCTFail() }
        XCTAssertEqual(miss["ready"], .bool(false))
        XCTAssertTrue(try cache.publishPeer(.object(["id": .integer(42), "first_name": .string("Real")]), publisher: token, source: "native-peer"))
        guard case let .object(ready) = cache.read(key: peer.key, scope: scope, kind: "user") else { return XCTFail() }
        XCTAssertEqual(ready["ready"], .bool(true))
        cache.end(scope)
        let replacement = cache.begin(recordId: 71, userId: 901)
        XCTAssertNotEqual(scope.generation, replacement.generation)
        XCTAssertFalse(try cache.publishPeer(.object(["id": .integer(42)]), publisher: token, source: "late-old-account"))
        XCTAssertNil(cache.readyValue(key: peer.key, scope: replacement))
        XCTAssertEqual(cache.retainedBytes, 0)
    }

    func testReferencedCacheLRUEvictionProtectsSelfAndRejectsLateSamePeerGeneration() throws {
        let cache = NativeServiceSnapshots(peerLimit: 2)
        let scope = cache.begin(recordId: 1, userId: 1)
        let me = try NativeServiceSnapshots.Peer(kind: .user, id: 1)
        let first = try NativeServiceSnapshots.Peer(kind: .channel, id: 11)
        let second = try NativeServiceSnapshots.Peer(kind: .group, id: 12)
        _ = try XCTUnwrap(cache.reference(me, scope: scope, pinned: true))
        let old = try XCTUnwrap(cache.reference(first, scope: scope)).publisher
        XCTAssertTrue(try cache.publishPeer(.object(["id": .integer(11)]), publisher: old, source: "native"))
        let added = try XCTUnwrap(cache.reference(second, scope: scope))
        XCTAssertEqual(added.evicted, [old])
        XCTAssertEqual(cache.peerCount(scope: scope), 2)
        XCTAssertFalse(cache.isCurrent(old))
        let fresh = try XCTUnwrap(cache.reference(first, scope: scope)).publisher
        XCTAssertNotEqual(old.generation, fresh.generation)
        XCTAssertFalse(try cache.publishPeer(.object(["id": .integer(11)]), publisher: old, source: "late"))
        XCTAssertNil(cache.readyValue(key: first.key, scope: scope))
        XCTAssertNotNil(cache.reference(me, scope: scope))
    }

    func testSnapshotByteQuotaIsTransactionalAndInvalidationRemovesReadiness() throws {
        let cache = NativeServiceSnapshots(byteLimit: 32)
        let scope = cache.begin(recordId: 1, userId: 1)
        XCTAssertTrue(try cache.publish(.string("online"), key: "connection", scope: scope, source: "network"))
        XCTAssertThrowsError(try cache.publish(.string(String(repeating: "x", count: 128)), key: "connection", scope: scope, source: "oversized"))
        XCTAssertEqual(cache.readyValue(key: "connection", scope: scope), .string("online"))
        _ = try cache.publish(.null, key: "connection", scope: scope, source: "invalidated")
        XCTAssertNil(cache.readyValue(key: "connection", scope: scope))
        XCTAssertEqual(cache.retainedBytes, 0)
    }

    func testCoalescingCannotCrossAnAppliedMessageBarrier() throws {
        let pending = NativePhase2Results()
        let pool = NativeServiceLeasePool<String>()
        let released = NativePhase2Box<[Int64]>([])
        let lease = try pool.make(pluginId: "fixture", owner: "epoch", handle: 1, isCurrent: { _ in true },
            callback: { _, _, _, _ in XCTFail("event used admission-only callback"); return false },
            resultCallback: pending.callback, release: { _, values in released.change { $0 += values } })
        let delivery = NativeServiceEventDelivery<String>()
        func put(_ value: String, status: Bool) {
            XCTAssertTrue(delivery.enqueue(lease: lease, argumentsJSON: value, coalescingKey: status ? "progress" : nil,
                valid: { true }, retire: { lease.close() }))
        }
        put("[1]", status: false)
        let first = try pending.next()
        put("[10]", status: true)
        put("[2]", status: false)
        put("[20]", status: true)
        put("[30]", status: true)
        XCTAssertEqual(delivery.count(owner: "epoch"), 4)
        first.complete(.success(.null))
        for expected in ["[10]", "[2]", "[30]"] {
            let call = try pending.next()
            XCTAssertEqual(call.json, expected)
            call.complete(.success(.null))
        }
        XCTAssertTrue(waitUntil { delivery.count(owner: "epoch") == 0 })
        XCTAssertEqual(delivery.retainedBytes, 0)
        lease.close()
        XCTAssertEqual(released.value, [1])
        XCTAssertEqual(pool.count, 0)
    }

    func testEventBudgetIncludesExecutingCallbackAndCancellationIsIdempotent() throws {
        let pending = NativePhase2Results()
        let pool = NativeServiceLeasePool<String>()
        let released = NativePhase2Box<Int>(0)
        let lease = try pool.make(pluginId: "fixture", owner: "epoch", handle: 1, isCurrent: { _ in true },
            callback: { _, _, _, _ in true }, resultCallback: pending.callback,
            release: { _, _ in released.change { $0 += 1 } })
        let delivery = NativeServiceEventDelivery<String>(maximumPerOwner: 2)
        XCTAssertTrue(delivery.enqueue(lease: lease, argumentsJSON: "[1]", coalescingKey: nil, valid: { true }, retire: { lease.close() }))
        let running = try pending.next()
        XCTAssertTrue(delivery.enqueue(lease: lease, argumentsJSON: "[2]", coalescingKey: nil, valid: { true }, retire: { lease.close() }))
        XCTAssertFalse(delivery.enqueue(lease: lease, argumentsJSON: "[3]", coalescingKey: nil, valid: { true }, retire: { lease.close() }))
        XCTAssertFalse(running.control.isActive)
        delivery.remove(subscriptionId: lease.id)
        delivery.remove(subscriptionId: lease.id)
        running.complete(.failure(.unavailable("cancelled")))
        XCTAssertTrue(waitUntil { delivery.count(owner: "epoch") == 0 })
        XCTAssertEqual(released.value, 1)
        XCTAssertEqual(pool.count, 0)
    }

    func testClosedAccountExecutionPredicateIsRecheckedByControl() throws {
        let valid = NativePhase2Box(true)
        let control = NativeServiceCallbackControl(deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        control.bindExecutionCheck { valid.value }
        XCTAssertTrue(control.allowsExecution)
        valid.change { $0 = false }
        XCTAssertFalse(control.allowsExecution)
    }

    func testReleaseBackpressureHoldsPoolCreditUntilCAdmission() throws {
        let permit = NativePhase2Box(false)
        let successful = NativePhase2Box<[Int64]>([])
        let queue = NativeServiceReleaseQueue<String>(current: { _ in true }, submit: { _, handles in
            guard permit.value else { return false }
            successful.change { $0 += handles }
            return true
        })
        let pool = NativeServiceLeasePool<String>(maximumPerOwner: 1)
        let release: NativeServiceAcknowledgedRelease<String> = { owner, handles, done in queue.release(owner, handles, onAccepted: done) }
        let lease = try pool.make(pluginId: "fixture", owner: "epoch", handle: 9, isCurrent: { _ in true },
            callback: { _, _, _, _ in true }, release: { _, _ in XCTFail("unacknowledged release") }, acknowledgedRelease: release)
        lease.close()
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(queue.pendingHandleCount, 1)
        XCTAssertThrowsError(try pool.make(pluginId: "fixture", owner: "epoch", handle: 10, isCurrent: { _ in true },
            callback: { _, _, _, _ in true }, release: { _, _ in }))
        permit.change { $0 = true }
        XCTAssertTrue(waitUntil { pool.count == 0 })
        XCTAssertEqual(successful.value, [9])
        XCTAssertEqual(queue.pendingHandleCount, 0)
    }

    func testPlaybackUsesRealSeekIdentifierAndOriginalArgumentShapes() throws {
        var reducer = NativeServicePlaybackReducer()
        XCTAssertTrue(reducer.receive(nil).isEmpty)
        func frame(_ position: Double, seek: Int64 = 1, identity: String = "user:1:55") throws -> NativeServicePlaybackFrame {
            try NativeServicePlaybackFrame(identity: identity, messageId: 55, message: .object(["nativeType": .string("MessageObject"), "fixture": .bool(true)]),
                state: "playing", position: position, duration: 20, rate: 1, seekId: seek)
        }
        let start = reducer.receive(try frame(0))
        XCTAssertEqual(start.map(\.0), [.messagePlayingDidStart, .messagePlayingPlayStateChanged, .messagePlayingProgressDidChanged])
        XCTAssertEqual(start[0].1.count, 2)
        let jump = reducer.receive(try frame(10))
        XCTAssertEqual(jump.map(\.0), [.messagePlayingProgressDidChanged])
        let seek = reducer.receive(try frame(5, seek: 2))
        XCTAssertEqual(seek.map(\.0), [.messagePlayingDidSeek, .messagePlayingProgressDidChanged])
        XCTAssertEqual(seek[0].1, [.integer(55), .number(0.25)])
        let replaced = reducer.receive(try frame(0, identity: "channel:2:55"))
        XCTAssertEqual(replaced.first?.0, .messagePlayingDidStart)
        XCTAssertNil(NativeServiceNotification(rawValue: 149)) // Android stopService payload is not invented.
    }
}
