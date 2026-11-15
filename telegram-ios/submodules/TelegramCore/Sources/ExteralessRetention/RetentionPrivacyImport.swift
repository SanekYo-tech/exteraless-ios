import ExteralessCore
import Foundation
import Postbox

struct RetentionPrivacyReadInput {
    let messageId: MessageId
    let timestamp: Int32
    let played: Bool
}

struct RetentionPrivacyImportInput {
    var reads: [RetentionPrivacyReadInput] = []
    var activities: [PeerId: Int32] = [:]
    var otherAccounts = 0
    var unsetDates = 0
    var expiredActivities = 0
    var selfActivities = 0
    var unresolvedPeers = Set<Int64>()
}

struct RetentionPrivacyImportMerge {
    let activity: PrivacyObservations
    let readDates: PrivacyObservations
    let importedReads: Int
    let importedPlayed: Int
    let importedActivities: Int
    let duplicates: Int
    let quotaSkipped: Int
}

/// Source dates are Unix seconds. AyuSpyController writes update.date/contentsDate directly;
/// formatPlayedDate multiplies by 1000 only for display. LastSeenHelper's cutoff is seconds.
/// Zero is an unset legacy field, not the current time. Milliseconds/negative/future values
/// are rejected rather than guessed or converted using the device timezone.
func retentionAyuUnixSeconds(_ row: ExteralessAyuRow, key: String, now: Int64) throws -> Int32? {
    let raw = try row.integer(key)
    if raw == 0 { return nil }
    guard let timestamp = Int32(exactly: raw), timestamp > 0, raw <= now else { throw ExteralessRetentionError.invalidArchive }
    return timestamp
}

func retentionNormalizeAyuPrivacy(_ source: ExteralessAyuDatabase, transaction: Transaction, accountPeerId: PeerId, mappings: [Int64: PeerId], now: Int64) throws -> RetentionPrivacyImportInput {
    var result = RetentionPrivacyImportInput()
    let ownerId = accountPeerId.id._internalGetInt64Value()
    for table in ["SpyMessageRead", "SpyMessageContentsRead"] {
        for row in source.auxiliaryRows[table] ?? [] {
            // In these tables userId is the source ACCOUNT, not the message author.
            let userId = try row.integer("userId")
            guard userId > 0 else { throw ExteralessRetentionError.invalidArchive }
            guard userId == ownerId else { result.otherAccounts += 1; continue }
            let sourcePeer = try row.integer("dialogId")
            guard let peerId = try exteralessAyuPeer(sourcePeer, transaction: transaction, mappings: mappings),
                  transaction.getPeer(peerId) != nil else { result.unresolvedPeers.insert(sourcePeer); continue }
            let id = try row.int32("messageId")
            guard id > 0 else { throw ExteralessRetentionError.invalidArchive }
            // The alias is used only when the actual date column is absent, exactly as
            // AyuDatabaseImport.READ_ALIASES. Null/zero date does not borrow another date.
            let dateKey = row.values["date"] == nil ? "entityCreateDate" : "date"
            guard let date = try retentionAyuUnixSeconds(row, key: dateKey, now: now) else { result.unsetDates += 1; continue }
            let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
            if let known = transaction.getMessage(messageId), known.flags.contains(.Incoming) {
                // Source collectReads/collectContentsReads only select out=1. A conflict with
                // a known receiving-account row must not become a made-up outgoing read date.
                throw ExteralessRetentionError.invalidArchive
            }
            result.reads.append(RetentionPrivacyReadInput(messageId: messageId, timestamp: date, played: table == "SpyMessageContentsRead"))
        }
    }
    // copyLastSeen prefers LastSeenEntity if it exists, even when it is empty.
    let table = source.auxiliaryTables["LastSeenEntity"] != nil ? "LastSeenEntity" : "SpyLastSeen"
    let column = table == "LastSeenEntity" ? "lastSeen" : "lastSeenDate"
    for row in source.auxiliaryRows[table] ?? [] {
        // In the global last-seen table userId is the OBSERVED USER. Import only into this
        // selected account and only if it has that actual cloud user; never fan out to accounts.
        let userId = try row.integer("userId")
        guard userId > 0, userId <= 0x00ff_ffff_ffff_ffff else { throw ExteralessRetentionError.invalidArchive }
        let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(userId))
        if peerId == accountPeerId { result.selfActivities += 1; continue }
        guard transaction.getPeer(peerId) is TelegramUser else { result.unresolvedPeers.insert(userId); continue }
        guard let timestamp = try retentionAyuUnixSeconds(row, key: column, now: now) else { result.unsetDates += 1; continue }
        if Int64(timestamp) < now - Int64(PrivacyObservations.lastSeenRetention) { result.expiredActivities += 1; continue }
        result.activities[peerId] = max(result.activities[peerId] ?? 0, timestamp)
    }
    return result
}

