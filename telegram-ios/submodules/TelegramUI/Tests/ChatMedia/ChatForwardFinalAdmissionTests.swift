import AccountContext
import ChatInterfaceState
import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox
@testable import TelegramCore
@testable import TelegramUI

/// Real ChatInterfaceState.update -> Postbox read -> transform -> queued native
/// setter. No Account/Network, UI export, Photos or RPC is constructed.
@MainActor
final class ChatForwardFinalAdmissionTests: XCTestCase {
    func testHeldPeerAndThreadWriteAfterTransformRevokeAndDisposeMakesZeroWrites() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        for target in ForwardDraftStore.targets {
            let store = ForwardDraftStore(db: db)
            try store.seed(target, state: store.richDraft("original"))
            let before = try store.snapshot(target)
            let access = db.access(expected: [try db.message()])
            let admission = access.draftWriteAdmission(peerId: target.peer, threadId: target.thread, permit: access.permit, accountId: db.accountId, sourceMessageIds: [db.id])
            let hold = ForwardDraftHold()
            store.hold = hold
            let navigations = Atomic(value: 0)
            let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: admission, { @Sendable state in
                hold.transformed.signal()
                return state.withUpdatedForwardMessageIds([db.id]).withUpdatedForwardOptionsState(.init(hideNames: true, hideCaptions: false, unhideNamesOnCaptionChange: false))
            }).start(next: exteralessForwardDraftCompletion { _ = navigations.modify { $0 + 1 } })
            XCTAssertEqual(hold.transformed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(hold.entered.wait(timeout: .now() + 1), .success)
            access.permit.revoke()
            pending.dispose()
            hold.release.signal()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success, "the disposed Postbox body really ran")
            let after = try store.snapshot(target)
            XCTAssertEqual(store.results.count, 1)
            XCTAssertEqual(store.writes, 0)
            XCTAssertNotNil(store.results.first?.rejection)
            XCTAssertEqual(store.results.first?.peerId, target.peer)
            XCTAssertEqual(store.results.first?.threadId, target.thread)
            XCTAssertEqual(after.storedState, before.storedState)
            XCTAssertEqual(after.state?.opaqueData, before.state?.opaqueData, "rich/media/reply/forward bytes unchanged")
            XCTAssertEqual(navigations.with { $0 }, 0)
            access.cancel()
        }
    }

    func testOperationCancellationWhilePermitRemainsValidStillDeniesQueuedWrite() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        let target = ForwardDraftStore.targets[0]
        let store = ForwardDraftStore(db: db)
        try store.seed(target, state: store.richDraft("cancel"))
        let before = try store.snapshot(target)
        let access = db.access(expected: [try db.message()])
        let admission = access.draftWriteAdmission(peerId: target.peer, threadId: target.thread, permit: access.permit, accountId: db.accountId, sourceMessageIds: [db.id])
        let hold = ForwardDraftHold()
        store.hold = hold
        let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: nil, admission: admission, { @Sendable state in state.withUpdatedForwardMessageIds([db.id]) }).start()
        XCTAssertEqual(hold.entered.wait(timeout: .now() + 1), .success)
        access.cancel()
        XCTAssertTrue(access.permit.allows(accountId: db.accountId))
        pending.dispose()
        hold.release.signal()
        XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(try store.snapshot(target).storedState, before.storedState)
    }

    func testNativeCASPreservesUnrelatedNewRichDestinationDraftForPeerAndThread() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        for target in ForwardDraftStore.targets {
            let store = ForwardDraftStore(db: db)
            try store.seed(target, state: store.richDraft("old"))
            let replacement = ForwardDraftOpaque(state: try store.opaque(store.richDraft("new user draft")))
            store.intervening = { transaction in
                let written = _internal_writeChatInterfaceState(transaction: transaction, accountId: db.accountId, peerId: target.peer, threadId: target.thread, state: replacement.state, expectedState: nil, admission: nil)
                XCTAssertTrue(written.isWritten)
                store.rememberIntervening(_internal_chatInterfaceStateSnapshot(transaction: transaction, accountId: db.accountId, peerId: target.peer, threadId: target.thread))
            }
            let access = db.access(expected: [try db.message()])
            let admission = access.draftWriteAdmission(peerId: target.peer, threadId: target.thread, permit: access.permit, accountId: db.accountId, sourceMessageIds: [db.id])
            let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: admission, { @Sendable state in state.withUpdatedForwardMessageIds([db.id]) }).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            let after = try store.snapshot(target)
            XCTAssertEqual(store.results.first?.rejection, .destinationChanged)
            XCTAssertEqual(store.writes, 0)
            XCTAssertEqual(after.storedState, try XCTUnwrap(store.interveningSnapshot).storedState)
            XCTAssertEqual(after.state?.opaqueData, store.interveningSnapshot?.state?.opaqueData)
            XCTAssertTrue(access.permit.allows(accountId: db.accountId), "CAS must work even with an otherwise valid permit")
            pending.dispose()
            access.cancel()
            store.intervening = nil
        }
    }

    func testSourcePolicyVersionDeletionAndThreadAreReadInsideTheActualWriteTransaction() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        for reason in 0 ..< 5 {
            try db.protect([])
            try db.transaction { transaction in _ = transaction.addMessages([db.stored()], location: .Random) }
            let target = ForwardDraftStore.targets[reason % 2]
            let store = ForwardDraftStore(db: db)
            try store.seed(target, state: store.richDraft("protected"))
            let before = try store.snapshot(target)
            let access = db.access(expected: [try db.message()])
            let admission = access.draftWriteAdmission(peerId: target.peer, threadId: target.thread, permit: access.permit, accountId: db.accountId, sourceMessageIds: [db.id])
            // No UI source observer has been started. Only the terminal native
            // transaction can see this intervening source/policy change.
            store.intervening = { transaction in
                switch reason {
                case 0: transaction.updatePeerCachedData(peerIds: [db.peer]) { _, _ in CachedUserData().withUpdatedFlags([.copyProtectionEnabled]) }
                case 1: transaction.updatePeerCachedData(peerIds: [db.peer]) { _, _ in CachedUserData().withUpdatedFlags([.myCopyProtectionEnabled]) }
                case 2: transaction.updateMessage(db.id, update: { _ in .update(db.stored(text: "edited source")) })
                case 3: transaction.deleteMessages([db.id], forEachMedia: nil)
                default: transaction.updateMessage(db.id, update: { _ in .update(db.stored(thread: 77)) })
                }
            }
            let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: admission, { @Sendable state in state.withUpdatedForwardMessageIds([db.id]) }).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(store.writes, 0)
            XCTAssertEqual(store.results.first?.rejection, reason < 2 ? .copyProtected : .sourceChanged)
            XCTAssertEqual(try store.snapshot(target).storedState, before.storedState)
            pending.dispose()
            access.cancel()
        }
    }

    func testPositiveNativeWriteOncePreservesRichReplyAndOptionsForPeerAndThread() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        for target in ForwardDraftStore.targets {
            let store = ForwardDraftStore(db: db)
            try store.seed(target, state: store.richDraft("positive"))
            let before = ChatInterfaceState.parse(try XCTUnwrap(store.snapshot(target).state))
            let access = db.access(expected: [try db.message()])
            let admission = access.draftWriteAdmission(peerId: target.peer, threadId: target.thread, permit: access.permit, accountId: db.accountId, sourceMessageIds: [db.id])
            let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: admission, { @Sendable state in state.withUpdatedForwardMessageIds([db.id]) }).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            let afterSnapshot = try store.snapshot(target)
            let after = ChatInterfaceState.parse(try XCTUnwrap(afterSnapshot.state))
            XCTAssertEqual(store.writes, 1)
            XCTAssertTrue(store.results.first?.isWritten == true)
            XCTAssertEqual(after.forwardMessageIds, [db.id])
            XCTAssertEqual(after.replyMessageSubject, before.replyMessageSubject)
            XCTAssertEqual(after.forwardOptionsState, before.forwardOptionsState)
            XCTAssertEqual(instantPage(from: after.composeInputState.content), instantPage(from: before.composeInputState.content))
            // Even with a current CAS operand, a repeated execution cannot write.
            let duplicate = store.setOpaqueChatInterfaceStateWithResult(peerId: target.peer, threadId: target.thread, state: try XCTUnwrap(afterSnapshot.state), expectedState: afterSnapshot, admission: admission).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(store.writes, 1)
            XCTAssertEqual(store.results.last?.rejection, .alreadyCommitted)
            XCTAssertEqual(try store.snapshot(target).storedState, afterSnapshot.storedState)
            duplicate.dispose()
            pending.dispose()
            access.cancel()
        }
    }

    func testWrongAccountPeerNamespaceThreadAndUndecodableStateFailWithoutDataLoss() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        let target = ForwardDraftStore.targets[1]
        let store = ForwardDraftStore(db: db)
        try store.seed(target, state: store.richDraft("identity"))
        let before = try store.snapshot(target)
        for mismatch in 0 ..< 3 {
            let admission = ChatInterfaceStateWriteAdmission(accountId: mismatch == 0 ? db.accountId + 1 : db.accountId, peerId: mismatch == 1 ? ForwardDraftStore.targets[0].peer : target.peer, threadId: mismatch == 2 ? nil : target.thread, sourceMessages: [try db.message()], execute: { $0() })
            let pending = store.setOpaqueChatInterfaceStateWithResult(peerId: target.peer, threadId: target.thread, state: try XCTUnwrap(before.state), expectedState: before, admission: admission).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(store.results.last?.rejection, .identityMismatch)
            XCTAssertEqual(store.writes, 0)
            pending.dispose()
        }
        XCTAssertEqual(try store.snapshot(target).storedState, before.storedState)
        for mismatch in 0 ..< 3 {
            let expected = OpaqueChatInterfaceStateSnapshot(accountId: mismatch == 0 ? db.accountId + 1 : db.accountId, peerId: mismatch == 1 ? ForwardDraftStore.targets[0].peer : target.peer, threadId: mismatch == 2 ? nil : target.thread, storedState: before.storedState)
            let pending = store.setOpaqueChatInterfaceStateWithResult(peerId: target.peer, threadId: target.thread, state: try XCTUnwrap(before.state), expectedState: expected, admission: nil).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(store.results.last?.rejection, .identityMismatch)
            XCTAssertEqual(store.writes, 0)
            pending.dispose()
        }
        let invalid = OpaqueChatInterfaceState(opaqueData: Data([0xff, 0x00, 0x7f]), historyScrollMessageIndex: nil, mediaDraftState: nil, synchronizeableInputState: nil)
        try db.transaction { transaction in
            _ = _internal_writeChatInterfaceState(transaction: transaction, accountId: db.accountId, peerId: target.peer, threadId: target.thread, state: invalid, expectedState: nil, admission: nil)
        }
        let invalidSnapshot = try store.snapshot(target)
        let ended = DispatchSemaphore(value: 0)
        let result = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: nil, expectedState: invalidSnapshot, { @Sendable _ in XCTFail("invalid opaque data reached transform"); return ChatInterfaceState() }).start(next: { value in
            XCTAssertEqual(value.rejection, .decodingFailed)
            ended.signal()
        })
        XCTAssertEqual(ended.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try store.snapshot(target).storedState, invalidSnapshot.storedState)
        XCTAssertEqual(store.writes, 0)
        result.dispose()
    }

    func testAbsentReadSnapshotCannotOverwriteANewPeerOrThreadDraft() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        for target in ForwardDraftStore.targets {
            let store = ForwardDraftStore(db: db)
            let absent = try store.snapshot(target)
            XCTAssertNil(absent.storedState)
            try store.seed(target, state: store.richDraft("inserted after absent read"))
            let inserted = try store.snapshot(target)
            let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: nil, expectedState: absent, { @Sendable state in state.withUpdatedForwardMessageIds([db.id]) }).start()
            XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(store.results.first?.rejection, .destinationChanged)
            XCTAssertEqual(store.writes, 0)
            XCTAssertEqual(try store.snapshot(target).storedState, inserted.storedState)
            pending.dispose()
        }
    }

    func testNilAdmissionAndExpectedStateKeepTheLegacyUnconditionalContract() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        let target = ForwardDraftStore.targets[0]
        let store = ForwardDraftStore(db: db)
        try store.seed(target, state: store.richDraft("legacy original"))
        let replacement = ForwardDraftOpaque(state: try store.opaque(store.richDraft("intervening")))
        store.intervening = { transaction in
            _ = _internal_writeChatInterfaceState(transaction: transaction, accountId: db.accountId, peerId: target.peer, threadId: target.thread, state: replacement.state, expectedState: nil, admission: nil)
        }
        let pending = ChatInterfaceState.update(source: store, peerId: target.peer, threadId: target.thread, admission: nil, { @Sendable state in state.withUpdatedForwardMessageIds([db.id]) }).start()
        XCTAssertEqual(store.executed.wait(timeout: .now() + 1), .success)
        let state = ChatInterfaceState.parse(try XCTUnwrap(store.snapshot(target).state))
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(state.inputLanguage, "legacy original")
        XCTAssertEqual(state.forwardMessageIds, [db.id])
        pending.dispose()
    }
}

