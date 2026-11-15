import Foundation
import PluginHooks
import SwiftSignalKit
import TelegramApi
import XCTest
@testable import Postbox
@testable import TelegramCore

private final class TLReviewBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { self.stored = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        self.lock.lock(); defer { self.lock.unlock() }; return body(&self.stored)
    }
}

/// Canned native objects and a temporary in-memory Postbox. No Account/Network is
/// created and the test host never sends, decrypts ciphertext or invokes plugins.
final class ExteralessTLReviewTests: XCTestCase {
    private func object(_ name: String, _ values: [String: ExteralessTLValue] = [:]) -> ExteralessTLValue {
        var fields = values; fields["_"] = .string(name); return .object(fields)
    }
    private func parse<T>(_ data: Data, as type: T.Type) throws -> T {
        let reader = BufferReader(Buffer(data: data))
        let signature = try XCTUnwrap(reader.readInt32())
        return try XCTUnwrap(Api.parse(reader, signature: signature) as? T)
    }

    func testRejectedPostKeepsNativeSecretMutationAndOriginalCounters() throws {
        let codec = ExteralessTLCodec.shared
        let secret = object("encryptedMessageService", ["random_id": .integer(7), "chat_id": .integer(9), "date": .integer(100), "bytes": .bytes(Data([0]))])
        let counters = object("updates.state", ["pts": .integer(10), "qts": .integer(11), "date": .integer(100), "seq": .integer(1), "unread_count": .integer(0)])
        let original = try codec.normalize(object("updates.difference", ["new_messages": .array([]), "new_encrypted_messages": .array([secret]), "other_updates": .array([]), "chats": .array([]), "users": .array([]), "state": counters]), as: "updates.Difference")
        let originalBytes = try codec.encode(original, as: "updates.Difference")
        guard case var .object(fields) = original else { return XCTFail() }
        fields["new_encrypted_messages"] = .array([])
        var replacementParserEntries = 0
        let delivered: Api.updates.Difference
        do {
            let bytes = try ExteralessTLTransformCodec.response(ExteralessTLValue.object(fields).jsonString(), original: original, type: "updates.Difference", metadata: .object([:]))
            replacementParserEntries += 1
            delivered = try parse(bytes, as: Api.updates.Difference.self)
            XCTFail("encrypted mutation accepted")
        } catch is ExteralessTLError {
            delivered = try parse(originalBytes, as: Api.updates.Difference.self)
        }
        XCTAssertEqual(replacementParserEntries, 0)
        let initial = AccountInitialState(state: .init(pts: 9, qts: 10, date: 99, seq: 0), peerIds: [], peerIdsRequiringLocalChatState: [], channelStates: [:], peerChatInfos: [:], locallyGeneratedMessageTimestamps: [:], cloudReadStates: [:], channelsToPollExplicitely: [])
        var replay = AccountMutableState(initialState: initial, initialPeers: [:], initialReferencedReplyMessageIds: ReferencedReplyMessageIds(), initialReferencedGeneralMessageIds: [], initialStoredMessages: [], initialStoredStories: [:], initialReadInboxMaxIds: [:], storedMessagesByPeerIdAndTimestamp: [:], initialSentScheduledMessageIds: [])
        guard case let .difference(data) = delivered, case let .state(state) = data.state else { return XCTFail() }
        replay.updateState(.init(pts: state.pts, qts: state.qts, date: state.date, seq: state.seq))
        replay.addSecretMessages(data.newEncryptedMessages)
        XCTAssertEqual(replay.state.qts, 11)
        XCTAssertEqual(replay.state.pts, 10)
        let operations = replay.operations.compactMap { operation -> [Api.EncryptedMessage]? in
            if case let .AddSecretMessages(values) = operation { return values }; return nil
        }.flatMap { $0 }
        XCTAssertEqual(operations.count, 1)
        let buffer = Buffer(); try XCTUnwrap(operations.first).serialize(buffer, true)
        XCTAssertEqual(try codec.decode(buffer.makeData(), as: "EncryptedMessage"), secret)
    }

