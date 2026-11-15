import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public enum ExteralessRetentionScope {
    case account
    case peer(EnginePeer.Id, threadId: Int64?)
    case message(EngineMessage.Id)
    case version(EngineMessage.Id, sequence: UInt64)
}

public struct ExteralessRetentionAttachment {
    public enum Availability { case retained, awaitingLocalData, failed, notRetained }
    public let resourceId: String
    public let title: String
    public let availability: Availability
    public let byteCount: Int64?
    public let fileExtension: String?
}

public struct ExteralessRetentionEntry {
    public let message: EngineMessage
    public let displayText: String
    public let sequence: UInt64
    public let capturedAt: Int64
    public let versionDate: Int32
    public let reason: RetentionVersion.Reason
    public let attachments: [ExteralessRetentionAttachment]
    public let mediaOmitted: Bool
    let sourceForFiltering: Message
    let accountPeerId: PeerId
    let testingEnvironment: Bool

    func withDisplayMessage(_ message: EngineMessage) -> Self {
        Self(message: message, displayText: self.displayText, sequence: self.sequence, capturedAt: self.capturedAt, versionDate: self.versionDate, reason: self.reason, attachments: self.attachments, mediaOmitted: self.mediaOmitted, sourceForFiltering: self.sourceForFiltering, accountPeerId: self.accountPeerId, testingEnvironment: self.testingEnvironment)
    }
}

public struct ExteralessRetentionPage {
    public let entries: [ExteralessRetentionEntry]
    public let next: EngineMessage.Index?
    public let hasMore: Bool

    public init(entries: [ExteralessRetentionEntry], next: EngineMessage.Index?, hasMore: Bool) {
        self.entries = entries
        self.next = next
        self.hasMore = hasMore
    }
}

public struct ExteralessRetentionSummary {
    public let messageCount: Int
    public let deletedCount: Int
    public let versionCount: Int
    public let retainedMediaBytes: Int64
    public let pendingMediaCount: Int
}

func exteralessRetentionEntry(version: RetentionVersion, key: RetentionMessageKey, index: ExteralessRetentionIndex, transaction: Transaction) throws -> ExteralessRetentionEntry {
    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId.toInt64() == index.accountPeerId else { throw ExteralessRetentionError.unavailable }
    let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
    guard snapshot.key == key else { throw ExteralessRetentionError.invalidArchive }
    let message = try snapshot.render(version: version)
    var attachments: [ExteralessRetentionAttachment] = []
    var seen = Set<String>()
    func append(_ resource: MediaResource, title: String, image: Bool = false) {
        let id = resource.id.stringRepresentation
        guard seen.insert(id).inserted else { return }
        let retained = version.resourceIds.contains(id) ? index.media[id] : nil
        let availability: ExteralessRetentionAttachment.Availability
        if let retained { availability = retained.state == .stored ? .retained : (retained.state == .failed ? .failed : .awaitingLocalData) }
        else { availability = .notRetained }
        let ext = image ? "jpg" : (title as NSString).pathExtension.lowercased()
        let safeExtension = !ext.isEmpty && ext.utf8.count <= 12 && ext.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 122).contains($0) } ? ext : nil
        attachments.append(ExteralessRetentionAttachment(resourceId: id, title: title, availability: availability, byteCount: retained?.storedBytes, fileExtension: safeExtension))
    }
    func visit(_ media: Media, depth: Int) {
        guard depth < 4 else { return }
        if let file = media as? TelegramMediaFile {
            append(file.resource, title: file.fileName ?? (file.isVoice ? "Voice message" : file.isInstantVideo ? "Video message" : "File"))
        } else if let image = media as? TelegramMediaImage {
            if let representation = image.representations.max(by: { Int64($0.dimensions.width) * Int64($0.dimensions.height) < Int64($1.dimensions.width) * Int64($1.dimensions.height) }) {
                append(representation.resource, title: "Photo", image: true)
            }
        } else if let paid = media as? TelegramMediaPaidContent {
            for item in paid.extendedMedia { if case let .full(media) = item { visit(media, depth: depth + 1) } }
        } else if let poll = media as? TelegramMediaPoll {
            if let media = poll.attachedMedia { visit(media, depth: depth + 1) }
            for option in poll.options { if let media = option.media { visit(media, depth: depth + 1) } }
            if let media = poll.results.solution?.media { visit(media, depth: depth + 1) }
        } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
            if let image = content.image { visit(image, depth: depth + 1) }
            if let file = content.file { visit(file, depth: depth + 1) }
        } else if let story = media as? TelegramMediaStory, let stored = message.associatedStories[story.storyId]?.get(Stories.StoredItem.self), case let .item(item) = stored, let media = item.media {
            visit(media, depth: depth + 1)
        }
    }
    for media in message.effectiveMedia { visit(media, depth: 0) }
    for attribute in message.attributes {
        if let page = (attribute as? TranslationMessageAttribute)?.instantPage {
            for media in page.rawMedia.values { visit(media, depth: 0) }
        }
    }
    var displayText = message.text.isEmpty ? message.richText.map { exteralessRetentionRichText($0.fullInstantPage ?? $0.instantPage) } ?? "" : message.text
    if displayText.isEmpty, message.media.isEmpty, let source = snapshot.ayuSource,
       let row = try? JSONDecoder().decode(ExteralessAyuRow.self, from: source), let kind = try? row.integer("documentType"), kind != 0 {
        displayText = "Imported media metadata; the file was not included in the database export."
    }
    let albumStableId = try RetentionAlbumIdentities.resolve(transaction: transaction, index: index, message: message)
    return ExteralessRetentionEntry(message: EngineMessage(try snapshot.render(version: version, localMediaIndex: index, albumStableId: albumStableId)), displayText: displayText, sequence: version.sequence, capturedAt: version.capturedAt, versionDate: version.messageVersionDate, reason: version.reason, attachments: attachments, mediaOmitted: snapshot.mediaOmitted, sourceForFiltering: message, accountPeerId: state.peerId, testingEnvironment: state.isTestingEnvironment)
}

