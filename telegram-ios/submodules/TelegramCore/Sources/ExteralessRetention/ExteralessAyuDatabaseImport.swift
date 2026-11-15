import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

public struct ExteralessAyuImportReceipt {
    public var importedVersions = 0
    public var duplicates = 0
    public var expired = 0
    public var otherAccounts = 0
    public var unresolvedPeers: Set<Int64> = []
    public var mediaWithoutFiles = 0
    public var importedReadDates = 0
    public var importedContentReadDates = 0
    public var importedActivities = 0
    public var importedChatDescriptors = 0
    public var auxiliaryDuplicates = 0
    public var auxiliaryExpired = 0
    public var auxiliaryUnsetDates = 0
    public var auxiliaryQuotaSkipped = 0
    public var auxiliarySelfActivities = 0
}

public extension TelegramEngine.Messages {
    /// AyuDatabaseImport.merge boundary. Reads the original source tables and merges only this
    /// native account's versions. The SQLite file never replaces Postbox or its server state.
    func importAyuDatabase(url: URL, peerMappings: [Int64: EnginePeer.Id] = [:]) -> Signal<Result<ExteralessAyuImportReceipt, ExteralessRetentionError>, NoError> {
        let account = self.account
        return Signal { subscriber in
            guard let owner = ExteralessRetentionAccount.get(mediaBox: account.postbox.mediaBox) else {
                subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable
            }
            let cancelled = Atomic<Bool>(value: false)
            let work = owner.operationScope.makeWork()
            let privacyWork = exteralessPrivacyImportWork(postbox: account.postbox)
            let reader = ExteralessAyuDatabaseReader()
            let transactionDisposable = MetaDisposable()
            DispatchQueue.global(qos: .utility).async {
                do {
                    let source = try reader.read(url: url)
                    guard !cancelled.with({ $0 }) else { return }
                    transactionDisposable.set(account.postbox.transaction { transaction -> Result<ExteralessAyuImportReceipt, ExteralessRetentionError> in
                        do {
                            guard !cancelled.with({ $0 }), work.isCurrent, privacyWork.isCurrent else { return .failure(.cancelled) }
                            guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == account.peerId, state.isTestingEnvironment == account.testingEnvironment else { return .failure(.unavailable) }
                            guard let policy = owner.loadedPolicy else { return .failure(.unavailable) }
                            let receipt = try exteralessImportAyuDatabase(source, transaction: transaction, accountPeerId: account.peerId, mediaBox: account.postbox.mediaBox, peerMappings: peerMappings, policy: policy, now: owner.clock(), cancelled: { cancelled.with { $0 } || !work.isCurrent || !privacyWork.isCurrent }, didMutate: owner.didMutate)
                            return .success(receipt)
                        } catch { return .failure(exteralessRetentionError(error)) }
                    }.start(next: { result in subscriber.putNext(work.isCurrent && privacyWork.isCurrent ? result : .failure(.cancelled)) }, completed: { subscriber.putCompletion() }))
                } catch {
                    if !cancelled.with({ $0 }) { subscriber.putNext(.failure(exteralessRetentionError(error))); subscriber.putCompletion() }
                }
            }
            return ActionDisposable { _ = cancelled.swap(true); work.cancel(); privacyWork.cancel(); reader.cancel(); transactionDisposable.dispose() }
        }
        |> timeout(25.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(.failure(.cancelled)))
    }
}

