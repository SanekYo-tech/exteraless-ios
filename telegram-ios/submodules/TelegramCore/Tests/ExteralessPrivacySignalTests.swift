import XCTest
import SwiftSignalKit
import Postbox
import TelegramApi
@testable import TelegramCore

final class ExteralessPrivacySignalTests: XCTestCase {
    func testSuppressedRequestEmitsCompletesAndRunsLocalFinalizerWithoutNetworkFactory() {
        var requests = 0
        var values: [Int?] = []
        var finalizations = 0
        var completions = 0
        let signal: Signal<Int?, NoError> = exteralessPrivacyRequest(allow: { false }, suppressed: { nil }, request: {
            requests += 1
            return .single(1)
        })
        let disposable = (signal |> then(Signal<Int?, NoError> { subscriber in
            finalizations += 1
            subscriber.putCompletion()
            return EmptyDisposable
        })).start(next: { values.append($0) }, completed: { completions += 1 })
        disposable.dispose()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values[0])
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(completions, 1)
    }

    func testPolicyIsCheckedAtSubscriptionAndAllowedRequestCancellationPropagates() {
        var allowed = false
        var requests = 0
        var cancelled = 0
        let signal: Signal<Int, NoError> = exteralessPrivacyRequest(allow: { allowed }, suppressed: { 0 }, request: {
            requests += 1
            return Signal { _ in ActionDisposable { cancelled += 1 } }
        })
        allowed = true
        let disposable = signal.start()
        XCTAssertEqual(requests, 1)
        disposable.dispose()
        disposable.dispose()
        XCTAssertEqual(cancelled, 1)
        allowed = false
        var completed = false
        let second = signal.start(completed: { completed = true })
        XCTAssertTrue(completed)
        XCTAssertEqual(requests, 1)
        second.dispose()
    }

    func testStorySessionDisposalAndAccountSwitchDoNotAffectAnotherAccount() {
        let sessions = ExteralessStoryPrivacySessions()
        let a = sessions.begin(accountId: 1)
        let b = sessions.begin(accountId: 2)
        XCTAssertTrue(sessions.isActive(accountId: 1))
        XCTAssertFalse(sessions.isActive(accountId: 3))
        sessions.clear(accountId: 1)
        a.dispose()
        XCTAssertFalse(sessions.isActive(accountId: 1))
        XCTAssertTrue(sessions.isActive(accountId: 2))
        b.dispose()
        XCTAssertFalse(sessions.isActive(accountId: 2))
    }

    func testOutgoingPeerExtractionUsesGeneratedRequestValuesAndPreservesNamespace() {
        let channel = Api.InputPeer.inputPeerChannel(.init(channelId: 42, accessHash: 1))
        let user = Api.InputPeer.inputPeerUser(.init(userId: 42, accessHash: 1))
        let channelRequest = Api.functions.messages.sendScheduledMessages(peer: channel, id: [8])
        let userRequest = Api.functions.messages.sendScheduledMessages(peer: user, id: [8])
        XCTAssertEqual(exteralessOutgoingPeer(channelRequest.0), PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42)))
        XCTAssertEqual(exteralessOutgoingPeer(userRequest.0), PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)))
        XCTAssertNotEqual(exteralessOutgoingPeer(channelRequest.0), exteralessOutgoingPeer(userRequest.0))
    }
}
