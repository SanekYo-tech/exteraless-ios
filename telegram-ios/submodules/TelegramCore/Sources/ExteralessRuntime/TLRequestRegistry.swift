import Foundation

/// Native request leases. A ticket is meaningful only for its captured interpreter
/// owner. Claiming completion or removing a running ticket is the terminal-event
/// linearization point; late outcomes lose against cancel/timeout/unload. A claimed
/// completion retains only its bounded delivery lease. No closure runs under the lock.
public final class ExteralessTLRequestRegistry<Owner: Hashable & Sendable>: @unchecked Sendable {
    public struct Ticket: Hashable, Sendable {
        public let id: String
        public let pluginId: String
        public let owner: Owner
        public let callbackHandle: Int64
        public let accountRecordId: Int64
        public let isMedia: Bool
        public let deadlineNanoseconds: UInt64
        public let originPluginIds: [String]
        public let originRootId: String?
        fileprivate let executionIsCurrent: @Sendable () -> Bool

        /// Revocation is independent of resource ownership. Evaluate outside the
        /// registry lock; it may consult other owners/permissions or reenter us.
        public var permitsExecution: Bool { self.executionIsCurrent() }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.pluginId == rhs.pluginId && lhs.owner == rhs.owner
                && lhs.callbackHandle == rhs.callbackHandle && lhs.accountRecordId == rhs.accountRecordId
                && lhs.isMedia == rhs.isMedia && lhs.deadlineNanoseconds == rhs.deadlineNanoseconds
                && lhs.originPluginIds == rhs.originPluginIds && lhs.originRootId == rhs.originRootId
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(self.id)
            hasher.combine(self.owner)
        }
    }

    private final class Entry {
        let ticket: Ticket
        let timer: DispatchSourceTimer
        var completed = false
        private let resourceLock = NSLock()
        private var cancellations: [() -> Void] = []

        init(ticket: Ticket, timer: DispatchSourceTimer) {
            self.ticket = ticket
            self.timer = timer
        }

        func cancelResources() {
            self.resourceLock.lock()
            let cancellations = self.cancellations
            self.cancellations.removeAll()
            self.resourceLock.unlock()
            self.timer.cancel()
            for cancel in cancellations { cancel() }
        }

        func appendCancellation(_ cancel: @escaping () -> Void) {
            self.resourceLock.lock()
            self.cancellations.append(cancel)
            self.resourceLock.unlock()
        }
    }

    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "Exteraless.TLRequestDeadlines", qos: .utility)
    private var entries: [String: Entry] = [:]
    private var owners: [String: Owner] = [:]
    private let maximumPerPlugin: Int
    private let maximumTotal: Int

    public init(maximumPerPlugin: Int = 64, maximumTotal: Int = 256) {
        self.maximumPerPlugin = max(1, min(64, maximumPerPlugin))
        self.maximumTotal = max(1, min(256, maximumTotal))
    }

    deinit {
        for entry in self.entries.values { entry.cancelResources() }
    }

    public var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.count
    }

    /// A rejected admission owns no Python reference. The SDK releases that wrapper.
    public func reserve(pluginId: String, owner: Owner, callbackHandle: Int64, accountRecordId: Int64,
                        isMedia: Bool = false, timeoutMs: Int,
                        originPluginIds: [String] = [], originRootId: String? = nil,
                        executionIsCurrent: @escaping @Sendable () -> Bool = { true },
                        expired: @escaping @Sendable (Ticket) -> Void) throws -> Ticket {
        guard callbackHandle > 0, timeoutMs >= 100, timeoutMs <= 120_000 else {
            throw ExteralessTLError(.malformed, "TL callback/timeout is outside the supported range")
        }
        self.lock.lock()
        let pluginEntries = self.entries.values.filter { $0.ticket.pluginId == pluginId }
        if let existingOwner = self.owners[pluginId], existingOwner != owner {
            self.lock.unlock()
            throw ExteralessTLError(.malformed, "TL interpreter generation has not retired its previous requests")
        }
        if self.entries.count >= self.maximumTotal || pluginEntries.count >= self.maximumPerPlugin {
            self.lock.unlock()
            throw ExteralessTLError(.limit, "TL in-flight request limit reached")
        }
        if pluginEntries.contains(where: { $0.ticket.callbackHandle == callbackHandle }) {
            self.lock.unlock()
            throw ExteralessTLError(.malformed, "TL operations require distinct callback wrapper leases")
        }
        if isMedia && (pluginEntries.filter { $0.ticket.isMedia }.count >= 2 || self.entries.values.filter { $0.ticket.isMedia }.count >= 4) {
            self.lock.unlock()
            throw ExteralessTLError(.limit, "TL media preparation limit reached")
        }
        let ticket = Ticket(id: UUID().uuidString, pluginId: pluginId, owner: owner,
                            callbackHandle: callbackHandle, accountRecordId: accountRecordId, isMedia: isMedia,
                            deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000,
                            originPluginIds: originPluginIds, originRootId: originRootId,
                            executionIsCurrent: executionIsCurrent)
        let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
        timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
        timer.setEventHandler { [weak self] in
            guard self?.contains(ticket) == true else { return }
            expired(ticket)
        }
        self.entries[ticket.id] = Entry(ticket: ticket, timer: timer)
        self.owners[pluginId] = owner
        self.lock.unlock()
        // Even if a simultaneous unload cancelled it, resume exactly once before
        // releasing our local source reference (a suspended source must not deinit).
        timer.resume()
        return ticket
    }

    public func contains(_ ticket: Ticket) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries[ticket.id]?.ticket == ticket && self.entries[ticket.id]?.completed == false
    }

    public var runningTickets: [Ticket] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.values.filter { !$0.completed }.map(\.ticket)
    }

    /// Completion owns its callback lease but keeps an admission slot until the
    /// owner dispatcher accepts it. A slow callback consumer cannot create an
    /// unbounded backlog by repeatedly completing then admitting more requests.
    public func complete(_ ticket: Ticket) -> Ticket? {
        self.lock.lock()
        guard let entry = self.entries[ticket.id], entry.ticket == ticket, !entry.completed else {
            self.lock.unlock()
            return nil
        }
        entry.completed = true
        self.lock.unlock()
        entry.cancelResources()
        return entry.ticket
    }

    /// Cancellation owns no callback, but the C release can be backpressured.
    /// Keep the same admission slot until the owner control queue accepts release.
    public func cancelRetainingLease(id: String, pluginId: String, owner: Owner) -> Ticket? {
        self.lock.lock()
        guard let entry = self.entries[id], entry.ticket.pluginId == pluginId, entry.ticket.owner == owner, !entry.completed else {
            self.lock.unlock(); return nil
        }
        entry.completed = true
        self.lock.unlock()
        entry.cancelResources()
        return entry.ticket
    }

    public func completionPending(_ ticket: Ticket) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries[ticket.id]?.ticket == ticket && self.entries[ticket.id]?.completed == true
    }

    public func releaseCompletion(_ ticket: Ticket) -> Ticket? {
        return self.remove(id: ticket.id, pluginId: ticket.pluginId, owner: ticket.owner, completed: true)
    }

    /// Handles the finish-before-install race of SwiftSignalKit.start and Tasks.
    public func bindCancellation(_ ticket: Ticket, _ cancel: @escaping () -> Void) {
        self.lock.lock()
        if let entry = self.entries[ticket.id], entry.ticket == ticket, !entry.completed {
            entry.appendCancellation(cancel)
            self.lock.unlock()
        } else {
            self.lock.unlock()
            cancel()
        }
    }

    /// A cancellation winner owns release. A loser must not release the callback
    /// belonging to a claimed completion; completion uses complete/releaseCompletion.
    public func take(_ ticket: Ticket) -> Ticket? {
        return self.take(id: ticket.id, pluginId: ticket.pluginId, owner: ticket.owner)
    }

    public func take(id: String, pluginId: String, owner: Owner) -> Ticket? {
        return self.remove(id: id, pluginId: pluginId, owner: owner, completed: false)
    }

    private func remove(id: String, pluginId: String, owner: Owner, completed: Bool) -> Ticket? {
        self.lock.lock()
        guard let entry = self.entries[id], entry.ticket.pluginId == pluginId, entry.ticket.owner == owner, entry.completed == completed else {
            self.lock.unlock()
            return nil
        }
        self.entries.removeValue(forKey: id)
        if !self.entries.values.contains(where: { $0.ticket.pluginId == pluginId }) {
            self.owners.removeValue(forKey: pluginId)
        }
        self.lock.unlock()
        entry.cancelResources()
        return entry.ticket
    }

    /// Unload/context teardown: retire all tickets before disposing native work.
    /// Callbacks are suppressed; the provider releases only these captured owners.
    public func takeAll(pluginId: String? = nil) -> [Ticket] {
        self.lock.lock()
        let removed = self.entries.values.filter { pluginId == nil || $0.ticket.pluginId == pluginId }
        for entry in removed { self.entries.removeValue(forKey: entry.ticket.id) }
        if let pluginId {
            self.owners.removeValue(forKey: pluginId)
        } else {
            self.owners.removeAll()
        }
        self.lock.unlock()
        for entry in removed { entry.cancelResources() }
        return removed.map(\.ticket)
    }
}
