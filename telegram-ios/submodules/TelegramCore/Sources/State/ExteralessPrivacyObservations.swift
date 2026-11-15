import Foundation
import ExteralessCore
import Postbox
import SwiftSignalKit

// The shared allocation is declared centrally in SyncCore_Namespaces.swift.
// Clear only these keys: retention/extras may share the collection, not these rows.
let exteralessPrivacyObservationEntryIds = [
    ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.privacy.observations.v1")),
    ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.privacy.readDates.v1")),
    ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.privacy.ownLastSeen.v1"))
]
private let privacyObservationsId = exteralessPrivacyObservationEntryIds[0]
private let privacyReadDatesId = exteralessPrivacyObservationEntryIds[1]
private let privacyOwnLastSeenId = exteralessPrivacyObservationEntryIds[2]
private struct OwnLastSeenValue: Codable { let timestamp: Int32 }

private func loadPrivacyObservations(transaction: Transaction, readDates: Bool = false) -> PrivacyObservations {
    var value = transaction.retrieveItemCacheEntry(id: readDates ? privacyReadDatesId : privacyObservationsId)?.get(PrivacyObservations.self) ?? PrivacyObservations()
    let pruned = readDates ? value.pruneReadRecords() : value.pruneActivity(now: Int32(clamping: Int64(Date().timeIntervalSince1970)))
    if pruned { storePrivacyObservations(transaction: transaction, value: value, readDates: readDates) }
    return value
}

private func storePrivacyObservations(transaction: Transaction, value: PrivacyObservations, readDates: Bool = false) {
    if let entry = CodableEntry(value) { transaction.putItemCacheEntry(id: readDates ? privacyReadDatesId : privacyObservationsId, entry: entry) }
}

func exteralessObservePresences(transaction: Transaction, accountPeerId: PeerId, presences: [PeerId: PeerPresence]) {
    let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
    let policy = PrivacyPolicy.current
    var activities: [PeerId: Int32] = [:]
    for (peerId, presence) in presences {
        guard let presence = presence as? TelegramUserPresence, case let .present(timestamp) = presence.status, timestamp > 0, timestamp <= now else { continue }
        if peerId == accountPeerId {
            if let entry = CodableEntry(OwnLastSeenValue(timestamp: timestamp)) { transaction.putItemCacheEntry(id: privacyOwnLastSeenId, entry: entry) }
        } else if policy.saveLocalLastSeen && peerId.namespace == Namespaces.Peer.CloudUser {
            activities[peerId] = timestamp
        }
    }
    if !activities.isEmpty { exteralessObserveActivities(transaction: transaction, accountPeerId: accountPeerId, activities: activities) }
}

func exteralessObserveActivities(transaction: Transaction, accountPeerId: PeerId, activities: [PeerId: Int32]) {
    guard PrivacyPolicy.current.saveLocalLastSeen else { return }
    let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
    var value = loadPrivacyObservations(transaction: transaction)
    let previous = value
    var observed: [Int64: Int32] = [:]
    for (peerId, timestamp) in activities where peerId != accountPeerId && peerId.namespace == Namespaces.Peer.CloudUser {
        observed[peerId.toInt64()] = timestamp
    }
    value.observeActivities(observed, now: now)
    if previous != value { storePrivacyObservations(transaction: transaction, value: value) }
}

/// Called before applying the incoming outbox mark, so replay cannot invent new read dates.
func exteralessObserveOutgoingRead(transaction: Transaction, maximumId: MessageId, timestamp: Int32?) {
    guard PrivacyPolicy.current.saveReadDate else { return }
    // Some channel updates carry no date. This is the measured arrival time,
    // labelled as locally observed in UI, rather than an invented server read date.
    let timestamp = timestamp ?? Int32(clamping: Int64(Date().timeIntervalSince1970))
    guard timestamp > 0 else { return }
    var previousMax: Int32 = 0
    for (namespace, state) in transaction.getPeerReadStates(maximumId.peerId) ?? [] where namespace == maximumId.namespace {
        if case let .idBased(_, maxOutgoingReadId, _, _, _) = state { previousMax = maxOutgoingReadId }
    }
    guard maximumId.id > previousMax else { return }
    let from = transaction.getMessage(maximumId)?.index ?? MessageIndex.upperBound(peerId: maximumId.peerId, namespace: maximumId.namespace)
    let previousId = MessageId(peerId: maximumId.peerId, namespace: maximumId.namespace, id: previousMax)
    let to = transaction.getMessage(previousId)?.index ?? MessageIndex.lowerBound(peerId: maximumId.peerId, namespace: maximumId.namespace)
    exteralessObserveReadMessages(transaction: transaction, peerId: maximumId.peerId, namespace: maximumId.namespace, from: from, to: to, timestamp: timestamp) { message in
        return message.id.id > previousMax && message.id.id <= maximumId.id
    }
}

