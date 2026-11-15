import Foundation
import XCTest
@testable import ExteralessCore

final class FeedTests: XCTestCase {
    private func entry(_ peer: Int64, _ id: Int32, _ time: Int32, group: Int64? = nil, namespace: Int32 = 0, order: Int64? = nil) -> ChatFeedEntry {
        ChatFeedEntry(position: ChatFeedPosition(timestamp: time, identity: .init(peerId: peer, namespace: namespace, messageId: id), orderingPeerId: order), groupId: group)
    }

    func testOriginalSignedDialogTieOrderKeepsNativeIdentity() {
        // Android uid = -channelId; iOS PeerId values include the channel namespace.
        let a = self.entry(2_000_010, 7, 100, order: -10)
        let b = self.entry(2_000_020, 7, 100, order: -20)
        let c = self.entry(2_000_020, 8, 100, order: -20)
        let newer = self.entry(2_000_020, 9, 101, order: -20)
        let result = ChatFeedPolicy.ordered([b, a, c, newer], allowedPeers: [2_000_010, 2_000_020])
        XCTAssertEqual(result.map(\.identity), [newer.identity, a.identity, c.identity, b.identity])
        XCTAssertEqual(result[1].identity.peerId, 2_000_010)
        XCTAssertEqual(result[2].identity.messageId, 8)
    }

    func testFrontierInsideAnAlbumPreservesTailAndInterleavedNextWindow() {
        let head = self.entry(1, 5, 105, group: 77)
        let tail = self.entry(1, 4, 100, group: 77)
        let middle = self.entry(2, 4, 103)
        let otherPeerAlbum = self.entry(2, 3, 99, group: 77)
        let all = [head, middle, tail, otherPeerAlbum]
        let first = ChatFeedPolicy.ordered(all, allowedPeers: [1, 2], lowerBound: middle.position, limit: 2)
        XCTAssertEqual(first.map(\.identity), [head.identity, tail.identity])
        let second = ChatFeedPolicy.ordered(ChatFeedPolicy.remaining(after: first, in: all), allowedPeers: [1, 2])
        XCTAssertEqual(second.map(\.identity), [middle.identity, otherPeerAlbum.identity])
        XCTAssertEqual(Set((first + second).map(\.identity)).count, all.count)
    }

    func testNamespaceAndPeerScopedAlbumIdentitySurvivesEditsAndRemovals() {
        let first = self.entry(1, 10, 100, group: 50)
        let second = self.entry(2, 10, 99, group: 50)
        let local = self.entry(1, 10, 98, group: 50, namespace: 1)
        let posts = FeedPresentationPolicy.posts(ChatFeedPolicy.ordered([first, second, local], allowedPeers: [1, 2]))
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(Set(posts.map { FeedPostIdentity($0[0]) }).count, 3)
        let edited = ChatFeedEntry(position: first.position, groupId: first.groupId, version: 3)
        XCTAssertEqual(FeedPostIdentity(first), FeedPostIdentity(edited))
    }

    func testReceiptBatchesNeverUseAMaximumFromAnotherPeerOrNamespace() throws {
        var tracker = FeedUnreadTracker(accountId: 100)
        tracker.update(included: [.init(id: 1), .init(id: 2)], snapshots: [
            .init(peer: .init(id: 1), maxReadId: 9, unreadCount: 4),
            .init(peer: .init(id: 2), maxReadId: 900, unreadCount: 2)
        ])
        let a = self.entry(1, 11, 11)
        let b = self.entry(2, 901, 12)
        XCTAssertTrue(tracker.seen(a.position, now: 0))
        XCTAssertTrue(tracker.seen(b.position, now: 0.4))
        XCTAssertFalse(tracker.seen(self.entry(1, 900, 13, namespace: 1).position, now: 0.5))
        XCTAssertNil(tracker.takeBatch(now: 0.999))
        let batch = try XCTUnwrap(tracker.takeBatch(now: 1))
        XCTAssertEqual(batch.accountId, 100)
        XCTAssertEqual(Set(batch.positions.map(\.identity)), [a.identity, b.identity])
        XCTAssertTrue(tracker.complete(batch, applied: [a.identity, b.identity], now: 1.1))
        XCTAssertFalse(tracker.isUnread(a.identity))
        XCTAssertTrue(tracker.isUnread(self.entry(1, 12, 12).identity))
        // Numeric holes cannot be used to infer a countDiff; the native snapshot supplies it.
        XCTAssertEqual(tracker.unreadCount, 6)
        tracker.update(included: [.init(id: 1), .init(id: 2)], snapshots: [
            .init(peer: .init(id: 1), maxReadId: 11, unreadCount: 2),
            .init(peer: .init(id: 2), maxReadId: 901, unreadCount: 1)
        ])
        XCTAssertEqual(tracker.unreadCount, 3)
    }