    func testInviterAndServiceUsersAreRejectedBeforeNativePeerConversion() throws {
        let codec = ExteralessTLCodec.shared
        let original = object("updateChatParticipantAdd", ["chat_id": .integer(1), "user_id": .integer(2), "inviter_id": .integer(3), "date": .integer(100), "version": .integer(1)])
        for inviter in [Int64(4), Int64.max] {
            guard case var .object(fields) = original else { return XCTFail() }
            fields["inviter_id"] = .integer(inviter)
            XCTAssertThrowsError(try ExteralessTLTransformCodec.update(ExteralessTLValue.object(fields).jsonString(), original: original, metadata: .object([:])))
        }
        let unchanged: Api.Update = try parse(codec.encode(original, as: "Update"), as: Api.Update.self)
        guard case let .updateChatParticipantAdd(data) = unchanged else { return XCTFail() }
        XCTAssertEqual(PeerId.Id._internalFromInt64Value(data.inviterId)._internalGetInt64Value(), 3)

        func update(_ users: [Int64]) -> ExteralessTLValue {
            object("updateNewMessage", ["pts": .integer(11), "pts_count": .integer(1), "message": object("messageService", ["id": .integer(1), "peer_id": object("peerChat", ["chat_id": .integer(1)]), "date": .integer(100), "action": object("messageActionChatAddUser", ["users": .array(users.map(ExteralessTLValue.integer))])])])
        }
        let originalService = try codec.normalize(update([2]), as: "Update")
        XCTAssertThrowsError(try ExteralessTLTransformCodec.update(update([Int64.max]).jsonString(), original: originalService, metadata: .object([:])))
        let native: Api.Update = try parse(codec.encode(originalService, as: "Update"), as: Api.Update.self)
        guard case let .updateNewMessage(messageData) = native else { return XCTFail() }
        let stored = try XCTUnwrap(StoreMessage(apiMessage: messageData.message, accountPeerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(99)), peerIsForum: false))
        let action = try XCTUnwrap(stored.media.first as? TelegramMediaAction)
        guard case let .addedMembers(ids) = action.action else { return XCTFail() }
        XCTAssertEqual(ids.map { $0.id._internalGetInt64Value() }, [2])
    }

    func testOptionalNullRolesUseDeclaredFlagsThroughShippingValidators() throws {
        let codec = ExteralessTLCodec.shared
        let metadata = ExteralessTLValue.object([:])
        let fields: [String: ExteralessTLValue] = ["flags": .integer(0), "id": .integer(1), "user_id": .integer(2),
            "message": .string("before"), "pts": .integer(3), "pts_count": .integer(1), "date": .integer(4)]
        let original = try codec.normalize(object("updateShortMessage", fields), as: "Updates")
        var changed = fields; changed["message"] = .string("after")
        let omitted = try ExteralessTLTransformCodec.response(object("updateShortMessage", changed).jsonString(), original: original, type: "Updates", metadata: metadata)
        changed["via_bot_id"] = .null
        let nilBody = try ExteralessTLTransformCodec.response(object("updateShortMessage", changed).jsonString(), original: original, type: "Updates", metadata: metadata)
        XCTAssertEqual(omitted, nilBody)
        var inferred = changed; inferred.removeValue(forKey: "flags")
        XCTAssertEqual(try ExteralessTLTransformCodec.response(object("updateShortMessage", inferred).jsonString(), original: original, type: "Updates", metadata: metadata), nilBody)
        let native: Api.Updates = try parse(nilBody, as: Api.Updates.self)
        guard case let .updateShortMessage(data) = native else { return XCTFail() }
        XCTAssertEqual(data.message, "after"); XCTAssertNil(data.viaBotId)
        for (key, value, flags) in [("via_bot_id", ExteralessTLValue.null, Int64(1 << 11)),
                                    ("user_id", .null, 0), ("via_bot_id", .integer(Int64.max), 1 << 11),
                                    ("via_bot_id", .integer(29), 1 << 11)] {
            var invalid = changed; invalid[key] = value; invalid["flags"] = .integer(flags)
            XCTAssertThrowsError(try ExteralessTLTransformCodec.response(object("updateShortMessage", invalid).jsonString(), original: original, type: "Updates", metadata: metadata))
        }
        var withBot = fields; withBot["flags"] = .integer(1 << 11); withBot["via_bot_id"] = .integer(7)
        let originalBot = try codec.normalize(object("updateShortMessage", withBot), as: "Updates")
        withBot["via_bot_id"] = .integer(29)
        XCTAssertThrowsError(try ExteralessTLTransformCodec.response(object("updateShortMessage", withBot).jsonString(), original: originalBot, type: "Updates", metadata: metadata))
        var message: [String: ExteralessTLValue] = ["flags": .integer(0), "flags2": .integer(0), "id": .integer(1), "peer_id": object("peerUser", ["user_id": .integer(2)]), "date": .integer(4), "message": .string("before")]
        func update(_ fields: [String: ExteralessTLValue]) -> ExteralessTLValue {
            object("updateNewMessage", ["message": object("message", fields), "pts": .integer(3), "pts_count": .integer(1)])
        }
        let originalUpdate = try codec.normalize(update(message), as: "Update")
        message["message"] = .string("after")
        let updateOmitted = try ExteralessTLTransformCodec.update(update(message).jsonString(), original: originalUpdate, metadata: metadata)
        message["via_bot_id"] = .null
        let updateNull = try ExteralessTLTransformCodec.update(update(message).jsonString(), original: originalUpdate, metadata: metadata)
        XCTAssertEqual(updateOmitted, updateNull)
        let parsed: Api.Update = try parse(updateNull, as: Api.Update.self)
        guard case let .updateNewMessage(new) = parsed, case let .message(newMessage) = new.message else { return XCTFail() }
        XCTAssertEqual(newMessage.message, "after"); XCTAssertNil(newMessage.viaBotId)
        message["flags"] = .integer(1 << 11)
        XCTAssertThrowsError(try ExteralessTLTransformCodec.update(update(message).jsonString(), original: originalUpdate, metadata: metadata))
        message["via_bot_id"] = .integer(7)
        let updateWithBot = try codec.normalize(update(message), as: "Update")
        message["via_bot_id"] = .integer(29)
        XCTAssertThrowsError(try ExteralessTLTransformCodec.update(update(message).jsonString(), original: updateWithBot, metadata: metadata))
    }

    func testShippingPostVectorsUseOriginalNativeMethodParsers() throws {
        let metadata = ExteralessTLValue.object([:])
        let users = ExteralessTLValue.array([object("userEmpty", ["id": .integer(7)])])
        let appended = ExteralessTLValue.array([object("userEmpty", ["id": .integer(7)]), object("userEmpty", ["id": .integer(29)])])
        let request = Api.functions.users.getUsers(id: [.inputUserSelf])
        let addedBytes = try ExteralessTLTransformCodec.response(appended.jsonString(), original: users, type: "Vector<User>", metadata: metadata)
        let added = try XCTUnwrap(request.2.parse(Buffer(data: addedBytes)))
        XCTAssertEqual(added.compactMap { user -> Int64? in if case let .userEmpty(data) = user { return data.id }; return nil }, [7, 29])
        let filtered = ExteralessTLValue.array([object("userEmpty", ["id": .integer(29)])])
        let removedBytes = try ExteralessTLTransformCodec.response(filtered.jsonString(), original: appended, type: "Vector<User>", metadata: metadata)
        let removed = try XCTUnwrap(request.2.parse(Buffer(data: removedBytes)))
        XCTAssertEqual(removed.compactMap { user -> Int64? in if case let .userEmpty(data) = user { return data.id }; return nil }, [29])
        let ints = try ExteralessTLTransformCodec.response("[7,29]", original: .array([.integer(7)]), type: "Vector<int>", metadata: metadata)
        XCTAssertEqual(Api.functions.stories.readStories(peer: .inputPeerSelf, maxId: 1).2.parse(Buffer(data: ints)), [7, 29])
        let longs = try ExteralessTLTransformCodec.response("[9007199254740994]", original: .array([.integer(9_007_199_254_740_993)]), type: "Vector<long>", metadata: metadata)
        XCTAssertEqual(Api.functions.messages.receivedQueue(maxQts: 1).2.parse(Buffer(data: longs)), [9_007_199_254_740_994])
        let counterUpdate = object("updates", ["updates": .array([object("updateUser", ["user_id": .integer(7)])]), "users": .array([]), "chats": .array([]), "date": .integer(4), "seq": .integer(1)])
        let retargeted = object("updates", ["updates": .array([object("updateUser", ["user_id": .integer(29)])]), "users": .array([]), "chats": .array([]), "date": .integer(4), "seq": .integer(1)])
        XCTAssertThrowsError(try ExteralessTLTransformCodec.response(retargeted.jsonString(), original: counterUpdate, type: "Updates", metadata: metadata))
        XCTAssertThrowsError(try ExteralessTLTransformCodec.response("[{\"_\":\"userEmpty\",\"id\":9223372036854775807}]", original: users, type: "Vector<User>", metadata: metadata))
    }

    func testReferenceSpoilerOnOffInGenuineEditBodiesPreservesOtherFields() throws {
        let photo: Api.InputPhoto = .inputPhoto(.init(id: Int64.max, accessHash: Int64.min, fileReference: Buffer(data: Data([1, 2]))))
        let document: Api.InputDocument = .inputDocument(.init(id: Int64.max, accessHash: Int64.min, fileReference: Buffer(data: Data([3, 4]))))
        for spoiler in [false, true] {
            let attributes: [MessageAttribute] = spoiler ? [MediaSpoilerMessageAttribute()] : []
            let media: [Api.InputMedia] = [
                exteralessTLReferencePhotoInput(flags: 3, id: photo, ttlSeconds: 9, video: nil, attributes: attributes),
                exteralessTLReferenceDocumentInput(flags: 31, id: document, videoCover: photo, videoTimestamp: 3, ttlSeconds: 9, query: "emoji", attributes: attributes)
            ]
            for item in media {
                for caption in ["cached caption", "changed caption"] {
                    let request = Api.functions.messages.editMessage(flags: (1 << 11) | (1 << 14), peer: .inputPeerSelf, id: 7, message: caption, media: item, replyMarkup: nil, entities: nil, scheduleDate: nil, scheduleRepeatPeriod: nil, quickReplyShortcutId: nil, richMessage: nil)
                    let value = try ExteralessTLCodec.shared.decodeRequest(request.1.makeData())
                    XCTAssertEqual(value["message"], .string(caption))
                    XCTAssertEqual(value["media"]?["spoiler"], .bool(spoiler))
                    XCTAssertEqual(value["media"]?["ttl_seconds"], .integer(9))
                    XCTAssertEqual(value["media"]?["id"]?["id"], .integer(Int64.max))
                    XCTAssertEqual(value["media"]?["id"]?["access_hash"], .integer(Int64.min))
                    XCTAssertEqual(exteralessTLInputMediaSpoiler(item), spoiler)
                    if case .inputMediaDocument = item {
                        XCTAssertEqual(value["media"]?["query"], .string("emoji"))
                        XCTAssertEqual(value["media"]?["video_timestamp"], .integer(3))
                    }
                }
            }
        }
        XCTAssertNil(exteralessTLInputMediaSpoiler(.inputMediaEmpty))
    }

    func testExplicitAudibleAttributeWinsDefaultWhileMissingAttributeUsesDefault() {
        func message(_ attributes: [MessageAttribute]) -> EnqueueMessage {
            .message(text: "fixture", attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        }
        let explicit = exteralessDefaultSendNotifications([message([exteralessTLResolvedNotificationInfo(silent: false)])], defaultSilent: true)[0]
        let missing = exteralessDefaultSendNotifications([message([])], defaultSilent: true)[0]
        XCTAssertFalse(explicit.attributes.compactMap { $0 as? NotificationInfoMessageAttribute }.first!.flags.contains(.muted))
        XCTAssertTrue(missing.attributes.compactMap { $0 as? NotificationInfoMessageAttribute }.first!.flags.contains(.muted))
    }

    func testCancelledBotAuthorizationWaitReleasesProvisionalOrigin() throws {
        let store = TLRequestOrigins()
        let owner = NSObject()
        let correlation = try store.register(network: owner, origin: ExteralessTLRequestOrigin(rootId: "fixture", pluginIds: ["alpha"]))
        let pendingAuthorization = TLReviewBox<(() -> Void)?>(nil)
        let commit = ExteralessTLEnqueueCommit(canCommit: { true }, cancelProvisional: { store.remove(network: owner, correlations: [correlation]) })
        let native = Signal<[MessageId?], NoError> { subscriber in
            pendingAuthorization.with { $0 = {
                guard commit.beginCommit() else { subscriber.putNext([nil]); subscriber.putCompletion(); return }
                XCTFail("cancelled authorization reached a native write")
            } }
            return ActionDisposable { pendingAuthorization.with { $0 = nil } }
        }
        let disposable = exteralessTLRetainedEnqueue(commit: commit, native: native, track: { _ in XCTFail("cancelled authorization delivered ids") }).start(next: { _ in XCTFail() }, error: { _ in XCTFail() })
        XCTAssertEqual(store.pending(network: owner).count, 1)
        disposable.dispose()
        XCTAssertTrue(store.pending(network: owner).isEmpty)
        XCTAssertNil(pendingAuthorization.with { $0 })
        XCTAssertFalse(commit.beginCommit())
    }

    func testPermitRecheckAfterAuthorizationAndAtTransactionWithoutDispose() throws {
        // 0: revoke while authorization is held; 1: revoke after authorization
        // but before the transaction; 2: live control commits exactly once.
        for stage in 0 ... 2 {
            let db = try TLReviewPostbox()
            defer { db.close() }
            let store = TLRequestOrigins()
            let owner = NSObject()
            let correlation = try store.register(network: owner, origin: ExteralessTLRequestOrigin(rootId: "fixture", pluginIds: ["alpha"]))
            let permit = TLReviewBox<Bool>(true)
            let writes = TLReviewBox<Int>(0)
            let authorization = TLReviewBox<(() -> Void)?>(nil)
            let commit = ExteralessTLEnqueueCommit(canCommit: { permit.with { $0 } }, cancelProvisional: { store.remove(network: owner, correlations: [correlation]) })
            let id = db.id(8)
            let native = Signal<[MessageId?], NoError> { subscriber in
                let transactionDisposable = MetaDisposable()
                authorization.with { $0 = {
                    guard commit.allowsContinuation() else {
                        subscriber.putNext([nil]); subscriber.putCompletion(); return
                    }
                    if stage == 1 { permit.with { $0 = false } }
                    transactionDisposable.set(db.postbox.transaction { transaction -> [MessageId?] in
                        guard commit.beginCommit() else { return [nil] }
                        writes.with { $0 += 1 }
                        _ = transaction.addMessages([db.message(id, correlation: correlation, flags: [.Unsent])], location: .Random)
                        return [id]
                    }.start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() }))
                } }
                return ActionDisposable { transactionDisposable.dispose(); authorization.with { $0 = nil } }
            }
            let results = TLReviewBox<[MessageId?]>([])
            let done = DispatchSemaphore(value: 0)
            let subscription = exteralessTLRetainedEnqueue(commit: commit, native: native, track: { ids in
                if let first = ids.compactMap({ $0 }).first {
                    exteralessTLTrackEnqueueOrigin(store: store, owner: owner, postbox: db.postbox, correlation: correlation, messageId: first)
                } else {
                    store.remove(network: owner, correlations: [correlation])
                }
            }).start(next: { ids in results.with { $0 = ids } }, error: { _ in XCTFail(); done.signal() }, completed: { done.signal() })
            defer { subscription.dispose() }
            if stage == 0 { permit.with { $0 = false } }
            try XCTUnwrap(authorization.with { $0 })()
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
            try db.transaction { _ in }
            XCTAssertEqual(writes.with { $0 }, stage == 2 ? 1 : 0)
            let expected: [MessageId?] = stage == 2 ? [id] : [nil]
            XCTAssertEqual(results.with { $0 }, expected)
            XCTAssertEqual(store.pending(network: owner).count, stage == 2 ? 1 : 0)
            if stage == 2 {
                try db.transaction { transaction in transaction.deleteMessages([id], forEachMedia: nil) }
                let deadline = Date().addingTimeInterval(1)
                while !store.pending(network: owner).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                XCTAssertTrue(store.pending(network: owner).isEmpty)
            }
        }
    }

    func testCommitThenDisposeBeforeNextStillTracksRealMessageWithoutHooks() throws {
        for delete in [false, true] {
            let db = try TLReviewPostbox()
            defer { db.close() }
            let store = TLRequestOrigins()
            let owner = NSObject()
            let correlation = try store.register(network: owner, origin: ExteralessTLRequestOrigin(rootId: "fixture", pluginIds: ["alpha"]))
            let emit = TLReviewBox<(([MessageId?]) -> Void)?>(nil)
            let nativeDisposals = TLReviewBox<Int>(0)
            let commit = ExteralessTLEnqueueCommit(canCommit: { true }, cancelProvisional: { store.remove(network: owner, correlations: [correlation]) })
            let native = Signal<[MessageId?], NoError> { subscriber in
                emit.with { $0 = { ids in subscriber.putNext(ids); subscriber.putCompletion() } }
                return ActionDisposable { nativeDisposals.with { $0 += 1 } }
            }
            let id = db.id(7)
            let tracked = DispatchSemaphore(value: 0)
            let disposable = exteralessTLRetainedEnqueue(commit: commit, native: native, track: { ids in
                for case let id? in ids { exteralessTLTrackEnqueueOrigin(store: store, owner: owner, postbox: db.postbox, correlation: correlation, messageId: id) }
                tracked.signal()
            }).start(next: { _ in XCTFail("disposed client received a result") })
            try db.transaction { transaction in
                XCTAssertTrue(commit.beginCommit())
                _ = transaction.addMessages([db.message(id, correlation: correlation, flags: [.Unsent])], location: .Random)
            }
            disposable.dispose()
            XCTAssertEqual(nativeDisposals.with { $0 }, 0)
            emit.with { $0 }?([id])
            XCTAssertEqual(tracked.wait(timeout: .now() + 1), .success)
            try db.transaction { _ in }
            XCTAssertEqual(store.pending(network: owner).count, 1)
            XCTAssertFalse(PluginTLTransformRouter.hasSubscribers(.preRequest))
            try db.transaction { transaction in
                if delete { transaction.deleteMessages([id], forEachMedia: nil) }
                else { transaction.updateMessage(id, update: { _ in .update(db.message(id, correlation: correlation, flags: [])) }) }
            }
            let deadline = Date().addingTimeInterval(1)
            while !store.pending(network: owner).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(store.pending(network: owner).isEmpty)
            XCTAssertEqual(nativeDisposals.with { $0 }, 1)
        }
    }

    func testEntitiesOnlyResolveAgainstCachedTextAndCaptionPresenceClearsFormatting() throws {
        let bold = object("messageEntityBold", ["offset": .integer(0), "length": .integer(1)])
        let cached = TextEntitiesMessageAttribute(entities: [.init(range: 0 ..< 2, type: .Italic)])
        let edited = try exteralessTLResolveEditText(cachedText: "ab", cachedEntities: cached, caption: nil, entities: [bold])
        XCTAssertEqual(edited.text, "ab")
        XCTAssertEqual(edited.entities?.entities.first?.range, 0 ..< 1)
        XCTAssertThrowsError(try exteralessTLResolveEditText(cachedText: "", cachedEntities: cached, caption: nil, entities: [bold]))
        XCTAssertThrowsError(try exteralessTLResolveEditText(cachedText: "ab", cachedEntities: cached, caption: "", entities: [bold]))
        let cleared = try exteralessTLResolveEditText(cachedText: "ab", cachedEntities: cached, caption: "cd", entities: nil)
        XCTAssertTrue(cleared.entities?.entities.isEmpty == true)
        let kept = try exteralessTLResolveEditText(cachedText: "ab", cachedEntities: cached, caption: nil, entities: nil)
        XCTAssertTrue(kept.entities === cached)
    }
}

