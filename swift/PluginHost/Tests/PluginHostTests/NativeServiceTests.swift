import Foundation
import XCTest
@testable import PluginHost

private final class NativeServiceRecord<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func add(_ value: Value) { lock.lock(); items.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class NativeServiceDeferredResults: @unchecked Sendable {
    struct Request: Sendable {
        let handle: Int64
        let control: NativeServiceCallbackControl
        let completion: @Sendable (NativeServiceCallbackResult) -> Void
    }
    private let lock = NSLock()
    private var requests: [Request] = []
    let enqueued = DispatchSemaphore(value: 0)
    var callback: NativeServiceResultCallback<String> {
        { [self] _, handle, _, _, control, completion in
            lock.lock()
            requests.append(Request(handle: handle, control: control, completion: completion))
            lock.unlock()
            enqueued.signal()
            return true
        }
    }
    func take() throws -> Request {
        XCTAssertEqual(enqueued.wait(timeout: .now() + 2), .success)
        lock.lock(); defer { lock.unlock() }
        return try XCTUnwrap(requests.isEmpty ? nil : requests.removeFirst())
    }
}

final class NativeServiceTests: XCTestCase {
    private func lease(_ pool: NativeServiceLeasePool<String>, handle: Int64, owner: String = "generation-a",
                       events: NativeServiceRecord<String>, results: NativeServiceResultCallback<String>? = nil,
                       current: @escaping @Sendable (String) -> Bool = { _ in true },
                       callback: (@Sendable (String, Int64, String, String) -> Bool)? = nil) throws -> NativeServiceCallbackLease<String> {
        try pool.make(pluginId: "own-fixture", owner: owner, handle: handle, isCurrent: current,
            callback: callback ?? { owner, handle, method, _ in events.add("call:\(owner):\(handle):\(method)"); return true },
            resultCallback: results, release: { owner, handles in events.add("release:\(owner):\(handles[0])") })
    }

    func testSchedulerDelayCancellationAndFIFORelease() throws {
        let pool = NativeServiceLeasePool<String>()
        let scheduler = NativeServiceOwnerScheduler<String>()
        let events = NativeServiceRecord<String>()
        let called = DispatchSemaphore(value: 0)
        let first = try lease(pool, handle: 1, events: events, callback: { owner, handle, method, args in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(method, "run")
            XCTAssertEqual(args, "[]")
            events.add("call:\(owner):\(handle):\(method)")
            called.signal()
            return true
        })
        let cancelled = try lease(pool, handle: 2, events: events)
        let id = try scheduler.schedule(first, delayMs: 50, queue: "PLUGINS_QUEUE")
        let cancelledId = try scheduler.schedule(cancelled, delayMs: 86_400_000, queue: "PLUGINS_QUEUE")
        XCTAssertEqual(events.values, [])
        XCTAssertFalse(scheduler.cancel(id: cancelledId, owner: "generation-b"))
        XCTAssertTrue(scheduler.cancel(id: cancelledId, owner: "generation-a"))
        XCTAssertFalse(scheduler.cancel(id: cancelledId, owner: "generation-a"))
        XCTAssertEqual(called.wait(timeout: .now() + 2), .success)
        // close() takes the same lease gate as send, making the assertion below
        // deterministic even if the fixture signalled just before FIFO release.
        first.close()
        XCTAssertEqual(events.values, ["release:generation-a:2", "call:generation-a:1:run", "release:generation-a:1"])
        XCTAssertFalse(scheduler.cancel(id: id, owner: "generation-a"))
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(pool.count, 0)
    }