func exteralessObserveSecretOutgoingRead(transaction: Transaction, peerId: PeerId, maximumTimestamp: Int32, timestamp: Int32) {
    guard PrivacyPolicy.current.saveReadDate, timestamp > 0 else { return }
    var previousTimestamp: Int32 = 0
    for (_, state) in transaction.getPeerReadStates(peerId) ?? [] {
        if case let .indexBased(_, outgoing, _, _) = state { previousTimestamp = max(previousTimestamp, outgoing.timestamp) }
    }
    guard maximumTimestamp > previousTimestamp else { return }
    let from = MessageIndex.upperBound(peerId: peerId, timestamp: maximumTimestamp, namespace: Namespaces.Message.Local)
    let to = MessageIndex.upperBound(peerId: peerId, timestamp: previousTimestamp, namespace: Namespaces.Message.Local)
    exteralessObserveReadMessages(transaction: transaction, peerId: peerId, namespace: Namespaces.Message.Local, from: from, to: to, timestamp: timestamp) { message in
        return message.timestamp > previousTimestamp && message.timestamp <= maximumTimestamp
    }
}

private func exteralessObserveReadMessages(transaction: Transaction, peerId: PeerId, namespace: Int32, from initialFrom: MessageIndex, to: MessageIndex, timestamp: Int32, matches: (Message) -> Bool) {
    guard initialFrom.id.peerId == peerId, to.id.peerId == peerId, initialFrom.id.namespace == namespace, to.id.namespace == namespace else { return }
    var value = loadPrivacyObservations(transaction: transaction, readDates: true)
    let previous = value
    // Imported history can have dates that do not increase with cloud IDs. Keep
    // the ID predicate authoritative if timestamp-based narrowing is inverted.
    var from = initialFrom > to ? initialFrom : MessageIndex.upperBound(peerId: peerId, namespace: namespace)
    let lowerBound = initialFrom > to ? to : MessageIndex.lowerBound(peerId: peerId, namespace: namespace)
    var includeFrom = true
    var inspected = 0
    var ids: [Int32] = []
    // Bounded pages prevent an exceptionally large history from stalling state replay.
    while inspected < PrivacyObservations.maximumReadRecords {
        let count = min(256, PrivacyObservations.maximumReadRecords - inspected)
        let page = transaction.getMessages(peerId: peerId, namespace: namespace, from: from, includeFrom: includeFrom, to: lowerBound, limit: count)
        if page.isEmpty { break }
        for message in page where !message.flags.contains(.Incoming) && matches(message) {
            ids.append(message.id.id)
        }
        inspected += page.count
        guard let last = page.last, last.index < from || includeFrom else { break }
        from = last.index
        includeFrom = false
        if page.count < count { break }
    }
    value.observeReadMessages(peerId: peerId.toInt64(), namespace: namespace, ids: ids, timestamp: timestamp, played: false)
    if previous != value { storePrivacyObservations(transaction: transaction, value: value, readDates: true) }
}

func exteralessObservePlayed(transaction: Transaction, messageId: MessageId, timestamp: Int32?) {
    guard PrivacyPolicy.current.saveReadDate,
          let message = transaction.getMessage(messageId), !message.flags.contains(.Incoming) else { return }
    let timestamp = timestamp ?? Int32(clamping: Int64(Date().timeIntervalSince1970))
    guard timestamp > 0 else { return }
    if message.attributes.contains(where: { ($0 as? ConsumableContentMessageAttribute)?.consumed == true }) { return }
    var value = loadPrivacyObservations(transaction: transaction, readDates: true)
    let previous = value
    value.observeRead(peerId: messageId.peerId.toInt64(), namespace: messageId.namespace, id: messageId.id, timestamp: timestamp, played: true)
    if previous != value { storePrivacyObservations(transaction: transaction, value: value, readDates: true) }
}

