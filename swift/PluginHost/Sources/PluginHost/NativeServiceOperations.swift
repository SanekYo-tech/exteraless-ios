import Foundation

/// Cancellable native Signals and their last actually published value. This is a
/// lock-only synchronous cache; it never waits for main, Postbox, or Python.
public final class NativeServiceOperations<Owner: Hashable & Sendable>: @unchecked Sendable {
    public struct Ticket: Sendable {
        public let lease: NativeServiceCallbackLease<Owner>
        public let accountRecordId: Int64
        public let kind: String
        public var id: String { lease.id }
    }

    private struct Entry {
        let ticket: Ticket
        var cancel: (@Sendable () -> Void)?
        let timer: DispatchSourceTimer?
        var latest: PluginJSONValue?
        var latestBytes: Int
    }
    private let lock = NSLock()
    private let timers = DispatchQueue(label: "Exteraless.NativeServiceTimeouts", qos: .utility)
    private let maximumSnapshotBytes: Int
    private var snapshotBytes = 0
    private var entries: [String: Entry] = [:]

    public init(maximumSnapshotBytes: Int = 16_777_216) {
        self.maximumSnapshotBytes = max(1, min(16_777_216, maximumSnapshotBytes))
    }

    public func reserve(lease: NativeServiceCallbackLease<Owner>, accountRecordId: Int64, kind: String,
                        timeoutMs: Int?, expired: @escaping @Sendable (Ticket) -> Void) throws -> Ticket {
        if let timeoutMs, !(1...600_000).contains(timeoutMs) { throw BridgeFailure.malformed("Native operation timeout must be 1...600000 ms") }
        let ticket = Ticket(lease: lease, accountRecordId: accountRecordId, kind: kind)
        let timer: DispatchSourceTimer?
        if let timeoutMs {
            let value = DispatchSource.makeTimerSource(queue: timers)
            value.schedule(deadline: .now() + .milliseconds(timeoutMs))
            value.setEventHandler { expired(ticket) }
            timer = value
        } else {
            timer = nil
        }
        lock.lock()
        guard entries.count < 1024, entries[ticket.id] == nil else {
            lock.unlock()
            timer?.setEventHandler {}
            timer?.resume()
            timer?.cancel()
            throw BridgeFailure.unavailable("Native operation budget exhausted")
        }
        entries[ticket.id] = Entry(ticket: ticket, cancel: nil, timer: timer, latest: nil, latestBytes: 0)
        timer?.resume()
        lock.unlock()
        return ticket
    }

    public func contains(_ ticket: Ticket) -> Bool {
        lock.lock()
        let present = entries[ticket.id]?.ticket.lease.owner == ticket.lease.owner
        lock.unlock()
        return present && ticket.lease.isOpen
    }

    public func bindCancellation(_ ticket: Ticket, _ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        if var entry = entries[ticket.id] {
            let previous = entry.cancel
            entry.cancel = cancel
            entries[ticket.id] = entry
            lock.unlock()
            previous?()
        } else {
            lock.unlock()
            cancel()
        }
    }

    @discardableResult
    public func publish(_ value: PluginJSONValue, for ticket: Ticket) throws -> Bool {
        let bytes = try NativeServiceWire.json(value).utf8.count
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[ticket.id] else { return false }
        guard snapshotBytes - entry.latestBytes + bytes <= maximumSnapshotBytes else {
            throw BridgeFailure.unavailable("Native subscription snapshot byte budget exhausted")
        }
        snapshotBytes = snapshotBytes - entry.latestBytes + bytes
        entry.latest = value
        entry.latestBytes = bytes
        entries[ticket.id] = entry
        return true
    }

    public func state(id: String, owner: Owner) throws -> PluginJSONValue {
        lock.lock()
        let entry = entries[id]
        lock.unlock()
        guard let entry, entry.ticket.lease.owner == owner, entry.ticket.lease.isOpen else {
            throw BridgeFailure.invalidHandle("Native service subscription is missing, retired, or owned by another interpreter")
        }
        return .object(["ready": .bool(entry.latest != nil), "kind": .string(entry.ticket.kind), "value": entry.latest ?? .null])
    }

    public func take(id: String, owner: Owner) -> Ticket? {
        take(id: id, accepting: { $0.owner == owner })
    }