func exteralessImportAyuDatabase(_ source: ExteralessAyuDatabase, transaction: Transaction, accountPeerId: PeerId, mediaBox: MediaBox, peerMappings: [Int64: PeerId], policy: RetentionPolicy, now: Int64, cancelled: () -> Bool = { false }, didMutate: (ExteralessRetentionIndex) -> Void) throws -> ExteralessAyuImportReceipt {
    let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: now)
    let sourceUserId = accountPeerId.id._internalGetInt64Value()
    var receipt = ExteralessAyuImportReceipt()
    let privacyInput = try retentionNormalizeAyuPrivacy(source, transaction: transaction, accountPeerId: accountPeerId, mappings: peerMappings, now: now)
    receipt.otherAccounts += privacyInput.otherAccounts
    receipt.unresolvedPeers.formUnion(privacyInput.unresolvedPeers)
    receipt.auxiliaryUnsetDates = privacyInput.unsetDates
    receipt.auxiliaryExpired = privacyInput.expiredActivities
    receipt.auxiliarySelfActivities = privacyInput.selfActivities
    var privacyCommit: ((Transaction) -> Void)?
    if !privacyInput.reads.isEmpty || !privacyInput.activities.isEmpty {
        let prepared = try retentionPreparePrivacyImport(transaction: transaction, accountPeerId: accountPeerId, input: privacyInput, now: Int32(clamping: now))
        privacyCommit = prepared.commit
        receipt.importedReadDates = prepared.merge.importedReads
        receipt.importedContentReadDates = prepared.merge.importedPlayed
        receipt.importedActivities = prepared.merge.importedActivities
        receipt.auxiliaryDuplicates += prepared.merge.duplicates
        receipt.auxiliaryQuotaSkipped += prepared.merge.quotaSkipped
    }
    var dialogPlan: RetentionArchivePeerImport?
    if let rows = source.auxiliaryRows["DeletedDialog"] {
        let plan = try retentionPrepareAyuDialogs(rows, transaction: transaction, accountPeerId: accountPeerId, mappings: peerMappings, policy: policy, now: now)
        dialogPlan = plan
        receipt.importedChatDescriptors = plan.imported
        receipt.auxiliaryDuplicates += plan.duplicates
        receipt.auxiliaryExpired += plan.expired
        receipt.auxiliaryQuotaSkipped += plan.quotaSkipped
        receipt.otherAccounts += plan.otherAccounts
        receipt.unresolvedPeers.formUnion(plan.unresolved)
    }
    for row in source.rows {
        if cancelled() { throw ExteralessRetentionError.cancelled }
        guard try row.integer("userId") == sourceUserId else { receipt.otherAccounts += 1; continue }
        let capturedAt = try row.integer("entityCreateDate")
        guard capturedAt > 0, capturedAt <= now + 300 else { throw ExteralessRetentionError.invalidArchive }
        if capturedAt <= policy.cutoff(now: now) { receipt.expired += 1; continue }
        let dialog = try row.integer("dialogId")
        guard let peerId = try exteralessAyuPeer(dialog, transaction: transaction, mappings: peerMappings) else {
            receipt.unresolvedPeers.insert(dialog)
            continue
        }
        let messageId = try row.int32("messageId")
        let key = RetentionMessageKey(peerId: peerId.toInt64(), namespace: Namespaces.Message.Cloud, id: messageId)
        let versionDate = max(try row.int32("date"), try row.int32("editDate"))
        if let existing = try store.record(key) {
            let reason: RetentionVersion.Reason = row.table == "DeletedMessage" ? .deleted : .edit
            if (reason == .deleted && existing.deletedAt != nil) || existing.versions.contains(where: { $0.reason == reason && $0.capturedAt == capturedAt && $0.messageVersionDate == versionDate }) {
                receipt.duplicates += 1
                continue
            }
        }
        // Reserve from Postbox's actual display-id counter, never Android fakeId/messageId.
        // This reserves only a local display identity; it inserts no server/history row.
        guard let stableId = transaction.reserveMessageStableId() else { throw ExteralessRetentionError.unavailable }
        let reactions = source.reactions[try row.integer("fakeId")] ?? []
        let message = try exteralessAyuMessage(row, reactions: row.table == "DeletedMessage" ? reactions : [], peerId: peerId, stableId: stableId, transaction: transaction, mappings: peerMappings)
        if try row.integer("documentType") != 0, message.media.isEmpty { receipt.mediaWithoutFiles += 1 }
        let changed = try store.importAyu(message: message, source: exteralessRetentionEncode(row), capturedAt: capturedAt, deleted: row.table == "DeletedMessage", mediaBox: mediaBox)
        if changed { receipt.importedVersions += 1 } else { receipt.duplicates += 1 }
    }
    if cancelled() { throw ExteralessRetentionError.cancelled }
    if receipt.importedVersions > 0 || privacyCommit != nil || dialogPlan != nil {
        let index = try store.finish()
        if let dialogPlan { transaction.putItemCacheEntry(id: retentionArchivePeersId, entry: dialogPlan.entry) }
        privacyCommit?(transaction)
        didMutate(index)
    }
    return receipt
}

func exteralessAyuPeer(_ id: Int64, transaction: Transaction, mappings: [Int64: PeerId]) throws -> PeerId? {
    guard id != 0, id != Int64.min else { return nil }
    // DialogObject's actual encrypted-dialog bit. Android secret-chat ids cannot be mapped
    // to a different iOS secret-chat session; a numeric slot conversion would be false identity.
    if id > 0 && (id & 0x4000000000000000) != 0 { return nil }
    let bareId = id < 0 ? -id : id
    guard bareId <= 0x00ff_ffff_ffff_ffff else { throw ExteralessRetentionError.invalidArchive }
    if id > 0 { return PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)) }
    if let mapped = mappings[id] {
        guard mapped.id._internalGetInt64Value() == bareId, [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(mapped.namespace), transaction.getPeer(mapped) != nil else { throw ExteralessRetentionError.invalidArchive }
        return mapped
    }
    let candidates = [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].map { PeerId(namespace: $0, id: ._internalFromInt64Value(bareId)) }.filter { transaction.getPeer($0) != nil }
    return candidates.count == 1 ? candidates[0] : nil
}