/// Builds a bounded merge through the existing public PrivacyObservations model. Native dates
/// win on conflict (original DAO CONFLICT_IGNORE); known activity only moves forward. The
/// final key set is selected once so importing into a full 50k-row model is not quadratic.
func retentionMergePrivacyObservations(activity originalActivity: PrivacyObservations, readDates originalReads: PrivacyObservations, input: RetentionPrivacyImportInput, now: Int32) throws -> RetentionPrivacyImportMerge {
    var activity = originalActivity
    activity.observeActivities(Dictionary(uniqueKeysWithValues: input.activities.map { ($0.key.toInt64(), $0.value) }), now: now)
    var merged = originalReads.reads
    var candidates: [(String, Bool)] = []
    var duplicates = 0
    for read in input.reads.sorted(by: { $0.timestamp < $1.timestamp }) {
        let key = PrivacyObservations.messageKey(peerId: read.messageId.peerId.toInt64(), namespace: read.messageId.namespace, id: read.messageId.id)
        var value = merged[key] ?? PrivacyObservations.Read()
        if read.played {
            if value.playedAt == nil { value.playedAt = read.timestamp; candidates.append((key, true)) }
            else { duplicates += 1 }
        } else {
            if value.readAt == nil { value.readAt = read.timestamp; candidates.append((key, false)) }
            else { duplicates += 1 }
        }
        merged[key] = value
    }
    if merged.count > PrivacyObservations.maximumReadRecords {
        let sorted = merged.sorted { lhs, rhs in
            let l = min(lhs.value.readAt ?? Int32.max, lhs.value.playedAt ?? Int32.max)
            let r = min(rhs.value.readAt ?? Int32.max, rhs.value.playedAt ?? Int32.max)
            return l == r ? lhs.key < rhs.key : l < r
        }
        for value in sorted.prefix(merged.count - PrivacyObservations.maximumReadRecords) { merged.removeValue(forKey: value.key) }
    }
    var reads = PrivacyObservations()
    reads.observeActivities(originalReads.lastSeen, now: now)
    for (key, value) in merged {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let peer = Int64(parts[0]), let namespace = Int32(parts[1]), let id = Int32(parts[2]), peer != 0, namespace >= 0, id != 0,
              PrivacyObservations.messageKey(peerId: peer, namespace: namespace, id: id) == key else { throw ExteralessRetentionError.invalidArchive }
        guard value.readAt != nil || value.playedAt != nil,
              value.readAt == nil || value.readAt! > 0, value.playedAt == nil || value.playedAt! > 0 else { throw ExteralessRetentionError.invalidArchive }
        if let date = value.readAt { reads.observeRead(peerId: peer, namespace: namespace, id: id, timestamp: date, played: false) }
        if let date = value.playedAt { reads.observeRead(peerId: peer, namespace: namespace, id: id, timestamp: date, played: true) }
    }
    let addedReads = candidates.filter { !$0.1 && reads.reads[$0.0]?.readAt != nil }.count
    let addedPlayed = candidates.filter { $0.1 && reads.reads[$0.0]?.playedAt != nil }.count
    let addedActivities = input.activities.filter { id, date in
        activity.lastSeen[id.toInt64()] == date && date > (originalActivity.lastSeen[id.toInt64()] ?? 0)
    }.count
    duplicates += input.activities.filter { $0.value <= (originalActivity.lastSeen[$0.key.toInt64()] ?? 0) }.count
    return RetentionPrivacyImportMerge(activity: activity, readDates: reads, importedReads: addedReads, importedPlayed: addedPlayed, importedActivities: addedActivities, duplicates: duplicates,
        quotaSkipped: candidates.count - addedReads - addedPlayed + input.activities.filter { activity.lastSeen[$0.key.toInt64()] == nil }.count)
}

/// Storage capability is supplied by the privacy owner API (thin patch delivered separately).
/// This file never names or writes an exteraless.privacy.* cache key itself.
func retentionPreparePrivacyImport(transaction: Transaction, accountPeerId: PeerId, input: RetentionPrivacyImportInput, now: Int32) throws -> (merge: RetentionPrivacyImportMerge, commit: (Transaction) -> Void) {
    let current = try exteralessPrivacyImportSnapshot(transaction: transaction, accountPeerId: accountPeerId)
    let merged = try retentionMergePrivacyObservations(activity: current.activity, readDates: current.readDates, input: input, now: now)
    let commit = try exteralessPrivacyPrepareImportCommit(activity: merged.activity, readDates: merged.readDates)
    return (merged, commit)
}