    public func cancel(id: String, cleanup: NativeServiceCleanupIdentity) -> Bool {
        guard let ticket = take(id: id, accepting: { $0.matchesCleanup(cleanup) }) else { return false }
        ticket.lease.close()
        return true
    }

    private func take(id: String, accepting: (NativeServiceCallbackLease<Owner>) -> Bool) -> Ticket? {
        lock.lock()
        guard let current = entries[id], accepting(current.ticket.lease) else { lock.unlock(); return nil }
        let entry = entries.removeValue(forKey: id)
        snapshotBytes -= entry?.latestBytes ?? 0
        lock.unlock()
        entry?.timer?.cancel()
        entry?.cancel?()
        return entry?.ticket
    }

    public func takeAll(pluginId: String? = nil, accountRecordId: Int64? = nil) -> [Ticket] {
        lock.lock()
        let removed = entries.values.filter {
            (pluginId == nil || $0.ticket.lease.pluginId == pluginId) && (accountRecordId == nil || $0.ticket.accountRecordId == accountRecordId)
        }
        for entry in removed {
            entries.removeValue(forKey: entry.ticket.id)
            snapshotBytes -= entry.latestBytes
        }
        lock.unlock()
        for entry in removed { entry.timer?.cancel(); entry.cancel?() }
        return removed.map(\.ticket)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func retirePermissions(pluginId: String) -> [Ticket] {
        lock.lock()
        let candidates = entries.values.map(\.ticket).filter { $0.lease.pluginId == pluginId }
        lock.unlock()
        return candidates.filter { !$0.lease.isOpen }.compactMap { take(id: $0.id, owner: $0.lease.owner) }
    }

    public func tickets(accountRecordId: Int64, kind: String) -> [Ticket] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.ticket.accountRecordId == accountRecordId && $0.ticket.kind == kind }.map(\.ticket)
    }

    deinit {
        for entry in entries.values {
            entry.timer?.cancel()
            entry.cancel?()
            entry.ticket.lease.close()
        }
    }
}

/// Numeric ids are pinned to totalEvents++ in the checked-in Android source.
/// Runtime availability is the intersection with actually installed publishers.
public enum NativeServiceNotification: Int32, CaseIterable, Sendable {
    case didReceiveNewMessages = 1
    case dialogsNeedReload = 3
    case contactsDidLoad = 25
    case mainUserInfoChanged = 46
    case didUpdateConnectionState = 137
    case fileLoaded = 142
    case fileLoadFailed = 143
    case messagePlayingProgressDidChanged = 148
    case messagePlayingPlayStateChanged = 150
    case messagePlayingDidStart = 151
    case messagePlayingDidSeek = 152
    case onDownloadingFilesChanged = 306

    public var name: String {
        switch self {
        case .didReceiveNewMessages: return "didReceiveNewMessages"
        case .dialogsNeedReload: return "dialogsNeedReload"
        case .contactsDidLoad: return "contactsDidLoad"
        case .mainUserInfoChanged: return "mainUserInfoChanged"
        case .didUpdateConnectionState: return "didUpdateConnectionState"
        case .fileLoaded: return "fileLoaded"
        case .fileLoadFailed: return "fileLoadFailed"
        case .messagePlayingProgressDidChanged: return "messagePlayingProgressDidChanged"
        case .messagePlayingPlayStateChanged: return "messagePlayingPlayStateChanged"
        case .messagePlayingDidStart: return "messagePlayingDidStart"
        case .messagePlayingDidSeek: return "messagePlayingDidSeek"
        case .onDownloadingFilesChanged: return "onDownloadingFilesChanged"
        }
    }

    public var permissions: Set<PluginPermission> {
        switch self {
        case .fileLoaded, .fileLoadFailed: return [.messagesRead, .files]
        default: return [.messagesRead]
        }
    }

    public var coalesces: Bool {
        switch self {
        case .didReceiveNewMessages, .fileLoaded, .fileLoadFailed, .messagePlayingDidStart, .messagePlayingDidSeek: return false
        default: return true
        }
    }
}

public enum NativeServicePublisherSite: String, Hashable, Sendable {
    case committedMessages = "AccountStateManager.processEvents.committedMessageIds"
    case mediaFetch = "fetchedMediaResource.terminalResult"
}
