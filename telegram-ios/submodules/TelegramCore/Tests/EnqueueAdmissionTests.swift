import Postbox
import SwiftSignalKit
import XCTest
@testable import TelegramCore

@MainActor
final class EnqueueAdmissionTests: XCTestCase {
    func testTypedSlotsPreserveCancellationAndDownstreamReasonWithLegacyArrayShape() {
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1))
        let id = MessageId(peerId: peer, namespace: Namespaces.Message.Local, id: 1)
        let result = EnqueueMessagesResult(slots: [.enqueued(id), .rejected(.retainedReplyUnavailable)]).restoringSlots(count: 4, acceptedIndices: [1, 3])
        XCTAssertEqual(result.slots, [.rejected(.pluginCancelled), .enqueued(id), .rejected(.pluginCancelled), .rejected(.retainedReplyUnavailable)])
        XCTAssertEqual(result.messageIds, [nil, id, nil, nil])
        XCTAssertTrue(result.hasEnqueuedMessages); XCTAssertFalse(result.allEnqueued)
    }

    func testCancellationWhilePendingEditSourceReadIsHeldPreventsInstallation() {
        let source = ValuePipe<Bool>()
        let token = PendingMessageUpdateAdmissionToken()
        var installed = 0
        var result: PendingMessageUpdateAdmission?
        let subscription = admitPendingMessageUpdate(sourceMatches: source.signal(), token: token, queue: .mainQueue(), install: { installed += 1 }).start(next: { result = $0 })
        token.cancel()
        source.putNext(true)
        XCTAssertEqual(installed, 0)
        XCTAssertEqual(result, .rejected(.cancelledBeforeCommit))
        subscription.dispose()
    }

    func testAdmittedEditInstallsOnceAndDisposalDoesNotReclassifyIt() {
        let token = PendingMessageUpdateAdmissionToken()
        var installed = 0
        var result: PendingMessageUpdateAdmission?
        let subscription = admitPendingMessageUpdate(sourceMatches: .single(true), token: token, queue: .mainQueue(), install: { installed += 1 }).start(next: { result = $0 })
        subscription.dispose(); token.cancel()
        XCTAssertEqual(installed, 1); XCTAssertEqual(result, .admitted)
        XCTAssertFalse(token.claimCommit())
    }
}
