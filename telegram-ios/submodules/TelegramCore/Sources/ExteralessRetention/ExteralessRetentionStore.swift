import CryptoKit
import ExteralessCore
import Foundation
import Postbox

// Coordinator-approved shared local-state collection. NEVER clear the whole collection:
// privacy/other local-state owners use their own prefixes. Quotas below belong to retention.
let exteralessRetentionCollection = Namespaces.CachedItemCollection.exteralessLocalState
let exteralessRetentionIndexId = ItemCacheEntryId(collectionId: exteralessRetentionCollection, key: ValueBoxKey("exteraless.retention.index"))
let exteralessRetentionResetId = ItemCacheEntryId(collectionId: exteralessRetentionCollection, key: ValueBoxKey("exteraless.retention.reset"))
private let exteralessRetentionExceptionsId = ItemCacheEntryId(collectionId: exteralessRetentionCollection, key: ValueBoxKey("exteraless.retention.exceptions"))
let exteralessRetentionSlotCount = 20000

func exteralessRetentionRowId(_ slot: Int) -> ItemCacheEntryId {
    precondition((0 ..< exteralessRetentionSlotCount).contains(slot))
    return ItemCacheEntryId(collectionId: exteralessRetentionCollection, key: ValueBoxKey("exteraless.retention.row.\(slot)"))
}

struct ExteralessRetentionIndexRow: Codable {
    let key: RetentionMessageKey
    let slot: Int
    let bytes: Int
    let firstCapture: Int64
    let lastCapture: Int64
    let timestamp: Int32
    let threadId: Int64?
    let deletedAt: Int64?
    let versionCount: Int
    let resources: [String]

    init(key: RetentionMessageKey, slot: Int, bytes: Int, record: RetentionPolicyRecord, timestamp: Int32, threadId: Int64?) {
        self.key = key
        self.slot = slot
        self.bytes = bytes
        self.firstCapture = record.versions.map(\.capturedAt).min() ?? record.deletedAt ?? 0
        self.lastCapture = max(record.versions.map(\.capturedAt).max() ?? 0, record.deletedAt ?? 0)
        self.timestamp = timestamp
        self.threadId = threadId
        self.deletedAt = record.deletedAt
        self.versionCount = record.versions.count
        self.resources = record.resourceIds.sorted()
    }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["key", "slot", "bytes", "firstCapture", "lastCapture", "timestamp", "threadId", "deletedAt", "versionCount", "resources"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(RetentionMessageKey.self, forKey: .key)
        self.slot = try c.decode(Int.self, forKey: .slot)
        self.bytes = try c.decode(Int.self, forKey: .bytes)
        self.firstCapture = try c.decode(Int64.self, forKey: .firstCapture)
        self.lastCapture = try c.decode(Int64.self, forKey: .lastCapture)
        self.timestamp = try c.decode(Int32.self, forKey: .timestamp)
        self.threadId = try c.decodeIfPresent(Int64.self, forKey: .threadId)
        self.deletedAt = try c.decodeIfPresent(Int64.self, forKey: .deletedAt)
        self.versionCount = try c.decode(Int.self, forKey: .versionCount)
        self.resources = try c.decode([String].self, forKey: .resources)
        guard (0 ..< exteralessRetentionSlotCount).contains(self.slot), self.bytes > 0, self.bytes <= RetentionPolicy.maximumMetadataBytes,
              self.firstCapture > 0, self.lastCapture >= self.firstCapture, self.timestamp > 0,
              (0 ... RetentionPolicy.maximumVersions).contains(self.versionCount),
              self.resources.count <= RetentionPolicy.maximumVersions * RetentionPolicy.maximumResourcesPerVersion,
              Set(self.resources).count == self.resources.count else { throw ExteralessRetentionError.invalidArchive }
    }
}

struct ExteralessRetentionMediaEntry: Codable, Equatable {
    enum State: String, Codable { case pending, stored, failed }
    let id: String
    let token: String
    let capturedAt: Int64
    var reservedBytes: Int64
    var storedBytes: Int64?
    var state: State

