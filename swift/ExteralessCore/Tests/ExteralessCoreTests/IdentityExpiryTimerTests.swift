import Foundation
import XCTest
@testable import ExteralessCore

private final class IdentityTestClocks {
    struct Wakeup {
        let deadline: TimeInterval
        let callback: () -> Void
    }
    var wall: TimeInterval = 1_000
    var monotonic: TimeInterval = 0
    var nextId = 0
    var wakeups: [Int: Wakeup] = [:]
    var callbacks: [Int: () -> Void] = [:]

    var deadlines: [TimeInterval] { wakeups.values.map(\.deadline).sorted() }

    func schedule(_ delay: TimeInterval, _ callback: @escaping () -> Void) -> IdentityExpiryTimer.Cancellation {
        nextId += 1
        let id = nextId
        wakeups[id] = Wakeup(deadline: monotonic + delay, callback: callback)
        callbacks[id] = callback
        return { [weak self] in self?.wakeups.removeValue(forKey: id) }
    }

    func advance(_ interval: TimeInterval, deliver: Bool = true) {
        wall += interval
        monotonic += interval
        if deliver {
            let due = wakeups.filter { $0.value.deadline <= monotonic }.map(\.key).sorted()
            for id in due { wakeups.removeValue(forKey: id)?.callback() }
        }
    }
}

final class IdentityExpiryTimerTests: XCTestCase {
    func testBackwardJumpWithoutNotificationRearmsEarlyMonotonicCallback() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        clocks.advance(50)
        clocks.wall -= 100
        clocks.advance(50)
        XCTAssertEqual(clocks.wall, 1_000)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(clocks.deadlines, [200])
        clocks.advance(100)
        XCTAssertEqual(clocks.wall, 1_100)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(clocks.wakeups.isEmpty)
        timer.refresh()
        XCTAssertEqual(changes, 1)
    }

    func testBackwardClockNotificationReplacesAndRetiresTheOldWakeup() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        let old = clocks.callbacks[1]
        clocks.advance(50)
        clocks.wall -= 100
        timer.refresh()
        XCTAssertEqual(clocks.deadlines, [200])
        old?() // Cancellation may race a queued DispatchSource callback.
        XCTAssertEqual(clocks.deadlines, [200])
        XCTAssertEqual(changes, 0)
        clocks.advance(150)
        XCTAssertEqual(changes, 1)
    }

    func testForwardJumpBeforeExpiryShortensMonotonicDeadline() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        clocks.advance(10)
        clocks.wall += 50
        timer.refresh()
        XCTAssertEqual(clocks.deadlines, [50])
        clocks.advance(39)
        XCTAssertEqual(changes, 0)
        clocks.advance(1)
        XCTAssertEqual(changes, 1)
    }

    func testForwardPastExpiryAndBackwardRevivalPublishBothWallBoundaries() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        clocks.wall = 1_200
        timer.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(clocks.deadlines.isEmpty)
        clocks.wall = 1_000
        timer.refresh()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(clocks.deadlines, [100])
        clocks.advance(100)
        XCTAssertEqual(changes, 3)
    }

    func testForegroundAfterSuspensionExpiresAndCancelsUndeliveredWakeup() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        let old = clocks.callbacks[1]
        clocks.advance(300, deliver: false)
        timer.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(clocks.deadlines.isEmpty)
        old?()
        XCTAssertEqual(changes, 1)
    }

    func testNewStatusDeadlineRejectsPreviousStatusCallback() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        let old = clocks.callbacks[1]
        timer.updateDeadline(1_300)
        clocks.advance(100)
        old?()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(clocks.deadlines, [300])
        clocks.advance(200)
        XCTAssertEqual(changes, 1)
    }

    func testDuplicateSnapshotAtExpiryDoesNotConsumeTheUnpublishedBoundary() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        clocks.advance(100, deliver: false)
        timer.updateDeadline(1_100)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(clocks.deadlines.isEmpty)
    }

    func testRetirementDoesNotInvalidateAnotherAccountLifetime() {
        let clocks = IdentityTestClocks()
        var current = true
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { current }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(1_100)
        let old = clocks.callbacks[1]
        current = false
        clocks.advance(100)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(clocks.deadlines.isEmpty)
        timer.invalidate()
        timer.updateDeadline(2_000)
        old?()
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(clocks.deadlines.isEmpty)
    }

    func testNoDeadlineOrDisabledStatusDoesNotCreateAnExpiry() {
        let clocks = IdentityTestClocks()
        var changes = 0
        let timer = IdentityExpiryTimer(wallTime: { clocks.wall }, schedule: clocks.schedule,
            isCurrent: { true }, availabilityChanged: { changes += 1 })
        timer.updateDeadline(nil)
        timer.updateDeadline(0)
        XCTAssertTrue(clocks.deadlines.isEmpty)
        timer.updateDeadline(1_100)
        timer.updateDeadline(nil)
        clocks.advance(200)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(clocks.deadlines.isEmpty)
    }
}