    func testNamedSchedulersAreIndependentAndNeverRunInline() throws {
        let pool = NativeServiceLeasePool<String>()
        let scheduler = NativeServiceOwnerScheduler<String>()
        let events = NativeServiceRecord<String>()
        let entered = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let other = DispatchSemaphore(value: 0)
        let slow = try lease(pool, handle: 1, events: events, callback: { _, _, _, _ in
            entered.signal()
            XCTAssertEqual(unblock.wait(timeout: .now() + 2), .success)
            return true
        })
        let fast = try lease(pool, handle: 2, events: events, callback: { _, _, _, _ in other.signal(); return true })
        _ = try scheduler.schedule(slow, delayMs: 0, queue: "SEARCH_QUEUE")
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        _ = try scheduler.schedule(fast, delayMs: 0, queue: "UI")
        let result = other.wait(timeout: .now() + 1)
        unblock.signal()
        XCTAssertEqual(result, .success)
        slow.close()
        fast.close()
        XCTAssertEqual(pool.count, 0)
    }

    func testInvalidQueueDelayBudgetsAndStaleOwnerDoNotInvoke() throws {
        XCTAssertThrowsError(try NativeServiceOwnerScheduler<String>.validate(delayMs: -1, queue: "UI"))
        XCTAssertThrowsError(try NativeServiceOwnerScheduler<String>.validate(delayMs: 86_400_001, queue: "UI"))
        XCTAssertThrowsError(try NativeServiceOwnerScheduler<String>.validate(delayMs: 0, queue: "unbounded-custom-name"))
        let pool = NativeServiceLeasePool<String>(maximumPerOwner: 1, maximumTotal: 2)
        let events = NativeServiceRecord<String>()
        let stale = try lease(pool, handle: 9, events: events, current: { _ in false })
        XCTAssertThrowsError(try lease(pool, handle: 9, events: events))
        XCTAssertThrowsError(try lease(pool, handle: 10, events: events))
        XCTAssertFalse(stale.send(method: "run", argumentsJSON: "[]", terminal: true))
        XCTAssertEqual(events.values, ["release:generation-a:9"])
        let fresh = try lease(pool, handle: 9, owner: "generation-b", events: events)
        fresh.close()
        XCTAssertEqual(pool.count, 0)
    }

    func testAsynchronousResultPinsHandleAcrossUnregisterBeforeEnqueue() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let item = try lease(pool, handle: 7, events: events, results: pending.callback)
        let control = NativeServiceCallbackControl(deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        let completions = NativeServiceRecord<PluginJSONValue>()
        XCTAssertTrue(item.request(argumentsJSON: "[]", control: control, completion: { result in
            if case let .success(value) = result { completions.add(value) }
        }))
        let request = try pending.take()
        item.close()
        XCTAssertFalse(request.control.isActive)
        XCTAssertEqual(events.values, []) // async Task may not have enqueued yet
        request.completion(.success(.bool(false)))
        request.completion(.success(.bool(true))) // broken transport cannot double-release
        XCTAssertEqual(events.values, ["release:generation-a:7"])
        XCTAssertEqual(completions.values, [.bool(false)])
        XCTAssertEqual(pool.count, 0)
    }

    func testFileLiteralFiltersAndSuccessfulDictionaryReturnMatchesOriginal() throws {
        let model = try NativeServiceFileRegistration(.object(["extension": .string(".ZIP"),
            "whitelist": .array([.string("Report")]), "blacklist": .array([.string("draft")]), "icon": .bool(false)]))
        XCTAssertTrue(model.matches(fileName: "REPORT-final.zip"))
        XCTAssertFalse(model.matches(fileName: "report-draft.zip"))
        XCTAssertFalse(model.matches(fileName: "report.zip.exe"))
        XCTAssertFalse(model.matches(fileName: "ChatActivity.zip"))
        XCTAssertThrowsError(try NativeServiceFileRegistration(.object(["extension": .string("*.zip")])))
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let item = try lease(pool, handle: 1, events: events, results: pending.callback)
        let decisions = NativeServiceRecord<NativeServiceOpenDecision>()
        let done = DispatchSemaphore(value: 0)
        let barrier = NativeServiceOpenBarrier(steps: [try NativeServiceOpenStep(lease: item, context: .object([:]))], fileCallback: true) {
            decisions.add($0); done.signal()
        }
        barrier.start()
        let request = try pending.take()
        // Original ignores any return, including a dictionary saying false.
        request.completion(.success(.object(["handled": .bool(false)])))
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(decisions.values, [.handled])
        item.close()
        XCTAssertEqual(pool.count, 0)
    }

