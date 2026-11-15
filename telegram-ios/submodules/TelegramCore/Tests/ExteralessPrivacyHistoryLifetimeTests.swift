import ExteralessCore
import Foundation
import SwiftSignalKit
import XCTest
@testable import TelegramCore

private final class PrivacyControlledQueue {
    private var blocks: [() -> Void] = []
    func async(_ block: @escaping () -> Void) { blocks.append(block) }
    func drain() {
        let pending = blocks
        blocks.removeAll()
        XCTAssertLessThan(pending.count, 32)
        for block in pending { block() }
    }
}

/// Executes the real per-subscription capture/start/dispose helper using controlled
/// tracker and Postbox-like queues. The queued store body deliberately survives
/// signal disposal, like Postbox, and uses the same captured work at admission.
private final class PrivacyHistoryFixture {
    let input = ValuePipe<Int32>()
    let epoch: PrivacyObservationEpoch
    let tracker: PrivacyControlledQueue
    let database: PrivacyControlledQueue
    var observations = PrivacyObservations()
    var starts = 0
    var cancellations = 0
    var writes = 0

    init(epoch: PrivacyObservationEpoch = PrivacyObservationEpoch(), tracker: PrivacyControlledQueue, database: PrivacyControlledQueue) {
        self.epoch = epoch; self.tracker = tracker; self.database = database
    }

    func history() -> Signal<Int32, NoError> {
        return withState(input.signal(), { ExteralessHistoryObservationLifetime() }, next: { [self] timestamp, lifetime in
            let batch = lifetime.capture(epoch: epoch) { work in
                Signal { [self] subscriber in
                    starts += 1
                    database.async { [self] in
                        if work.isCurrent {
                            observations.observeActivity(peerId: 7, timestamp: timestamp, now: timestamp)
                            writes += 1
                        }
                        subscriber.putCompletion()
                    }
                    return ActionDisposable { [self] in cancellations += 1 }
                }
            }
            tracker.async { batch?.start() }
        }, disposed: { lifetime in lifetime.dispose() })
    }

    func clear() { epoch.invalidate(); observations.clear() }
}

final class ExteralessPrivacyHistoryLifetimeTests: XCTestCase {
    func testPR04ClearBeforeTrackerHopCannotRecaptureFreshEpoch() {
        let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
        let fixture = PrivacyHistoryFixture(tracker: tracker, database: database)
        let disposable = fixture.history().start()
        fixture.input.putNext(100)
        fixture.clear()
        tracker.drain(); database.drain()
        XCTAssertEqual(fixture.starts, 0)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertTrue(fixture.observations.lastSeen.isEmpty)
        fixture.input.putNext(101)
        tracker.drain(); database.drain()
        XCTAssertEqual(fixture.writes, 1)
        XCTAssertEqual(fixture.observations.lastSeen[7], 101)
        disposable.dispose()
    }

    func testPR04DisposeBeforeTrackerHopLeavesOtherAccountIndependent() {
        let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
        let old = PrivacyHistoryFixture(tracker: tracker, database: database)
        let other = PrivacyHistoryFixture(tracker: tracker, database: database)
        let oldDisposable = old.history().start(), otherDisposable = other.history().start()
        old.input.putNext(100); other.input.putNext(200)
        oldDisposable.dispose()
        tracker.drain(); database.drain()
        XCTAssertEqual(old.starts, 0)
        XCTAssertEqual(old.writes, 0)
        XCTAssertEqual(other.writes, 1)
        XCTAssertEqual(other.observations.lastSeen[7], 200)
        otherDisposable.dispose()
    }

    func testPR04DisposeCancelsStartedSignalAndQueuedStoreWrite() {
        let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
        let fixture = PrivacyHistoryFixture(tracker: tracker, database: database)
        let disposable = fixture.history().start()
        fixture.input.putNext(100)
        tracker.drain()
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.cancellations, 0)
        disposable.dispose()
        XCTAssertEqual(fixture.cancellations, 1)
        database.drain()
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertTrue(fixture.observations.lastSeen.isEmpty)
    }

    func testPR04ClearAfterStartInvalidatesQueuedStoreWithoutDisposingHistory() {
        let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
        let fixture = PrivacyHistoryFixture(tracker: tracker, database: database)
        let disposable = fixture.history().start()
        fixture.input.putNext(100)
        tracker.drain()
        XCTAssertEqual(fixture.starts, 1)
        fixture.clear()
        database.drain()
        XCTAssertEqual(fixture.writes, 0)
        fixture.input.putNext(101)
        tracker.drain(); database.drain()
        XCTAssertEqual(fixture.writes, 1)
        disposable.dispose()
    }

    func testPR04SameAccountSubscriptionsDoNotCancelEachOther() {
        let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
        let fixture = PrivacyHistoryFixture(tracker: tracker, database: database)
        let history = fixture.history()
        let first = history.start(), second = history.start()
        fixture.input.putNext(100)
        first.dispose()
        tracker.drain(); database.drain()
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.writes, 1)
        second.dispose()
    }

    func testPR04CaptureStartAndDisposeNeedNoMainActor() {
        let completed = expectation(description: "controlled non-main history")
        DispatchQueue(label: "Privacy.PR04.fixture").async {
            XCTAssertFalse(Thread.isMainThread)
            let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
            let old = PrivacyHistoryFixture(tracker: tracker, database: database)
            let other = PrivacyHistoryFixture(tracker: tracker, database: database)
            let oldDisposable = old.history().start(), otherDisposable = other.history().start()
            old.input.putNext(100); other.input.putNext(200)
            tracker.drain()
            old.clear(); oldDisposable.dispose()
            XCTAssertEqual(old.cancellations, 1)
            database.drain()
            XCTAssertEqual(old.writes, 0)
            XCTAssertEqual(other.writes, 1)
            otherDisposable.dispose()
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1.0)
    }

    @MainActor
    func testPR04MainActorClearAndDisposeBeforeHopKeepsOtherAccountRunning() {
        XCTAssertTrue(Thread.isMainThread)
        let tracker = PrivacyControlledQueue(), database = PrivacyControlledQueue()
        let old = PrivacyHistoryFixture(tracker: tracker, database: database)
        let other = PrivacyHistoryFixture(tracker: tracker, database: database)
        let oldDisposable = old.history().start(), otherDisposable = other.history().start()
        old.input.putNext(100); other.input.putNext(200)
        old.clear(); oldDisposable.dispose()
        tracker.drain(); database.drain()
        XCTAssertEqual(old.starts, 0)
        XCTAssertEqual(old.writes, 0)
        XCTAssertEqual(other.writes, 1)
        otherDisposable.dispose()
    }

    func testPR04SynchronousCompletionBeforeHandleInstallDisposesOnce() {
        let lifetime = ExteralessHistoryObservationLifetime()
        let epoch = PrivacyObservationEpoch()
        var starts = 0, disposals = 0
        let batch = lifetime.capture(epoch: epoch) { _ in
            Signal { subscriber in
                starts += 1
                subscriber.putCompletion()
                return ActionDisposable { disposals += 1 }
            }
        }
        batch?.start(); batch?.start(); lifetime.dispose()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(disposals, 1)
    }
}
