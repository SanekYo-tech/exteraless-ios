import CryptoKit
import ExteralessCore
import Foundation
import Postbox
import sqlcipher
import SwiftSignalKit
import XCTest
@testable import TelegramCore

/// Hermetic accountless fixtures: real disposable encrypted Postboxes, synthetic peers/messages,
/// no Network/Account/AccountContext and no remote fetch. Each wait is capped at three seconds.
final class ExteralessRetentionTests: XCTestCase {
    private var roots: [URL] = []
    private var postboxes: [Postbox] = []
    private var owners: [ExteralessRetentionAccount] = []
    private var deadline: Double = 0
    private let accountPeer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(700001))
    private let senderId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(700002))

    override func setUp() {
        super.setUp()
        self.deadline = ProcessInfo.processInfo.systemUptime + 25
        initializeAccountManagement()
    }

    override func tearDown() {
        for owner in self.owners { owner.dispose() }
        self.owners.removeAll()
        self.postboxes.removeAll()
        for url in self.roots { try? FileManager.default.removeItem(at: url) }
        self.roots.removeAll()
        super.tearDown()
    }

    private var policy: RetentionPolicy {
        RetentionPolicy(values: ["privacy.enableSaveDeletedMessages": .bool(true), "privacy.enableSaveEditsHistory": .bool(true)])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exteraless-retention-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.roots.append(url)
        return url
    }

    private func value<T>(_ signal: Signal<T, NoError>, timeout: TimeInterval = 3.0, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let done = self.expectation(description: "bounded native result")
        var result: T?
        let disposable = signal.start(next: { result = $0 }, completed: { done.fulfill() })
        self.wait(for: [done], timeout: max(0.01, min(timeout, self.deadline - ProcessInfo.processInfo.systemUptime)))
        disposable.dispose()
        return try XCTUnwrap(result, file: file, line: line)
    }

    private func postbox() throws -> Postbox {
        let root = try self.temporaryDirectory()
        let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true,
            key: ValueBoxEncryptionParameters.Key(data: Data(repeating: 0x31, count: 32))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(repeating: 0x32, count: 16))!)
        let result = try self.value(openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: parameters, timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> filter { if case .upgrading = $0 { return false }; return true } |> take(1))
        guard case let .postbox(postbox) = result else { throw ExteralessRetentionError.unavailable }
        postbox.mediaBox.fetchResource = { _, _, _ in
            XCTFail("Retention fixture attempted a remote fetch")
            return .fail(.generic)
        }
        self.postboxes.append(postbox)
        return postbox
    }

    private func sender() -> TelegramUser {
        TelegramUser(id: self.senderId, accessHash: nil, firstName: "Synthetic", lastName: "Sender", username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }

    private func owner(_ postbox: Postbox) throws -> ExteralessRetentionAccount {
        _ = try self.value(postbox.transaction { transaction -> Bool in
            if transaction.getState() == nil {
                transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: self.accountPeer, state: .init(pts: 71, qts: 9, date: 100, seq: 21), invalidatedChannels: []))
            }
            return true
        })
        let root = URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent()
        var values = Dictionary(uniqueKeysWithValues: RetentionFeatures.definitions.map { ($0.key, $0.defaultValue) })
        values["privacy.enableSaveDeletedMessages"] = .bool(true)
        values["privacy.enableSaveEditsHistory"] = .bool(true)
        let snapshot = ClientSettingsSnapshot(definitions: RetentionFeatures.definitions, values: values, storedKeys: Set(values.keys))
        return ExteralessRetentionAccount(postbox: postbox, accountPeerId: self.accountPeer, configuration: try ExteralessRetentionProcessConfiguration(role: .mainApplication, snapshot: snapshot, durabilityRootURL: root))
    }

    private func stored(id: Int32 = 1, text: String = "received text", editDate: Int32? = nil, media: [Media] = []) -> StoreMessage {
        let attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< 8, type: .Bold)])] + (editDate.map { [EditedMessageAttribute(date: $0, isHidden: false)] } ?? [])
        return StoreMessage(id: MessageId(peerId: self.senderId, namespace: Namespaces.Message.Cloud, id: id), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: self.senderId, text: text, attributes: attributes, media: media)
    }

    private func seed(_ postbox: Postbox, messages: [StoreMessage]) throws {
        _ = try self.value(postbox.transaction { transaction -> Bool in
            transaction.updatePeersInternal([self.sender()], update: { _, value in value })
            _ = transaction.addMessages(messages, location: .Random)
            return true
        })
    }

    func testEncryptedPostboxRoundTripSurvivesActualDeleteAndPreservesServerState() throws {
        let postbox = try self.postbox()
        let message = self.stored()
        try self.seed(postbox, messages: [message])
        let id = MessageId(peerId: self.senderId, namespace: Namespaces.Message.Cloud, id: 1)
        let key = RetentionMessageKey(peerId: self.senderId.toInt64(), namespace: 0, id: 1)
        let expectedState = AuthorizedAccountState.State(pts: 71, qts: 9, date: 100, seq: 21)
        let saved: Result<Bool, Error> = try self.value(postbox.transaction { transaction in
            Result {
                transaction.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2, peerId: self.accountPeer, state: expectedState, invalidatedChannels: []))
                let before = try XCTUnwrap(transaction.getMessage(id))
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: 1000)
                let captured = try store.captureDeleted(before, mediaBox: postbox.mediaBox)
                _ = try store.finish()
                transaction.deleteMessages([id], forEachMedia: nil)
                return captured
            }
        })
        XCTAssertTrue(try saved.get())
        let read: Result<RetentionPolicyRecord, Error> = try self.value(postbox.transaction { transaction in
            Result {
                XCTAssertNil(transaction.getMessage(id))
                XCTAssertEqual((transaction.getState() as? AuthorizedAccountState)?.state, expectedState)
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: 1001)
                return try XCTUnwrap(store.record(key))
            }
        })
        let record = try read.get()
        let version = try XCTUnwrap(record.versions.first)
        let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
        let rendered = try snapshot.render(version: version)
        XCTAssertEqual(rendered.text, "received text")
        XCTAssertEqual(rendered.id, id)
        XCTAssertEqual((rendered.attributes.first { $0 is TextEntitiesMessageAttribute } as? TextEntitiesMessageAttribute)?.entities.first?.range, 0 ..< 8)
        XCTAssertTrue(EngineMessage(rendered).exteralessRetention?.isDeleted == true)
        let db = try FileHandle(forReadingFrom: self.roots[0].appendingPathComponent("db/db_sqlite"))
        defer { try? db.close() }
        XCTAssertNotEqual(try db.read(upToCount: 16), Data("SQLite format 3\0".utf8))
    }

    func testEditsFreezeNativeAttributesAndReplayDoesNotDuplicate() throws {
        let postbox = try self.postbox()
        let id = MessageId(peerId: self.senderId, namespace: Namespaces.Message.Cloud, id: 1)
        try self.seed(postbox, messages: [self.stored()])
        let result: Result<RetentionPolicyRecord, Error> = try self.value(postbox.transaction { transaction in
            Result {
                let before = try XCTUnwrap(transaction.getMessage(id))
                let updated = self.stored(text: "new received text", editDate: 200)
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: 1000)
                XCTAssertTrue(try store.captureEdit(previous: before, updated: updated, mediaBox: postbox.mediaBox))
                XCTAssertFalse(try store.captureEdit(previous: before, updated: updated, mediaBox: postbox.mediaBox))
                _ = try store.finish()
                transaction.updateMessage(id, update: { _ in .update(updated) })
                let next = try XCTUnwrap(transaction.getMessage(id))
                let deletion = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: 1001)
                XCTAssertTrue(try deletion.captureDeleted(next, mediaBox: postbox.mediaBox))
                _ = try deletion.finish()
                transaction.deleteMessages([id], forEachMedia: nil)
                return try XCTUnwrap(deletion.record(before.retentionKey))
            }
        })
        let record = try result.get()
        XCTAssertEqual(record.versions.map(\.reason), [.edit, .deleted])
        XCTAssertEqual(try record.versions.map { try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: $0.payload).text }, ["received text", "new received text"])
    }

    func testAccountIsolationExceptionNamespacesExpiryAndPrefixOnlyClear() throws {
        let a = try self.postbox()
        let b = try self.postbox()
        try self.seed(a, messages: [self.stored()])
        let privacyId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.privacy.fixture"))
        let group = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(700002))
        let result: Result<Bool, Error> = try self.value(a.transaction { transaction in
            Result {
                transaction.putItemCacheEntry(id: privacyId, entry: CodableEntry(data: Data([4, 5, 6])))
                try ExteralessRetentionStore.setPeerExceptions(transaction: transaction, accountPeerId: self.accountPeer, peerId: group, value: .init(deleted: true))
                XCTAssertFalse(try ExteralessRetentionStore.peerExceptions(transaction: transaction, accountPeerId: self.accountPeer, peerId: self.senderId).deleted)
                let message = try XCTUnwrap(transaction.getMessage(MessageId(peerId: self.senderId, namespace: 0, id: 1)))
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: 1000)
                XCTAssertTrue(try store.captureDeleted(message, mediaBox: a.mediaBox))
                _ = try store.finish()
                let expired = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: 1000 + 31 * 86400)
                _ = try expired.finish()
                XCTAssertTrue(expired.index.rows.isEmpty)
                XCTAssertEqual(transaction.retrieveItemCacheEntry(id: privacyId)?.data, Data([4, 5, 6]))
                return true
            }
        })
        XCTAssertTrue(try result.get())
        let other: Result<Bool, Error> = try self.value(b.transaction { transaction in
            Result {
                XCTAssertNil(try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeer))
                XCTAssertFalse(try ExteralessRetentionStore.peerExceptions(transaction: transaction, accountPeerId: self.accountPeer, peerId: group).deleted)
                return true
            }
        })
        XCTAssertTrue(try other.get())
    }

    func testCiphertextRoundTripTamperTruncationAndAccountBinding() throws {
        let root = try self.temporaryDirectory()
        let vault = ExteralessRetentionMediaVault(directory: root.appendingPathComponent("encrypted"))
        let original = Data(repeating: 0xA7, count: ExteralessRetentionMediaVault.chunkSize + 71)
        let sourceURL = root.appendingPathComponent("received-file")
        try original.write(to: sourceURL)
        let index = ExteralessRetentionIndex(accountPeerId: self.accountPeer)
        let entry = ExteralessRetentionMediaEntry(id: "fixture-resource", capturedAt: 1000, reservedBytes: Int64(original.count))
        XCTAssertEqual(try vault.store(source: FileHandle(forReadingFrom: sourceURL), length: Int64(original.count), entry: entry, index: index, cancelled: { false }), Int64(original.count))
        var stored = entry
        stored.state = .stored
        stored.storedBytes = Int64(original.count)
        let encryptedURL = try vault.file(for: entry)
        let ciphertext = try Data(contentsOf: encryptedURL)
        XCTAssertNil(ciphertext.range(of: original.prefix(64)))
        try FileManager.default.removeItem(at: sourceURL) // Simulate cache deletion while offline.
        let restored = try vault.restore(entry: stored, index: index, nativeCacheDirectory: root, cancelled: { false })
        XCTAssertEqual(try Data(contentsOf: restored), original)
        var wrongAccount = try XCTUnwrap(JSONSerialization.jsonObject(with: exteralessRetentionEncode(index)) as? [String: Any])
        wrongAccount["accountPeerId"] = self.senderId.toInt64()
        let changed = try JSONDecoder().decode(ExteralessRetentionIndex.self, from: JSONSerialization.data(withJSONObject: wrongAccount))
        XCTAssertThrowsError(try vault.read(entry: entry, index: changed, expectedLength: Int64(original.count), output: nil, cancelled: { false }))
        var corrupted = ciphertext
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: encryptedURL)
        XCTAssertThrowsError(try vault.read(entry: entry, index: index, expectedLength: Int64(original.count), output: nil, cancelled: { false }))
        try ciphertext.dropLast().write(to: encryptedURL)
        XCTAssertThrowsError(try vault.read(entry: entry, index: index, expectedLength: Int64(original.count), output: nil, cancelled: { false }))
    }

    func testMediaOwnershipUsesIndependentRealMediaBoxResourcesAndNeverCloudFallback() throws {
        let postbox = try self.postbox()
        let owner = try self.owner(postbox)
        self.owners.append(owner)
        XCTAssertTrue(try self.value(owner.ready))
        let resource = CloudPhotoSizeMediaResource(datacenterId: 1, photoId: 10, accessHash: 20, sizeSpec: "x", size: 4, fileReference: nil)
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 10), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 2, height: 2), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        try self.seed(postbox, messages: [self.stored(media: [image])])
        // No data is supplied for the source. Metadata is known; the file must remain unavailable.
        let result: Result<ExteralessRetentionMediaEntry, Error> = try self.value(postbox.transaction { transaction in
            Result {
                let message = try XCTUnwrap(transaction.getMessage(MessageId(peerId: self.senderId, namespace: 0, id: 1)))
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: Int64(Date().timeIntervalSince1970))
                XCTAssertTrue(try store.captureDeleted(message, mediaBox: postbox.mediaBox))
                let index = try store.finish()
                owner.didMutate(index)
                let entry = try XCTUnwrap(index.media[resource.id.stringRepresentation])
                let version = try XCTUnwrap(store.record(message.retentionKey)?.versions.first)
                let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
                let rendered = try snapshot.render(version: version, localMediaIndex: index)
                let renderedImage = try XCTUnwrap(rendered.media.first as? TelegramMediaImage)
                XCTAssertEqual(renderedImage.representations.first?.resource.id, entry.cacheId)
                XCTAssertTrue(renderedImage.representations.first?.resource is LocalFileMediaResource)
                XCTAssertNotEqual(entry.cacheId, resource.id)
                return entry
            }
        })
        let entry = try result.get()
        let file = try self.value(owner.materialize(resourceId: entry.id))
        if case .success = file { XCTFail("A never-downloaded file was presented as available") }
        let fetch = try XCTUnwrap(exteralessFetchRetainedLocalResource(postbox: postbox, resource: LocalFileMediaResource(fileId: entry.cacheFileId)))
        let done = self.expectation(description: "missing retained media terminates once")
        var values = 0
        var errors = 0
        var completions = 0
        let disposable = fetch.start(next: { _ in values += 1 }, error: { _ in errors += 1; done.fulfill() }, completed: { completions += 1; done.fulfill() })
        self.wait(for: [done], timeout: 3.0)
        disposable.dispose()
        XCTAssertEqual(values, 0)
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(completions, 0)
    }

    func testUnknownIndexFieldsFailClosedWithoutOverwritingAnyData() throws {
        let postbox = try self.postbox()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exteralessRetentionEncode(ExteralessRetentionIndex(accountPeerId: self.accountPeer))) as? [String: Any])
        object["future-field"] = "must not be silently dropped"
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let result: Result<Bool, Error> = try self.value(postbox.transaction { transaction in
            Result {
                transaction.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: encoded))
                XCTAssertThrowsError(try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeer))
                XCTAssertEqual(transaction.retrieveItemCacheEntry(id: exteralessRetentionIndexId)?.data, encoded)
                return true
            }
        })
        XCTAssertTrue(try result.get())
    }

    func testRangeHookCapturesOnlyKnownRowsUsingTheReceivingPeerNamespace() throws {
        let postbox = try self.postbox()
        let owner = try self.owner(postbox)
        self.owners.append(owner)
        XCTAssertTrue(try self.value(owner.ready))
        try self.seed(postbox, messages: [self.stored(id: 1), self.stored(id: 2), self.stored(id: 3)])
        let result: Result<Bool, Error> = try self.value(postbox.transaction { transaction in
            Result {
                let captured = exteralessRetainBeforeRangeDeletion(transaction: transaction, mediaBox: postbox.mediaBox, peerId: self.senderId, namespace: Namespaces.Message.Cloud, maxId: 2, policy: self.policy)
                XCTAssertNil(captured.error)
                XCTAssertEqual(captured.captured, 2)
                let index = try XCTUnwrap(ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: self.accountPeer))
                XCTAssertEqual(Set(index.rows.values.map { $0.key.id }), [1, 2])
                XCTAssertTrue(index.rows.values.allSatisfy { $0.key.peerId == self.senderId.toInt64() && $0.key.namespace == Namespaces.Message.Cloud })
                return true
            }
        })
        XCTAssertTrue(try result.get())
    }

    func testFullResetResumesAfterCrashAndDoesNotClearOtherPrefixes() throws {
        let postbox = try self.postbox()
        let privacy = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.privacy.fixture"))
        _ = try self.value(postbox.transaction { transaction -> Bool in
            transaction.putItemCacheEntry(id: privacy, entry: CodableEntry(data: Data([7])))
            transaction.putItemCacheEntry(id: exteralessRetentionRowId(19999), entry: CodableEntry(data: Data([1, 2, 3])))
            transaction.putItemCacheEntry(id: exteralessRetentionResetId, entry: CodableEntry(data: Data([1])))
            return true
        })
        let owner = try self.owner(postbox)
        self.owners.append(owner)
        // Full fixed-key reset is the only fixture with a longer wait; total bound is <30 s.
        XCTAssertTrue(try self.value(owner.ready, timeout: 20.0))
        _ = try self.value(postbox.transaction { transaction -> Bool in
            XCTAssertNil(transaction.retrieveItemCacheEntry(id: exteralessRetentionResetId))
            XCTAssertNil(transaction.retrieveItemCacheEntry(id: exteralessRetentionRowId(19999)))
            XCTAssertEqual(transaction.retrieveItemCacheEntry(id: privacy)?.data, Data([7]))
            return true
        })
    }

    func testTwoVersionsShareOneBackupAndLastOwnerClearRemovesNativeAliases() throws {
        let postbox = try self.postbox()
        let owner = try self.owner(postbox)
        self.owners.append(owner)
        XCTAssertTrue(try self.value(owner.ready))
        let bytes = Data([0x41, 0x42, 0x43, 0x44])
        let resource = CloudPhotoSizeMediaResource(datacenterId: 1, photoId: 101, accessHash: 0, sizeSpec: "x", size: 4, fileReference: nil)
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 101), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 2, height: 2), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        postbox.mediaBox.storeResourceData(resource.id, data: bytes, synchronous: true)
        try self.seed(postbox, messages: [self.stored(id: 1, media: [image]), self.stored(id: 2, media: [image])])
        _ = try self.value(postbox.transaction { transaction -> Bool in
            let result = exteralessRetainBeforeDelete(transaction: transaction, mediaBox: postbox.mediaBox, ids: [1, 2].map { MessageId(peerId: self.senderId, namespace: 0, id: $0) }, policy: self.policy)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.captured, 2)
            return true
        })
        let viewKey = PostboxViewKey.cachedItem(exteralessRetentionIndexId)
        let stored = try self.value(postbox.combinedView(keys: [viewKey]) |> map { view -> ExteralessRetentionMediaEntry? in
            guard let data = (view.views[viewKey] as? CachedItemView)?.value?.data,
                  let index = try? JSONDecoder().decode(ExteralessRetentionIndex.self, from: data), index.media.count == 1,
                  let entry = index.media[resource.id.stringRepresentation], entry.state == .stored else { return nil }
            return entry
        } |> filter { $0 != nil } |> take(1))
        let entry = try XCTUnwrap(stored)
        _ = try self.value(postbox.mediaBox.removeCachedResources([resource.id], force: true))
        let file = try self.value(owner.materialize(resourceId: entry.id, pathExtension: "jpg")).get()
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        for messageId in [Int32(1), Int32(2)] {
            let cleared: Result<Bool, Error> = try self.value(postbox.transaction { transaction in
                Result {
                    let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: Int64(Date().timeIntervalSince1970))
                    store.remove(RetentionMessageKey(peerId: self.senderId.toInt64(), namespace: 0, id: messageId))
                    owner.didMutate(try store.finish())
                    return true
                }
            })
            XCTAssertTrue(try cleared.get())
            try self.value(owner.cleanupUnownedMedia()).get()
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.url.path), messageId == 1)
        }
        XCTAssertEqual(postbox.mediaBox.fileSizeForId(entry.cacheId), 0)
    }

    func testAyuSQLiteSchemaConvertsToNativeArchiveAndRepeatedMergeIsIdempotent() throws {
        let root = try self.temporaryDirectory()
        let url = root.appendingPathComponent("database-export.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE DeletedMessage (fakeId INTEGER, userId INTEGER, dialogId INTEGER, messageId INTEGER, date INTEGER, entityCreateDate INTEGER, editDate INTEGER, flags INTEGER, text TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO DeletedMessage VALUES (10, 700001, 700002, 55, 100, \(now), 0, 0, 'from Android')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO DeletedMessage VALUES (11, 999999, 700002, 56, 100, \(now), 0, 0, 'other account')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        let source = try ExteralessAyuDatabaseReader().read(url: url)
        let postbox = try self.postbox()
        for expected in [1, 0] {
            let result: Result<ExteralessAyuImportReceipt, Error> = try self.value(postbox.transaction { transaction in
                Result {
                    try exteralessImportAyuDatabase(source, transaction: transaction, accountPeerId: self.accountPeer, mediaBox: postbox.mediaBox, peerMappings: [:], policy: self.policy, now: now, didMutate: { _ in })
                }
            })
            let receipt = try result.get()
            XCTAssertEqual(receipt.importedVersions, expected)
            XCTAssertEqual(receipt.otherAccounts, 1)
        }
        let result: Result<Bool, Error> = try self.value(postbox.transaction { transaction in
            Result {
                let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: self.accountPeer, policy: self.policy, now: now)
                let record = try XCTUnwrap(store.record(RetentionMessageKey(peerId: self.senderId.toInt64(), namespace: 0, id: 55)))
                let version = try XCTUnwrap(record.versions.first)
                let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
                XCTAssertEqual(snapshot.text, "from Android")
                XCTAssertNotNil(snapshot.ayuSource)
                XCTAssertNil(transaction.getMessage(record.key.messageId))
                XCTAssertNil(transaction.getState())
                return true
            }
        })
        XCTAssertTrue(try result.get())
    }

    func testAyuUnknownColumnsAreRejectedBeforeTargetMutation() throws {
        let url = try self.temporaryDirectory().appendingPathComponent("future.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE DeletedMessage (userId INTEGER, dialogId INTEGER, messageId INTEGER, date INTEGER, entityCreateDate INTEGER, editDate INTEGER, flags INTEGER, text TEXT, futureUnknown TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        XCTAssertThrowsError(try ExteralessAyuDatabaseReader().read(url: url))
    }
}
