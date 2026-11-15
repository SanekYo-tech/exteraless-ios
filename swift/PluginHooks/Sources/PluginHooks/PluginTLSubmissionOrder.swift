import Foundation

/// Async prefixes (including Postbox privacy resolution) may finish out of order.
/// This small sequencer releases nonblocking native add() calls in subscription
/// order. A cancellation fills its slot without submitting anything.
public final class PluginTLSubmissionOrder: @unchecked Sendable {
    public static let shared = PluginTLSubmissionOrder()
    public struct Ticket: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let account: Int64
    }
    public enum Admission: Equatable, Sendable {
        case bypass
        case reserved(Ticket)
        case full
    }
    private final class Entry {
        let ticket: Ticket
        var ready = false
        var preparationStarted = false
        var submitting = false
        var preparation: (() -> Void)?
        var action: (() -> Void)?
        init(_ ticket: Ticket) { self.ticket = ticket }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "PluginTLSubmissionOrder", qos: .userInitiated)
    private var lanes: [Int64: [Entry]] = [:]
    private var count = 0

    public init() {}

    public func reserve(accountRecordId: Int64) -> Ticket? {
        if case let .reserved(ticket) = self.reserveIfNeeded(accountRecordId: accountRecordId, transformsEnabled: true) { return ticket }
        return nil
    }

    /// The empty-gate fast path and pending-lane admission have ONE linearization
    /// point. A gate-off request still joins an earlier prefix's account lane.
    public func reserveIfNeeded(accountRecordId: Int64, transformsEnabled: Bool) -> Admission {
        self.lock.lock(); defer { self.lock.unlock() }
        guard transformsEnabled || self.lanes[accountRecordId]?.isEmpty == false else { return .bypass }
        guard self.count < 256 else { return .full }
        let ticket = Ticket(id: UUID(), account: accountRecordId)
        self.lanes[accountRecordId, default: []].append(Entry(ticket))
        self.count += 1
        return .reserved(ticket)
    }

    public func ready(_ ticket: Ticket, submission: @escaping () -> Void) {
        self.set(ticket, action: submission)
    }

    /// Begin the entire async prefix in subscription order, not in whichever order
    /// per-request decoding/Postbox queues happened to reach the hook dispatcher.
    /// Preparation must return immediately and call ready/cancel asynchronously.
    public func begin(_ ticket: Ticket, preparation: @escaping () -> Void) {
        self.lock.lock()
        if let entry = self.lanes[ticket.account]?.first(where: { $0.ticket == ticket }),
           !entry.ready, !entry.preparationStarted, entry.preparation == nil {
            entry.preparation = preparation
        }
        self.lock.unlock()
        self.queue.async { self.pump(ticket.account) }
    }

    public func cancel(_ ticket: Ticket) { self.set(ticket, action: nil) }

    private func set(_ ticket: Ticket, action: (() -> Void)?) {
        self.lock.lock()
        if let entry = self.lanes[ticket.account]?.first(where: { $0.ticket == ticket }), !entry.submitting {
            // Cancellation may replace ready work; late ready cannot resurrect it.
            if !entry.ready || action == nil {
                entry.ready = true
                entry.action = action
            }
        }
        self.lock.unlock()
        self.queue.async { self.pump(ticket.account) }
    }

    private func pump(_ account: Int64) {
        while true {
            self.lock.lock()
            guard let entry = self.lanes[account]?.first else { self.lock.unlock(); return }
            guard entry.ready else {
                let preparation = entry.preparation
                entry.preparation = nil
                if preparation != nil { entry.preparationStarted = true }
                self.lock.unlock()
                preparation?()
                return
            }
            guard !entry.submitting else { self.lock.unlock(); return }
            entry.submitting = true
            let action = entry.action
            entry.action = nil
            self.lock.unlock()
            // Keep the head visible until add() RETURNS. Removing it before this
            // action lets a concurrent empty-gate caller bypass and overtake it.
            action?()
            self.lock.lock()
            self.lanes[account]?.removeFirst()
            if self.lanes[account]?.isEmpty == true { self.lanes.removeValue(forKey: account) }
            self.count -= 1
            self.lock.unlock()
        }
    }
}