private final class ForwardDraftHold: @unchecked Sendable {
    let transformed = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private struct ForwardDraftOpaque: @unchecked Sendable {
    let state: OpaqueChatInterfaceState
}

/// Only queue barriers/receipts are injected. Both reads and writes call the
/// actual production Core functions on this real Postbox, including disposal.
private final class ForwardDraftStore: ChatInterfaceStateUpdating, @unchecked Sendable {
    struct Target: @unchecked Sendable {
        let peer: EnginePeer.Id
        let thread: Int64?
    }
    static var targets: [Target] { [
        Target(peer: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9430)), thread: nil),
        Target(peer: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(9430)), thread: 421)
    ] }
    let db: ChatMediaNativeFixture
    let executed = DispatchSemaphore(value: 0)
    var hold: ForwardDraftHold?
    var intervening: (@Sendable (Transaction) -> Void)?
    private let lock = NSLock()
    private var records: [ChatInterfaceStateWriteResult] = []
    private var replacement: OpaqueChatInterfaceStateSnapshot?
    var results: [ChatInterfaceStateWriteResult] { self.lock.lock(); defer { self.lock.unlock() }; return self.records }
    var writes: Int { self.results.filter(\.isWritten).count }
    var interveningSnapshot: OpaqueChatInterfaceStateSnapshot? { self.lock.lock(); defer { self.lock.unlock() }; return self.replacement }

    init(db: ChatMediaNativeFixture) { self.db = db }

    func rememberIntervening(_ snapshot: OpaqueChatInterfaceStateSnapshot) {
        self.lock.lock(); self.replacement = snapshot; self.lock.unlock()
    }

    func richDraft(_ marker: String) -> ChatInterfaceState {
        let original = self.db.rich([self.db.imageA, self.db.video]).instantPage
        let page = InstantPage(blocks: [.paragraph(.plain(marker))] + original.blocks, media: original.media, isComplete: true, rtl: false, url: "", views: nil)
        let content = chatInputContent(fromInstantPage: page)
        let quote = EngineMessageReplyQuote(text: "quoted 👋", offset: 0, entities: [.init(range: 0 ..< 6, type: .Bold)], media: self.db.imageB, richText: [.bold(.plain("quoted 👋"))])
        return ChatInterfaceState().withUpdatedComposeInputState(ChatTextInputState(content: content, selectionRange: 0 ..< 0))
            .withUpdatedReplyMessageSubject(.init(messageId: self.db.id, quote: quote, innerSubject: nil))
            .withUpdatedForwardMessageIds([EngineMessage.Id(peerId: self.db.peer, namespace: Namespaces.Message.Cloud, id: 99)])
            .withUpdatedForwardOptionsState(.init(hideNames: true, hideCaptions: true, unhideNamesOnCaptionChange: false))
            .withUpdatedInputLanguage(marker).withUpdatedTimestamp(100)
    }

    func opaque(_ state: ChatInterfaceState) throws -> OpaqueChatInterfaceState {
        OpaqueChatInterfaceState(opaqueData: try EngineEncoder.encode(state), historyScrollMessageIndex: state.historyScrollMessageIndex, mediaDraftState: nil, synchronizeableInputState: state.synchronizeableInputState)
    }

    func seed(_ target: Target, state: ChatInterfaceState) throws {
        let opaque = try self.opaque(state)
        try self.db.transaction { transaction in
            XCTAssertTrue(_internal_writeChatInterfaceState(transaction: transaction, accountId: self.db.accountId, peerId: target.peer, threadId: target.thread, state: opaque, expectedState: nil, admission: nil).isWritten)
        }
    }

    func snapshot(_ target: Target) throws -> OpaqueChatInterfaceStateSnapshot {
        try self.db.transaction { _internal_chatInterfaceStateSnapshot(transaction: $0, accountId: self.db.accountId, peerId: target.peer, threadId: target.thread) }
    }

    func getOpaqueChatInterfaceStateSnapshot(peerId: EnginePeer.Id, threadId: Int64?) -> Signal<OpaqueChatInterfaceStateSnapshot, NoError> {
        self.db.postbox.transaction { _internal_chatInterfaceStateSnapshot(transaction: $0, accountId: self.db.accountId, peerId: peerId, threadId: threadId) }
    }

    func setOpaqueChatInterfaceStateWithResult(peerId: EnginePeer.Id, threadId: Int64?, state: OpaqueChatInterfaceState, expectedState: OpaqueChatInterfaceStateSnapshot?, admission: ChatInterfaceStateWriteAdmission?) -> Signal<ChatInterfaceStateWriteResult, NoError> {
        if let intervening = self.intervening {
            let _ = self.db.postbox.transaction(intervening).start()
        }
        if let hold = self.hold {
            self.db.queue.justDispatch {
                hold.entered.signal()
                _ = hold.release.wait(timeout: .now() + 2)
            }
        }
        return _internal_setOpaqueChatInterfaceState(postbox: self.db.postbox, accountId: self.db.accountId, peerId: peerId, threadId: threadId, state: state, expectedState: expectedState, admission: admission, observeWriteBody: { result in
            XCTAssertFalse(Thread.isMainThread, "the native write/claim must execute on Postbox, not sync to MainActor")
            self.lock.lock(); self.records.append(result); self.lock.unlock()
            self.executed.signal()
        })
    }
}