    func testVisibleReceiptCannotEscapeItsAccountAfterReplacement() throws {
        var old = FeedUnreadTracker(accountId: 1)
        var replacement = FeedUnreadTracker(accountId: 2)
        let snapshots = [FeedUnreadTracker.Snapshot(peer: .init(id: 10), maxReadId: 0, unreadCount: 1)]
        old.update(included: [.init(id: 10)], snapshots: snapshots)
        replacement.update(included: [.init(id: 10)], snapshots: snapshots)
        let position = self.entry(10, 4, 100).position
        old.seen(position, now: 0)
        let batch = try XCTUnwrap(old.takeBatch(now: 1))
        old.invalidate()
        XCTAssertFalse(old.complete(batch, applied: [position.identity], now: 2))
        XCTAssertFalse(replacement.complete(batch, applied: [position.identity], now: 2))
        XCTAssertTrue(replacement.isUnread(position.identity))
        XCTAssertNil(replacement.takeBatch(now: 10, force: true))
    }

    func testExclusionCancelsPendingReceiptAndBadgeWithoutMarkingOtherPeers() {
        var tracker = FeedUnreadTracker(accountId: 1)
        tracker.update(included: [.init(id: 1), .init(id: 2)], snapshots: [
            .init(peer: .init(id: 1), maxReadId: 0, unreadCount: 7),
            .init(peer: .init(id: 2), maxReadId: 0, unreadCount: 3)
        ])
        tracker.seen(self.entry(1, 20, 100).position, now: 0)
        tracker.update(included: [.init(id: 2)], snapshots: [])
        XCTAssertNil(tracker.takeBatch(now: 1))
        XCTAssertEqual(tracker.unreadCount, 3)
        XCTAssertTrue(tracker.isUnread(self.entry(2, 1, 99).identity))
    }

    func testReceiptFailureRetriesWithoutLosingANewerVisibleFrontier() throws {
        var tracker = FeedUnreadTracker(accountId: 1)
        tracker.update(included: [.init(id: 1)], snapshots: [.init(peer: .init(id: 1), maxReadId: 0, unreadCount: 20)])
        let first = self.entry(1, 10, 10)
        let next = self.entry(1, 12, 12)
        tracker.seen(first.position, now: 0)
        let batch = try XCTUnwrap(tracker.takeBatch(now: 1))
        tracker.seen(next.position, now: 1.1)
        XCTAssertTrue(tracker.complete(batch, applied: [], now: 1.2))
        let retry = try XCTUnwrap(tracker.takeBatch(now: 2.2))
        XCTAssertEqual(retry.positions.map(\.identity), [next.identity])
        XCTAssertFalse(tracker.complete(batch, applied: [first.identity], now: 2.3))
    }

    func testUnreadBoundaryIsOutsideWholeAlbumAndIncludesMutedCounters() {
        var tracker = FeedUnreadTracker(accountId: 1)
        tracker.update(included: [.init(id: 1), .init(id: 2)], snapshots: [
            .init(peer: .init(id: 1), maxReadId: 10, unreadCount: 3),
            .init(peer: .init(id: 2), maxReadId: 99, unreadCount: 4)
        ])
        let rows = [self.entry(1, 13, 105), self.entry(1, 12, 103, group: 5), self.entry(1, 10, 100, group: 5), self.entry(2, 99, 99)]
        let posts = FeedPresentationPolicy.posts(rows)
        XCTAssertEqual(FeedPresentationPolicy.unreadBoundary(posts: posts, isUnread: tracker.isUnread), 2)
        XCTAssertEqual(tracker.oldestUnreadIndex(in: rows), 1)
        XCTAssertEqual(tracker.unreadCount, 7)
    }

    func testVisibleNativePostReceiptsWaitForRealLayoutForegroundAndNoOverlay() {
        XCTAssertFalse(FeedPresentationPolicy.admitsReceipt(visibleHeight: 100, postHeight: 200, viewportHeight: 600, active: true, positioned: true, unobscured: true))
        XCTAssertTrue(FeedPresentationPolicy.admitsReceipt(visibleHeight: 600, postHeight: 1200, viewportHeight: 600, active: true, positioned: true, unobscured: true))
        XCTAssertFalse(FeedPresentationPolicy.admitsReceipt(visibleHeight: 600, postHeight: 1200, viewportHeight: 600, active: false, positioned: true, unobscured: true))
        XCTAssertFalse(FeedPresentationPolicy.admitsReceipt(visibleHeight: 200, postHeight: 200, viewportHeight: 600, active: true, positioned: false, unobscured: true))
        XCTAssertFalse(FeedPresentationPolicy.admitsReceipt(visibleHeight: 200, postHeight: 200, viewportHeight: 600, active: true, positioned: true, unobscured: false))
        XCTAssertFalse(FeedPresentationPolicy.admitsReceipt(visibleHeight: .nan, postHeight: 200, viewportHeight: 600, active: true, positioned: true, unobscured: true))
    }

