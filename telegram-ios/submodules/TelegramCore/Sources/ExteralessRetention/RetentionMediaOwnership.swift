import ExteralessCore
import Foundation
import Postbox

let retentionMediaOwnershipId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.retention.mediaOwnership.v1"))

/// Independent of the cipher filename AND the message index. Reservations stay here until
/// actual native files, aliases and ciphertext have been removed and directory-synchronized.
struct RetentionMediaOwnership: Codable {
    let format: Int
    let accountPeerId: Int64
    var owned: [String: String] // token -> exact native resource id
    var pending: Set<String>
    static let maximumEntries = 20000
    static let maximumBytes = 4 * 1024 * 1024

    init(accountPeerId: PeerId) { self.format = 1; self.accountPeerId = accountPeerId.toInt64(); self.owned = [:]; self.pending = [] }
    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["format", "accountPeerId", "owned", "pending"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try c.decode(Int.self, forKey: .format)
        self.accountPeerId = try c.decode(Int64.self, forKey: .accountPeerId)
        self.owned = try c.decode([String: String].self, forKey: .owned)
        self.pending = try c.decode(Set<String>.self, forKey: .pending)
        guard self.format == 1, self.owned.count <= Self.maximumEntries,
              self.pending.isSubset(of: Set(self.owned.keys)), self.owned.allSatisfy({ Self.nativeId(token: $0.key) == $0.value }),
              Set(self.owned.values).count == self.owned.count else { throw ExteralessRetentionError.invalidArchive }
    }

    static func nativeId(token: String) -> String? {
        guard UUID(uuidString: token)?.uuidString.lowercased() == token else { return nil }
        let id = ExteralessRetentionMediaEntry.cacheFileId(token: token)
        guard id != 0 else { return nil }
        return LocalFileMediaResource(fileId: id).id.stringRepresentation
    }

    static func load(transaction: Transaction, accountPeerId: PeerId) throws -> Self {
        guard let entry = transaction.retrieveItemCacheEntry(id: retentionMediaOwnershipId) else { return Self(accountPeerId: accountPeerId) }
        guard entry.data.count <= Self.maximumBytes else { throw ExteralessRetentionError.limitExceeded }
        let value = try JSONDecoder().decode(Self.self, from: entry.data)
        guard value.accountPeerId == accountPeerId.toInt64() else { throw ExteralessRetentionError.invalidArchive }
        return value
    }

    mutating func enroll(token: String) throws {
        guard let id = Self.nativeId(token: token) else { throw ExteralessRetentionError.invalidArchive }
        if let previous = self.owned[token] { guard previous == id else { throw ExteralessRetentionError.invalidArchive }; return }
        guard self.owned.count < Self.maximumEntries, !self.owned.values.contains(id) else { throw ExteralessRetentionError.limitExceeded }
        self.owned[token] = id
    }

    mutating func retire(_ entries: [ExteralessRetentionMediaEntry]) throws {
        for entry in entries { try self.enroll(token: entry.token); self.pending.insert(entry.token) }
    }

    func save(transaction: Transaction) throws {
        let data = try exteralessRetentionEncode(self)
        guard data.count <= Self.maximumBytes else { throw ExteralessRetentionError.limitExceeded }
        transaction.putItemCacheEntry(id: retentionMediaOwnershipId, entry: CodableEntry(data: data))
    }
}

struct RetentionMediaVersionOwner {
    let messageId: MessageId
    let sequence: UInt64
}

struct RetentionMediaAdmission {
    let index: ExteralessRetentionIndex
    let entry: ExteralessRetentionMediaEntry
}

/// Both the engine facade and the raw native fetch use this admission again before publication.
/// Merely finding a token in an unpruned index is not a live ownership proof.
func retentionAdmitMedia(transaction: Transaction, accountPeerId: PeerId, policy: RetentionPolicy, now: Int64, resourceId: String, versionOwner: RetentionMediaVersionOwner? = nil) throws -> RetentionMediaAdmission {
    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == accountPeerId else { throw ExteralessRetentionError.unavailable }
    let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: now)
    guard let entry = store.index.media[resourceId] else { throw ExteralessRetentionError.mediaUnavailable }
    let cutoff = policy.cutoff(now: now)
    for row in store.index.rows.values where row.lastCapture > cutoff && row.resources.contains(resourceId) {
        if let owner = versionOwner, row.key.messageId != owner.messageId { continue }
        guard let record = try store.record(row.key) else { continue }
        if record.versions.contains(where: { version in
            version.capturedAt > cutoff && version.capturedAt <= now && version.resourceIds.contains(resourceId)
                && (versionOwner == nil || versionOwner?.sequence == version.sequence)
        }) { return RetentionMediaAdmission(index: store.index, entry: entry) }
    }
    throw ExteralessRetentionError.mediaUnavailable
}
