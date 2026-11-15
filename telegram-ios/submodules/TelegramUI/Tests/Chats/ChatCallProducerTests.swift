import Postbox
import SwiftSignalKit
import TelegramCore
import XCTest
@testable import TelegramUI

@MainActor
final class ChatCallProducerTests: XCTestCase {
    private let target = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1))
    private let other = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(2))

    func testHeldInitialPeerReadCannotPresentAfterAccountABA() {
        let changes = ValuePipe<Bool>()
        let read = ValuePipe<(target: String?, current: String?)>()
        var presentations = 0, calls = 0
        let flow = ExteralessChatCallFlow<String>(targetId: target, ask: true, validity: .single(true) |> then(changes.signal()), load: { _ in read.signal() }, request: { _ in calls += 1; return .started }, present: { _, _, _, _ in presentations += 1; return EmptyDisposable }, completion: {}, navigate: {})
        flow.start()
        changes.putNext(false); changes.putNext(true)
        read.putNext(("A", nil))
        XCTAssertEqual(presentations, 0); XCTAssertEqual(calls, 0)
        flow.cancel()
    }

    func testHeldSecondReadAndOldReplacementOKRetireOnForegroundLoss() {
        for holdSecondRead in [true, false] {
            let changes = ValuePipe<Bool>()
            let second = ValuePipe<(target: String?, current: String?)>()
            var reads = 0, replacements = 0, finished = 0
            var buttons: [() -> Void] = []
            let flow = ExteralessChatCallFlow<String>(targetId: target, ask: true, validity: .single(true) |> then(changes.signal()), load: { _ in
                reads += 1
                return reads == 1 ? .single(("A", nil)) : second.signal()
            }, request: { replace in
                if replace { replacements += 1; return .started }
                return .alreadyInProgress(self.other)
            }, present: { _, _, proceed, _ in buttons.append(proceed); return EmptyDisposable }, completion: { finished += 1 }, navigate: {})
            flow.start(); buttons[0]()
            XCTAssertEqual(reads, 2)
            if !holdSecondRead { second.putNext(("A", "current call")) }
            let oldButtons = buttons
            changes.putNext(false); changes.putNext(true)
            if holdSecondRead { second.putNext(("A", "current call")) }
            for button in oldButtons { button(); button() }
            XCTAssertEqual(replacements, 0); XCTAssertEqual(finished, 0)
            XCTAssertEqual(buttons.count, holdSecondRead ? 1 : 2)
            flow.cancel()
        }
    }

    func testOrdinaryConfirmationCanStartExactlyOnce() {
        var accept: (() -> Void)?
        var calls = 0, finished = 0
        let flow = ExteralessChatCallFlow<String>(targetId: target, ask: true, validity: .single(true), load: { _ in .single(("A", nil)) }, request: { _ in calls += 1; return .started }, present: { _, _, proceed, _ in accept = proceed; return EmptyDisposable }, completion: { finished += 1 }, navigate: {})
        flow.start(); flow.start()
        XCTAssertEqual(calls, 0)
        accept?(); accept?()
        XCTAssertEqual(calls, 1); XCTAssertEqual(finished, 1)
    }

    func testReplacementConfirmationStartsOnceAndDoesNotReuseInitialOK() {
        var buttons: [() -> Void] = []
        var attempts: [Bool] = []
        var finished = 0
        let flow = ExteralessChatCallFlow<String>(targetId: target, ask: true, validity: .single(true), load: { current in .single(("A", current == nil ? nil : "existing")) }, request: { replace in
            attempts.append(replace)
            return replace ? .started : .alreadyInProgress(self.other)
        }, present: { _, _, proceed, _ in buttons.append(proceed); return EmptyDisposable }, completion: { finished += 1 }, navigate: {})
        flow.start()
        buttons[0](); buttons[0]()
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(attempts, [false])
        buttons[1](); buttons[1]()
        XCTAssertEqual(attempts, [false, true])
        XCTAssertEqual(finished, 1)
    }
}