    func testEvictionRewindsOnlyTrimmedSourcesAndWindowsDoNotDuplicate() {
        let entries = (1 ... 1200).map { self.entry(Int64($0 % 3 + 1), Int32($0), Int32($0)) }
        let retention = FeedPresentationPolicy.retention(entries: entries)
        XCTAssertLessThanOrEqual(retention.identities.count, 500 + 4 * 29)
        XCTAssertEqual(Set(retention.rewind.keys), [1, 2, 3])
        for (peer, cursor) in retention.rewind {
            XCTAssertEqual(cursor, entries.filter { $0.identity.peerId == peer && retention.identities.contains($0.identity) }.map(\.position).min())
        }
        let first = ChatFeedPolicy.ordered(entries, allowedPeers: [1, 2, 3], limit: 500)
        let second = ChatFeedPolicy.ordered(ChatFeedPolicy.remaining(after: first, in: entries), allowedPeers: [1, 2, 3], limit: 500)
        XCTAssertEqual(Set(first.map(\.identity)).intersection(second.map(\.identity)), [])
        XCTAssertEqual(first.count + second.count, 1000)
    }

    func testFullPaginationPassesMoreThanOneThousandAndDoesNotEndAtGap() {
        // 13 finite pages; the cursor, not a configured list count, decides completion.
        var seen = Set<Int>()
        for page in 0 ..< 13 {
            let range = page * 100 ..< min(1250, (page + 1) * 100)
            seen.formUnion(range)
            XCTAssertEqual(FeedPageProgress.evaluate(hasEarlier: page < 12, hasGap: false, advanced: !range.isEmpty, succeeded: true), page < 12 ? .more : .end)
        }
        XCTAssertEqual(seen.count, 1250)
        XCTAssertEqual(FeedPageProgress.evaluate(hasEarlier: false, hasGap: true, advanced: false, succeeded: true), .retry)
        XCTAssertEqual(FeedPageProgress.evaluate(hasEarlier: true, hasGap: false, advanced: false, succeeded: true), .retry)
        XCTAssertEqual(FeedPageProgress.evaluate(hasEarlier: false, hasGap: false, advanced: false, succeeded: false), .retry)
    }

    func testRoundCancellationAndThirtySecondFixtureBudgetAreVirtualTimeOnly() {
        var round = ChatFeedLoadRound()
        let old = round.begin(channels: [1, 2, 3, 4, 5], now: 0)
        XCTAssertEqual(old.count, 4)
        round.complete(old[0])
        XCTAssertEqual(round.expire(now: 10), [2, 3, 4])
        let retry = round.begin(channels: [2, 3, 4], now: 11)
        XCTAssertFalse(round.complete(old[1]))
        round.cancel()
        XCTAssertFalse(round.complete(retry[0]))
        XCTAssertTrue(round.pending.isEmpty)
        XCTAssertNil(round.deadline)
    }

    func testCellLeaseRejectsOldMediaAfterEditReuseAndAccountReplacement() {
        var lease = FeedRenderLease()
        let first = FeedPostIdentity(self.entry(1, 1, 1))
        let other = FeedPostIdentity(self.entry(2, 1, 1))
        let loading = lease.begin(accountId: 1, post: first)
        let edited = lease.begin(accountId: 1, post: first)
        XCTAssertFalse(lease.accepts(loading))
        XCTAssertTrue(lease.accepts(edited))
        let reused = lease.begin(accountId: 1, post: other)
        XCTAssertFalse(lease.accepts(edited))
        lease.cancel()
        XCTAssertFalse(lease.accepts(reused))
        let replacement = lease.begin(accountId: 2, post: first)
        XCTAssertFalse(lease.accepts(loading))
        XCTAssertTrue(lease.accepts(replacement))
    }

    func testSemanticMembershipAndFiveHundredMillisecondCoalescing() {
        var config = ChatFeedConfiguration()
        config.setAddNewChannels(false, currentChannels: [1, 2])
        XCTAssertFalse(config.includes(3, archived: false))
        config.setIncluded(3, included: true)
        XCTAssertTrue(config.includes(3, archived: false))
        XCTAssertFalse(config.includes(3, archived: true))
        var gate = ChatFeedRefreshGate()
        for tick in 0 ..< 5 { gate.request(now: Double(tick) / 10.0) }
        XCTAssertEqual(gate.due, 0.5)
        XCTAssertTrue(gate.consume(now: 0.5))
        gate.request(now: 0.6)
        gate.cancel()
        XCTAssertFalse(gate.consume(now: 2))
    }

    func testOriginalIncludeAllClearsDepartedChannelExclusionsButPreservesKnownRules() {
        var config = ChatFeedConfiguration(addNewChannels: false, excludedChannels: [1, 99], knownChannels: [1])
        config.includeAll([1, 2])
        XCTAssertTrue(config.excludedChannels.isEmpty)
        XCTAssertTrue(config.includes(2, archived: false))
        XCTAssertFalse(config.includes(99, archived: false))
        config.setAddNewChannels(true, currentChannels: [1, 2])
        XCTAssertTrue(config.includes(99, archived: false))
    }

    func testOnlyMissingDefinitionsAreRegisteredByFeedDomain() {
        XCTAssertEqual(Set(FeedFeatures.definitions.map(\.key)), ["appearance.showFeedTab", "appearance.showFeedUnreadCounter"])
        XCTAssertTrue(Set(FeedFeatures.definitions.map(\.key)).isDisjoint(with: Set(ChatFeatures.definitions.map(\.key))))
    }
}