private final class TLReviewPostbox {
    let queue = Queue(name: "TLReviewPostbox")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tl-review-" + UUID().uuidString)
    let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1))
    private var valueBox: SqliteValueBox?
    private(set) var postbox: Postbox!
    init() throws {
        initializeAccountManagement()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 100, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("TL fixture attempted fetch"); return .fail(.generic) }
    }
    func id(_ id: Int32) -> MessageId { MessageId(peerId: peer, namespace: Namespaces.Message.Local, id: id) }
    func message(_ id: MessageId, correlation: Int64, flags: StoreMessageFlags) -> StoreMessage {
        StoreMessage(id: id, customStableId: nil, globallyUniqueId: 900, groupingKey: nil, threadId: nil, timestamp: 100, flags: flags, tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer, text: "fixture", attributes: [OutgoingMessageInfoAttribute(uniqueId: 900, flags: [], acknowledged: false, correlationId: correlation, bubbleUpEmojiOrStickersets: [], partialReference: nil)], media: [])
    }
    func transaction(_ body: @escaping (Transaction) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        let disposable = postbox.transaction(body).start(completed: { done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 2) == .success else { throw NSError(domain: "TLReviewTimeout", code: 1) }
    }
    func close() {
        let done = DispatchSemaphore(value: 0)
        let disposable = postbox.mediaBox.storageBox.totalSize().start(next: { _ in done.signal() })
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        disposable.dispose()
        postbox = nil
        queue.sync { self.valueBox = nil }
        try? FileManager.default.removeItem(at: root)
    }
}