    func testIntentFilterParsingLiteralPlusFlagsAndOpaqueTelegramURI() throws {
        let event = try NativeServiceIntentContext(url: XCTUnwrap(URL(string: "tg:resolve/Name?start=a%2Bb+c&start=ignored")), account: 4)
        XCTAssertEqual(event.scheme, "tg")
        XCTAssertEqual(event.host, "resolve")
        XCTAssertEqual(event.query["start"], "a+b c")
        let model = try NativeServiceIntentRegistration(.object(["before": .bool(true), "priority": .integer(12), "filters": .object([
            "schemes": .array([.string("TG")]), "hosts": .array([.string("RESOLVE")]),
            "path_template": .string("resolve/{username}"), "query_args": .array([.string("start")]),
            "action": .string("android.intent.action.VIEW"), "blacklist_flags": .integer(4)
        ])]))
        let matched = try XCTUnwrap(model.matchingContext(event))
        guard case let .object(fields) = matched else { return XCTFail("expected context") }
        XCTAssertEqual(fields["username"], .string("Name"))
        XCTAssertEqual(fields["query_args"], .object(["start": .string("a+b c")]))
        XCTAssertEqual(fields["path_args"], .object(["username": .string("Name")]))
        try model.validateNativeURLSites()
        let category = try NativeServiceIntentRegistration(.object(["before": .bool(true), "filters": .object(["categories": .array([.string("android.intent.category.BROWSABLE")])])]))
        XCTAssertThrowsError(try category.validateNativeURLSites())
        XCTAssertNil(category.matchingContext(event))
        let categorized = try NativeServiceIntentContext(url: XCTUnwrap(URL(string: "https://example.test/")), account: 4,
            categories: ["android.intent.category.BROWSABLE"], flags: 4)
        XCTAssertNotNil(category.matchingContext(categorized))
    }

    func testIntentTrueIsExecutionResultNotAdmissionAndAfterIsOneShot() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let registry = NativeServiceInterceptions<String>(sites: [.externalURL])
        let before = try lease(pool, handle: 1, events: events, results: pending.callback)
        let after = try lease(pool, handle: 2, events: events, results: pending.callback)
        _ = try registry.registerIntent(NativeServiceIntentRegistration(.object(["before": .bool(true)])), lease: before)
        _ = try registry.registerIntent(NativeServiceIntentRegistration(.object(["before": .bool(false)])), lease: after)
        let decisions = NativeServiceRecord<NativeServiceOpenDecision>()
        let done = DispatchSemaphore(value: 0)
        let event = try NativeServiceIntentContext(url: XCTUnwrap(URL(string: "https://example.test/test")), account: 1)
        let barrier = registry.interceptIntent(event) { decision, after in
            decisions.add(decision)
            after.completeOriginal()
            after.completeOriginal()
            done.signal()
        }
        XCTAssertNotNil(barrier)
        let request = try pending.take()
        XCTAssertEqual(decisions.values, []) // Bool true from admission is NOT cancellation.
        request.completion(.success(.bool(false)))
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(decisions.values, [.continueOpening])
        XCTAssertEqual(events.values, ["call:generation-a:2:__call__"])
        registry.releaseInstances()
        XCTAssertEqual(pool.count, 0)
    }