func exteralessObserveReactions(transaction: Transaction, accountPeerId: PeerId, reactions: ReactionsMessageAttribute) {
    guard PrivacyPolicy.current.saveLocalLastSeen else { return }
    var activities: [PeerId: Int32] = [:]
    for reaction in reactions.recentPeers {
        if let timestamp = reaction.timestamp { activities[reaction.peerId] = max(activities[reaction.peerId] ?? 0, timestamp) }
    }
    exteralessObserveActivities(transaction: transaction, accountPeerId: accountPeerId, activities: activities)
}

func exteralessObservedReadDate(transaction: Transaction, messageId: MessageId) -> (readAt: Int32?, playedAt: Int32?) {
    guard PrivacyPolicy.current.saveReadDate else { return (nil, nil) }
    let value = loadPrivacyObservations(transaction: transaction, readDates: true).reads[PrivacyObservations.messageKey(peerId: messageId.peerId.toInt64(), namespace: messageId.namespace, id: messageId.id)]
    return (value?.readAt, value?.playedAt)
}

func exteralessObservedReadDates(transaction: Transaction, messageIds: [MessageId]) -> [MessageId: (readAt: Int32?, playedAt: Int32?)] {
    guard PrivacyPolicy.current.saveReadDate else { return [:] }
    let reads = loadPrivacyObservations(transaction: transaction, readDates: true).reads
    var result: [MessageId: (readAt: Int32?, playedAt: Int32?)] = [:]
    for id in messageIds {
        if let value = reads[PrivacyObservations.messageKey(peerId: id.peerId.toInt64(), namespace: id.namespace, id: id.id)] {
            result[id] = (value.readAt, value.playedAt)
        }
    }
    return result
}

func exteralessObservedLastSeen(transaction: Transaction, peerId: PeerId, now: Int32) -> Int32? {
    guard PrivacyPolicy.current.saveLocalLastSeen else { return nil }
    return loadPrivacyObservations(transaction: transaction).observedActivity(peerId: peerId.toInt64(), now: now)
}

func exteralessOwnLastSeen(transaction: Transaction) -> Int32? {
    return transaction.retrieveItemCacheEntry(id: privacyOwnLastSeenId)?.get(OwnLastSeenValue.self)?.timestamp
}

public func exteralessPrivacyAdjustedPresence(account: Account, peerId: PeerId, presence: TelegramUserPresence?) -> Signal<TelegramUserPresence?, NoError> {
    let policy = PrivacyPolicy.current
    if peerId == account.peerId {
        guard !policy.sendOnlinePackets || policy.sendOfflinePacketAfterOnline else { return .single(nil) }
        return exteralessPrivacyObservationTransaction(account: account, fallback: nil) { transaction -> TelegramUserPresence? in
            let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
            guard let timestamp = exteralessOwnLastSeen(transaction: transaction), timestamp > 0, timestamp <= now else { return nil }
            return TelegramUserPresence(status: .present(until: timestamp), lastActivity: 0)
        }
    }
    guard policy.saveLocalLastSeen, let presence else { return .single(presence) }
    switch presence.status {
    case .recently, .lastWeek, .lastMonth:
        return exteralessPrivacyObservationTransaction(account: account, fallback: nil) { transaction -> TelegramUserPresence? in
            guard let timestamp = exteralessObservedLastSeen(transaction: transaction, peerId: peerId, now: Int32(clamping: Int64(Date().timeIntervalSince1970))) else { return presence }
            return TelegramUserPresence(status: .present(until: timestamp), lastActivity: 0)
        }
    default: return .single(presence)
    }
}

public func exteralessClearPrivacyObservations(account: Account) -> Signal<Void, NoError> {
    let epoch = ExteralessPrivacyObservationEpochs.shared.epoch(for: account.postbox)
    return exteralessPrivacyObservationTransaction(account: account, fallback: ()) { transaction in
        epoch.invalidate()
        transaction.removeItemCacheEntry(id: privacyObservationsId)
        transaction.removeItemCacheEntry(id: privacyReadDatesId)
        transaction.removeItemCacheEntry(id: privacyOwnLastSeenId)
    }
}

