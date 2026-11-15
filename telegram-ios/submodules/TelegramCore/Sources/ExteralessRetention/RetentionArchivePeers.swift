import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

let retentionArchivePeersId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.retention.archivePeers"))

struct RetentionArchivePeerDescriptor: Codable, Equatable {
    let peerId: Int64
    let androidDialogId: Int64
    let folderId: Int32
    let topMessage: Int32
    let lastMessageDate: Int32
    let capturedAt: Int64

    init(peerId: PeerId, androidDialogId: Int64, folderId: Int32, topMessage: Int32, lastMessageDate: Int32, capturedAt: Int64) {
        self.peerId = peerId.toInt64(); self.androidDialogId = androidDialogId; self.folderId = folderId
        self.topMessage = topMessage; self.lastMessageDate = lastMessageDate; self.capturedAt = capturedAt
    }

    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["peerId", "androidDialogId", "folderId", "topMessage", "lastMessageDate", "capturedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.peerId = try c.decode(Int64.self, forKey: .peerId)
        self.androidDialogId = try c.decode(Int64.self, forKey: .androidDialogId)
        self.folderId = try c.decode(Int32.self, forKey: .folderId)
        self.topMessage = try c.decode(Int32.self, forKey: .topMessage)
        self.lastMessageDate = try c.decode(Int32.self, forKey: .lastMessageDate)
        self.capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        guard self.peerId != 0, self.androidDialogId != 0, self.androidDialogId != Int64.min,
              self.folderId == 0 || self.folderId == 1, self.topMessage > 0, self.lastMessageDate > 0, self.capturedAt > 0 else { throw ExteralessRetentionError.invalidArchive }
    }
}

struct RetentionArchivePeerStore: Codable {
    let version: Int
    let accountPeerId: Int64
    var peers: [String: RetentionArchivePeerDescriptor]
    static let maximumBytes = 1024 * 1024
    static let maximumRecords = 5000

    init(accountPeerId: PeerId) { self.version = 1; self.accountPeerId = accountPeerId.toInt64(); self.peers = [:] }
    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["version", "accountPeerId", "peers"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        guard self.version == 1 else { throw ExteralessRetentionError.unsupportedFormat }
        self.accountPeerId = try c.decode(Int64.self, forKey: .accountPeerId)
        self.peers = try c.decode([String: RetentionArchivePeerDescriptor].self, forKey: .peers)
        guard self.accountPeerId != 0, self.peers.count <= Self.maximumRecords,
              self.peers.allSatisfy({ $0.key == String($0.value.androidDialogId) }) else { throw ExteralessRetentionError.invalidArchive }
    }

    static func load(transaction: Transaction, accountPeerId: PeerId, policy: RetentionPolicy, now: Int64) throws -> Self {
        guard transaction.retrieveItemCacheEntry(id: exteralessRetentionResetId) == nil else { throw ExteralessRetentionError.unavailable }
        guard let entry = transaction.retrieveItemCacheEntry(id: retentionArchivePeersId) else { return Self(accountPeerId: accountPeerId) }
        guard entry.data.count <= Self.maximumBytes else { throw ExteralessRetentionError.limitExceeded }
        var value = try JSONDecoder().decode(Self.self, from: entry.data)
        guard value.accountPeerId == accountPeerId.toInt64() else { throw ExteralessRetentionError.invalidArchive }
        value.peers = value.peers.filter { $0.value.capturedAt > policy.cutoff(now: now) && $0.value.capturedAt <= now }
        return value
    }

    mutating func bound(limit: Int) throws -> CodableEntry {
        let limit = max(0, min(Self.maximumRecords, limit))
        let sorted = self.peers.values.sorted { $0.capturedAt == $1.capturedAt ? $0.androidDialogId < $1.androidDialogId : $0.capturedAt < $1.capturedAt }
        var index = 0
        while self.peers.count > limit { self.peers.removeValue(forKey: String(sorted[index].androidDialogId)); index += 1 }
        var data = try exteralessRetentionEncode(self)
        if data.count > Self.maximumBytes {
            // Find the largest newest suffix that fits, instead of re-encoding the whole map
            // once per removed peer when a large import reaches the byte limit.
            let candidates = Array(sorted.dropFirst(index))
            var lower = 0, upper = candidates.count
            var best: [String: RetentionArchivePeerDescriptor] = [:]
            while lower < upper {
                let count = (lower + upper + 1) / 2
                let candidate = Dictionary(uniqueKeysWithValues: candidates.suffix(count).map { (String($0.androidDialogId), $0) })
                var probe = self
                probe.peers = candidate
                if try exteralessRetentionEncode(probe).count <= Self.maximumBytes { lower = count; best = candidate }
                else { upper = count - 1 }
            }
            self.peers = best
            data = try exteralessRetentionEncode(self)
        }
        guard data.count <= Self.maximumBytes else { throw ExteralessRetentionError.limitExceeded }
        return CodableEntry(data: data)
    }
}