private func exteralessRetentionRows(index: ExteralessRetentionIndex, scope: ExteralessRetentionScope, cutoff: Int64) throws -> [ExteralessRetentionIndexRow] {
    if case let .version(_, sequence) = scope, sequence == 0 { throw ExteralessRetentionError.invalidArchive }
    return index.rows.values.filter { row in
        guard row.lastCapture > cutoff else { return false }
        switch scope {
        case .account: return true
        case let .peer(id, threadId): return row.key.peerId == id.toInt64() && (threadId == nil || row.threadId == threadId)
        case let .message(id), let .version(id, _): return row.key.messageId == id
        }
    }.sorted { lhs, rhs in
        MessageIndex(id: lhs.key.messageId, timestamp: lhs.timestamp) > MessageIndex(id: rhs.key.messageId, timestamp: rhs.timestamp)
    }
}

public extension TelegramEngine.Messages {
    /// Observes only the current account. All Postbox reads/decoding stay on TelegramCore's side.
    func retentionChanges() -> Signal<Void, NoError> {
        let key = PostboxViewKey.cachedItem(exteralessRetentionIndexId)
        return self.account.postbox.combinedView(keys: [key]) |> map { _ in () }
    }

    func refreshRetention() {
        ExteralessRetentionAccount.get(mediaBox: self.account.postbox.mediaBox)?.refresh(prune: true, retryFailedMedia: true)
    }

    func retentionErrors() -> Signal<ExteralessRetentionError?, NoError> {
        ExteralessRetentionAccount.get(mediaBox: self.account.postbox.mediaBox)?.errors ?? .single(.unavailable)
    }