/// Called on receipt of the history batch, before the caller's tracker-queue hop.
/// The captured work belongs to that history subscription, not to the tracker.
func exteralessCaptureLoadedMessagesObservation(lifetime: ExteralessHistoryObservationLifetime, account: Account, peerId: PeerId, messages: [Message]) -> ExteralessHistoryObservationLifetime.Batch? {
    guard PrivacyPolicy.current.saveLocalLastSeen else { return nil }
    let epoch = ExteralessPrivacyObservationEpochs.shared.epoch(for: account.postbox)
    let accountPeerId = account.peerId
    return lifetime.capture(epoch: epoch) { work in
        return exteralessPrivacyObservationTransaction(account: account, fallback: (), capturedWork: work) { transaction in
            guard PrivacyPolicy.current.saveLocalLastSeen else { return }
            var activities: [PeerId: Int32] = [:]
            for message in messages {
                if peerId.namespace == Namespaces.Peer.CloudUser, message.author?.id == peerId {
                    activities[peerId] = max(activities[peerId] ?? 0, message.timestamp)
                }
                for attribute in message.attributes {
                    if let reactions = attribute as? ReactionsMessageAttribute {
                        for reaction in reactions.recentPeers {
                            if let timestamp = reaction.timestamp {
                                activities[reaction.peerId] = max(activities[reaction.peerId] ?? 0, timestamp)
                            }
                        }
                    }
                }
            }
            exteralessObserveActivities(transaction: transaction, accountPeerId: accountPeerId, activities: activities)
        }
    }
}

/// Per-history-subscription side effects. Capture is synchronous, start may be on
/// any queue, and disposal cancels both queued admission and an installed signal.
/// No callback, signal start or child disposal runs under the lifetime lock.
final class ExteralessHistoryObservationLifetime: Disposable {
    final class Batch: Disposable {
        private enum State { case pending, started, finished }
        private let lock = NSLock()
        private let work: PrivacyObservationWork
        private let disposable = MetaDisposable()
        private var state: State = .pending
        private var signal: Signal<Void, NoError>?
        private let finished: () -> Void

        fileprivate init(work: PrivacyObservationWork, signal: Signal<Void, NoError>, finished: @escaping () -> Void) {
            self.work = work
            self.signal = signal
            self.finished = finished
        }

        func start() {
            self.lock.lock()
            guard case .pending = self.state else { self.lock.unlock(); return }
            guard self.work.isCurrent, let signal = self.signal else {
                self.lock.unlock()
                self.dispose()
                return
            }
            self.state = .started
            self.signal = nil
            self.lock.unlock()
            // A concurrent dispose cancels work before Postbox's queued body and
            // MetaDisposable also disposes a child returned after that dispose.
            self.disposable.set(signal.start(completed: { [weak self] in self?.dispose() }))
        }

        func dispose() {
            self.lock.lock()
            if case .finished = self.state { self.lock.unlock(); return }
            self.state = .finished
            self.signal = nil
            self.lock.unlock()
            self.work.cancel()
            self.disposable.dispose()
            self.finished()
        }

        deinit { self.dispose() }
    }

    private let lock = NSLock()
    private var disposed = false
    private var batches: [UUID: Batch] = [:]

    func capture(epoch: PrivacyObservationEpoch, signal: (PrivacyObservationWork) -> Signal<Void, NoError>) -> Batch? {
        self.lock.lock()
        let alreadyDisposed = self.disposed
        self.lock.unlock()
        guard !alreadyDisposed else { return nil }
        // Capture before a signal factory or any caller-controlled queue hop.
        let work = epoch.makeWork()
        let source = signal(work)
        let id = UUID()
        let batch = Batch(work: work, signal: source, finished: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.batches.removeValue(forKey: id)
            self.lock.unlock()
        })
        self.lock.lock()
        let disposed = self.disposed
        if !disposed { self.batches[id] = batch }
        self.lock.unlock()
        if disposed { batch.dispose(); return nil }
        return batch
    }

    func dispose() {
        self.lock.lock()
        self.disposed = true
        let batches = self.batches
        self.batches.removeAll()
        self.lock.unlock()
        for batch in batches.values { batch.dispose() }
    }

    deinit { self.dispose() }
}

