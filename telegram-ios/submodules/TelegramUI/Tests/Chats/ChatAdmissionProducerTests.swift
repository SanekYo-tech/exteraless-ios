import AccountContext
import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import XCTest
@testable import TelegramUI

@MainActor
final class ChatAdmissionProducerTests: XCTestCase {
    private let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))
    private func message(_ correlation: Int64? = nil) -> EnqueueMessage {
        let page = InstantPage(blocks: [.paragraph(.plain("draft"))], media: [:], isComplete: true, rtl: false, url: "", views: nil)
        return .message(text: "", attributes: [RichTextMessageAttribute(instantPage: page, fullInstantPage: nil)], inlineStickers: [:], mediaReference: nil, threadId: 42, replyToMessageId: .init(messageId: MessageId(peerId: peer, namespace: 0, id: 8), quote: nil, innerSubject: nil), replyToStoryId: nil, localGroupingKey: 100, correlationId: correlation, bubbleUpEmojiOrStickersets: [])
    }

    func testReduceMotionNilCorrelationRefusalsCannotArmUnrelatedHistoryCleanup() {
        for reason in [EnqueueMessageRejectionReason.pluginCancelled, .botAuthorizationDenied, .retainedReplyUnavailable, .cancelledBeforeCommit, .localEnqueueUnavailable] {
            let result = ValuePipe<EnqueueMessagesResult>()
            var draft = "rich body + media + reply + forward"
            var errors: [EnqueueMessageRejectionReason] = []
            var received: [EnqueueMessage] = []
            let operation = ExteralessChatSendOperation(matchesRevision: { true }, cleanup: { draft = "" }, retireLayout: { _ in }, cancelTransitions: { _ in }, failure: { errors.append($0.firstRejection!) })
            let outgoing = message() // Actual Reduce Motion case: no transition correlation.
            let subscription = exteralessSubmitChatBatch(messages: [outgoing], operation: operation, enqueue: { received = $0; return result.signal() }).start()
            XCTAssertEqual(received.count, 1)
            XCTAssertFalse(operation.cleanupIfAdmitted(), "unrelated history while admission is held")
            result.putNext(.rejected(count: 1, reason: reason))
            XCTAssertFalse(operation.cleanupIfAdmitted(), "unrelated history after terminal refusal")
            XCTAssertEqual(draft, "rich body + media + reply + forward")
            XCTAssertEqual(errors, [reason])
            subscription.dispose()
        }
    }

    func testPartialBatchRetainsDraftAndCancelsOnlyRejectedOwnedTransitions() {
        let result = ValuePipe<EnqueueMessagesResult>()
        var cleanups = 0
        var cancelled = Set<Int64>()
        var observed: EnqueueMessagesResult?
        let operation = ExteralessChatSendOperation(matchesRevision: { true }, cleanup: { cleanups += 1 }, retireLayout: { _ in }, cancelTransitions: { cancelled.formUnion($0) }, failure: { observed = $0 })
        let messages = [message(11), message(12)]
        let subscription = exteralessSubmitChatBatch(messages: messages, operation: operation, enqueue: { _ in result.signal() }).start()
        let id = MessageId(peerId: peer, namespace: Namespaces.Message.Local, id: 1)
        result.putNext(.init(slots: [.enqueued(id), .rejected(.pluginCancelled)]))
        XCTAssertEqual(observed?.messageIds, [id, nil])
        XCTAssertEqual(cleanups, 0)
        XCTAssertEqual(cancelled, [12])
        XCTAssertFalse(cancelled.contains(99), "another operation's animation remains registered")
        subscription.dispose()
    }

    func testCommittedOldDraftNeverClearsNewInputAndCannotRetireNewLayoutOwner() {
        let result = ValuePipe<EnqueueMessagesResult>()
        var revision = 0
        var draft = "A"
        var layoutOwner: UUID?
        var retiredB = 0
        let operation = ExteralessChatSendOperation(matchesRevision: { revision == 0 }, cleanup: { draft = "" }, retireLayout: { id in
            if layoutOwner == id { retiredB += 1; layoutOwner = nil }
        }, cancelTransitions: { _ in }, failure: { _ in XCTFail("stale UI error") })
        layoutOwner = UUID() // An independent B operation has taken over the UI slot.
        let subscription = exteralessSubmitChatBatch(messages: [message()], operation: operation, enqueue: { _ in result.signal() }).start()
        revision += 1; draft = "B: newly typed"
        result.putNext(.committed(messageIds: [MessageId(peerId: peer, namespace: Namespaces.Message.Local, id: 2)]))
        XCTAssertEqual(draft, "B: newly typed")
        XCTAssertEqual(retiredB, 0)
        XCTAssertFalse(operation.cleanupIfAdmitted())
        subscription.dispose()
    }

    func testSuccessfulMatchingRevisionClearsOnceOnlyAfterLocalResult() {
        let result = ValuePipe<EnqueueMessagesResult>()
        var cleanups = 0
        let operation = ExteralessChatSendOperation(matchesRevision: { true }, cleanup: { cleanups += 1 }, retireLayout: { _ in }, cancelTransitions: { _ in }, failure: { _ in XCTFail() })
        let subscription = exteralessSubmitChatBatch(messages: [message(4)], operation: operation, enqueue: { _ in result.signal() }).start()
        XCTAssertEqual(cleanups, 0)
        let committed = EnqueueMessagesResult.committed(messageIds: [MessageId(peerId: peer, namespace: Namespaces.Message.Local, id: 3)])
        result.putNext(committed); result.putNext(committed)
        _ = operation.cleanupIfAdmitted()
        XCTAssertEqual(cleanups, 1)
        subscription.dispose()
    }

    func testInheritedExportPermitIsRecheckedAtActualCommitAndNeverWidened() {
        let source = MessageId(peerId: peer, namespace: 0, id: 7)
        let permit = ExteralessContentExportPermit(accountId: 3, messageIds: [source], exportAllowed: true)
        let commit = exteralessExportEnqueueCommit(permit: permit, accountId: 3, sourceMessageIds: [source])
        XCTAssertTrue(commit.allowsContinuation())
        permit.revoke()
        XCTAssertFalse(commit.beginCommit(), "revoked after preparation, before queued transaction")
        let fresh = ExteralessContentExportPermit(accountId: 3, messageIds: [source], exportAllowed: true)
        XCTAssertFalse(exteralessExportEnqueueCommit(permit: fresh, accountId: 4, sourceMessageIds: [source]).beginCommit())
        XCTAssertFalse(exteralessExportEnqueueCommit(permit: fresh, accountId: 3, sourceMessageIds: [MessageId(peerId: peer, namespace: 0, id: 8)]).beginCommit())
    }

    func testClaimedExportCommitKeepsTrackingAfterUIRevocationAndDisposal() {
        let source = MessageId(peerId: peer, namespace: 0, id: 7)
        let permit = ExteralessContentExportPermit(accountId: 3, messageIds: [source], exportAllowed: true)
        let commit = exteralessExportEnqueueCommit(permit: permit, accountId: 3, sourceMessageIds: [source])
        var cancelled = 0, tracked = 0
        commit.bindCancellation { cancelled += 1 }
        XCTAssertTrue(commit.beginCommit())
        permit.revoke(); commit.cancelSubscriber()
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(commit.complete(track: { claimed in XCTAssertTrue(claimed); tracked += 1 }), false)
        XCTAssertEqual(tracked, 1); XCTAssertEqual(cancelled, 1)
        XCTAssertNil(commit.complete(track: { _ in XCTFail("duplicate terminal") }))
    }
}