    func retentionSummary() -> Signal<Result<ExteralessRetentionSummary, ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do {
                let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                let index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: account.peerId)
                let rows = index?.rows.values.filter { $0.lastCapture > current.policy.cutoff(now: current.now) } ?? []
                return .success(ExteralessRetentionSummary(messageCount: rows.count, deletedCount: rows.filter { $0.deletedAt != nil }.count, versionCount: rows.reduce(0) { $0 + $1.versionCount }, retainedMediaBytes: index?.media.values.reduce(Int64(0), { $0 + ($1.storedBytes ?? 0) }) ?? 0, pendingMediaCount: index?.media.values.filter { $0.state != .stored }.count ?? 0))
            } catch { return .failure(exteralessRetentionError(error)) }
        }
    }

    func retainedMessages(peerId: EnginePeer.Id? = nil, threadId: Int64? = nil, before: EngineMessage.Index? = nil, lowerBound: EngineMessage.Index? = nil, upperBound: EngineMessage.Index? = nil, deletedOnly: Bool = true, limit: Int = 100) -> Signal<Result<ExteralessRetentionPage, ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do {
                let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                let policy = current.policy
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: account.peerId, policy: policy, now: current.now)
                let scope: ExteralessRetentionScope = peerId.map { .peer($0, threadId: threadId) } ?? .account
                let rows = try exteralessRetentionRows(index: store.index, scope: scope, cutoff: policy.cutoff(now: current.now)).filter { row in
                    let index = MessageIndex(id: row.key.messageId, timestamp: row.timestamp)
                    return (!deletedOnly || row.deletedAt != nil) && (before == nil || index < before!) && (lowerBound == nil || index >= lowerBound!) && (upperBound == nil || index <= upperBound!)
                }
                let count = max(1, min(RetentionPolicy.pageSize, limit))
                var result: [ExteralessRetentionEntry] = []
                var cursor: EngineMessage.Index?
                for row in rows.prefix(count) {
                    cursor = MessageIndex(id: row.key.messageId, timestamp: row.timestamp)
                    guard let record = try store.record(row.key), let version = record.versions.last(where: { !deletedOnly || $0.reason == .deleted }) else { continue }
                    result.append(try exteralessRetentionEntry(version: version, key: row.key, index: store.index, transaction: transaction))
                }
                return .success(ExteralessRetentionPage(entries: result, next: cursor, hasMore: rows.count > count))
            } catch { return .failure(exteralessRetentionError(error)) }
        }
    }

    func retainedVersions(messageId: EngineMessage.Id) -> Signal<Result<[ExteralessRetentionEntry], ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do {
                let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: account.peerId, policy: current.policy, now: current.now)
                let key = RetentionMessageKey(peerId: messageId.peerId.toInt64(), namespace: messageId.namespace, id: messageId.id)
                guard let record = try store.record(key) else { return .success([]) }
                return .success(try record.chronologicalVersions.map { try exteralessRetentionEntry(version: $0, key: key, index: store.index, transaction: transaction) })
            } catch { return .failure(exteralessRetentionError(error)) }
        }
    }

    func retentionPeerExceptions(peerId: EnginePeer.Id) -> Signal<Result<RetentionPeerExceptions, ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do { return .success(try ExteralessRetentionStore.peerExceptions(transaction: transaction, accountPeerId: account.peerId, peerId: peerId)) }
            catch { return .failure(exteralessRetentionError(error)) }
        }
    }

    func setRetentionPeerExceptions(peerId: EnginePeer.Id, value: RetentionPeerExceptions) -> Signal<Result<Void, ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do {
                try ExteralessRetentionStore.setPeerExceptions(transaction: transaction, accountPeerId: account.peerId, peerId: peerId, value: value)
                return .success(())
            } catch { return .failure(exteralessRetentionError(error)) }
        }
    }

    func clearRetention(_ scope: ExteralessRetentionScope) -> Signal<Result<Void, ExteralessRetentionError>, NoError> {
        let account = self.account
        return Signal { subscriber in
            guard let owner = ExteralessRetentionAccount.get(mediaBox: account.postbox.mediaBox), owner.performsMaintenance else {
                subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable
            }
            owner.operationScope.invalidate()
            let work = owner.operationScope.makeWork()
            return (exteralessRetentionScopedTransaction(postbox: account.postbox, accountPeerId: account.peerId, testingEnvironment: account.testingEnvironment, work: work) { transaction -> Result<Void, ExteralessRetentionError> in
                if case .account = scope { return .success(()) }
                do {
                    let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                    let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: account.peerId, policy: current.policy, now: current.now)
                    let clearDescriptors = try retentionPreparePeerDescriptorClear(transaction: transaction, accountPeerId: account.peerId, scope: scope, policy: current.policy, now: current.now)
                    let rows = try exteralessRetentionRows(index: store.index, scope: scope, cutoff: 0)
                    for row in rows {
                        guard work.isCurrent else { return .failure(.cancelled) }
                        if case let .version(_, sequence) = scope, var record = try store.record(row.key) {
                            record.removeVersion(sequence: sequence)
                            try store.save(record, timestamp: row.timestamp, threadId: row.threadId)
                        } else { store.remove(row.key) }
                    }
                    guard work.isCurrent else { return .failure(.cancelled) }
                    let index = try store.finish()
                    clearDescriptors(transaction)
                    owner.didMutate(index)
                    return .success(())
                } catch { return .failure(exteralessRetentionError(error)) }
            } |> mapToSignal { result -> Signal<Result<Void, ExteralessRetentionError>, NoError> in
                guard case .success = result else { return .single(result) }
                if case .account = scope { return owner.clearAll() }
                return owner.cleanupUnownedMedia()
            }).start(next: subscriber.putNext, completed: subscriber.putCompletion)
        }
    }

    /// Never fetches a missing file. The selected version must own this real MediaBox id.
    func retainedMedia(messageId: EngineMessage.Id, sequence: UInt64, resourceId: String) -> Signal<Result<ExteralessRetainedResourceFile, ExteralessRetentionError>, NoError> {
        let account = self.account
        guard let owner = ExteralessRetentionAccount.get(mediaBox: account.postbox.mediaBox) else { return .single(.failure(.unavailable)) }
        return exteralessRetentionScopedTransaction(account: account) { transaction -> Result<String?, ExteralessRetentionError> in
            do {
                let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                _ = try retentionAdmitMedia(transaction: transaction, accountPeerId: account.peerId, policy: current.policy, now: current.now, resourceId: resourceId, versionOwner: RetentionMediaVersionOwner(messageId: messageId, sequence: sequence))
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: account.peerId, policy: current.policy, now: current.now)
                let key = RetentionMessageKey(peerId: messageId.peerId.toInt64(), namespace: messageId.namespace, id: messageId.id)
                guard let version = try store.record(key)?.versions.first(where: { $0.sequence == sequence && $0.resourceIds.contains(resourceId) }) else { return .failure(.mediaUnavailable) }
                let entry = try exteralessRetentionEntry(version: version, key: key, index: store.index, transaction: transaction)
                return .success(entry.attachments.first(where: { $0.resourceId == resourceId })?.fileExtension)
            } catch { owner.report(error); return .failure(exteralessRetentionError(error)) }
        } |> mapToSignal { authorization -> Signal<Result<ExteralessRetainedResourceFile, ExteralessRetentionError>, NoError> in
            switch authorization {
            case let .success(pathExtension): return owner.materialize(resourceId: resourceId, pathExtension: pathExtension, versionOwner: RetentionMediaVersionOwner(messageId: messageId, sequence: sequence))
            case let .failure(error): return .single(.failure(error))
            }
        }
    }

    /// Explicit, bounded text/entity JSON export. It contains neither account/media encryption
    /// keys nor cache paths, access hashes, peer phone numbers or native executable encodings.
    func exportRetention(_ scope: ExteralessRetentionScope) -> Signal<Result<Data, ExteralessRetentionError>, NoError> {
        let account = self.account
        return exteralessRetentionScopedTransaction(account: account) { transaction in
            do {
                let current = try ExteralessRetentionAccount.readState(mediaBox: account.postbox.mediaBox)
                let now = current.now
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: account.peerId, policy: current.policy, now: now)
                let rows = try exteralessRetentionRows(index: store.index, scope: scope, cutoff: current.policy.cutoff(now: now))
                guard rows.reduce(Int64(0), { $0 + Int64($1.bytes) }) <= 16 * 1024 * 1024 else { throw ExteralessRetentionError.limitExceeded }
                var exported: [ExteralessRetentionExport.Version] = []
                for row in rows {
                    guard let record = try store.record(row.key) else { continue }
                    for version in record.chronologicalVersions {
                        if case let .version(_, sequence) = scope, sequence != version.sequence { continue }
                        let entry = try exteralessRetentionEntry(version: version, key: row.key, index: store.index, transaction: transaction)
                        let entities = (entry.message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
                        let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
                        exported.append(ExteralessRetentionExport.Version(message: row.key, sequence: version.sequence, reason: version.reason, capturedAt: version.capturedAt, versionDate: version.messageVersionDate, postedAt: entry.message.timestamp, authorId: entry.message.author?.id.toInt64(), text: snapshot.text, entities: entities, richTextPlain: entry.message.richText == nil ? nil : entry.displayText, attachments: entry.attachments.map { $0.title }))
                    }
                }
                let data = try exteralessRetentionEncode(ExteralessRetentionExport(format: "exteraless-retained-messages", version: 1, accountPeerId: account.peerId.toInt64(), exportedAt: now, versions: exported))
                guard data.count <= 16 * 1024 * 1024 else { throw ExteralessRetentionError.limitExceeded }
                return .success(data)
            } catch { return .failure(exteralessRetentionError(error)) }
        }
    }
}

private struct ExteralessRetentionExport: Encodable {
    struct Version: Encodable {
        let message: RetentionMessageKey
        let sequence: UInt64
        let reason: RetentionVersion.Reason
        let capturedAt: Int64
        let versionDate: Int32
        let postedAt: Int32
        let authorId: Int64?
        let text: String
        let entities: [MessageTextEntity]
        let richTextPlain: String?
        let attachments: [String]
    }
    let format: String
    let version: Int
    let accountPeerId: Int64
    let exportedAt: Int64
    let versions: [Version]
}
