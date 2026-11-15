import Foundation
import XCTest
@testable import PluginHooks

private final class TLTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R { self.lock.lock(); defer { self.lock.unlock() }; return body(&self.value) }
}

final class PluginTLTransformTests: XCTestCase {
    private func payload(_ name: String, account: Int64 = 1,
                         normalize: @escaping @Sendable (String) throws -> String = { $0 }) -> PluginTLTransformPayload {
        return PluginTLTransformPayload(kind: .preRequest, accountRecordId: account, correlationId: name,
            name: name, valueJSON: "{\"_\":\"fixture\"}", metadataJSON: "{}", normalize: normalize)
    }

    func testAccountFIFOAndCancellationOfQueuedWork() {
        let calls = TLTestBox<[String]>([])
        let firstReply = TLTestBox<(@Sendable (PluginTLTransformResult) -> Void)?>(nil)
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let registration = PluginTLTransformRouter.attach(handler: { payload, reply in
            calls.with { $0.append(payload.name) }
            if payload.name == "first" { firstReply.with { $0 = reply }; entered.signal() }
            else { reply(.keepOriginal) }
            return nil
        }, subscriptions: [.preRequest])
        defer { registration.detach() }
        let first = PluginTLTransformRouter.intercept(payload("first")) { _ in finished.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let cancelled = PluginTLTransformRouter.intercept(payload("cancelled")) { _ in XCTFail("disposed work delivered") }
        cancelled?.cancel()
        let third = PluginTLTransformRouter.intercept(payload("third")) { _ in finished.signal() }
        firstReply.with { $0 }?(.keepOriginal)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(calls.with { $0 }, ["first", "third"])
        first?.cancel(); third?.cancel()
    }

    func testTimeoutIgnoresLateRepliesAndCancelsHost() {
        let reply = TLTestBox<(@Sendable (PluginTLTransformResult) -> Void)?>(nil)
        let hostCancelled = DispatchSemaphore(value: 0)
        let terminal = DispatchSemaphore(value: 0)
        let results = TLTestBox<[PluginTLTransformResult]>([])
        let registration = PluginTLTransformRouter.attach(handler: { _, completion in
            reply.with { $0 = completion }
            return PluginHookCancellation { hostCancelled.signal() }
        }, subscriptions: [.preRequest])
        defer { registration.detach() }
        let token = PluginTLTransformRouter.intercept(payload("timeout"), timeout: 0.05) { value in
            results.with { $0.append(value) }; terminal.signal()
        }
        XCTAssertEqual(terminal.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(hostCancelled.wait(timeout: .now() + 1), .success)
        reply.with { $0 }?(.cancel)
        XCTAssertEqual(results.with { $0 }, [.keepOriginal])
        token?.cancel()
    }

    func testInvalidModificationFallsBackWithNamedDiagnostic() {
        enum Invalid: Error { case fixture }
        let diagnostics = TLTestBox<[String]>([])
        let terminal = DispatchSemaphore(value: 0)
        let result = TLTestBox<PluginTLTransformResult?>(nil)
        let registration = PluginTLTransformRouter.attach(handler: { _, reply in reply(.modify("bad")); return nil },
            subscriptions: [.preRequest], diagnostic: { code, _, _ in diagnostics.with { $0.append(code) } })
        defer { registration.detach() }
        let token = PluginTLTransformRouter.intercept(payload("invalid", normalize: { _ in throw Invalid.fixture })) { value in
            result.with { $0 = value }; terminal.signal()
        }
        XCTAssertEqual(terminal.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.with { $0 }, .keepOriginal)
        XCTAssertTrue(diagnostics.with { $0.contains("TL_HOOK_INVALID_REPLACEMENT") })
        token?.cancel()
    }

    func testFirstReplyWinsBeforeAsynchronousValidation() {
        let terminal = DispatchSemaphore(value: 0)
        let result = TLTestBox<PluginTLTransformResult?>(nil)
        let registration = PluginTLTransformRouter.attach(handler: { _, reply in
            reply(.modify("first"))
            reply(.cancel)
            return nil
        }, subscriptions: [.preRequest])
        defer { registration.detach() }
        let token = PluginTLTransformRouter.intercept(payload("duplicate", normalize: { value in
            Thread.sleep(forTimeInterval: 0.03)
            return value
        })) { value in result.with { $0 = value }; terminal.signal() }
        XCTAssertEqual(terminal.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.with { $0 }, .modify("first"))
        token?.cancel()
    }

    func testRegistrationReplacementCannotReuseOldReply() {
        let reply = TLTestBox<(@Sendable (PluginTLTransformResult) -> Void)?>(nil)
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let results = TLTestBox<[PluginTLTransformResult]>([])
        let old = PluginTLTransformRouter.attach(handler: { _, completion in reply.with { $0 = completion }; entered.signal(); return nil }, subscriptions: [.preRequest])
        let token = PluginTLTransformRouter.intercept(payload("old")) { value in results.with { $0.append(value) }; finished.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let current = PluginTLTransformRouter.attach(handler: { _, completion in completion(.cancel); return nil }, subscriptions: [.preRequest])
        defer { current.detach() }
        old.detach()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        reply.with { $0 }?(.modify("{\"new\":true}"))
        XCTAssertEqual(results.with { $0 }, [.keepOriginal])
        XCTAssertTrue(PluginTLTransformRouter.hasSubscribers(.preRequest))
        token?.cancel()
    }

    func testNoSubmissionAfterDisposeAndSynchronousCompletionRace() {
        let closed = PluginTLSubmissionGate()
        closed.stop()
        var sent = 0
        XCTAssertFalse(closed.submit { sent += 1; return nil })
        XCTAssertEqual(sent, 0)
        let synchronous = PluginTLSubmissionGate()
        var disposed = 0
        XCTAssertTrue(synchronous.submit {
            synchronous.stop()
            return { disposed += 1 }
        })
        synchronous.bind { disposed += 1 }
        XCTAssertEqual(disposed, 2)
        XCTAssertFalse(synchronous.stop())
    }

    func testPrivacyPrefixCompletionOrderCannotReorderNativeAdds() {
        let order = PluginTLSubmissionOrder()
        let first = order.reserve(accountRecordId: Int64.max)!
        let second = order.reserve(accountRecordId: Int64.max)!
        let values = TLTestBox<[Int]>([])
        let finished = DispatchSemaphore(value: 0)
        order.ready(second) { values.with { $0.append(2) }; finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.02), .timedOut)
        order.ready(first) { values.with { $0.append(1) }; finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(values.with { $0 }, [1, 2])
        let third = order.reserve(accountRecordId: 2)!
        order.cancel(third)
        order.ready(third) { XCTFail("cancelled prefix submitted") }
    }

    func testPrefixesStartInSubscriptionOrderAndSkipCancelledSlots() {
        let order = PluginTLSubmissionOrder()
        let first = order.reserve(accountRecordId: 1)!
        let cancelled = order.reserve(accountRecordId: 1)!
        let last = order.reserve(accountRecordId: 1)!
        let calls = TLTestBox<[String]>([])
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Later per-request queues reach begin first; they must not invoke hooks.
        order.begin(last) {
            calls.with { $0.append("pre-last") }
            order.ready(last) { calls.with { $0.append("add-last") }; finished.signal() }
        }
        order.begin(cancelled) { XCTFail("cancelled prefix entered hooks") }
        order.cancel(cancelled)
        order.begin(first) { calls.with { $0.append("pre-first") }; entered.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(calls.with { $0 }, ["pre-first"])
        let otherAccount = order.reserve(accountRecordId: 2)!
        order.begin(otherAccount) { order.ready(otherAccount) { entered.signal() } }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        order.ready(first) { calls.with { $0.append("add-first") }; finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(calls.with { $0 }, ["pre-first", "add-first", "pre-last", "add-last"])
    }
}
