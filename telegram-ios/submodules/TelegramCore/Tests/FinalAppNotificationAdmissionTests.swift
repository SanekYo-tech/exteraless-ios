import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit
import XCTest
@testable import TelegramCore

/// Drives the real admission/stream helpers through two held callbacks. The
/// effects are an array recorder; no Account, network, Keychain or UIKit is used.
final class FinalAppNotificationAdmissionTests: XCTestCase {
    private final class Revisions: @unchecked Sendable {
        private let lock = NSLock()
        private var filtering: UInt64 = 1
        private var hidden: UInt64 = 1

        func read() -> FilteringNotificationRevision {
            self.lock.lock(); defer { self.lock.unlock() }
            return FilteringNotificationRevision(filtering: self.filtering, hidden: self.hidden)
        }

        func changeFilter() { self.lock.lock(); self.filtering += 1; self.lock.unlock() }
        func changeHidden() { self.lock.lock(); self.hidden += 1; self.lock.unlock() }
    }

    private final class Fixture {
        let identity = PrivacyExtrasAccountIdentity(recordId: 101, userId: 202, testingEnvironment: true)
        let accountObject = NSObject()
        let revisions = Revisions()
        let source = ValuePipe<ExteralessNotificationMessageBatch>()
        var receiverObject: NSObject?
        var engineCallbacks: [() -> Void] = []
        var lockCallbacks: [() -> Void] = []
        var effects: [FilteringNotificationEffect] = []
        var disposable: Disposable?

        init() {
            let identity = self.identity
            let object = ObjectIdentifier(self.accountObject)
            let revisions = self.revisions
            self.disposable = exteralessAdmittedNotificationStream(source: self.source.signal(), prepare: { batch, batchId in
                let state = FilteringNotificationAdmission(batchId: batchId, accountIdentity: identity,
                    accountObject: object, revision: revisions.read(), currentRevision: { revisions.read() })
                return .single(ExteralessAdmittedNotificationBatch(messages: batch, admission: ExteralessNotificationAdmission(state: state)))
            }).start(next: { [weak self] delivery in
                self?.engineCallbacks.append { [weak self] in
                    self?.lockCallbacks.append { [weak self] in
                        guard let self else { return }
                        let receiver = ObjectIdentifier(self.receiverObject ?? self.accountObject)
                        for effect in [FilteringNotificationEffect.sound, .vibration, .enqueue] {
                            delivery.admission.state.performIfCurrent(accountIdentity: self.identity,
                                accountObject: receiver, effect: effect) {
                                self.effects.append(effect)
                            }
                        }
                    }
                }
            })
        }

        func send(_ id: Int32 = 1) {
            let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(303))
            let message = Message(stableId: UInt32(id), stableVersion: 0,
                id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: id), globallyUniqueId: nil,
                groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: id, flags: [.Incoming],
                tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil,
                text: "synthetic", attributes: [], media: [], peers: SimpleDictionary<PeerId, Peer>(),
                associatedMessages: SimpleDictionary<MessageId, Message>(), associatedMessageIds: [],
                associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
            self.source.putNext([([message], .root, true, nil)])
        }

        func finishEngineHop() {
            let callbacks = self.engineCallbacks
            self.engineCallbacks.removeAll()
            for callback in callbacks { callback() }
        }

        func finishLockHop() {
            let callbacks = self.lockCallbacks
            self.lockCallbacks.removeAll()
            for callback in callbacks { callback() }
        }

        deinit { self.disposable?.dispose() }
    }

    func testFilterAndHiddenChangesBetweenAsyncHopsPreventAllEffects() {
        for hidden in [false, true] {
            let fixture = Fixture()
            fixture.send()
            fixture.finishEngineHop()
            if hidden { fixture.revisions.changeHidden() } else { fixture.revisions.changeFilter() }
            fixture.finishLockHop()
            XCTAssertTrue(fixture.effects.isEmpty)
        }
    }

    func testDisposedAndSupersededBatchesCannotReachLateCallbacks() {
        let disposed = Fixture()
        disposed.send()
        disposed.finishEngineHop()
        disposed.disposable?.dispose()
        disposed.finishLockHop()
        XCTAssertTrue(disposed.effects.isEmpty)

        let superseded = Fixture()
        superseded.send()
        superseded.finishEngineHop()
        superseded.send(2)
        superseded.finishLockHop()
        XCTAssertTrue(superseded.effects.isEmpty)
        superseded.finishEngineHop()
        superseded.finishLockHop()
        XCTAssertEqual(superseded.effects, [.sound, .vibration, .enqueue])
    }

    func testSameIdentityWithAReplacementReceiverObjectIsRejected() {
        let fixture = Fixture()
        fixture.send()
        fixture.finishEngineHop()
        fixture.receiverObject = NSObject()
        fixture.finishLockHop()
        XCTAssertTrue(fixture.effects.isEmpty)
    }

    func testUnchangedPolicyAdmitsEachImmediateEffectOnlyOnce() throws {
        let fixture = Fixture()
        fixture.send()
        fixture.finishEngineHop()
        let repeated = try XCTUnwrap(fixture.lockCallbacks.first)
        repeated()
        repeated()
        fixture.finishLockHop()
        XCTAssertEqual(fixture.effects, [.sound, .vibration, .enqueue])
    }
}
