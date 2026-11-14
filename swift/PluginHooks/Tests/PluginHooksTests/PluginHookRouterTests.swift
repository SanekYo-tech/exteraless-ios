import Foundation
import PluginHooks
import XCTest

final class PluginHookRouterTests: XCTestCase {
    private var registration: PluginHookRegistration?

    override func tearDown() {
        self.registration?.detach()
        self.registration = nil
        super.tearDown()
    }

    func testNoSubscribersDoesNotBuildOrFanOutAndSendCompletesSynchronously() {
        let unexpected = expectation(description: "no handler or factory")
        unexpected.isInverted = true
        self.registration = PluginHookRouter.attach(PluginHookHandlers(
            sendMessage: { _, _ in unexpected.fulfill(); return nil },
            observe: { _ in unexpected.fulfill() }
        ))
        for kind in PluginHookKind.allCases {
            XCTAssertFalse(PluginHookRouter.hasSubscribers(kind))
        }
        PluginHookRouter.observe(.update, makeEvent: {
            unexpected.fulfill()
            return fixtureUpdate()
        })
        var results: [PluginSendResult] = []
        let cancellation = PluginHookRouter.interceptSend(fixtureSend(), completion: { results.append($0) })
        XCTAssertNil(cancellation)
        XCTAssertEqual(results, [.keepOriginal])
        wait(for: [unexpected], timeout: 0.03)
    }

    func testReplacingRegistrationMakesOldTokenHarmless() {
        let old = PluginHookRouter.attach(PluginHookHandlers(sendMessage: { _, reply in
            reply(.keepOriginal)
            return nil
        }), subscriptions: [.sendMessage])
        XCTAssertTrue(PluginHookRouter.hasSubscribers(.sendMessage))
        let current = PluginHookRouter.attach(PluginHookHandlers(observe: { _ in }))
        self.registration = current
        old.updateSubscriptions([.sendMessage, .updates])
        XCTAssertFalse(PluginHookRouter.hasSubscribers(.sendMessage))
        current.updateSubscriptions([.update, .sendMessage])
        // A subscription with no matching handler never opens its gate.
        XCTAssertFalse(PluginHookRouter.hasSubscribers(.sendMessage))
        XCTAssertTrue(PluginHookRouter.hasSubscribers(.update))
        old.detach()
        XCTAssertTrue(PluginHookRouter.hasSubscribers(.update))
        current.detach()
        XCTAssertFalse(PluginHookRouter.hasSubscribers(.update))
    }

    func testObservationFactoryAndHandlerRunOffCallerQueue() {
        let delivered = expectation(description: "observation")
        let expected = fixtureUpdate()
        self.registration = PluginHookRouter.attach(PluginHookHandlers(observe: { event in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(event, expected)
            delivered.fulfill()
        }), subscriptions: [.update])
        PluginHookRouter.observe(.update, makeEvent: {
            XCTAssertFalse(Thread.isMainThread)
            return expected
        })
        wait(for: [delivered], timeout: 1.0)
    }

    func testDuplicateCompletionCannotReplaceFirstDecision() {
        let delivered = expectation(description: "one decision")
        delivered.assertForOverFulfill = true
        let repliedTwice = expectation(description: "both replies attempted")
        let results = Locked<[PluginSendResult]>([])
        let expected = PluginSendResult.modify(PluginSendMessagePatch(text: "replacement"))
        self.registration = PluginHookRouter.attach(PluginHookHandlers(sendMessage: { _, reply in
            reply(expected)
            reply(.cancel)
            repliedTwice.fulfill()
            return nil
        }), subscriptions: [.sendMessage])
        let cancellation = PluginHookRouter.interceptSend(fixtureSend(), completion: { result in
            results.update { $0.append(result) }
            delivered.fulfill()
        })
        wait(for: [delivered, repliedTwice], timeout: 1.0)
        XCTAssertEqual(results.value, [expected])
        cancellation?.cancel()
    }

