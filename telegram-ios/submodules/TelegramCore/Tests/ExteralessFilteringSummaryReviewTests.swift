import ExteralessCore
import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox
@testable import TelegramCore

/// Actual native projection over a disposable in-memory Postbox. There is no
/// Account, AccountManager, Network, Keychain, retention owner, or server operation.
final class ExteralessFilteringSummaryReviewTests: XCTestCase {
    func testPR01ActualOneRowChatListOffAndOnForOrdinaryForumAndSecret() throws {
        let db = try FilteringSummaryPostboxFixture()
        defer { db.close() }
        for kind in FilteringSummaryPostboxFixture.Kind.allCases {
            let seeded = try db.seed(kind: kind, text: "block this message")
            let before = try db.snapshot(peerId: seeded.peerId, ids: [seeded.id], thread: seeded.thread)
            let list = try db.list(peerId: seeded.peerId, top: seeded.id, thread: seeded.thread)
            try db.settings.set(.bool(false), for: "privacy.regexFiltersEnabled")
            let off = try db.value(exteralessFilterChatList(account: db.identity, postbox: db.postbox, list: list, runtime: db.runtime))
            XCTAssertTrue(off === list)
            XCTAssertEqual(off.items.first?.messages.map(\.id), [seeded.id])
            // Exercise the inactive per-chat implementation too: no preview query.
            let inactive = try db.transaction { transaction in
                exteralessFilteredChatSummary(account: db.identity, transaction: transaction, peerId: seeded.peerId, threadId: seeded.thread, runtime: db.runtime)
            }
            XCTAssertFalse(inactive.filteringActive)
            XCTAssertNil(inactive.preview)

            try db.settings.set(.bool(true), for: "privacy.regexFiltersEnabled")
            let on = try db.value(exteralessFilterChatList(account: db.identity, postbox: db.postbox, list: list, runtime: db.runtime))
            let item = try XCTUnwrap(on.items.first)
            XCTAssertTrue(item.messages.isEmpty)
            XCTAssertEqual(item.readCounters?.count, 0)
            XCTAssertEqual(item.draft?.text, "keep draft")
            XCTAssertEqual(item.id, list.items[0].id)
            XCTAssertEqual(item.index, list.items[0].index)
            XCTAssertEqual(item.hasFailed, list.items[0].hasFailed)
            let after = try db.snapshot(peerId: seeded.peerId, ids: [seeded.id], thread: seeded.thread)
            XCTAssertEqual(before, after)
        }
    }

    func testPR01ActiveForumPagesStayInTheRequestedThread() throws {
        let db = try FilteringSummaryPostboxFixture()
        defer { db.close() }
        let seeded = try db.seed(kind: .forum, text: "clean requested topic")
        let foreign = MessageId(peerId: seeded.peerId, namespace: Namespaces.Message.Cloud, id: 99)
        try db.transaction { transaction in
            _ = transaction.addMessages([db.message(foreign, thread: 999, timestamp: 999, incoming: true, text: "block other topic")], location: .Random)
        }
        try db.settings.set(.bool(true), for: "privacy.regexFiltersEnabled")
        let list = try db.list(peerId: seeded.peerId, top: seeded.id, thread: seeded.thread)
        let projected = try db.value(exteralessFilterChatList(account: db.identity, postbox: db.postbox, list: list, runtime: db.runtime))
        XCTAssertEqual(projected.items.first?.messages.map(\.id), [seeded.id])
        XCTAssertEqual(projected.items.first?.readCounters?.count, 1)
    }

    func testPR06SecretIncomingAndLocalUseDistinctNativeRowsAndOneBudget() throws {
        let db = try FilteringSummaryPostboxFixture()
        defer { db.close() }
        let seeded = try db.seed(kind: .secret, text: "block incoming")
        let outgoing = MessageId(peerId: seeded.peerId, namespace: Namespaces.Message.Local, id: seeded.id.id)
        try db.transaction { transaction in
            _ = transaction.addMessages([db.message(outgoing, timestamp: 50, incoming: false, text: "outgoing preview")], location: .Random)
            transaction.resetIncomingReadStates([seeded.peerId: [
                Namespaces.Message.SecretIncoming: db.secretReadState(peer: seeded.peerId, namespace: Namespaces.Message.SecretIncoming, count: 1),
                Namespaces.Message.Local: db.secretReadState(peer: seeded.peerId, namespace: Namespaces.Message.Local, count: 0)
            ]])
        }
        try db.settings.set(.bool(true), for: "privacy.regexFiltersEnabled")
        let before = try db.snapshot(peerId: seeded.peerId, ids: [seeded.id, outgoing], thread: nil)
        let projected = try db.transaction { transaction in
            var work = FilteringWorkBudget(operations: 2_000)
            var rows = 2
            let result = extrasChatSummary(account: db.identity, transaction: transaction, peerId: seeded.peerId, threadId: nil, budget: &work, remainingMessages: &rows, runtime: db.runtime)
            return (result, rows)
        }
        XCTAssertEqual(projected.1, 0)
        XCTAssertEqual(projected.0.unreadCount, 0)
        XCTAssertEqual(projected.0.knownHiddenUnread, 1)
        XCTAssertEqual(projected.0.preview?.id, outgoing)
        let after = try db.snapshot(peerId: seeded.peerId, ids: [seeded.id, outgoing], thread: nil)
        XCTAssertEqual(before, after)

        // A smaller shared budget cannot fabricate a complete two-namespace preview.
        let bounded = try db.transaction { transaction in
            var work = FilteringWorkBudget(operations: 100)
            var rows = 1
            let result = extrasChatSummary(account: db.identity, transaction: transaction, peerId: seeded.peerId, threadId: nil, budget: &work, remainingMessages: &rows, runtime: db.runtime)
            return (result, rows)
        }
        XCTAssertEqual(bounded.1, 0)
        XCTAssertNil(bounded.0.preview)
    }