private final class ExteralessPrivacyObservationEpochs: @unchecked Sendable {
    static let shared = ExteralessPrivacyObservationEpochs()
    private final class Entry {
        weak var postbox: Postbox?
        let epoch = PrivacyObservationEpoch()
        init(postbox: Postbox) { self.postbox = postbox }
    }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    func epoch(for postbox: Postbox) -> PrivacyObservationEpoch {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.postbox != nil }
        let key = ObjectIdentifier(postbox)
        if let entry = entries[key], entry.postbox === postbox { return entry.epoch }
        let entry = Entry(postbox: postbox)
        entries[key] = entry
        return entry.epoch
    }
}

/// Postbox's queued transaction body can still run after subscription disposal.
/// Admission is checked inside the real transaction, against this exact account
/// identity and a per-subscription cancellation token, before touching any row.
func exteralessPrivacyObservationTransaction<T>(account: Account, fallback: T, capturedGeneration: UUID? = nil, capturedWork: PrivacyObservationWork? = nil, _ body: @escaping (Transaction) -> T) -> Signal<T, NoError> {
    let postbox = account.postbox
    let accountPeerId = account.peerId
    let testingEnvironment = account.testingEnvironment
    let epoch = ExteralessPrivacyObservationEpochs.shared.epoch(for: postbox)
    return Signal { subscriber in
        let work = capturedWork ?? epoch.makeWork(capturedGeneration: capturedGeneration)
        let disposable = postbox.transaction { transaction -> T in
            guard work.isCurrent, let state = transaction.getState() as? AuthorizedAccountState,
                  state.peerId == accountPeerId, state.isTestingEnvironment == testingEnvironment else { return fallback }
            return body(transaction)
        }.start(next: subscriber.putNext, completed: subscriber.putCompletion)
        return ActionDisposable { work.cancel(); disposable.dispose() }
    }
}

func exteralessMaintainPrivacyObservations(transaction: Transaction) {
    let policy = PrivacyPolicy.current
    if policy.saveLocalLastSeen { let _ = loadPrivacyObservations(transaction: transaction) }
    if policy.saveReadDate { let _ = loadPrivacyObservations(transaction: transaction, readDates: true) }
}

// Explicit archive import uses the same admission epoch as Clear privacy observations.
// The source adapter receives models/commit capability, never these private cache keys.
func exteralessPrivacyImportWork(postbox: Postbox) -> PrivacyObservationWork {
    return ExteralessPrivacyObservationEpochs.shared.epoch(for: postbox).makeWork()
}

func exteralessPrivacyImportSnapshot(transaction: Transaction, accountPeerId: PeerId) throws -> (activity: PrivacyObservations, readDates: PrivacyObservations) {
    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == accountPeerId else {
        throw ExteralessRetentionError.unavailable
    }
    func load(_ id: ItemCacheEntryId) throws -> PrivacyObservations {
        guard let entry = transaction.retrieveItemCacheEntry(id: id) else { return PrivacyObservations() }
        guard let value = entry.get(PrivacyObservations.self), value.lastSeen.count <= PrivacyObservations.maximumActivityRecords,
              value.reads.count <= PrivacyObservations.maximumReadRecords else { throw ExteralessRetentionError.invalidArchive }
        return value
    }
    return (try load(privacyObservationsId), try load(privacyReadDatesId))
}

// Encode before any archive writes. Invoke the returned closure in the same transaction.
func exteralessPrivacyPrepareImportCommit(activity: PrivacyObservations, readDates: PrivacyObservations) throws -> (Transaction) -> Void {
    guard activity.lastSeen.count <= PrivacyObservations.maximumActivityRecords,
          readDates.reads.count <= PrivacyObservations.maximumReadRecords,
          let activityEntry = CodableEntry(activity), let readsEntry = CodableEntry(readDates),
          activityEntry.data.count <= 8 * 1024 * 1024, readsEntry.data.count <= 16 * 1024 * 1024 else {
        throw ExteralessRetentionError.limitExceeded
    }
    return { transaction in
        transaction.putItemCacheEntry(id: privacyObservationsId, entry: activityEntry)
        transaction.putItemCacheEntry(id: privacyReadDatesId, entry: readsEntry)
    }
}