struct RetentionArchivePeerImport {
    let entry: CodableEntry
    let imported: Int
    let duplicates: Int
    let expired: Int
    let otherAccounts: Int
    let unresolved: Set<Int64>
    let quotaSkipped: Int
}

func retentionPrepareAyuDialogs(_ rows: [ExteralessAyuRow], transaction: Transaction, accountPeerId: PeerId, mappings: [Int64: PeerId], policy: RetentionPolicy, now: Int64) throws -> RetentionArchivePeerImport {
    var store = try RetentionArchivePeerStore.load(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: now)
    var duplicates = 0, expired = 0, other = 0
    var unresolved = Set<Int64>(), candidates = Set<String>()
    for row in rows {
        guard try row.integer("userId") == accountPeerId.id._internalGetInt64Value() else { other += 1; continue }
        let dialog = try row.integer("dialogId")
        guard let peerId = try exteralessAyuPeer(dialog, transaction: transaction, mappings: mappings), transaction.getPeer(peerId) != nil else { unresolved.insert(dialog); continue }
        guard let capturedAt = try retentionAyuUnixSeconds(row, key: "entityCreateDate", now: now),
              let lastMessageDate = try retentionAyuUnixSeconds(row, key: "lastMessageDate", now: now) else { throw ExteralessRetentionError.invalidArchive }
        if Int64(capturedAt) <= policy.cutoff(now: now) { expired += 1; continue }
        let folder = try row.int32("folderId"), top = try row.int32("topMessage")
        guard folder == 0 || folder == 1, top > 0 else { throw ExteralessRetentionError.invalidArchive }
        let key = String(dialog)
        if let current = store.peers[key] {
            guard current.peerId == peerId.toInt64() else { throw ExteralessRetentionError.invalidArchive }
            duplicates += 1
        } else {
            store.peers[key] = RetentionArchivePeerDescriptor(peerId: peerId, androidDialogId: dialog, folderId: folder, topMessage: top, lastMessageDate: lastMessageDate, capturedAt: Int64(capturedAt))
            candidates.insert(key)
        }
    }
    let entry = try store.bound(limit: policy.messageLimit)
    let imported = candidates.filter { store.peers[$0] != nil }.count
    return RetentionArchivePeerImport(entry: entry, imported: imported, duplicates: duplicates, expired: expired, otherAccounts: other, unresolved: unresolved, quotaSkipped: candidates.count - imported)
}

func retentionPreparePeerDescriptorClear(transaction: Transaction, accountPeerId: PeerId, scope: ExteralessRetentionScope, policy: RetentionPolicy, now: Int64) throws -> (Transaction) -> Void {
    guard case let .peer(peerId, threadId) = scope, threadId == nil else { return { _ in } }
    var store = try RetentionArchivePeerStore.load(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: now)
    store.peers = store.peers.filter { $0.value.peerId != peerId.toInt64() }
    let entry = try store.bound(limit: policy.messageLimit)
    return { transaction in transaction.putItemCacheEntry(id: retentionArchivePeersId, entry: entry) }
}

public struct ExteralessRetainedChatDescriptor {
    public let peerId: EnginePeer.Id
    public let peer: EnginePeer?
    public let wasArchived: Bool
    public let topMessageId: Int32
    public let lastMessageDate: Int32
    public let capturedAt: Int64
}

public extension TelegramEngine.Messages {
    func retainedChatDescriptors() -> Signal<Result<[ExteralessRetainedChatDescriptor], ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do {
                let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                let store = try RetentionArchivePeerStore.load(transaction: transaction, accountPeerId: account.peerId, policy: current.policy, now: current.now)
                let descriptors = store.peers.values.sorted { $0.capturedAt == $1.capturedAt ? $0.peerId < $1.peerId : $0.capturedAt > $1.capturedAt }.map { value in
                    ExteralessRetainedChatDescriptor(peerId: PeerId(value.peerId), peer: transaction.getPeer(PeerId(value.peerId)).map(EnginePeer.init), wasArchived: value.folderId == 1, topMessageId: value.topMessage, lastMessageDate: value.lastMessageDate, capturedAt: value.capturedAt)
                }
                return .success(descriptors)
            } catch { return .failure(exteralessRetentionError(error)) }
        }
    }
}