    func testCancellationCancelsHostOnceAndSuppressesLateReplies() {
        let entered = expectation(description: "handler entered")
        let cancelled = expectation(description: "host cancelled once")
        cancelled.assertForOverFulfill = true
        let unexpected = expectation(description: "cancelled send has no callback")
        unexpected.isInverted = true
        let replySlot = Locked<((PluginSendResult) -> Void)?>(nil)
        let cancellationCount = Locked(0)
        self.registration = PluginHookRouter.attach(PluginHookHandlers(sendMessage: { _, reply in
            replySlot.update { $0 = reply }
            entered.fulfill()
            return PluginHookCancellation {
                cancellationCount.update { $0 += 1 }
                cancelled.fulfill()
            }
        }), subscriptions: [.sendMessage])
        let cancellation = PluginHookRouter.interceptSend(fixtureSend(), completion: { _ in unexpected.fulfill() })
        wait(for: [entered], timeout: 1.0)
        cancellation?.cancel()
        cancellation?.cancel()
        replySlot.value?(.modify(PluginSendMessagePatch(text: "too late")))
        replySlot.value?(.cancel)
        wait(for: [cancelled], timeout: 1.0)
        wait(for: [unexpected], timeout: 0.03)
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testDetachResolvesPendingSendAndCancelsHostWork() {
        let entered = expectation(description: "handler entered")
        let delivered = expectation(description: "detach resolves send")
        delivered.assertForOverFulfill = true
        let cancelled = expectation(description: "detach cancels host")
        let diagnostic = expectation(description: "detach diagnostic")
        let replySlot = Locked<((PluginSendResult) -> Void)?>(nil)
        self.registration = PluginHookRouter.attach(PluginHookHandlers(sendMessage: { _, reply in
            replySlot.update { $0 = reply }
            entered.fulfill()
            return PluginHookCancellation { cancelled.fulfill() }
        }, diagnostic: { value in
            XCTAssertEqual(value.code, .sendHandlerDetached)
            diagnostic.fulfill()
        }), subscriptions: [.sendMessage])
        let cancellation = PluginHookRouter.interceptSend(fixtureSend(), completion: { result in
            XCTAssertEqual(result, .keepOriginal)
            delivered.fulfill()
        })
        wait(for: [entered], timeout: 1.0)
        self.registration?.detach()
        XCTAssertFalse(PluginHookRouter.hasSubscribers(.sendMessage))
        wait(for: [delivered, cancelled, diagnostic], timeout: 1.0)
        replySlot.value?(.cancel)
        cancellation?.cancel()
    }

    func testTimeoutCompletesWithoutHandlerReply() {
        let delivered = expectation(description: "timeout is a terminal decision")
        delivered.assertForOverFulfill = true
        let diagnostic = expectation(description: "timeout diagnostic")
        self.registration = PluginHookRouter.attach(PluginHookHandlers(sendMessage: { _, _ in
            return nil
        }, diagnostic: { value in
            XCTAssertEqual(value.code, .sendTimedOut)
            diagnostic.fulfill()
        }), subscriptions: [.sendMessage])
        let cancellation = PluginHookRouter.interceptSend(fixtureSend(), timeout: 0.01, completion: { result in
            XCTAssertEqual(result, .keepOriginal)
            delivered.fulfill()
        })
        wait(for: [delivered, diagnostic], timeout: 1.0)
        cancellation?.cancel()
    }

    func testTypedResultCannotBypassEntityProtection() {
        let delivered = expectation(description: "invalid typed patch keeps original")
        let diagnostic = expectation(description: "unsupported modification")
        self.registration = PluginHookRouter.attach(PluginHookHandlers(sendMessage: { _, reply in
            reply(.modify(PluginSendMessagePatch(text: "would invalidate entity ranges")))
            return nil
        }, diagnostic: { value in
            XCTAssertEqual(value.code, .unsupportedSendModification)
            diagnostic.fulfill()
        }), subscriptions: [.sendMessage])
        let payload = PluginSendPayload(accountRecordId: 42, peerId: 73, text: "original", hasTextEntities: true)
        let cancellation = PluginHookRouter.interceptSend(payload, completion: { result in
            XCTAssertEqual(result, .keepOriginal)
            delivered.fulfill()
        })
        wait(for: [delivered, diagnostic], timeout: 1.0)
        cancellation?.cancel()
    }
}

private func fixtureSend() -> PluginSendPayload {
    return PluginSendPayload(accountRecordId: Int64.max - 37, peerId: 73, text: "original", canModifyText: true)
}

private func fixtureUpdate() -> PluginHookObservation {
    return .update(PluginUpdateObservation(accountRecordId: 42, name: "fixtureUpdate", source: .acceptedUpdateBatch, stage: .beforeUpdateApplication, serializedTLBytes: Data([1, 2, 3]), batchIndex: 0, batchCount: 1))
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        body(&self.storage)
    }
}