    func testPR06IdenticalNumericIdsDoNotMergeUnreadAcrossNamespaces() throws {
        let db = try FilteringSummaryPostboxFixture()
        defer { db.close() }
        let seeded = try db.seed(kind: .secret, text: "block current incoming")
        let legacy = MessageId(peerId: seeded.peerId, namespace: Namespaces.Message.Local, id: seeded.id.id)
        try db.transaction { transaction in
            _ = transaction.addMessages([db.message(legacy, timestamp: 50, incoming: true, text: "block legacy local incoming")], location: .Random)
            transaction.resetIncomingReadStates([seeded.peerId: [
                Namespaces.Message.SecretIncoming: db.secretReadState(peer: seeded.peerId, namespace: Namespaces.Message.SecretIncoming, count: 1),
                Namespaces.Message.Local: db.secretReadState(peer: seeded.peerId, namespace: Namespaces.Message.Local, count: 1)
            ]])
        }
        try db.settings.set(.bool(true), for: "privacy.regexFiltersEnabled")
        let filtered = try db.transaction { transaction in
            exteralessFilteredChatSummary(account: db.identity, transaction: transaction, peerId: seeded.peerId, runtime: db.runtime)
        }
        XCTAssertEqual(filtered.knownHiddenUnread, 2)
        XCTAssertEqual(filtered.unreadCount, 0)
        try db.settings.set(.bool(false), for: "privacy.regexFiltersEnabled")
        let restored = try db.transaction { transaction in
            exteralessFilteredChatSummary(account: db.identity, transaction: transaction, peerId: seeded.peerId, runtime: db.runtime)
        }
        XCTAssertEqual(restored.unreadCount, 2)
        XCTAssertEqual(try db.transaction { [$0.getMessage(seeded.id)?.id, $0.getMessage(legacy)?.id] }, [seeded.id, legacy])
    }
}

private final class FilteringSummaryPostboxFixture {
    enum Kind: CaseIterable { case ordinary, forum, secret }
    struct Seed { let peerId: PeerId; let id: MessageId; let thread: Int64? }
    struct Snapshot: Equatable {
        let ids: [MessageId]
        let texts: [String]
        let read: CombinedPeerReadState
        let thread: MessageHistoryThreadData?
        let state: AuthorizedAccountState.State?
    }
    enum Failure: Error { case timeout }

