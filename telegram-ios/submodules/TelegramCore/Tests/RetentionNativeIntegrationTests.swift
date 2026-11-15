import ExteralessCore
import Foundation
import Postbox
import sqlcipher
import SwiftSignalKit
import XCTest
@testable import TelegramCore

/// Synthetic Postbox/messages only; no Account, AccountContext, Network or real identity.
final class RetentionNativeIntegrationTests: XCTestCase {
    private var roots: [URL] = []
    private var postboxes: [Postbox] = []
    private let ownerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(710001))
    private let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(710002))

    override func setUp() { super.setUp(); initializeAccountManagement() }
    override func tearDown() {
        self.postboxes.removeAll()
        for root in self.roots { try? FileManager.default.removeItem(at: root) }
        self.roots.removeAll()
        super.tearDown()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retention-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.roots.append(url)
        return url
    }

    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = self.expectation(description: "bounded native transaction")
        var result: T?
        let disposable = signal.start(next: { result = $0 }, completed: { done.fulfill() })
        self.wait(for: [done], timeout: 3.0)
        disposable.dispose()
        return try XCTUnwrap(result)
    }

    private func makePostbox() throws -> Postbox {
        let root = try self.directory()
        let key = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: .init(data: Data(repeating: 0x35, count: 32))!, salt: .init(data: Data(repeating: 0x53, count: 16))!)
        let result = try self.value(openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: key, timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false) |> filter { if case .upgrading = $0 { return false }; return true } |> take(1))
        guard case let .postbox(postbox) = result else { throw ExteralessRetentionError.unavailable }
        self.postboxes.append(postbox)
        _ = try self.value(postbox.transaction { transaction -> Bool in
            transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: self.ownerId, state: .init(pts: 41, qts: 7, date: 1000, seq: 9), invalidatedChannels: []))
            transaction.updatePeersInternal([self.user(self.ownerId), self.user(self.peerId)], update: { _, value in value })
            return true
        })
        return postbox
    }

    private func user(_ id: PeerId) -> TelegramUser {
        TelegramUser(id: id, accessHash: nil, firstName: "Fixture", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }

    private func message(_ text: String) -> StoreMessage {
        StoreMessage(id: MessageId(peerId: self.peerId, namespace: Namespaces.Message.Cloud, id: 5), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 1000, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: self.ownerId, text: text, attributes: [], media: [])
    }

    func testRealObserverSeesBeforeImageForUpsertAndEditAndOnlyWritesItsCacheRow() throws {
        let postbox = try self.makePostbox()
        let id = MessageId(peerId: self.peerId, namespace: Namespaces.Message.Cloud, id: 5)
        let cacheId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.retention.fixture.before"))
        _ = try self.value(postbox.transaction { transaction -> Bool in _ = transaction.addMessages([self.message("v1")], location: .Random); return true })
        var pairs: [String] = []
        let observer = postbox.installMessageHistoryObserver { transaction, previous, next in
            XCTAssertEqual(transaction.getMessage(id)?.text, previous.text)
            pairs.append(previous.text + ">" + next.text)
            transaction.putItemCacheEntry(id: cacheId, entry: CodableEntry(data: Data(previous.text.utf8)))
        }
        defer { observer.dispose() }
        _ = try self.value(postbox.transaction { transaction -> Bool in
            _ = transaction.addMessages([self.message("v2")], location: .Random)
            transaction.updateMessage(id, update: { _ in .update(self.message("v3")) })
            XCTAssertEqual(transaction.getMessage(id)?.text, "v3")
            XCTAssertEqual(transaction.retrieveItemCacheEntry(id: cacheId)?.data, Data("v2".utf8))
            let first = transaction.reserveMessageStableId(), second = transaction.reserveMessageStableId()
            XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
            XCTAssertEqual((transaction.getState() as? AuthorizedAccountState)?.state?.pts, 41)
            return true
        })
        XCTAssertEqual(pairs, ["v1>v2", "v2>v3"])
        observer.dispose()
        _ = try self.value(postbox.transaction { transaction -> Bool in _ = transaction.addMessages([self.message("v4")], location: .Random); return true })
        XCTAssertEqual(pairs.count, 2)
    }

    func testClearEpochAndDisposalRejectQueuedWritesBeforeTheyTouchPostbox() throws {
        let postbox = try self.makePostbox()
        let scope = RetentionOperationScope()
        let work = scope.makeWork()
        let ready = self.expectation(description: "transactions paused")
        postbox.setCanBeginTransactions(false, afterTransactionIfRunning: { ready.fulfill() })
        self.wait(for: [ready], timeout: 3.0)
        let done = self.expectation(description: "invalidated transaction terminates")
        let cache = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.retention.fixture.cancel"))
        var bodies = 0
        let request = exteralessRetentionScopedTransaction(postbox: postbox, accountPeerId: self.ownerId, testingEnvironment: false, work: work) { transaction -> Result<Bool, ExteralessRetentionError> in
            bodies += 1
            transaction.putItemCacheEntry(id: cache, entry: CodableEntry(data: Data([1])))
            return .success(true)
        }.start(next: { result in if case .success = result { XCTFail("old scope succeeded") } }, completed: { done.fulfill() })
        scope.invalidate()
        postbox.setCanBeginTransactions(true)
        self.wait(for: [done], timeout: 3.0)
        request.dispose()
        XCTAssertEqual(bodies, 0)
        _ = try self.value(postbox.transaction { transaction -> Bool in XCTAssertNil(transaction.retrieveItemCacheEntry(id: cache)); return true })
        let cancelled = scope.makeWork(); cancelled.cancel()
        XCTAssertFalse(cancelled.isCurrent)
        XCTAssertTrue(scope.makeWork().isCurrent)
        scope.invalidate(close: true)
        XCTAssertFalse(scope.makeWork().isCurrent)
    }

    func testAuxiliarySQLiteImportUsesRealPrivacyRowsAndLocalPeerDescriptors() throws {
        let postbox = try self.makePostbox()
        let now: Int64 = 1_700_000_500
        let url = try self.directory().appendingPathComponent("database-export.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let statements = [
            "CREATE TABLE DeletedMessage (userId INTEGER, dialogId INTEGER, messageId INTEGER, date INTEGER, entityCreateDate INTEGER, editDate INTEGER, flags INTEGER, text TEXT)",
            "CREATE TABLE SpyMessageRead (userId INTEGER, dialogId INTEGER, messageId INTEGER, date INTEGER)",
            "CREATE TABLE SpyMessageContentsRead (userId INTEGER, dialogId INTEGER, messageId INTEGER, entityCreateDate INTEGER)",
            "CREATE TABLE LastSeenEntity (userId INTEGER, lastSeen INTEGER)",
            "CREATE TABLE SpyLastSeen (userId INTEGER, lastSeenDate INTEGER)",
            "CREATE TABLE DeletedDialog (userId INTEGER, dialogId INTEGER, folderId INTEGER, topMessage INTEGER, lastMessageDate INTEGER, entityCreateDate INTEGER)",
            "INSERT INTO SpyMessageRead VALUES (710001,710002,5,\(now - 10))",
            "INSERT INTO SpyMessageRead VALUES (999999,710002,6,\(now - 10))",
            "INSERT INTO SpyMessageContentsRead VALUES (710001,710002,5,\(now - 9))",
            "INSERT INTO LastSeenEntity VALUES (710002,\(now - 3))",
            "INSERT INTO SpyLastSeen VALUES (710002,\(now - 1))",
            "INSERT INTO DeletedDialog VALUES (710001,710002,1,999,\(now - 100),\(now - 2))"
        ]
        for statement in statements { XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK) }
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let source = try ExteralessAyuDatabaseReader().read(url: url)
        XCTAssertEqual(source.auxiliaryRows["SpyMessageRead"]?.count, 2)
        for pass in 0 ..< 2 {
            let result: Result<ExteralessAyuImportReceipt, Error> = try self.value(postbox.transaction { transaction in
                Result {
                    let result = try exteralessImportAyuDatabase(source, transaction: transaction, accountPeerId: self.ownerId, mediaBox: postbox.mediaBox, peerMappings: [:], policy: RetentionPolicy(), now: now, didMutate: { _ in })
                    let privacy = try exteralessPrivacyImportSnapshot(transaction: transaction, accountPeerId: self.ownerId)
                    let key = PrivacyObservations.messageKey(peerId: self.peerId.toInt64(), namespace: Namespaces.Message.Cloud, id: 5)
                    XCTAssertEqual(privacy.readDates.reads[key]?.readAt, Int32(now - 10))
                    XCTAssertEqual(privacy.readDates.reads[key]?.playedAt, Int32(now - 9))
                    XCTAssertEqual(privacy.activity.lastSeen[self.peerId.toInt64()], Int32(now - 3)) // LastSeenEntity wins over SpyLastSeen.
                    let peers = try RetentionArchivePeerStore.load(transaction: transaction, accountPeerId: self.ownerId, policy: .current, now: now)
                    XCTAssertEqual(peers.peers["710002"]?.folderId, 1)
                    XCTAssertNil(transaction.getMessage(MessageId(peerId: self.peerId, namespace: Namespaces.Message.Cloud, id: 999)))
                    XCTAssertNil(transaction.getPeerChatListIndex(self.peerId))
                    XCTAssertEqual((transaction.getState() as? AuthorizedAccountState)?.state?.seq, 9)
                    return result
                }
            })
            let receipt = try result.get()
            XCTAssertEqual(receipt.importedReadDates, pass == 0 ? 1 : 0)
            XCTAssertEqual(receipt.importedContentReadDates, pass == 0 ? 1 : 0)
            XCTAssertEqual(receipt.importedActivities, pass == 0 ? 1 : 0)
            XCTAssertEqual(receipt.importedChatDescriptors, pass == 0 ? 1 : 0)
            XCTAssertEqual(receipt.otherAccounts, 1)
        }
    }

    func testUnixSecondsAliasesZeroAndMillisecondsAreNotGuessed() throws {
        let now: Int64 = 1_700_000_500
        let seconds = ExteralessAyuRow(table: "SpyMessageRead", values: ["date": .integer(now - 1)])
        XCTAssertEqual(try retentionAyuUnixSeconds(seconds, key: "date", now: now), Int32(now - 1))
        XCTAssertNil(try retentionAyuUnixSeconds(ExteralessAyuRow(table: "SpyMessageRead", values: ["date": .null]), key: "date", now: now))
        XCTAssertThrowsError(try retentionAyuUnixSeconds(ExteralessAyuRow(table: "SpyLastSeen", values: ["lastSeenDate": .integer(now * 1000)]), key: "lastSeenDate", now: now))
        XCTAssertThrowsError(try retentionAyuUnixSeconds(ExteralessAyuRow(table: "SpyMessageRead", values: ["date": .integer(now + 1)]), key: "date", now: now))
        var first = PrivacyObservations()
        first.observeRead(peerId: self.peerId.toInt64(), namespace: 0, id: 5, timestamp: 100, played: false)
        var input = RetentionPrivacyImportInput()
        input.reads = [RetentionPrivacyReadInput(messageId: MessageId(peerId: self.peerId, namespace: 0, id: 5), timestamp: 90, played: false)]
        let merged = try retentionMergePrivacyObservations(activity: PrivacyObservations(), readDates: first, input: input, now: Int32(now))
        XCTAssertEqual(merged.readDates.reads[PrivacyObservations.messageKey(peerId: self.peerId.toInt64(), namespace: 0, id: 5)]?.readAt, 100)
        XCTAssertEqual(merged.duplicates, 1)
    }

    func testCachedRichTranslationUsesOnlyOwnedLocalMediaWithoutChangingTheSource() throws {
        let postbox = try self.makePostbox()
        let resource = CloudPhotoSizeMediaResource(datacenterId: 1, photoId: 30, accessHash: 40, sizeSpec: "x", size: 4, fileReference: nil)
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 30), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 2, height: 2), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let page = InstantPage(blocks: [.paragraph(.plain("Received translation"))], rawMedia: [image.imageId: image], isComplete: true, rtl: false, url: "", views: nil)
        let translation = TranslationMessageAttribute(text: "", entities: [], toLang: "en", instantPage: page)
        let source = self.message("original").withUpdatedAttributes([RichTextMessageAttribute(instantPage: page, fullInstantPage: nil), translation])
        let outcome: Result<Bool, Error> = try self.value(postbox.transaction { transaction in
            Result {
                _ = transaction.addMessages([source], location: .Random)
                let message = try XCTUnwrap(transaction.getMessage(MessageId(peerId: self.peerId, namespace: Namespaces.Message.Cloud, id: 5)))
                let snapshot = try ExteralessRetentionSnapshot(message: message, includeMedia: true)
                let version = try RetentionVersion(sequence: 1, capturedAt: 1001, messageVersionDate: 1000, fingerprint: exteralessRetentionFingerprint(text: message.text, attributes: message.attributes, media: message.media), reason: .deleted, payload: exteralessRetentionEncode(snapshot), resourceIds: [resource.id.stringRepresentation])
                var index = ExteralessRetentionIndex(accountPeerId: self.ownerId)
                let entry = ExteralessRetentionMediaEntry(id: resource.id.stringRepresentation, capturedAt: 1001, reservedBytes: 4)
                index.media[entry.id] = entry
                let rendered = try snapshot.render(version: version, localMediaIndex: index)
                let mapped = try XCTUnwrap(rendered.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute)
                let mappedImage = try XCTUnwrap(mapped.instantPage?.rawMedia[image.imageId] as? TelegramMediaImage)
                XCTAssertEqual(mapped.toLang, translation.toLang)
                XCTAssertEqual(mapped.instantPage?.blocks, page.blocks)
                XCTAssertEqual(mappedImage.representations.first?.resource.id, entry.cacheId)
                XCTAssertTrue(mappedImage.representations.first?.resource is LocalFileMediaResource)
                XCTAssertEqual((translation.instantPage?.rawMedia[image.imageId] as? TelegramMediaImage)?.representations.first?.resource.id, resource.id)

                let poll = TelegramMediaPoll(pollId: MediaId(namespace: Namespaces.Media.CloudPoll, id: 31), publicity: .anonymous, kind: .quiz(multipleAnswers: false), text: "Question", textEntities: [], options: [TelegramMediaPollOption(text: "Answer", entities: [], opaqueIdentifier: Data([1]), media: image, date: 1000, addedBy: nil)], correctAnswers: nil, results: TelegramMediaPollResults(voters: nil, totalVoters: 1, recentVoters: [], solution: .init(text: "Solution", entities: [], media: image), hasUnseenVotes: nil, canViewStats: false), isClosed: false, deadlineTimeout: nil, deadlineDate: nil, pollHash: 7, attachedMedia: image)
                let mappedPoll = try XCTUnwrap(exteralessRetentionLocalMedia(poll, index: index) as? TelegramMediaPoll)
                for value in [mappedPoll.attachedMedia, mappedPoll.options.first?.media, mappedPoll.results.solution?.media] {
                    XCTAssertEqual((value as? TelegramMediaImage)?.representations.first?.resource.id, entry.cacheId)
                }
                XCTAssertEqual(mappedPoll.pollHash, poll.pollHash)
                XCTAssertEqual(mappedPoll.results.totalVoters, poll.results.totalVoters)
                let emptyPoll = try XCTUnwrap(exteralessRetentionLocalMedia(poll, index: ExteralessRetentionIndex(accountPeerId: self.ownerId)) as? TelegramMediaPoll)
                XCTAssertNil(emptyPoll.attachedMedia)
                XCTAssertNil(emptyPoll.options.first?.media)
                XCTAssertNil(emptyPoll.results.solution?.media)

                let unowned = try snapshot.render(version: version, localMediaIndex: ExteralessRetentionIndex(accountPeerId: self.ownerId))
                XCTAssertTrue((unowned.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute)?.instantPage?.rawMedia.isEmpty == true)
                let excluded = try ExteralessRetentionSnapshot(message: message, includeMedia: false).render(version: version)
                XCTAssertTrue((excluded.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute)?.instantPage?.rawMedia.isEmpty == true)
                XCTAssertEqual((transaction.getState() as? AuthorizedAccountState)?.state?.pts, 41)
                return true
            }
        })
        XCTAssertTrue(try outcome.get())
    }
}
