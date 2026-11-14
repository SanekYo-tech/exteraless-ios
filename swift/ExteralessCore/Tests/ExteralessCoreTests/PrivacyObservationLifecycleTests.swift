import Foundation
import XCTest
@testable import ExteralessCore

final class PrivacyObservationLifecycleTests: XCTestCase {
    func testExpiryAfterReloadNeedsNoNewActivityAndDoesNotExpireReadDates() throws {
        var original = PrivacyObservations()
        original.observeActivity(peerId: 1, timestamp: 100, now: 101)
        original.observeActivity(peerId: 2, timestamp: 101, now: 101)
        original.observeRead(peerId: 2, namespace: 0, id: 8, timestamp: 100, played: false)
        var loaded = try JSONDecoder().decode(PrivacyObservations.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(loaded.pruneActivity(now: 101 + PrivacyObservations.lastSeenRetention))
        XCTAssertNil(loaded.lastSeen[1])
        XCTAssertEqual(loaded.lastSeen[2], 101)
        XCTAssertEqual(loaded.reads["2:0:8"]?.readAt, 100)
        XCTAssertFalse(loaded.pruneActivity(now: 101 + PrivacyObservations.lastSeenRetention))
    }

    func testBulkReadQuotaIsEnforcedOnceAndReplayPreservesFirstDate() {
        var observations = PrivacyObservations()
        let count = PrivacyObservations.maximumReadRecords + 3
        observations.observeReadMessages(peerId: 7, namespace: 0, ids: (1...count).map(Int32.init), timestamp: 100, played: false)
        XCTAssertEqual(observations.reads.count, PrivacyObservations.maximumReadRecords)
        observations.observeRead(peerId: 7, namespace: 0, id: 999, timestamp: 200, played: false)
        observations.observeRead(peerId: 7, namespace: 0, id: 999, timestamp: 300, played: true)
        XCTAssertEqual(observations.reads["7:0:999"], .init(readAt: 100, playedAt: 300))
        XCTAssertEqual(observations.reads.count, PrivacyObservations.maximumReadRecords)
    }

    func testPruneRepairsAnOverQuotaSnapshotDeterministically() throws {
        var source = PrivacyObservations()
        source.observeRead(peerId: 7, namespace: 0, id: 1, timestamp: 10, played: false)
        source.observeRead(peerId: 7, namespace: 0, id: 2, timestamp: 20, played: false)
        source.observeRead(peerId: 7, namespace: 0, id: 3, timestamp: 20, played: false)
        source.observeRead(peerId: 7, namespace: 0, id: 4, timestamp: 30, played: true)
        var loaded = try JSONDecoder().decode(PrivacyObservations.self, from: JSONEncoder().encode(source))
        XCTAssertTrue(loaded.pruneReadRecords(maximumRecords: 2))
        XCTAssertEqual(Set(loaded.reads.keys), ["7:0:3", "7:0:4"])
        XCTAssertFalse(loaded.pruneReadRecords(maximumRecords: 2))
        XCTAssertTrue(loaded.pruneReadRecords(maximumRecords: 0))
        XCTAssertTrue(loaded.reads.isEmpty)
    }

    func testActivityQuotaKeepsNewestWithoutRewritingObservedTimes() {
        var observations = PrivacyObservations()
        observations.observeActivities([1: 10, 2: 20, 3: 20, 4: 30], now: 30)
        XCTAssertTrue(observations.pruneActivity(now: 30, maximumRecords: 2))
        XCTAssertEqual(observations.lastSeen, [3: 20, 4: 30])
        observations.observeActivity(peerId: 4, timestamp: 25, now: 30)
        XCTAssertEqual(observations.lastSeen[4], 30)
    }

    func testClearRejectsPreviouslyCapturedWorkIncludingLateSubscriptions() {
        let epoch = PrivacyObservationEpoch()
        let captured = epoch.capture()
        let queued = epoch.makeWork(capturedGeneration: captured)
        XCTAssertTrue(queued.isCurrent)
        epoch.invalidate()
        XCTAssertFalse(queued.isCurrent)
        XCTAssertFalse(epoch.makeWork(capturedGeneration: captured).isCurrent)
        XCTAssertTrue(epoch.makeWork().isCurrent)
    }

    func testCancellationIsPerSubscriptionAndEpochIsPerStore() {
        let firstAccount = PrivacyObservationEpoch()
        let secondAccount = PrivacyObservationEpoch()
        let cancelled = firstAccount.makeWork()
        let stillLive = firstAccount.makeWork()
        let otherAccount = secondAccount.makeWork()
        cancelled.cancel()
        XCTAssertFalse(cancelled.isCurrent)
        XCTAssertTrue(stillLive.isCurrent)
        firstAccount.invalidate()
        XCTAssertFalse(stillLive.isCurrent)
        XCTAssertTrue(otherAccount.isCurrent)
    }
}
