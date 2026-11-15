import Foundation
import XCTest
@testable import PluginHooks

private final class IngressBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

final class PluginHookIngressTests: XCTestCase {
    private func settle(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if PluginHookRouter.ingressSnapshot.count == count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func observation(_ name: String) -> PluginHookObservation {
        .update(.init(accountRecordId: 1, name: name, source: .acceptedUpdateBatch,
                      stage: .beforeUpdateApplication, serializedTLBytes: Data(repeating: 1, count: 32)))
    }

    func testObservationCreditsFollowValueCopiesAcrossHandoffAndRegistrationReplacement() async {
        let empty = await settle(0)
        XCTAssertTrue(empty)
        let retained = IngressBox<[PluginHookObservation]>([])
        let factories = IngressBox(0)
        let delivered = expectation(description: "two retained deliveries")
        delivered.expectedFulfillmentCount = 2
        let one = observation("one")
        let two = observation("two")
        let old = PluginHookRouter.attach(.init(observe: { event in
            XCTAssertTrue(event.reserveDeliveryBytes(128))
            retained.update { $0.append(event) } // simulates a suspended main handoff
            delivered.fulfill()
        }), subscriptions: [.update], ingressLimits: .init(count: 2, bytes: 4096))
        defer { old.detach(); retained.update { $0.removeAll() } }
        PluginHookRouter.observe(.update) { factories.update { $0 += 1 }; return one }
        PluginHookRouter.observe(.update) { factories.update { $0 += 1 }; return two }
        PluginHookRouter.observe(.update) { factories.update { $0 += 1 }; return one }
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(factories.value, 2)
        XCTAssertEqual(PluginHookRouter.ingressSnapshot.count, 2)
        let nextDelivery = expectation(description: "new registration after old work drains")
        let next = PluginHookRouter.attach(.init(observe: { event in
            XCTAssertTrue(event.reserveDeliveryBytes(128))
            nextDelivery.fulfill()
        }), subscriptions: [.update], ingressLimits: .init(count: 2, bytes: 4096))
        defer { next.detach() }
        PluginHookRouter.observe(.update) { factories.update { $0 += 1 }; return one }
        XCTAssertEqual(factories.value, 2)
        retained.update { $0.removeAll() }
        let drained = await settle(0)
        XCTAssertTrue(drained)
        PluginHookRouter.observe(.update) { return one }
        await fulfillment(of: [nextDelivery], timeout: 1)
    }

    func testEncodedObservationBytesAreReservedBeforeTheMainHop() async {
        let empty = await settle(0)
        XCTAssertTrue(empty)
        let retained = IngressBox<PluginHookObservation?>(nil)
        let factories = IngressBox(0)
        let delivered = expectation(description: "retained encoded payload")
        let value = observation("one")
        let registration = PluginHookRouter.attach(.init(observe: { event in
            XCTAssertTrue(event.reserveDeliveryBytes(700))
            retained.update { $0 = event }
            delivered.fulfill()
        }), subscriptions: [.update], ingressLimits: .init(count: 4, bytes: 1200))
        defer { registration.detach(); retained.update { $0 = nil } }
        PluginHookRouter.observe(.update) { factories.update { $0 += 1 }; return value }
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(PluginHookRouter.ingressSnapshot.count, 1)
        XCTAssertGreaterThan(PluginHookRouter.ingressSnapshot.bytes, 900)
        PluginHookRouter.observe(.update) { factories.update { $0 += 1 }; return value }
        XCTAssertEqual(factories.value, 1) // count has room, aggregate bytes do not
        XCTAssertLessThanOrEqual(PluginHookRouter.ingressSnapshot.bytes, 1200)
    }

    func testSendFallbackRevokesBeforeHostCancellationAndTerminalPayloadKeepsCredit() async {
        let empty = await settle(0)
        XCTAssertTrue(empty)
        typealias Predicate = @Sendable () -> Bool
        let predicates = IngressBox<[Predicate]>([])
        let retained = IngressBox<[PluginSendPayload]>([])
        let index = IngressBox(0)
        let handlerHeld = DispatchSemaphore(value: 0)
        defer { handlerHeld.signal(); retained.update { $0.removeAll() } }
        let firstDone = expectation(description: "successful send")
        let secondEntered = expectation(description: "second handler before returning cancellation")
        let fallback = expectation(description: "fallback does not wait for handler")
        let registration = PluginHookRouter.attach(.init(sendMessage: { payload, reply in
            var call = 0
            index.update { $0 += 1; call = $0 }
            predicates.update { $0.append(PluginHookRouter.currentSendExecutionPredicate()) }
            retained.update { $0.append(payload) }
            if call == 1 { reply(.keepOriginal) }
            else {
                secondEntered.fulfill()
                _ = handlerHeld.wait(timeout: .now() + 5)
            }
            return nil
        }, diagnostic: { _ in }), subscriptions: [.sendMessage], ingressLimits: .init(count: 2, bytes: 8192))
        defer { registration.detach() }
        let payload = PluginSendPayload(accountRecordId: 1, peerId: 2, text: "fixture")
        let first = PluginHookRouter.interceptSend(payload, completion: { _ in firstDone.fulfill() })
        await fulfillment(of: [firstDone], timeout: 1)
        let second = PluginHookRouter.interceptSend(payload, timeout: 0.05, completion: { _ in fallback.fulfill() })
        await fulfillment(of: [secondEntered, fallback], timeout: 1)
        XCTAssertEqual(predicates.value.count, 2)
        XCTAssertTrue(predicates.value[0]()) // normal completion is not cancellation
        XCTAssertFalse(predicates.value[1]()) // false before handler even returns its cancellation
        XCTAssertEqual(PluginHookRouter.ingressSnapshot.count, 2)
        let third = PluginHookRouter.interceptSend(payload, completion: { result in XCTAssertEqual(result, .keepOriginal) })
        XCTAssertNil(third)
        handlerHeld.signal()
        first?.cancel(); second?.cancel()
        retained.update { $0.removeAll() }
        let drained = await settle(0)
        XCTAssertTrue(drained)
    }
}