private func exteralessAyuEntities(_ data: Data?, text: String) throws -> [MessageTextEntity] {
    guard let data else { return [] }
    let reader = BufferReader(Buffer(data: data))
    var values: [Api.MessageEntity] = []
    while reader.offset < UInt(data.count) {
        guard values.count < 256, let signature = reader.readInt32(), let entity = Api.parse(reader, signature: signature) as? Api.MessageEntity else { throw ExteralessRetentionError.unsupportedFormat }
        let description = entity.descriptionFields()
        let fields = Dictionary(uniqueKeysWithValues: description.1)
        guard let offset = fields["offset"]?.value as? Int32, let length = fields["length"]?.value as? Int32,
              offset >= 0, length > 0, Int64(offset) + Int64(length) <= Int64(text.utf16.count) else { throw ExteralessRetentionError.invalidArchive }
        if description.0 == "messageEntityMentionName" {
            guard let id = fields["user_id"]?.value as? Int64, id > 0, id <= 0x00ff_ffff_ffff_ffff else { throw ExteralessRetentionError.invalidArchive }
        }
        for position in [Int(offset), Int(offset) + Int(length)] {
            let boundary = text.utf16.index(text.utf16.startIndex, offsetBy: position)
            guard String.Index(boundary, within: text) != nil else { throw ExteralessRetentionError.invalidArchive }
        }
        values.append(entity)
    }
    guard reader.offset == UInt(data.count) else { throw ExteralessRetentionError.invalidArchive }
    let result = messageTextEntitiesFromApiEntities(values)
    guard result.count == values.count else { throw ExteralessRetentionError.unsupportedFormat }
    return result
}

private func exteralessAyuMessage(_ row: ExteralessAyuRow, reactions: [ExteralessAyuRow], peerId: PeerId, stableId: UInt32, transaction: Transaction, mappings: [Int64: PeerId]) throws -> Message {
    let id = try row.int32("messageId")
    let date = try row.int32("date")
    let editDate = try row.int32("editDate")
    guard id > 0, date > 0, editDate >= 0 else { throw ExteralessRetentionError.invalidArchive }
    let text = try row.text("text")
    let entities = try exteralessAyuEntities(row.data("textEntities"), text: text)
    var attributes: [MessageAttribute] = entities.isEmpty ? [] : [TextEntitiesMessageAttribute(entities: entities)]
    if editDate > 0 { attributes.append(EditedMessageAttribute(date: editDate, isHidden: false)) }
    let viewCount = try row.int32("views")
    guard viewCount >= 0 else { throw ExteralessRetentionError.invalidArchive }
    if viewCount > 0 { attributes.append(ViewCountMessageAttribute(count: Int(viewCount))) }
    let authorId = try exteralessAyuPeer(row.integer("fromId"), transaction: transaction, mappings: mappings)
    let author = authorId.flatMap { transaction.getPeer($0) }
    var peers = SimpleDictionary<PeerId, Peer>()
    if let peer = transaction.getPeer(peerId) { peers[peer.id] = peer }
    if let author { peers[author.id] = author }
    let replyId = try row.int32("replyMessageId")
    let topId = try row.int32("replyTopId")
    let topicId = try row.integer("topicId")
    if replyId > 0 {
        let replyPeerValue = try row.integer("replyPeerId")
        let replyPeer: PeerId?
        if replyPeerValue == 0 { replyPeer = peerId }
        else { replyPeer = try exteralessAyuPeer(replyPeerValue, transaction: transaction, mappings: mappings) }
        guard let replyPeer else { throw ExteralessRetentionError.invalidArchive }
        let quoteText = try row.text("replyQuoteText")
        let quoteEntities = try exteralessAyuEntities(row.data("replyQuoteEntities"), text: quoteText)
        let quote = quoteText.isEmpty ? nil : EngineMessageReplyQuote(text: quoteText, offset: nil, entities: quoteEntities, media: nil)
        attributes.append(ReplyMessageAttribute(messageId: MessageId(peerId: replyPeer, namespace: Namespaces.Message.Cloud, id: replyId), threadMessageId: topId > 0 ? MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: topId) : nil, quote: quote, isQuote: try row.integer("replyQuote") != 0, innerSubject: nil))
    }
    if !reactions.isEmpty {
        let values = try reactions.map { reaction -> MessageReaction in
            let count = try reaction.int32("count")
            let documentId = try reaction.integer("documentId")
            let emoji = try reaction.text("emoticon")
            let custom = try reaction.integer("isCustom") != 0
            guard count >= 0, custom ? documentId != 0 : !emoji.isEmpty else { throw ExteralessRetentionError.invalidArchive }
            return MessageReaction(value: custom ? .custom(documentId) : .builtin(emoji), count: count, chosenOrder: try reaction.integer("selfSelected") != 0 ? 0 : nil)
        }
        attributes.append(ReactionsMessageAttribute(canViewList: false, isTags: false, reactions: values, recentPeers: [], topPeers: []))
    }
    var forward: MessageForwardInfo?
    let forwardDate = try row.int32("fwdDate")
    if forwardDate > 0 {
        let forwardPeer = try exteralessAyuPeer(row.integer("fwdFromId"), transaction: transaction, mappings: mappings).flatMap { transaction.getPeer($0) }
        if let forwardPeer { peers[forwardPeer.id] = forwardPeer }
        let name = try row.text("fwdName")
        let signature = try row.text("fwdPostAuthor")
        forward = MessageForwardInfo(author: forwardPeer, source: nil, sourceMessageId: nil, date: forwardDate, authorSignature: !signature.isEmpty ? signature : (name.isEmpty ? nil : name), psaType: nil, flags: [])
    }
    var media: [Media] = []
    if let data = try row.data("documentSerialized") {
        let reader = BufferReader(Buffer(data: data))
        guard let signature = reader.readInt32(), let parsed = Api.parse(reader, signature: signature) as? Api.MessageMedia, reader.offset == UInt(data.count) else { throw ExteralessRetentionError.unsupportedFormat }
        // These native converters don't create peers from untrusted nested peer identifiers.
        // Other TL media constructors remain in the encrypted source receipt, and fail visibly
        // rather than being silently treated as a converted native message.
        switch parsed {
        case .messageMediaPhoto, .messageMediaDocument:
            guard let converted = textMediaAndExpirationTimerFromApiMedia(parsed, peerId).media else { throw ExteralessRetentionError.unsupportedFormat }
            try exteralessValidateAyuMedia(converted)
            media = [converted]
        default: throw ExteralessRetentionError.unsupportedFormat
        }
    }
    // Absolute Android mediaPath/hqThumbPath are source metadata, never file capabilities.
    let flags = try row.int32("flags")
    let grouping = try row.integer("groupedId")
    return Message(stableId: stableId, stableVersion: 0, id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id), globallyUniqueId: nil, groupingKey: grouping == 0 ? nil : grouping, groupInfo: nil, threadId: topicId > 0 ? topicId : (topId > 0 ? Int64(topId) : nil), timestamp: date, flags: flags & 2 == 0 ? [.Incoming] : [], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: forward, author: author, text: text, attributes: attributes, media: media, peers: peers, associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
}