    init(id: String, capturedAt: Int64, reservedBytes: Int64) {
        self.id = id
        self.token = UUID().uuidString.lowercased()
        self.capturedAt = capturedAt
        self.reservedBytes = reservedBytes
        self.storedBytes = nil
        self.state = .pending
    }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["id", "token", "capturedAt", "reservedBytes", "storedBytes", "state"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.token = try c.decode(String.self, forKey: .token)
        self.capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        self.reservedBytes = try c.decode(Int64.self, forKey: .reservedBytes)
        self.storedBytes = try c.decodeIfPresent(Int64.self, forKey: .storedBytes)
        self.state = try c.decode(State.self, forKey: .state)
        guard Self.validResourceId(self.id), UUID(uuidString: self.token)?.uuidString.lowercased() == self.token, self.cacheFileId != 0,
              self.capturedAt > 0, self.reservedBytes > 0, self.reservedBytes <= RetentionPolicy.maximumResourceBytes,
              self.storedBytes == nil || (self.storedBytes! > 0 && self.storedBytes! <= self.reservedBytes),
              (self.state == .stored) == (self.storedBytes != nil) else { throw ExteralessRetentionError.invalidArchive }
    }

    static func validResourceId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.contains("/") && !id.contains("\\") && !id.contains("\0") && id != "." && id != ".."
    }
}

struct ExteralessRetentionIndex: Codable {
    let formatVersion: Int
    let accountPeerId: Int64
    let epoch: String
    let mediaKey: Data
    var revision: UInt64
    var nextSlot: Int
    var rows: [String: ExteralessRetentionIndexRow]
    var media: [String: ExteralessRetentionMediaEntry]

    init(accountPeerId: PeerId) {
        self.formatVersion = 1
        self.accountPeerId = accountPeerId.toInt64()
        self.epoch = UUID().uuidString.lowercased()
        self.mediaKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        self.revision = 0
        self.nextSlot = 0
        self.rows = [:]
        self.media = [:]
    }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["formatVersion", "accountPeerId", "epoch", "mediaKey", "revision", "nextSlot", "rows", "media"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard self.formatVersion == 1 else { throw ExteralessRetentionError.unsupportedFormat }
        self.accountPeerId = try c.decode(Int64.self, forKey: .accountPeerId)
        self.epoch = try c.decode(String.self, forKey: .epoch)
        self.mediaKey = try c.decode(Data.self, forKey: .mediaKey)
        self.revision = try c.decode(UInt64.self, forKey: .revision)
        self.nextSlot = try c.decode(Int.self, forKey: .nextSlot)
        self.rows = try c.decode([String: ExteralessRetentionIndexRow].self, forKey: .rows)
        self.media = try c.decode([String: ExteralessRetentionMediaEntry].self, forKey: .media)
        guard self.accountPeerId != 0, UUID(uuidString: self.epoch)?.uuidString.lowercased() == self.epoch, self.mediaKey.count == 32,
              (0 ..< exteralessRetentionSlotCount).contains(self.nextSlot), self.rows.count <= exteralessRetentionSlotCount,
              Set(self.rows.values.map(\.slot)).count == self.rows.count, self.rows.allSatisfy({ $0.key == $0.value.key.storageKey }),
              self.media.count <= RetentionPolicy.maximumResourceCount, self.media.allSatisfy({ $0.key == $0.value.id }),
              Set(self.media.values.map(\.cacheFileId)).count == self.media.count,
              self.rows.values.reduce(Int64(0), { $0 + Int64($1.bytes) }) <= Int64(RetentionPolicy.maximumMetadataBytes) else {
            throw ExteralessRetentionError.invalidArchive
        }
    }

    static func load(transaction: Transaction, accountPeerId: PeerId) throws -> ExteralessRetentionIndex? {
        guard transaction.retrieveItemCacheEntry(id: exteralessRetentionResetId) == nil else { throw ExteralessRetentionError.unavailable }
        guard let entry = transaction.retrieveItemCacheEntry(id: exteralessRetentionIndexId) else { return nil }
        guard entry.data.count <= RetentionPolicy.maximumMetadataBytes else { throw ExteralessRetentionError.invalidArchive }
        let result = try JSONDecoder().decode(Self.self, from: entry.data)
        guard result.accountPeerId == accountPeerId.toInt64() else { throw ExteralessRetentionError.invalidArchive }
        guard result.rows.values.reduce(Int64(entry.data.count), { $0 + Int64($1.bytes) }) <= Int64(RetentionPolicy.maximumMetadataBytes) else { throw ExteralessRetentionError.invalidArchive }
        return result
    }
}

private struct ExteralessRetentionExceptions: Codable {
    let formatVersion: Int
    let accountPeerId: Int64
    var peers: [String: RetentionPeerExceptions]