    func testPriorityCancellationSkipsLowerBeforeAndAllAfterCallbacks() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let registry = NativeServiceInterceptions<String>(sites: [.externalURL])
        for (id, before, priority) in [(Int64(1), true, 0), (Int64(2), false, 100), (Int64(3), true, 50)] {
            _ = try registry.registerIntent(NativeServiceIntentRegistration(.object(["before": .bool(before), "priority": .integer(Int64(priority))])),
                lease: lease(pool, handle: id, events: events, results: pending.callback))
        }
        let done = DispatchSemaphore(value: 0)
        let event = try NativeServiceIntentContext(url: XCTUnwrap(URL(string: "https://example.test/")), account: 0)
        XCTAssertNotNil(registry.interceptIntent(event) { decision, after in
            XCTAssertEqual(decision, .handled)
            after.completeOriginal() // even accidental use cannot run after on handled.
            done.signal()
        })
        let first = try pending.take()
        XCTAssertEqual(first.handle, 3)
        first.completion(.success(.bool(true)))
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(events.values, [])
        registry.releaseInstances()
        XCTAssertEqual(pool.count, 0)
    }

    func testBarrierTimeoutAndLateTrueCannotReopenOrCancelTwice() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let item = try lease(pool, handle: 1, events: events, results: pending.callback)
        let decisions = NativeServiceRecord<NativeServiceOpenDecision>()
        let done = DispatchSemaphore(value: 0)
        let barrier = NativeServiceOpenBarrier(steps: [try NativeServiceOpenStep(lease: item, context: .null)], fileCallback: false,
            callbackTimeoutMs: 80, totalTimeoutMs: 120) { decisions.add($0); done.signal() }
        barrier.start()
        let request = try pending.take()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(request.control.isActive)
        request.completion(.success(.bool(true)))
        XCTAssertEqual(done.wait(timeout: .now() + .milliseconds(100)), .timedOut)
        XCTAssertEqual(decisions.values, [.continueOpening])
        item.close()
        XCTAssertEqual(pool.count, 0)
    }

    func testAccountCancellationWhileAwaitingThenUnregisterCannotResumeOrIndexRetiredSteps() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let registry = NativeServiceInterceptions<String>(sites: [.externalURL])
        let item = try lease(pool, handle: 1, events: events, results: pending.callback)
        _ = try registry.registerIntent(NativeServiceIntentRegistration(.object(["before": .bool(true)])), lease: item)
        let decisions = NativeServiceRecord<NativeServiceOpenDecision>()
        let done = DispatchSemaphore(value: 0)
        let context = try NativeServiceIntentContext(url: XCTUnwrap(URL(string: "https://example.test/")), account: 3)
        let barrier = try XCTUnwrap(registry.interceptIntent(context, accountRecordId: 123) { decision, _ in
            decisions.add(decision); done.signal()
        })
        let callback = try pending.take()
        registry.cancelOpenings(accountRecordId: 123)
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(callback.control.isActive)
        registry.releaseInstances()
        barrier.registrationsChanged() // races a completed/cancelled snapshot in practice
        callback.completion(.success(.bool(true)))
        XCTAssertEqual(done.wait(timeout: .now() + .milliseconds(100)), .timedOut)
        XCTAssertEqual(decisions.values, [.cancelled])
        XCTAssertEqual(pool.count, 0)
    }

    func testUnsupportedSitesAndCrossOwnerFileRemovalNeverAdmitAnInactiveRegistration() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let pending = NativeServiceDeferredResults()
        let item = try lease(pool, handle: 1, events: events, results: pending.callback)
        let model = try NativeServiceFileRegistration(.object(["extension": .string("zip")]))
        XCTAssertThrowsError(try NativeServiceInterceptions<String>(sites: []).registerFile(model, lease: item))
        let registry = NativeServiceInterceptions<String>(sites: [.chatDocument])
        let id = try registry.registerFile(model, lease: item)
        XCTAssertFalse(registry.remove(id: id, owner: "generation-b", file: true))
        XCTAssertTrue(registry.canInterceptFile(fileName: "report.zip"))
        XCTAssertTrue(registry.remove(id: id, owner: "generation-a", file: true))
        XCTAssertEqual(events.values, ["release:generation-a:1"])
        XCTAssertEqual(pool.count, 0)
    }

    func testStructuredLogPreservesSeverityAndErrorTextWithByteBoundAndCredentialRedaction() throws {
        let buffer = PluginServiceLogBuffer(capacity: 2)
        let event = try NativeServiceLogEvent(.object(["level": .string("E"), "phase": .string("sdk.safe_call"),
            "message": .string("ValueError: original user text; api_key=secret123"),
            "traceback": .string("Authorization: Bearer secret456\nhttps://name:password@example.test/\n" + String(repeating: "😀\n", count: 2000))]))
        buffer.append(pluginId: "own-fixture", event: event)
        let entry = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(entry.level, .error)
        XCTAssertLessThanOrEqual(entry.message.utf8.count, 4000)
        let decoded = try XCTUnwrap(entry.nativeServiceEvent)
        XCTAssertEqual(decoded.level, .error)
        XCTAssertEqual(decoded.phase, "sdk.safe_call")
        XCTAssertTrue(decoded.message.contains("ValueError: original user text"))
        XCTAssertFalse(entry.message.contains("secret123"))
        XCTAssertFalse(entry.message.contains("secret456"))
        XCTAssertFalse(entry.message.contains("name:password"))
        XCTAssertThrowsError(try NativeServiceLogEvent(.object(["level": .string("whatever"), "phase": .string("sdk"), "message": .string("text")])))
    }

    func testNativeCacheReadinessOwnershipAndLateCancellationBinding() throws {
        let pool = NativeServiceLeasePool<String>()
        let events = NativeServiceRecord<String>()
        let operations = NativeServiceOperations<String>(maximumSnapshotBytes: 32)
        let item = try lease(pool, handle: 1, events: events)
        let ticket = try operations.reserve(lease: item, accountRecordId: 99, kind: "nativeObservePeer", timeoutMs: nil, expired: { _ in XCTFail("persistent subscription expired") })
        XCTAssertEqual(try operations.state(id: ticket.id, owner: "generation-a"), .object(["ready": .bool(false), "kind": .string("nativeObservePeer"), "value": .null]))
        XCTAssertThrowsError(try operations.state(id: ticket.id, owner: "generation-b"))
        XCTAssertTrue(try operations.publish(.object(["id": .integer(123)]), for: ticket))
        XCTAssertThrowsError(try operations.publish(.string(String(repeating: "x", count: 64)), for: ticket))
        XCTAssertEqual(try operations.state(id: ticket.id, owner: "generation-a"), .object(["ready": .bool(true), "kind": .string("nativeObservePeer"), "value": .object(["id": .integer(123)])]))
        XCTAssertNotNil(operations.take(id: ticket.id, owner: "generation-a"))
        operations.bindCancellation(ticket) { events.add("disposed") }
        item.close()
        XCTAssertEqual(events.values, ["disposed", "release:generation-a:1"])
        XCTAssertEqual(pool.count, 0)
        XCTAssertEqual(operations.count, 0)
    }

    func testWireDoesNotStealLargeTLCallsAndRejectsMalformedCallbackTags() throws {
        let data = try JSONSerialization.data(withJSONObject: ["fqcn": "exteraless.ios.Runtime", "member": "tlRequest",
            "args": [String(repeating: "x", count: 1_048_600)]])
        let large = String(decoding: data, as: UTF8.self)
        XCTAssertNil(try NativeServiceRequest(json: large, members: ["logEvent"]))
        XCTAssertThrowsError(try NativeServiceWire.callbackHandle(.object(["__handle__": .bool(true)])))
        XCTAssertThrowsError(try NativeServiceWire.callbackHandle(.object(["__handle__": .integer(-1)])))
        XCTAssertThrowsError(try NativeServiceWire.callbackHandle(.object(["__handle__": .integer(1), "extra": .string("hidden")])))
    }
}
