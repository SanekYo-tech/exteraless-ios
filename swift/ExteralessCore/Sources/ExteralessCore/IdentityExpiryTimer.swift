import Foundation

/// A wall-clock deadline driven by one-shot monotonic timers. All operations,
/// including scheduled callbacks, run on the same serial executor. The scheduler
/// must enqueue (never synchronously invoke) a callback and return its cancellation.
public final class IdentityExpiryTimer {
    public typealias Cancellation = () -> Void
    public typealias Schedule = (_ delay: TimeInterval, _ callback: @escaping () -> Void) -> Cancellation

    private let wallTime: () -> TimeInterval
    private let schedule: Schedule
    private let isCurrent: () -> Bool
    private let availabilityChanged: () -> Void
    private var cancellation: Cancellation?
    private var deadline: Int32?
    private var wasActive: Bool?
    private var generation: UInt64 = 0
    private var stopped = false

    public init(wallTime: @escaping () -> TimeInterval, schedule: @escaping Schedule,
                isCurrent: @escaping () -> Bool, availabilityChanged: @escaping () -> Void) {
        self.wallTime = wallTime
        self.schedule = schedule
        self.isCurrent = isCurrent
        self.availabilityChanged = availabilityChanged
    }

    /// A changed deadline comes from a state publication. An identical deadline
    /// must retain its observed availability: a deduplicated state arriving at
    /// expiry must not cancel the wakeup without publishing that wall boundary.
    public func updateDeadline(_ deadline: Int32?) {
        let deadline = deadline.flatMap { $0 > 0 ? $0 : nil }
        if self.deadline != deadline {
            self.deadline = deadline
            self.wasActive = nil
        }
        self.refresh()
    }

    /// Re-evaluate on foreground/significant wall-time change AND timer delivery.
    /// A timer is a wakeup, not proof that the wall-clock expiry was reached.
    public func refresh() {
        self.generation &+= 1
        let generation = self.generation
        let previousCancellation = self.cancellation
        self.cancellation = nil
        previousCancellation?()

        guard !self.stopped, self.isCurrent(), let deadline = self.deadline else { return }
        let now = self.wallTime()
        guard now.isFinite else { return }
        let remaining = Double(deadline) - now
        let active = remaining > 0
        let changed = self.wasActive.map { $0 != active } ?? false
        self.wasActive = active

        if active {
            // If a monotonic callback arrived early after a backward clock jump,
            // this schedules the remaining WALL time instead of losing the expiry.
            let cancellation = self.schedule(remaining) { [weak self] in
                guard let self, !self.stopped, self.generation == generation else { return }
                self.refresh()
            }
            if self.stopped || self.generation != generation {
                cancellation()
            } else {
                self.cancellation = cancellation
            }
        }
        if changed, self.isCurrent() {
            self.availabilityChanged()
        }
    }

    public func invalidate() {
        self.stopped = true
        self.generation &+= 1
        self.deadline = nil
        self.wasActive = nil
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    deinit { self.cancellation?() }
}