    init(accountPeerId: PeerId) { self.formatVersion = 1; self.accountPeerId = accountPeerId.toInt64(); self.peers = [:] }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["formatVersion", "accountPeerId", "peers"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard self.formatVersion == 1 else { throw ExteralessRetentionError.unsupportedFormat }
        self.accountPeerId = try c.decode(Int64.self, forKey: .accountPeerId)
        self.peers = try c.decode([String: RetentionPeerExceptions].self, forKey: .peers)
        guard self.peers.count <= RetentionPolicy.maximumExceptions, self.peers.keys.allSatisfy({ key in
            guard let id = Int64(key) else { return false }
            return id != 0 && String(id) == key
        }) else { throw ExteralessRetentionError.invalidArchive }
    }

    static func load(transaction: Transaction, accountPeerId: PeerId) throws -> Self {
        guard let entry = transaction.retrieveItemCacheEntry(id: exteralessRetentionExceptionsId) else { return Self(accountPeerId: accountPeerId) }
        guard entry.data.count <= 4 * 1024 * 1024 else { throw ExteralessRetentionError.invalidArchive }
        let value = try JSONDecoder().decode(Self.self, from: entry.data)
        guard value.accountPeerId == accountPeerId.toInt64() else { throw ExteralessRetentionError.invalidArchive }
        return value
    }
}

/// Lives only inside a Postbox transaction. Writes are staged until every payload is encoded.
/// Fixed bounded slots let an explicit reset erase even an unknown/corrupt index without touching
/// privacy's entries or inventing a collection-wide deletion.
final class ExteralessRetentionStore {
    let transaction: Transaction
    let policy: RetentionPolicy
    let now: Int64
    private(set) var index: ExteralessRetentionIndex
    private var staged: [Int: Data] = [:]
    private var removed = Set<Int>()
    private let exceptions: ExteralessRetentionExceptions
    private var ownership: RetentionMediaOwnership
    private let originalMedia: [ExteralessRetentionMediaEntry]

