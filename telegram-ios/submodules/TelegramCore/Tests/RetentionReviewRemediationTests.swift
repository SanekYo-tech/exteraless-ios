import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit
import XCTest
@testable import TelegramCore

func retentionReviewConfiguration(root: URL, role: ExteralessRetentionProcessRole = .mainApplication, days: Int64 = 30) throws -> ExteralessRetentionProcessConfiguration {
    var values = Dictionary(uniqueKeysWithValues: RetentionFeatures.definitions.map { ($0.key, $0.defaultValue) })
    values["privacy.enableSaveDeletedMessages"] = .bool(true)
    values["privacy.enableSaveEditsHistory"] = .bool(true)
    values["privacy.retentionDays"] = .integer(days)
    return try ExteralessRetentionProcessConfiguration(role: role, snapshot: ClientSettingsSnapshot(definitions: RetentionFeatures.definitions, values: values, storedKeys: Set(values.keys)), durabilityRootURL: root)
}

private final class RetentionReviewSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { throw ExteralessRetentionError.unavailable }
}

private final class RetentionWeakOwnerBox {
    weak var owner: ExteralessRetentionAccount?
}

/// Actual disposable Postboxes, native retention owners, SQLite-backed rows and four-byte files.
/// No Account/Network/APNs/Share process is created. All waits <=3 s; reset alone <=20 s.
final class RetentionReviewRemediationTests: XCTestCase {
    private var roots: [URL] = []
    private var postboxes: [Postbox] = []
    private var owners: [ExteralessRetentionAccount] = []
    private let accountId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(720001))
    private let senderId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(720002))
    private let hiddenId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(720003))
    private let groupId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(720004))
    private let secretId = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(720005))
    private let now: Int64 = 1_800_000_000
    private var deadline: Double = 0

    override func setUp() { super.setUp(); self.deadline = ProcessInfo.processInfo.systemUptime + 25; initializeAccountManagement() }
    override func tearDown() {
        for owner in self.owners { owner.dispose() }
        self.owners.removeAll(); self.postboxes.removeAll()
        for root in self.roots { try? FileManager.default.removeItem(at: root) }
        self.roots.removeAll(); super.tearDown()
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("retention-review-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        self.roots.append(value); return value
    }
    private func value<T>(_ signal: Signal<T, NoError>, timeout: Double = 3) throws -> T {
        let done = self.expectation(description: "bounded retention adapter")
        var result: T?
        let disposable = signal.start(next: { result = $0 }, completed: { done.fulfill() })
        self.wait(for: [done], timeout: max(0.01, min(timeout, self.deadline - ProcessInfo.processInfo.systemUptime))); disposable.dispose()
        return try XCTUnwrap(result)
    }
    private func transaction<T>(_ postbox: Postbox, _ body: @escaping (Transaction) throws -> T) throws -> T {
        let result: Result<T, Error> = try self.value(postbox.transaction { tx in Result { try body(tx) } })
        return try result.get()
    }
    private func user(_ id: PeerId) -> TelegramUser {
        TelegramUser(id: id, accessHash: nil, firstName: "Fixture", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }
    private func postbox() throws -> Postbox {
        let root = try self.root()
        let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: .init(data: Data(repeating: 0x29, count: 32))!, salt: .init(data: Data(repeating: 0x92, count: 16))!)
        let result = try self.value(openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryption, timestampForAbsoluteTimeBasedOperations: Int32(self.now), isMainProcess: false, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false) |> filter { if case .upgrading = $0 { return false }; return true } |> take(1))
        guard case let .postbox(postbox) = result else { throw ExteralessRetentionError.unavailable }
        self.postboxes.append(postbox)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("fixture attempted non-retention fetch"); return .fail(.generic) }
        try self.transaction(postbox) { tx in
            tx.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: self.accountId, state: .init(pts: 21, qts: 22, date: Int32(self.now), seq: 23), invalidatedChannels: []))
            let group = TelegramChannel(id: self.groupId, accessHash: nil, title: "Synthetic group", username: nil, photo: [], creationDate: 1, version: 0, participationStatus: .member, info: .group(TelegramChannelGroupInfo(flags: [])), flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
            let secret = TelegramSecretChat(id: self.secretId, creationDate: 1, regularPeerId: self.senderId, accessHash: 0, role: .creator, embeddedState: .active, messageAutoremoveTimeout: nil)
            tx.updatePeersInternal([self.user(self.accountId), self.user(self.senderId), self.user(self.hiddenId), group, secret], update: { _, value in value })
        }
        return postbox
    }
    private func message(id: Int32, peer: PeerId? = nil, namespace: Int32 = Namespaces.Message.Cloud, thread: Int64? = nil, group: Int64? = nil, author: PeerId? = nil, text: String = "received", attributes: [MessageAttribute] = [], media: [Media] = [], timestamp: Int32? = nil) -> StoreMessage {
        StoreMessage(id: MessageId(peerId: peer ?? self.groupId, namespace: namespace, id: id), customStableId: nil, globallyUniqueId: nil, groupingKey: group, threadId: thread, timestamp: timestamp ?? Int32(self.now - 100), flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: author ?? self.senderId, text: text, attributes: attributes, media: media)
    }
    private func owner(_ postbox: Postbox, role: ExteralessRetentionProcessRole = .mainApplication, days: Int64 = 30, clock: (() -> Int64)? = nil, fileSystem: RetentionFileSystem = RetentionFileSystem()) throws -> ExteralessRetentionAccount {
        let configuration = try retentionReviewConfiguration(root: URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent(), role: role, days: days)
        let owner = ExteralessRetentionAccount(postbox: postbox, accountPeerId: self.accountId, configuration: configuration, clock: clock ?? { self.now }, fileSystem: fileSystem)
        self.owners.append(owner); return owner
    }
    private func policy(days: Int64 = 30) -> RetentionPolicy {
        RetentionPolicy(values: ["privacy.enableSaveDeletedMessages": .bool(true), "privacy.enableSaveEditsHistory": .bool(true), "privacy.retentionDays": .integer(days)])
    }

    private struct MediaFixture {
        let key: RetentionMessageKey
        let entry: ExteralessRetentionMediaEntry
        let index: ExteralessRetentionIndex
        let vault: ExteralessRetentionMediaVault
    }
    private func mediaFixture(_ postbox: Postbox, capturedAt: Int64) throws -> MediaFixture {
        let resource = CloudPhotoSizeMediaResource(datacenterId: 1, photoId: 91, accessHash: 0, sizeSpec: "x", size: 4, fileReference: nil)
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 91), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 2, height: 2), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        var index = try self.transaction(postbox) { tx -> ExteralessRetentionIndex in
            _ = tx.addMessages([self.message(id: 91, media: [image])], location: .Random)
            let message = try XCTUnwrap(tx.getMessage(MessageId(peerId: self.groupId, namespace: 0, id: 91)))
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: capturedAt)
            XCTAssertTrue(try store.captureDeleted(message, mediaBox: postbox.mediaBox))
            return try store.finish()
        }
        var entry = try XCTUnwrap(index.media[resource.id.stringRepresentation])
        let root = URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent()
        let vault = ExteralessRetentionMediaVault(directory: root.appendingPathComponent("exteraless-retention-media"), durabilityRootURL: root)
        let source = root.appendingPathComponent("fixture-received")
        try Data([1, 2, 3, 4]).write(to: source)
        _ = try vault.fileLock.withLock(cancelled: { false }) {
            try vault.store(source: FileHandle(forReadingFrom: source), length: 4, entry: entry, index: index, cancelled: { false })
        }
        entry.state = .stored; entry.storedBytes = 4; entry.reservedBytes = 4
        index.media[entry.id] = entry
        let committed = index
        try self.transaction(postbox) { tx in tx.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: try exteralessRetentionEncode(committed))) }
        return MediaFixture(key: .init(peerId: self.groupId.toInt64(), namespace: 0, id: 91), entry: entry, index: index, vault: vault)
    }
    private func expectNativeFetchFailure(_ postbox: Postbox, _ entry: ExteralessRetentionMediaEntry) throws {
        let fetch = try XCTUnwrap(exteralessFetchRetainedLocalResource(postbox: postbox, resource: LocalFileMediaResource(fileId: entry.cacheFileId)))
        let done = self.expectation(description: "native retained fetch terminal failure")
        var errors = 0
        let disposable = fetch.start(next: { _ in XCTFail("expired native fetch published bytes") }, error: { _ in errors += 1; done.fulfill() }, completed: { XCTFail("expired fetch succeeded"); done.fulfill() })
        self.wait(for: [done], timeout: max(0.01, min(3, self.deadline - ProcessInfo.processInfo.systemUptime))); disposable.dispose()
        XCTAssertEqual(errors, 1)
    }

    func testUnregisteredSupplementaryScopeCannotPruneNinetyDayArchiveAsThirty() throws {
        let postbox = try self.postbox()
        try self.transaction(postbox) { tx in
            _ = tx.addMessages([self.message(id: 1, timestamp: Int32(self.now - 60 * 86400 - 100))], location: .Random)
            let message = try XCTUnwrap(tx.getMessage(MessageId(peerId: self.groupId, namespace: 0, id: 1)))
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(days: 90), now: self.now - 60 * 86400)
            XCTAssertTrue(try store.captureDeleted(message, mediaBox: postbox.mediaBox)); _ = try store.finish()
        }
        let root = try self.root(), file = root.appendingPathComponent("settings.json")
        let main = try ClientSettings(storageURL: file, secretStore: RetentionReviewSecrets(), durabilityRootURL: root)
        try main.register(RetentionFeatures.definitions)
        try main.set(.integer(90), for: "privacy.retentionDays")
        let share = try ClientSettings(storageURL: file, secretStore: RetentionReviewSecrets(), durabilityRootURL: root)
        XCTAssertThrowsError(try ExteralessRetentionProcessConfiguration(role: .shareExtension, snapshot: share.readSnapshot(), durabilityRootURL: root))
        let unknown = ExteralessRetentionAccount(postbox: postbox, accountPeerId: self.accountId)
        unknown.refresh(prune: true)
        try self.transaction(postbox) { tx in XCTAssertEqual(try ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId)?.rows.count, 1) }
        unknown.dispose()
        try share.register(RetentionFeatures.definitions)
        let accountRoot = URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent()
        let scoped = ExteralessRetentionAccount(postbox: postbox, accountPeerId: self.accountId, configuration: try .init(role: .shareExtension, snapshot: share.readSnapshot(), durabilityRootURL: accountRoot), clock: { self.now })
        self.owners.append(scoped)
        XCTAssertTrue(try self.value(scoped.ready))
        scoped.refresh(prune: true)
        try self.transaction(postbox) { tx in XCTAssertEqual(try ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId)?.rows.count, 1) }
        scoped.dispose()
        let mainThirty = try self.owner(postbox, days: 30)
        XCTAssertTrue(try self.value(mainThirty.ready))
        try self.transaction(postbox) { tx in XCTAssertTrue(try ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId)?.rows.isEmpty == true) }
    }

    func testStandaloneWriterActuallyCapturesBeforeUpsertAndDeletion() throws {
        let postbox = try self.postbox()
        try self.transaction(postbox) { tx in _ = tx.addMessages([self.message(id: 1, text: "old")], location: .Random) }
        let owner = try self.owner(postbox, role: .notificationService)
        XCTAssertTrue(try self.value(owner.ready))
        try self.transaction(postbox) { tx in
            let id = MessageId(peerId: self.groupId, namespace: 0, id: 1)
            _ = tx.addMessages([self.message(id: 1, text: "edited")], location: .Random)
            XCTAssertEqual(exteralessRetainBeforeDelete(transaction: tx, mediaBox: postbox.mediaBox, ids: [id]).captured, 1)
            tx.deleteMessages([id], forEachMedia: nil)
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: self.now)
            let record = try XCTUnwrap(store.record(RetentionMessageKey(peerId: self.groupId.toInt64(), namespace: 0, id: 1)))
            XCTAssertEqual(record.versions.map(\.reason), [.edit, .deleted])
            XCTAssertEqual(try record.versions.map { try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: $0.payload).text }, ["old", "edited"])
            XCTAssertNil(tx.getMessage(id))
            XCTAssertEqual((tx.getState() as? AuthorizedAccountState)?.state?.pts, 21)
            XCTAssertEqual((tx.getState() as? AuthorizedAccountState)?.state?.qts, 22)
            XCTAssertEqual((tx.getState() as? AuthorizedAccountState)?.state?.seq, 23)
        }
    }

    func testSecretIncomingAndLocalUseSeparateKeysAndOneRangeBudget() throws {
        let postbox = try self.postbox(), owner = try self.owner(postbox, role: .notificationService)
        XCTAssertTrue(try self.value(owner.ready))
        try self.transaction(postbox) { tx in
            let namespaces = [Namespaces.Message.Local, Namespaces.Message.SecretIncoming]
            _ = tx.addMessages(namespaces.flatMap { ns in [1, 2, 3].map { self.message(id: Int32($0), peer: self.secretId, namespace: ns) } }, location: .Random)
            for namespace in namespaces {
                let explicit = MessageId(peerId: self.secretId, namespace: namespace, id: 1)
                XCTAssertEqual(exteralessRetainBeforeDelete(transaction: tx, mediaBox: postbox.mediaBox, ids: [explicit]).captured, 1)
                _internal_deleteMessages(transaction: tx, mediaBox: postbox.mediaBox, ids: [explicit])
                let ttl = MessageId(peerId: self.secretId, namespace: namespace, id: 2)
                XCTAssertEqual(exteralessRetainBeforeDelete(transaction: tx, mediaBox: postbox.mediaBox, ids: [ttl]).captured, 1)
                _internal_deleteMessages(transaction: tx, mediaBox: postbox.mediaBox, ids: [ttl])
            }
            let first = exteralessRetainBeforeRangeDeletion(transaction: tx, mediaBox: postbox.mediaBox, peerId: self.secretId, namespaces: namespaces, maxId: Int32.max, scanLimit: 1)
            XCTAssertEqual(first.captured, 1); XCTAssertTrue(first.bounded)
            let rest = exteralessRetainBeforeRangeDeletion(transaction: tx, mediaBox: postbox.mediaBox, peerId: self.secretId, namespaces: namespaces, maxId: Int32.max)
            XCTAssertEqual(rest.captured, 1)
            _internal_clearHistory(transaction: tx, mediaBox: postbox.mediaBox, peerId: self.secretId, threadId: nil, namespaces: .all)
            let index = try XCTUnwrap(ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId))
            XCTAssertEqual(index.rows.count, 6)
            XCTAssertEqual(Set(index.rows.values.map { $0.key.namespace }), Set(namespaces))
            XCTAssertEqual((tx.getState() as? AuthorizedAccountState)?.state?.seq, 23)
        }
    }

    func testRetainedSnapshotsRespectSenderReplyRegexAndReactionProjection() throws {
        let postbox = try self.postbox()
        try self.transaction(postbox) { tx in
            let reply = ReplyMessageAttribute(messageId: MessageId(peerId: self.groupId, namespace: 0, id: 1), threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil)
            let reactions = ReactionsMessageAttribute(canViewList: true, isTags: false, reactions: [.init(value: .builtin("x"), count: 5, chosenOrder: nil)], recentPeers: [.init(value: .builtin("x"), isLarge: false, isUnseen: false, isMy: false, peerId: self.hiddenId, timestamp: nil)], topPeers: [])
            _ = tx.addMessages([self.message(id: 1, author: self.hiddenId), self.message(id: 2, attributes: [reply]), self.message(id: 3, text: "blocked text"), self.message(id: 4, attributes: [reactions]), self.message(id: 5, thread: 7, group: 88, text: "clean")], location: .Random)
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: self.now)
            for id in 1 ... 5 { XCTAssertTrue(try store.captureDeleted(XCTUnwrap(tx.getMessage(MessageId(peerId: self.groupId, namespace: 0, id: Int32(id)))), mediaBox: postbox.mediaBox)) }
            let index = try store.finish()
            var entries: [ExteralessRetentionEntry] = []
            for row in index.rows.values.sorted(by: { $0.key.id < $1.key.id }) {
                let version = try XCTUnwrap(store.record(row.key)?.versions.first)
                entries.append(try exteralessRetentionEntry(version: version, key: row.key, index: index, transaction: tx))
            }
            var configuration = FilteringConfiguration()
            configuration.customFilteredUsers = [self.hiddenId.toInt64()]
            configuration.regexFiltersEnabled = true
            configuration.sharedRules = [.init(regex: "blocked")]
            let identity = PrivacyExtrasAccountIdentity(recordId: 1, userId: self.accountId.id._internalGetInt64Value(), testingEnvironment: false)
            let policy = FilteringPolicy(account: identity, configuration: configuration)
            let visible = retentionFilterDisplayEntries(entries, liveMessages: [], policy: policy, generation: 1, translated: false)
            XCTAssertEqual(visible.map { $0.message.id.id }, [4, 5])
            let projected = try XCTUnwrap(visible.first?.message.attributes.first(where: { $0 is ReactionsMessageAttribute }) as? ReactionsMessageAttribute)
            XCTAssertEqual(projected.reactions.first?.count, 4)
            let again = retentionFilterDisplayEntries(visible, liveMessages: [], policy: policy, generation: 2, translated: false)
            XCTAssertEqual((again.first?.message.attributes.first(where: { $0 is ReactionsMessageAttribute }) as? ReactionsMessageAttribute)?.reactions.first?.count, 4)
            XCTAssertEqual((tx.getMessage(MessageId(peerId: self.groupId, namespace: 0, id: 4))?.reactionsAttribute)?.reactions.first?.count, 5)
            _ = tx.addMessages([self.message(id: 6, thread: 7, group: 88, text: "blocked album")], location: .Random)
            let albumContext = try XCTUnwrap(tx.getMessage(MessageId(peerId: self.groupId, namespace: 0, id: 6)))
            XCTAssertTrue(retentionFilterDisplayEntries([entries[4]], liveMessages: [albumContext], policy: policy, generation: 3, translated: false).isEmpty)
            let other = FilteringPolicy(account: .init(recordId: 2, userId: 999, testingEnvironment: false), configuration: configuration)
            XCTAssertTrue(retentionFilterDisplayEntries(entries, liveMessages: [], policy: other, generation: 0, translated: false).isEmpty)
            XCTAssertEqual((tx.getState() as? AuthorizedAccountState)?.state?.pts, 21)
        }
    }

    func testAlbumIdentityAllocatorSeparatesNamespaceThreadAndPeerAndSurvivesReread() throws {
        let postbox = try self.postbox()
        try self.transaction(postbox) { tx in
            let messages = [self.message(id: 1, peer: self.secretId, namespace: 1, thread: 7, group: 88), self.message(id: 1, peer: self.secretId, namespace: 2, thread: 7, group: 88), self.message(id: 2, peer: self.secretId, namespace: 2, thread: 8, group: 88), self.message(id: 3, peer: self.groupId, thread: 7, group: 88), self.message(id: 4, peer: self.secretId, namespace: 2, thread: 7, group: 88)]
            _ = tx.addMessages(messages, location: .Random)
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: self.now)
            var raw: [Message] = []
            for message in messages { if case let .Id(id) = message.id { raw.append(try XCTUnwrap(tx.getMessage(id))) } }
            for message in raw { XCTAssertTrue(try store.captureDeleted(message, mediaBox: postbox.mediaBox)) }
            let index = try store.finish()
            let ids = try raw.map { try XCTUnwrap(RetentionAlbumIdentities.resolve(transaction: tx, index: index, message: $0)) }
            XCTAssertEqual(Set(ids).count, 4)
            XCTAssertEqual(ids[1], ids[4])
            XCTAssertTrue(ids.allSatisfy { $0 != 88 })
            XCTAssertEqual(try RetentionAlbumIdentities.resolve(transaction: tx, index: index, message: raw[1]), ids[1])
        }
    }

    func testNativeFetchRejectsExpiryWithoutAnyPruneEvent() throws {
        let postbox = try self.postbox()
        let fixture = try self.mediaFixture(postbox, capturedAt: self.now - 1)
        let clock = Atomic<Int64>(value: self.now)
        let owner = try self.owner(postbox, role: .notificationService, days: 1, clock: { clock.with { $0 } })
        XCTAssertTrue(try self.value(owner.ready))
        let file = try self.value(owner.materialize(resourceId: fixture.entry.id, versionOwner: .init(messageId: fixture.key.messageId, sequence: 1))).get()
        XCTAssertEqual(try Data(contentsOf: file.url), Data([1, 2, 3, 4]))
        _ = clock.swap(self.now + 86400)
        try self.expectNativeFetchFailure(postbox, fixture.entry)
        let scoped = try self.value(owner.materialize(resourceId: fixture.entry.id, versionOwner: .init(messageId: fixture.key.messageId, sequence: 1)))
        if case .success = scoped { XCTFail("version-scoped materialization bypassed expiry") }
        try self.transaction(postbox) { tx in
            XCTAssertNotNil(try ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId)?.media[fixture.entry.id])
        }
    }

    func testNativeFetchRechecksExpiryAfterAuthenticatingAndRestoringBytes() throws {
        let postbox = try self.postbox(), fixture = try self.mediaFixture(postbox, capturedAt: self.now - 1)
        let clock = Atomic<Int64>(value: self.now)
        var fs = RetentionFileSystem()
        let liveSync = fs.synchronizeFile
        fs.synchronizeFile = { handle, url in
            try liveSync(handle, url)
            if url.lastPathComponent.hasPrefix(".exteraless-restore-") { _ = clock.swap(self.now + 86400) }
        }
        let owner = try self.owner(postbox, role: .notificationService, days: 1, clock: { clock.with { $0 } }, fileSystem: fs)
        XCTAssertTrue(try self.value(owner.ready))
        try self.expectNativeFetchFailure(postbox, fixture.entry)
        XCTAssertEqual(clock.with { $0 }, self.now + 86400)
    }

    private func nativeCopies(_ postbox: Postbox, fixture: MediaFixture) throws -> (paths: [String], foreign: URL) {
        postbox.mediaBox.storeResourceData(fixture.entry.cacheId, data: Data([1, 2, 3, 4]), synchronous: true)
        let alias = try self.value(postbox.mediaBox.resourceData(id: fixture.entry.cacheId, pathExtension: "jpg") |> take(1))
        XCTAssertTrue(alias.complete)
        let cache = URL(fileURLWithPath: postbox.mediaBox.basePath).appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let derived = cache.appendingPathComponent(fixture.entry.cacheId.stringRepresentation + ":fixture")
        let foreign = cache.appendingPathComponent("foreign-resource:fixture")
        try Data([1, 2, 3, 4]).write(to: derived); try Data([9, 9, 9, 9]).write(to: foreign)
        try FileManager.default.removeItem(at: fixture.vault.file(for: fixture.entry))
        return ([postbox.mediaBox.storePathsForId(fixture.entry.cacheId).complete, alias.path, derived.path], foreign)
    }

    func testMessageClearUsesDurableOwnershipWhenCiphertextIsMissing() throws {
        let postbox = try self.postbox(), fixture = try self.mediaFixture(postbox, capturedAt: self.now - 1)
        let files = try self.nativeCopies(postbox, fixture: fixture)
        let owner = try self.owner(postbox)
        XCTAssertTrue(try self.value(owner.ready))
        try self.transaction(postbox) { tx in
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: self.now)
            store.remove(fixture.key)
            let index = try store.finish()
            XCTAssertEqual(try RetentionMediaOwnership.load(transaction: tx, accountPeerId: self.accountId).owned[fixture.entry.token], fixture.entry.cacheId.stringRepresentation)
            owner.didMutate(index)
        }
        try self.value(owner.cleanupUnownedMedia()).get()
        for path in files.paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        XCTAssertEqual(try Data(contentsOf: files.foreign), Data([9, 9, 9, 9]))
        try self.transaction(postbox) { tx in XCTAssertNil(try RetentionMediaOwnership.load(transaction: tx, accountPeerId: self.accountId).owned[fixture.entry.token]) }
    }

    func testInterruptedFullResetResumesJournalWithNoCiphertextFilename() throws {
        let postbox = try self.postbox(), fixture = try self.mediaFixture(postbox, capturedAt: self.now - 1)
        let files = try self.nativeCopies(postbox, fixture: fixture)
        try self.transaction(postbox) { tx in
            var ownership = try RetentionMediaOwnership.load(transaction: tx, accountPeerId: self.accountId)
            try ownership.retire([fixture.entry]); try ownership.save(transaction: tx)
            tx.putItemCacheEntry(id: exteralessRetentionResetId, entry: CodableEntry(data: Data([1])))
            tx.removeItemCacheEntry(id: exteralessRetentionIndexId)
        }
        let owner = try self.owner(postbox)
        XCTAssertTrue(try self.value(owner.ready, timeout: 20))
        for path in files.paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.foreign.path))
        try self.transaction(postbox) { tx in
            XCTAssertNil(tx.retrieveItemCacheEntry(id: exteralessRetentionResetId))
            XCTAssertTrue(try RetentionMediaOwnership.load(transaction: tx, accountPeerId: self.accountId).owned.isEmpty)
        }
    }

    func testFailedParentSyncIsRepeatedAfterAuthenticatedRenameRecovery() throws {
        let root = try self.root()
        let account = root.appendingPathComponent("account", isDirectory: true)
        let directory = account.appendingPathComponent("vault", isDirectory: true)
        let source = root.appendingPathComponent("received")
        try Data([1, 2, 3, 4]).write(to: source)
        var fs = RetentionFileSystem(), paths: [String] = [], fail = true
        let liveSync = fs.synchronizeDirectory
        fs.synchronizeDirectory = { url in
            paths.append(url.path)
            if url.path == account.path && fail { fail = false; throw ExteralessRetentionError.mediaIO }
            try liveSync(url)
        }
        let vault = ExteralessRetentionMediaVault(directory: directory, durabilityRootURL: root, fileSystem: fs)
        let index = ExteralessRetentionIndex(accountPeerId: self.accountId)
        let entry = ExteralessRetentionMediaEntry(id: "four-bytes", capturedAt: self.now, reservedBytes: 4)
        XCTAssertThrowsError(try vault.store(source: FileHandle(forReadingFrom: source), length: 4, entry: entry, index: index, cancelled: { false }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try vault.file(for: entry).path))
        paths.removeAll()
        XCTAssertEqual(try vault.recover(entry: entry, index: index, expectedLength: 4, cancelled: { false }), 4)
        XCTAssertEqual(paths, [directory.path, account.path, root.path])
        var corrupted = try Data(contentsOf: vault.file(for: entry))
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: vault.file(for: entry))
        paths.removeAll()
        XCTAssertThrowsError(try vault.recover(entry: entry, index: index, expectedLength: 4, cancelled: { false }))
        XCTAssertTrue(paths.isEmpty)
    }

    func testSeparateFileHandlesSerializePublicationAndDeletion() throws {
        let root = try self.root()
        let writer = RetentionFileLock(accountRoot: root), collector = RetentionFileLock(accountRoot: root)
        let entered = self.expectation(description: "writer owns lock"), completed = self.expectation(description: "collector completes")
        let release = DispatchSemaphore(value: 0)
        let writing = Atomic<Bool>(value: false)
        Queue.concurrentDefaultQueue().async {
            do {
                try writer.withLock(cancelled: { false }) {
                    _ = writing.swap(true); entered.fulfill()
                    guard release.wait(timeout: .now() + 1) == .success else { throw ExteralessRetentionError.cancelled }
                    _ = writing.swap(false)
                }
            } catch { XCTFail("writer lock failed: \(error)") }
        }
        self.wait(for: [entered], timeout: max(0.01, min(2, self.deadline - ProcessInfo.processInfo.systemUptime)))
        Queue.concurrentDefaultQueue().async {
            do { try collector.withLock(cancelled: { false }) { XCTAssertFalse(writing.with { $0 }) } }
            catch { XCTFail("collector lock failed: \(error)") }
            completed.fulfill()
        }
        Queue.concurrentDefaultQueue().after(0.05) { release.signal() }
        self.wait(for: [completed], timeout: max(0.01, min(2, self.deadline - ProcessInfo.processInfo.systemUptime)))
    }

    private func pause(_ postbox: Postbox) {
        let paused = self.expectation(description: "Postbox paused before admission")
        postbox.setCanBeginTransactions(false, afterTransactionIfRunning: { paused.fulfill() })
        self.wait(for: [paused], timeout: max(0.01, min(0.5, self.deadline - ProcessInfo.processInfo.systemUptime)))
    }

    func testPFR01UnavailableRevokesQueuedPruneAndOnlyNewerRecoveryCanResume() throws {
        let postbox = try self.postbox()
        try self.transaction(postbox) { tx in
            _ = tx.addMessages([self.message(id: 1, timestamp: Int32(self.now - 60 * 86400 - 100))], location: .Random)
            let message = try XCTUnwrap(tx.getMessage(MessageId(peerId: self.groupId, namespace: 0, id: 1)))
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(days: 90), now: self.now - 60 * 86400)
            XCTAssertTrue(try store.captureDeleted(message, mediaBox: postbox.mediaBox)); _ = try store.finish()
        }
        let root = try self.root()
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: RetentionReviewSecrets(), durabilityRootURL: root)
        try settings.register(RetentionFeatures.definitions)
        try settings.set(.integer(90), for: "privacy.retentionDays")
        let accountRoot = URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent()
        func configuration(_ snapshot: ClientSettingsSnapshot) throws -> ExteralessRetentionProcessConfiguration {
            try .init(role: .mainApplication, snapshot: snapshot, durabilityRootURL: accountRoot)
        }
        let ninety = try configuration(settings.readSnapshot())
        let owner = ExteralessRetentionAccount(postbox: postbox, accountPeerId: self.accountId, configurationState: .init(version: 1, availability: .available(ninety)), clock: { self.now })
        self.owners.append(owner)
        let originalToken = try self.value(owner.awaitReadiness()).get()
        self.pause(postbox)
        defer { postbox.setCanBeginTransactions(true) }
        try settings.set(.integer(30), for: "privacy.retentionDays")
        let thirty = try configuration(settings.readSnapshot())
        XCTAssertTrue(owner.updateConfiguration(.init(version: 2, availability: .available(thirty))))
        let pendingTerminated = self.expectation(description: "unavailable revokes an existing readiness waiter")
        var pendingResults = 0
        let pending = owner.awaitReadiness(timeout: 1).start(next: { result in
            pendingResults += 1
            if case let .failure(error) = result { XCTAssertEqual(error, .configurationUnavailable) }
            else { XCTFail("old readiness waiter survived invalid configuration") }
        }, completed: { pendingTerminated.fulfill() })
        defer { pending.dispose() }
        try settings.set(.integer(90), for: "privacy.retentionDays")
        let committed = settings.readSnapshot()
        // Inject the post-commit failure receipt at this owner boundary. The environment's
        // actual settings-fsync fault/publication test belongs to the App owner.
        let failed = ClientSettingsSnapshot(definitions: committed.definitions, values: committed.values, storedKeys: committed.storedKeys, lastError: .storageFailure(operation: "sync-directory", code: 5))
        XCTAssertThrowsError(try configuration(failed))
        XCTAssertTrue(owner.updateConfiguration(.init(version: 3, availability: .unavailable)))
        self.wait(for: [pendingTerminated], timeout: max(0.01, min(0.5, self.deadline - ProcessInfo.processInfo.systemUptime)))
        XCTAssertEqual(pendingResults, 1)
        XCTAssertNil(owner.loadedPolicy)
        XCTAssertFalse(owner.performsMaintenance)
        XCTAssertFalse(owner.isReadinessCurrent(originalToken))
        if case let .failure(error) = try self.value(owner.awaitReadiness(timeout: 0.2)) { XCTAssertEqual(error, .configurationUnavailable) }
        else { XCTFail("unavailable owner published ready") }
        XCTAssertFalse(owner.updateConfiguration(.init(version: 2, availability: .available(thirty))))
        postbox.setCanBeginTransactions(true)
        try self.transaction(postbox) { tx in XCTAssertEqual(try ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId)?.rows.count, 1) }
        XCTAssertTrue(owner.updateConfiguration(.init(version: 4, availability: .available(try configuration(committed)))))
        let recovered = try self.value(owner.awaitReadiness()).get()
        XCTAssertTrue(owner.isReadinessCurrent(recovered))
        XCTAssertFalse(owner.updateConfiguration(.init(version: 3, availability: .unavailable)))
        XCTAssertTrue(owner.isReadinessCurrent(recovered))
        XCTAssertEqual(owner.loadedPolicy?.days, 90)
        try self.transaction(postbox) { tx in XCTAssertEqual(try ExteralessRetentionIndex.load(transaction: tx, accountPeerId: self.accountId)?.rows.count, 1) }
    }

    func testPFR01RecoveredPolicyCannotReviveAnOldMediaWorkEpoch() throws {
        let postbox = try self.postbox(), fixture = try self.mediaFixture(postbox, capturedAt: self.now - 1)
        let root = URL(fileURLWithPath: postbox.mediaBox.basePath).deletingLastPathComponent()
        let configuration = try retentionReviewConfiguration(root: root, role: .notificationService)
        let box = RetentionWeakOwnerBox()
        var fs = RetentionFileSystem()
        let liveSync = fs.synchronizeFile
        fs.synchronizeFile = { handle, url in
            try liveSync(handle, url)
            if url.lastPathComponent.hasPrefix(".exteraless-restore-"), let owner = box.owner {
                XCTAssertTrue(owner.updateConfiguration(.init(version: 1, availability: .unavailable)))
                XCTAssertTrue(owner.updateConfiguration(.init(version: 2, availability: .available(configuration))))
            }
        }
        let owner = try self.owner(postbox, role: .notificationService, fileSystem: fs)
        box.owner = owner
        _ = try self.value(owner.awaitReadiness()).get()
        let result = try self.value(owner.materialize(resourceId: fixture.entry.id))
        if case let .failure(error) = result { XCTAssertEqual(error, .cancelled) }
        else { XCTFail("old media work survived unavailable/recovery") }
    }

    func testPFR04CorruptIndexFailsTypedReadinessAndRepairContinuesOnce() throws {
        let postbox = try self.postbox()
        let corrupt = Data([0x7b, 0x7d])
        try self.transaction(postbox) { tx in tx.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: corrupt)) }
        let owner = try self.owner(postbox)
        let failed = self.expectation(description: "typed corrupt-index error")
        var firstResults = 0, firstCompletions = 0
        let initial = owner.awaitReadiness(timeout: 1).start(next: { result in
            firstResults += 1
            if case let .failure(error) = result { XCTAssertEqual(error, .archive(.invalidArchive)) }
            else { XCTFail("corrupt index was treated as ready") }
        }, completed: { firstCompletions += 1; failed.fulfill() })
        self.wait(for: [failed], timeout: max(0.01, min(2, self.deadline - ProcessInfo.processInfo.systemUptime)))
        try self.transaction(postbox) { tx in
            XCTAssertEqual(tx.retrieveItemCacheEntry(id: exteralessRetentionIndexId)?.data, corrupt)
            XCTAssertNil(tx.retrieveItemCacheEntry(id: exteralessRetentionResetId))
            tx.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: try exteralessRetentionEncode(ExteralessRetentionIndex(accountPeerId: self.accountId))))
        }
        let token = try self.value(owner.retryReadiness()).get()
        XCTAssertTrue(owner.isReadinessCurrent(token))
        XCTAssertEqual(firstResults, 1); XCTAssertEqual(firstCompletions, 1)
        initial.dispose()
        try self.transaction(postbox) { tx in
            let state = (tx.getState() as? AuthorizedAccountState)?.state
            XCTAssertEqual(state?.pts, 21); XCTAssertEqual(state?.qts, 22); XCTAssertEqual(state?.seq, 23)
        }
    }

    func testPFR04UnsupportedIndexNeedsExplicitResetBeforeRetry() throws {
        let postbox = try self.postbox()
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: exteralessRetentionEncode(ExteralessRetentionIndex(accountPeerId: self.accountId))) as? [String: Any])
        future["formatVersion"] = 99
        let bytes = try JSONSerialization.data(withJSONObject: future)
        try self.transaction(postbox) { tx in tx.putItemCacheEntry(id: exteralessRetentionIndexId, entry: CodableEntry(data: bytes)) }
        let owner = try self.owner(postbox)
        if case let .failure(error) = try self.value(owner.awaitReadiness()) { XCTAssertEqual(error, .archive(.unsupportedFormat)) }
        else { XCTFail("unsupported index was accepted") }
        try self.transaction(postbox) { tx in
            XCTAssertEqual(tx.retrieveItemCacheEntry(id: exteralessRetentionIndexId)?.data, bytes)
            XCTAssertNil(tx.retrieveItemCacheEntry(id: exteralessRetentionResetId))
        }
        try self.value(owner.resetArchiveForRecovery(), timeout: 20).get()
        let token = try self.value(owner.retryReadiness()).get()
        XCTAssertTrue(owner.isReadinessCurrent(token))
        try self.transaction(postbox) { tx in
            XCTAssertNil(tx.retrieveItemCacheEntry(id: exteralessRetentionResetId))
            XCTAssertEqual((tx.getState() as? AuthorizedAccountState)?.state?.pts, 21)
        }
    }

    func testPFR04ReadinessDeadlineTerminatesWithoutInventingSuccess() throws {
        let postbox = try self.postbox()
        self.pause(postbox)
        defer { postbox.setCanBeginTransactions(true) }
        let owner = try self.owner(postbox)
        if case let .failure(error) = try self.value(owner.awaitReadiness(timeout: 0.05)) { XCTAssertEqual(error, .timedOut) }
        else { XCTFail("held initialization was treated as ready") }
        owner.dispose()
        postbox.setCanBeginTransactions(true)
        if case let .failure(error) = try self.value(owner.awaitReadiness(timeout: 0.05)) { XCTAssertEqual(error, .cancelled) }
        else { XCTFail("disposed owner became ready") }
    }

    func testPFR05ReturnedNativeReferenceStillFailsTerminallyAfterGCAndDisposal() throws {
        let postbox = try self.postbox(), fixture = try self.mediaFixture(postbox, capturedAt: self.now - 1)
        let nativeReference: LocalFileMediaResource = try self.transaction(postbox) { tx in
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: self.now)
            let version = try XCTUnwrap(store.record(fixture.key)?.versions.first)
            let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
            let rendered = try snapshot.render(version: version, localMediaIndex: store.index)
            return try XCTUnwrap((rendered.media.first as? TelegramMediaImage)?.representations.first?.resource as? LocalFileMediaResource)
        }
        XCTAssertTrue(nativeReference is ExteralessRetainedLocalFileMediaResource)
        let encoded = PostboxEncoder()
        encoded.encodeRootObject(nativeReference)
        let decoded = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoded.makeData())).decodeRootObject() as? LocalFileMediaResource)
        XCTAssertTrue(decoded is ExteralessRetainedLocalFileMediaResource)
        let owner = try self.owner(postbox)
        _ = try self.value(owner.awaitReadiness()).get()
        let file = try self.value(owner.materialize(resourceId: fixture.entry.id)).get()
        XCTAssertEqual(try Data(contentsOf: file.url), Data([1, 2, 3, 4]))
        try self.transaction(postbox) { tx in
            let store = try ExteralessRetentionStore(transaction: tx, accountPeerId: self.accountId, policy: self.policy(), now: self.now)
            store.remove(fixture.key); owner.didMutate(try store.finish())
        }
        try self.value(owner.cleanupUnownedMedia()).get()
        XCTAssertNil(owner.sourceId(forArchiveResource: nativeReference.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        func reject(_ resource: MediaResource) throws {
            let signal = try XCTUnwrap(exteralessFetchRetainedLocalResource(postbox: postbox, resource: resource))
            let done = self.expectation(description: "retired native ref terminates")
            var failures = 0
            let disposable = signal.start(next: { _ in XCTFail("retired resource produced bytes") }, error: { error in
                if case .generic = error { failures += 1 } else { XCTFail("unexpected fetch error") }
                done.fulfill()
            }, completed: { XCTFail("retired fetch completed successfully"); done.fulfill() })
            self.wait(for: [done], timeout: max(0.01, min(1, self.deadline - ProcessInfo.processInfo.systemUptime))); disposable.dispose()
            XCTAssertEqual(failures, 1)
        }
        try reject(nativeReference)
        try reject(decoded)
        XCTAssertNil(exteralessFetchRetainedLocalResource(postbox: postbox, resource: LocalFileMediaResource(fileId: 0)))
        owner.dispose()
        try reject(nativeReference)
    }
}