private func exteralessValidateAyuMedia(_ media: Media, depth: Int = 0) throws {
    guard depth < 8 else { throw ExteralessRetentionError.limitExceeded }
    func dimensions(_ value: PixelDimensions) throws {
        guard value.width > 0, value.height > 0, value.width <= 100000, value.height <= 100000 else { throw ExteralessRetentionError.invalidArchive }
    }
    func resource(_ value: MediaResource) throws {
        guard ExteralessRetentionMediaEntry.validResourceId(value.id.stringRepresentation), value.size == nil || value.size! >= 0 else { throw ExteralessRetentionError.invalidArchive }
    }
    if let image = media as? TelegramMediaImage {
        guard image.representations.count <= 64, image.videoRepresentations.count <= 64 else { throw ExteralessRetentionError.limitExceeded }
        for representation in image.representations { try dimensions(representation.dimensions); try resource(representation.resource) }
        for representation in image.videoRepresentations {
            try dimensions(representation.dimensions); try resource(representation.resource)
            guard representation.startTimestamp == nil || (representation.startTimestamp!.isFinite && representation.startTimestamp! >= 0) else { throw ExteralessRetentionError.invalidArchive }
        }
        if let video = image.video { try exteralessValidateAyuMedia(video, depth: depth + 1) }
    } else if let file = media as? TelegramMediaFile {
        guard file.attributes.count <= 128, file.previewRepresentations.count <= 64, file.alternativeRepresentations.count <= 16,
              file.mimeType.utf8.count <= 256, file.size == nil || file.size! >= 0 else { throw ExteralessRetentionError.invalidArchive }
        try resource(file.resource)
        for representation in file.previewRepresentations { try dimensions(representation.dimensions); try resource(representation.resource) }
        for attribute in file.attributes {
            if case let .Video(duration, size, _, _, timestamp, _) = attribute {
                try dimensions(size)
                guard duration.isFinite && duration >= 0, timestamp == nil || (timestamp!.isFinite && timestamp! >= 0) else { throw ExteralessRetentionError.invalidArchive }
            }
        }
        for alternative in file.alternativeRepresentations { try exteralessValidateAyuMedia(alternative, depth: depth + 1) }
    }
}