    init(transaction: Transaction, accountPeerId: PeerId, policy: RetentionPolicy, now: Int64) throws {
        self.transaction = transaction
        self.policy = policy
        self.now = now
        self.index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: accountPeerId) ?? ExteralessRetentionIndex(accountPeerId: accountPeerId)
        self.originalMedia = Array(self.index.media.values)
        self.ownership = try RetentionMediaOwnership.load(transaction: transaction, accountPeerId: accountPeerId)
        for entry in self.originalMedia { try self.ownership.enroll(token: entry.token) }
        self.exceptions = try ExteralessRetentionExceptions.load(transaction: transaction, accountPeerId: accountPeerId)
        self.removeExpiredRows()
    }

    func record(_ key: RetentionMessageKey) throws -> RetentionPolicyRecord? {
        guard let row = self.index.rows[key.storageKey] else { return nil }
        guard let data = self.staged[row.slot] ?? self.transaction.retrieveItemCacheEntry(id: exteralessRetentionRowId(row.slot))?.data,
              data.count == row.bytes else { throw ExteralessRetentionError.invalidArchive }
        var record = try JSONDecoder().decode(RetentionPolicyRecord.self, from: data)
        guard record.key == key else { throw ExteralessRetentionError.invalidArchive }
        record.prune(cutoff: self.policy.cutoff(now: self.now))
        return record
    }

    func captureDeleted(_ message: Message, mediaBox: MediaBox) throws -> Bool {
        guard self.isEligible(message), self.permits(message, editing: false) else { return false }
        var record = try self.record(message.retentionKey) ?? RetentionPolicyRecord(key: message.retentionKey)
        guard record.deletedAt == nil else { return false }
        let snapshot = try self.snapshot(message)
        let resources = self.reserveMedia(message, mediaBox: mediaBox)
        let changed = try record.captureDeletion(payload: snapshot, fingerprint: exteralessRetentionFingerprint(text: message.text, attributes: message.attributes, media: message.media), resourceIds: resources, messageVersionDate: message.retentionVersionDate, now: self.now)
        if changed { try self.save(record, timestamp: message.timestamp, threadId: message.threadId) }
        return changed
    }

    func captureEdit(previous: Message, updated: StoreMessage?, mediaBox: MediaBox, expired: Bool = false) throws -> Bool {
        guard self.isEligible(previous), self.permits(previous, editing: true), expired || updated?.authorId != nil else { return false }
        let previousFingerprint = exteralessRetentionFingerprint(text: previous.text, attributes: previous.attributes, media: previous.media)
        let updatedFingerprint = updated.map { exteralessRetentionFingerprint(text: $0.text, attributes: $0.attributes, media: $0.media) } ?? previousFingerprint
        guard expired || previousFingerprint != updatedFingerprint else { return false }
        var record = try self.record(previous.retentionKey) ?? RetentionPolicyRecord(key: previous.retentionKey)
        let snapshot = try self.snapshot(previous)
        let resources = self.reserveMedia(previous, mediaBox: mediaBox)
        let date = (updated?.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date
        let changed = try record.captureEdit(payload: snapshot, fingerprint: previousFingerprint, resourceIds: resources, previousVersionDate: previous.retentionVersionDate, incomingFingerprint: updatedFingerprint, incomingEditDate: date, now: self.now, expired: expired)
        if changed { try self.save(record, timestamp: previous.timestamp, threadId: previous.threadId) }
        return changed
    }

    func importAyu(message: Message, source: Data, capturedAt: Int64, deleted: Bool, mediaBox: MediaBox) throws -> Bool {
        guard capturedAt > self.policy.cutoff(now: self.now), capturedAt <= self.now + 300 else { return false }
        let snapshot = try exteralessRetentionEncode(ExteralessRetentionSnapshot(message: message, includeMedia: true, ayuSource: source))
        guard snapshot.count <= RetentionPolicy.maximumVersionBytes else { throw ExteralessRetentionError.limitExceeded }
        var record = try self.record(message.retentionKey) ?? RetentionPolicyRecord(key: message.retentionKey)
        let changed = try record.mergeImported(payload: snapshot, fingerprint: exteralessRetentionFingerprint(text: message.text, attributes: message.attributes, media: message.media), resourceIds: self.reserveMedia(message, mediaBox: mediaBox), reason: deleted ? .deleted : .edit, versionDate: message.retentionVersionDate, capturedAt: capturedAt)
        if changed { try self.save(record, timestamp: message.timestamp, threadId: message.threadId) }
        return changed
    }

    private func isEligible(_ message: Message) -> Bool {
        let namespaceAllowed = message.id.peerId.namespace == Namespaces.Peer.SecretChat
            ? [Namespaces.Message.Local, Namespaces.Message.SecretIncoming].contains(message.id.namespace)
            : message.id.namespace == Namespaces.Message.Cloud
        return namespaceAllowed && message.exteralessRetention == nil && !message.flags.contains(.Unsent) && !message.flags.contains(.Sending)
            && !message.media.contains(where: { $0 is TelegramMediaAction })
            && (!message.text.isEmpty || !message.effectiveMedia.isEmpty || message.richText != nil)
    }

    private func facts(_ message: Message) -> RetentionPeerFacts {
        let peer = self.transaction.getPeer(message.id.peerId) ?? message.peers[message.id.peerId]
        let kind: RetentionPeerFacts.Kind
        if message.id.peerId.namespace == Namespaces.Peer.CloudUser || message.id.peerId.namespace == Namespaces.Peer.SecretChat || peer is TelegramSecretChat {
            kind = .privateChat
        } else if let channel = peer as? TelegramChannel {
            let isPublic = channel.addressName?.isEmpty == false || channel.usernames.contains(where: { $0.flags.contains(.isActive) })
            if case .broadcast = channel.info { kind = .channel(isPublic: isPublic) }
            else { kind = .group(isPublic: isPublic) }
        } else if peer is TelegramGroup || message.id.peerId.namespace == Namespaces.Peer.CloudGroup {
            kind = .group(isPublic: false)
        } else {
            kind = .unknown
        }
        let author = message.author.flatMap { self.transaction.getPeer($0.id) ?? $0 } as? TelegramUser
        return RetentionPeerFacts(kind: kind, isArchived: self.transaction.getPeerChatListIndex(message.id.peerId)?.0 == Namespaces.PeerGroup.archive, chatIsBot: (peer as? TelegramUser)?.botInfo != nil, senderIsBot: author.map { $0.botInfo != nil })
    }

    private func permits(_ message: Message, editing: Bool) -> Bool {
        let chat = self.exceptions.peers[String(message.id.peerId.toInt64())] ?? RetentionPeerExceptions()
        let sender = message.author.flatMap { self.exceptions.peers[String($0.id.toInt64())] } ?? RetentionPeerExceptions()
        return editing ? self.policy.keepsEdits(in: self.facts(message), chat: chat, sender: sender) : self.policy.keepsDeleted(in: self.facts(message), chat: chat, sender: sender)
    }

    private func snapshot(_ message: Message) throws -> Data {
        let replyId = (message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute)?.messageId
        let replyAuthor = replyId.flatMap { self.transaction.getMessage($0)?.author?.id }
        let data = try exteralessRetentionEncode(ExteralessRetentionSnapshot(message: message, includeMedia: self.policy.keepsMedia(in: self.facts(message)), replyAuthorId: replyAuthor))
        guard data.count <= RetentionPolicy.maximumVersionBytes else { throw ExteralessRetentionError.limitExceeded }
        return data
    }

    private func reserveMedia(_ message: Message, mediaBox: MediaBox) -> [String] {
        guard self.policy.keepsMedia(in: self.facts(message)) else { return [] }
        var result: [String] = []
        var reserved = self.index.media.values.reduce(Int64(0)) { $0 + RetentionPolicy.mediaReservationCost(bytes: $1.reservedBytes) }
        for resource in exteralessRetentionResources(message) {
            if self.index.media[resource.id] != nil { result.append(resource.id); continue }
            let localSize = mediaBox.fileSizeForId(MediaResourceId(resource.id))
            let size = max(localSize, resource.size ?? RetentionPolicy.maximumResourceBytes)
            let cost = RetentionPolicy.mediaReservationCost(bytes: size)
            guard size > 0, size <= RetentionPolicy.maximumResourceBytes, cost <= self.policy.mediaByteLimit, reserved <= self.policy.mediaByteLimit - cost,
                  self.index.media.count < RetentionPolicy.maximumResourceCount else { continue }
            let usedCacheIds = Set(self.index.media.values.map { $0.cacheId.stringRepresentation }).union(self.ownership.owned.values)
            guard self.ownership.owned.count < RetentionMediaOwnership.maximumEntries else { continue }
            var entry: ExteralessRetentionMediaEntry?
            for _ in 0 ..< 4 {
                let candidate = ExteralessRetentionMediaEntry(id: resource.id, capturedAt: self.now, reservedBytes: size)
                if candidate.cacheFileId != 0 && !usedCacheIds.contains(candidate.cacheId.stringRepresentation) && mediaBox.fileSizeForId(candidate.cacheId) == 0 {
                    entry = candidate
                    break
                }
            }
            guard let entry else { continue }
            do { try self.ownership.enroll(token: entry.token) } catch { continue }
            self.index.media[resource.id] = entry
            reserved += cost
            result.append(resource.id)
        }
        return result
    }

    func save(_ record: RetentionPolicyRecord, timestamp: Int32, threadId: Int64?) throws {
        guard !record.versions.isEmpty || record.deletedAt != nil else { self.remove(record.key); return }
        let data = try exteralessRetentionEncode(record)
        guard data.count <= RetentionPolicy.maximumMetadataBytes else { throw ExteralessRetentionError.limitExceeded }
        let slot: Int
        if let existing = self.index.rows[record.key.storageKey] {
            slot = existing.slot
        } else {
            if self.index.rows.count >= self.policy.messageLimit { self.removeOldest() }
            let used = Set(self.index.rows.values.map(\.slot))
            var candidate = self.index.nextSlot
            for _ in 0 ..< exteralessRetentionSlotCount {
                if !used.contains(candidate) { break }
                candidate = (candidate + 1) % exteralessRetentionSlotCount
            }
            guard !used.contains(candidate) else { throw ExteralessRetentionError.limitExceeded }
            slot = candidate
            self.index.nextSlot = (slot + 1) % exteralessRetentionSlotCount
        }
        self.staged[slot] = data
        self.removed.remove(slot)
        self.index.rows[record.key.storageKey] = ExteralessRetentionIndexRow(key: record.key, slot: slot, bytes: data.count, record: record, timestamp: timestamp, threadId: threadId)
    }

    func remove(_ key: RetentionMessageKey) {
        guard let row = self.index.rows.removeValue(forKey: key.storageKey) else { return }
        self.staged.removeValue(forKey: row.slot)
        self.removed.insert(row.slot)
    }

    private func removeOldest() {
        if let row = self.index.rows.values.min(by: { lhs, rhs in
            lhs.firstCapture == rhs.firstCapture ? lhs.key < rhs.key : lhs.firstCapture < rhs.firstCapture
        }) { self.remove(row.key) }
    }

    private func removeExpiredRows() {
        let cutoff = self.policy.cutoff(now: self.now)
        for row in self.index.rows.values.filter({ $0.lastCapture <= cutoff }) { self.remove(row.key) }
    }

    /// Incremental expiry of versions inside otherwise live rows, capped per transaction.
    @discardableResult
    func pruneVersions(limit: Int = 128) throws -> Bool {
        let rows = self.index.rows.values.filter { $0.firstCapture <= self.policy.cutoff(now: self.now) }.sorted { $0.key < $1.key }
        for row in rows.prefix(limit) {
            if let record = try self.record(row.key) { try self.save(record, timestamp: row.timestamp, threadId: row.threadId) }
        }
        return rows.count > limit
    }

    func retryFailedMedia() {
        for id in self.index.media.keys {
            if var entry = self.index.media[id], entry.state == .failed {
                entry.state = .pending
                self.index.media[id] = entry
            }
        }
    }

    func finish() throws -> ExteralessRetentionIndex {
        while self.index.rows.count > self.policy.messageLimit { self.removeOldest() }
        var bytes = self.index.rows.values.reduce(0) { $0 + $1.bytes }
        while bytes > RetentionPolicy.maximumMetadataBytes && !self.index.rows.isEmpty {
            self.removeOldest()
            bytes = self.index.rows.values.reduce(0) { $0 + $1.bytes }
        }
        let referenced = Set(self.index.rows.values.flatMap(\.resources))
        self.index.media = self.index.media.filter { referenced.contains($0.key) }
        var reserved = self.index.media.values.reduce(Int64(0)) { $0 + RetentionPolicy.mediaReservationCost(bytes: $1.reservedBytes) }
        for media in self.index.media.values.sorted(by: { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }) {
            if reserved <= self.policy.mediaByteLimit { break }
            self.index.media.removeValue(forKey: media.id)
            reserved -= RetentionPolicy.mediaReservationCost(bytes: media.reservedBytes)
        }
        guard self.index.revision < UInt64.max else { throw ExteralessRetentionError.limitExceeded }
        self.index.revision += 1
        var encodedIndex = try exteralessRetentionEncode(self.index)
        while bytes + encodedIndex.count > RetentionPolicy.maximumMetadataBytes && !self.index.rows.isEmpty {
            self.removeOldest()
            bytes = self.index.rows.values.reduce(0) { $0 + $1.bytes }
            let remainingResources = Set(self.index.rows.values.flatMap(\.resources))
            self.index.media = self.index.media.filter { remainingResources.contains($0.key) }
            encodedIndex = try exteralessRetentionEncode(self.index)
        }
        guard bytes + encodedIndex.count <= RetentionPolicy.maximumMetadataBytes else { throw ExteralessRetentionError.limitExceeded }
        let liveTokens = Set(self.index.media.values.map(\.token))
        try self.ownership.retire(self.originalMedia.filter { !liveTokens.contains($0.token) })
        // Include reservations staged then evicted within this transaction as well.
        self.ownership.pending.formUnion(Set(self.ownership.owned.keys).subtracting(liveTokens))
        try self.ownership.save(transaction: self.transaction)
        for slot in self.removed { self.transaction.removeItemCacheEntry(id: exteralessRetentionRowId(slot)) }
        for (slot, data) in self.staged { self.transaction.putItemCacheEntry(id: exteralessRetentionRowId(slot), entry: CodableEntry(data: data)) }
        self.transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: encodedIndex))
        return self.index
    }

    static func peerExceptions(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId) throws -> RetentionPeerExceptions {
        try ExteralessRetentionExceptions.load(transaction: transaction, accountPeerId: accountPeerId).peers[String(peerId.toInt64())] ?? RetentionPeerExceptions()
    }

    static func setPeerExceptions(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, value: RetentionPeerExceptions) throws {
        guard peerId.toInt64() != 0 else { throw ExteralessRetentionError.invalidArchive }
        var data = try ExteralessRetentionExceptions.load(transaction: transaction, accountPeerId: accountPeerId)
        if value.deleted || value.edited { data.peers[String(peerId.toInt64())] = value }
        else { data.peers.removeValue(forKey: String(peerId.toInt64())) }
        guard data.peers.count <= RetentionPolicy.maximumExceptions else { throw ExteralessRetentionError.limitExceeded }
        transaction.putItemCacheEntry(id: exteralessRetentionExceptionsId, entry: CodableEntry(data: try exteralessRetentionEncode(data)))
    }
}