    let identity = PrivacyExtrasAccountIdentity(recordId: 77100, userId: 77200, testingEnvironment: true)
    let queue = Queue(name: "PrivacyExtrasSummaryFixture")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-extras-summary-" + UUID().uuidString, isDirectory: true)
    let settings: ClientSettings
    let runtime: ExteralessFilteringRuntime
    let senderId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77201))
    private var valueBox: SqliteValueBox?
    private(set) var postbox: Postbox!

    init() throws {
        initializeAccountManagement()
        settings = try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: SummaryFixtureSecrets())
        try settings.register(PrivacyExtrasFeatures.definitions)
        try settings.set(.bool(true), for: "privacy.regexFiltersEnableInChats")
        try settings.set(.object([identity.storageKey: try FilteringConfiguration.value(for: [.init(id: "block", regex: "block")])]), for: "privacy.regexFiltersData")
        runtime = ExteralessFilteringRuntime(settings: settings)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("Privacy fixture attempted network/media fetch"); return .fail(.generic) }
    }

    func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var output: T?
        let disposable = signal.start(next: { output = $0; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 3) == .success else { throw Failure.timeout }
        return try XCTUnwrap(output)
    }
    @discardableResult func transaction<T>(_ body: @escaping (Transaction) throws -> T) throws -> T {
        try value(postbox.transaction { transaction in Result { try body(transaction) } }).get()
    }
    func close() {
        _ = try? value(postbox.mediaBox.storageBox.totalSize())
        postbox = nil
        queue.sync { self.valueBox = nil }
        try? FileManager.default.removeItem(at: root)
    }

    func message(_ id: MessageId, thread: Int64? = nil, timestamp: Int32 = 100, incoming: Bool = true, text: String) -> StoreMessage {
        StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: thread, timestamp: timestamp, flags: incoming ? [.Incoming] : [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: senderId, text: text, attributes: [], media: [])
    }
    func secretReadState(peer: PeerId, namespace: Int32, count: Int32) -> PeerReadState {
        .indexBased(maxIncomingReadIndex: .lowerBound(peerId: peer, namespace: namespace), maxOutgoingReadIndex: .lowerBound(peerId: peer, namespace: namespace), count: count, markedUnread: false)
    }

    func seed(kind: Kind, text: String) throws -> Seed {
        let peerId: PeerId
        switch kind {
        case .ordinary: peerId = senderId
        case .forum: peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(77202))
        case .secret: peerId = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(77203))
        }
        let namespace = kind == .secret ? Namespaces.Message.SecretIncoming : Namespaces.Message.Cloud
        let id = MessageId(peerId: peerId, namespace: namespace, id: 7)
        let thread: Int64? = kind == .forum ? 77 : nil
        try transaction { transaction in
            let user = TelegramUser(id: self.senderId, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            var peers: [Peer] = [user]
            if kind == .forum {
                peers.append(TelegramChannel(id: peerId, accessHash: nil, title: "Synthetic forum", username: nil, photo: [], creationDate: 1, version: 0, participationStatus: .member, info: .group(TelegramChannelGroupInfo(flags: [])), flags: [.isForum], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil))
            } else if kind == .secret {
                peers.append(TelegramSecretChat(id: peerId, creationDate: 1, regularPeerId: self.senderId, accessHash: 0, role: .participant, embeddedState: .active, messageAutoremoveTimeout: nil))
            }
            transaction.updatePeersInternal(peers, update: { _, value in value })
            _ = transaction.addMessages([self.message(id, thread: thread, text: text)], location: .Random)
            let read: PeerReadState = kind == .secret ? self.secretReadState(peer: peerId, namespace: namespace, count: 1) : .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 7, count: 1, markedUnread: false)
            transaction.resetIncomingReadStates([peerId: [namespace: read]])
            if let thread {
                let data = MessageHistoryThreadData(creationDate: 1, isOwnedByMe: false, author: self.senderId, info: .init(title: "Fixture topic", icon: nil, iconColor: 0), incomingUnreadCount: 1, isMarkedUnread: false, maxIncomingReadId: 0, maxKnownMessageId: 7, maxOutgoingReadId: 0, isClosed: false, isHidden: false, notificationSettings: .defaultSettings, isMessageFeeRemoved: false)
                transaction.setMessageHistoryThreadInfo(peerId: peerId, threadId: thread, info: try XCTUnwrap(StoredMessageHistoryThreadInfo(data)))
            }
            transaction.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2, peerId: self.senderId, state: .init(pts: 71, qts: 9, date: 1000, seq: 21), invalidatedChannels: []))
        }
        return Seed(peerId: peerId, id: id, thread: thread)
    }

    func snapshot(peerId: PeerId, ids: [MessageId], thread: Int64?) throws -> Snapshot {
        try transaction { transaction in
            let messages = ids.compactMap { transaction.getMessage($0) }
            return Snapshot(ids: messages.map(\.id), texts: messages.map(\.text), read: CombinedPeerReadState(states: transaction.getPeerReadStates(peerId) ?? []), thread: thread.flatMap { transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: $0)?.data.get(MessageHistoryThreadData.self) }, state: (transaction.getState() as? AuthorizedAccountState)?.state)
        }
    }

    func list(peerId: PeerId, top: MessageId, thread: Int64?) throws -> EngineChatList {
        try transaction { transaction in
            let message = try XCTUnwrap(transaction.getMessage(top))
            let peer = try XCTUnwrap(transaction.getPeer(peerId))
            let data = thread.flatMap { transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: $0)?.data.get(MessageHistoryThreadData.self) }
            let index: EngineChatList.Item.Index = thread.map { .forum(pinnedIndex: .none, timestamp: message.timestamp, threadId: $0, namespace: message.id.namespace, id: message.id.id) } ?? .chatList(ChatListIndex(pinningIndex: nil, messageIndex: message.index))
            let item = EngineChatList.Item(id: thread.map { .forum($0) } ?? .chatList(peerId), index: index, messages: [EngineMessage(message)], readCounters: EnginePeerReadCounters(state: transaction.getCombinedPeerReadState(peerId), isMuted: false), isMuted: false, draft: .init(text: "keep draft", entities: []), threadData: data, renderedPeer: EngineRenderedPeer(peer: EnginePeer(peer)), presence: nil, hasUnseenMentions: false, hasUnseenReactions: false, hasUnseenPollVotes: false, forumTopicData: nil, topForumTopicItems: [], hasFailed: true, isContact: false, autoremoveTimeout: nil, storyStats: nil, displayAsTopicList: false, isPremiumRequiredToMessage: false, mediaDraftContentType: nil)
            return EngineChatList(items: [item], groupItems: [], additionalItems: [], hasEarlier: false, hasLater: false, isLoading: false)
        }
    }
}

private final class SummaryFixtureSecrets: ClientSecretStore, @unchecked Sendable {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { XCTFail("Public filter fixture attempted a secret write") }
}
