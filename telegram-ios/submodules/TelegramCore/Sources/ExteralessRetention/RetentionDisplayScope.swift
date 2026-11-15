import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public struct ExteralessRetentionAlbumKey: Hashable {
    public let peerId: EnginePeer.Id
    public let namespace: Int32
    public let threadId: Int64?
    public let group: Int64

    public init?(_ message: EngineMessage) {
        guard let group = message.groupingKey else { return nil }
        self.peerId = message.id.peerId; self.namespace = message.id.namespace
        self.threadId = message.threadId; self.group = group
    }

    var storageKey: String { "\(self.peerId.toInt64()):\(self.namespace):\(self.threadId.map(String.init) ?? "n"):\(self.group)" }
}

private let retentionAlbumIdsId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.retention.albumIds.v1"))

struct RetentionAlbumIdentities: Codable {
    struct Entry: Codable {
        let id: UInt32
        var members: Set<String>
        init(id: UInt32, members: Set<String>) { self.id = id; self.members = members }
        init(from decoder: Decoder) throws {
            try exteralessRetentionCheckKeys(decoder, ["id", "members"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UInt32.self, forKey: .id)
            self.members = try c.decode(Set<String>.self, forKey: .members)
            guard self.members.count <= exteralessRetentionSlotCount, self.members.allSatisfy({ $0.utf8.count <= 128 }) else { throw ExteralessRetentionError.limitExceeded }
        }
    }
    let format: Int
    let accountPeerId: Int64
    var entries: [String: Entry] = [:]

    init(accountPeerId: Int64) { self.format = 1; self.accountPeerId = accountPeerId }
    init(from decoder: Decoder) throws {
        try exteralessRetentionCheckKeys(decoder, ["format", "accountPeerId", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try c.decode(Int.self, forKey: .format)
        self.accountPeerId = try c.decode(Int64.self, forKey: .accountPeerId)
        self.entries = try c.decode([String: Entry].self, forKey: .entries)
        guard self.format == 1, self.entries.count <= exteralessRetentionSlotCount,
              self.entries.keys.allSatisfy({ $0.utf8.count <= 128 }), Set(self.entries.values.map(\.id)).count == self.entries.count else { throw ExteralessRetentionError.invalidArchive }
    }

    static func resolve(transaction: Transaction, index: ExteralessRetentionIndex, message: Message) throws -> Int64? {
        guard let key = ExteralessRetentionAlbumKey(EngineMessage(message)) else { return nil }
        var value = RetentionAlbumIdentities(accountPeerId: index.accountPeerId)
        if let entry = transaction.retrieveItemCacheEntry(id: retentionAlbumIdsId) {
            guard entry.data.count <= 4 * 1024 * 1024, let decoded = entry.get(Self.self), decoded.accountPeerId == index.accountPeerId else { throw ExteralessRetentionError.invalidArchive }
            value = decoded
        }
        let live = Set(index.rows.keys)
        for (key, previous) in value.entries {
            var entry = previous
            entry.members.formIntersection(live)
            value.entries[key] = entry.members.isEmpty ? nil : entry
        }
        var entry: Entry
        if let current = value.entries[key.storageKey] { entry = current }
        else {
            guard value.entries.count < exteralessRetentionSlotCount, let id = transaction.reserveMessageStableId() else { throw ExteralessRetentionError.limitExceeded }
            entry = Entry(id: id, members: [])
        }
        entry.members.insert(message.retentionKey.storageKey)
        value.entries[key.storageKey] = entry
        let data = try exteralessRetentionEncode(value)
        guard data.count <= 4 * 1024 * 1024 else { throw ExteralessRetentionError.limitExceeded }
        transaction.putItemCacheEntry(id: retentionAlbumIdsId, entry: CodableEntry(data: data))
        // Native stable-message counter, with a display-group tag outside its UInt32 domain.
        return (Int64(1) << 39) | Int64(entry.id)
    }

    static func clear(transaction: Transaction) { transaction.removeItemCacheEntry(id: retentionAlbumIdsId) }
}

func retentionFilterDisplayEntries(_ entries: [ExteralessRetentionEntry], liveMessages: [Message], policy: FilteringPolicy, generation: UInt32, translated: Bool) -> [ExteralessRetentionEntry] {
    guard entries.count <= RetentionPolicy.pageSize, liveMessages.count <= 1000 else { return [] }
    let entries = entries.filter { $0.accountPeerId.id._internalGetInt64Value() == policy.account.userId && $0.testingEnvironment == policy.account.testingEnvironment }
    let source = entries.map(\.sourceForFiltering)
    let messages = liveMessages + source
    let groups = Dictionary(grouping: messages.filter { $0.groupingKey != nil }, by: { ExteralessRetentionAlbumKey(EngineMessage($0))! })
    var decisions: [ExteralessRetentionAlbumKey: FilteringDecision] = [:]
    var budget = FilteringWorkBudget(operations: 1_000_000)
    return entries.compactMap { entry in
        let message = entry.sourceForFiltering
        let key = ExteralessRetentionAlbumKey(EngineMessage(message))
        let input = exteralessFilteringMessage(account: policy.account, message: message, group: key.flatMap { groups[$0] } ?? [], translated: translated, regexFiltersEnabled: policy.configuration.regexFiltersEnabled)
        let replyAuthor = input.replySenderId ?? message.exteralessRetention?.replyAuthorId?.toInt64()
        if input.isMegagroup && (policy.hidesSender(input.senderId) || policy.hidesSender(replyAuthor)) { return nil }
        let decision: FilteringDecision
        if let key, let cached = decisions[key] { decision = cached }
        else {
            decision = policy.decision(input, surface: .automaticDownload, budget: &budget)
            if let key { decisions[key] = decision }
        }
        guard !decision.isHidden else { return nil }
        // Only retained reactions are projected here. Native base entries/counts are not inputs
        // to this projection a second time; live messages above supply album text context only.
        let attributes: [MessageAttribute] = entry.message.attributes.map { value in
            guard value is ReactionsMessageAttribute,
                  let reactions = message.attributes.first(where: { $0 is ReactionsMessageAttribute }) as? ReactionsMessageAttribute else { return value }
            return exteralessFilterReactions(reactions, policy: policy, isMegagroup: input.isMegagroup)
        }
        let projected = entry.message._asMessage().withUpdatedAttributes(attributes).withUpdatedStableVersion(stableVersion: entry.message.stableVersion &+ generation)
        return entry.withDisplayMessage(EngineMessage(projected))
    }
}

public extension TelegramEngine.Messages {
    func filterRetainedHistoryEntries(_ entries: [ExteralessRetentionEntry], liveMessages: [EngineMessage], translated: Bool = false) -> [ExteralessRetentionEntry] {
        let identity = exteralessPrivacyExtrasIdentity(self.account)
        let snapshot = ExteralessFilteringRuntime.shared.snapshot(identity)
        return retentionFilterDisplayEntries(entries, liveMessages: liveMessages.map { $0._asMessage() }, policy: snapshot.policy, generation: snapshot.generation, translated: translated)
    }
}
