import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox
@testable import TelegramCore

/// Production pin replay/reconciliation and badge adapters over real, disposable
/// Postbox transactions. No Account, AccountManager, Network or RPC is started.
final class ExteralessDialogReviewTests: XCTestCase {
    func testIDS03CommittedReorderWinsOverLateUnpinAndOlderAcknowledgement() throws {
        let db = try DialogReviewPostboxFixture(account: 9001)
        defer { db.close() }
        try db.seedPins([1, 2, 3, 4, 5, 6])
        let before = try db.readSnapshot()
        let old = try db.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        // These are separate COMMITTED native transactions, not read-your-writes.
        try db.reorder([6, 1, 2, 3, 4, 5])
        XCTAssertEqual(try db.order(), [6, 1, 2, 3, 4, 5])
        try db.replay(.unpin(.peer(db.peer(6))), enabled: true)
        XCTAssertEqual(try db.order(), [6, 1, 2, 3, 4, 5])
        let newerIntent = try XCTUnwrap(try db.state()).generation
        XCTAssertGreaterThan(newerIntent, old.generation)
        try db.complete(old, local: [1, 2, 3, 4, 5, 6], acknowledged: [1, 2, 3, 4, 5], enabled: true)
        XCTAssertNotNil(try db.state()?.intentOrder)
        XCTAssertEqual(try db.state()?.acknowledgedGeneration, old.generation)

        let fresh = try db.begin(enabled: true)
        XCTAssertEqual(try db.applyReply(fresh, remote: [1, 2, 3, 4, 5], enabled: true), [6, 1, 2, 3, 4, 5])
        let wire = try db.record(fresh, local: [6, 1, 2, 3, 4, 5], wire: [6, 1, 2, 3, 4])
        XCTAssertEqual(wire.serverOrder, db.packed([6, 1, 2, 3, 4]))
        try db.complete(fresh, local: [6, 1, 2, 3, 4, 5], acknowledged: [6, 1, 2, 3, 4], enabled: true)
        XCTAssertNil(try db.state()?.intentOrder)
        XCTAssertEqual(try db.order(), [6, 1, 2, 3, 4, 5])
        XCTAssertEqual(try db.readSnapshot(), before)
    }

    func testIDS03ReverseDeliveryExplicitUnpinAndFailedRPCDoNotResurrectIntent() throws {
        let db = try DialogReviewPostboxFixture(account: 9002)
        defer { db.close() }
        try db.seedPins([1, 2, 3, 4, 5, 6])
        let sent = try db.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        try db.replay(.unpin(.peer(db.peer(6))), enabled: true)
        XCTAssertEqual(try db.order(), [1, 2, 3, 4, 5, 6])
        try db.reorder([6, 1, 2, 3, 4, 5])
        XCTAssertNil(try db.applyReply(sent, remote: [1, 2, 3, 4, 5], enabled: true)) // old read cannot overwrite reorder
        let result = try db.value(_internal_toggleItemPinned(postbox: db.postbox, accountPeerId: db.accountPeerId, location: .group(.root), itemId: .peer(db.peer(6))))
        guard case .done = result else { return XCTFail("Native explicit Unpin was rejected") }
        XCTAssertEqual(try db.order(), [1, 2, 3, 4, 5])
        // An old pin echo also cannot undo the now-committed explicit Unpin.
        try db.replay(.pin(.peer(db.peer(6))), enabled: true)
        XCTAssertEqual(try db.order(), [1, 2, 3, 4, 5])
        let fresh = try db.begin(enabled: true)
        XCTAssertEqual(try db.applyReply(fresh, remote: [6, 1, 2, 3, 4], enabled: true), [1, 2, 3, 4, 5])
        _ = try db.record(fresh, local: [1, 2, 3, 4, 5], wire: [1, 2, 3, 4, 5])
        try db.complete(fresh, local: [1, 2, 3, 4, 5], acknowledged: nil, enabled: true)
        XCTAssertNotNil(try db.state()?.intentOrder)
        XCTAssertNotEqual(try db.state()?.acknowledgedGeneration, fresh.generation)
        XCTAssertNotEqual(try db.state()?.acknowledgedRequestId, fresh.id)
        XCTAssertFalse(try db.order().contains(6))
    }

    func testIDS03AuthoritativeRemoteRemovalIsEventuallyAppliedNotUnconditionallyIgnored() throws {
        let db = try DialogReviewPostboxFixture(account: 9003)
        defer { db.close() }
        try db.seedPins([1, 2, 3, 4, 5, 6])
        let sent = try db.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        try db.complete(sent, local: [1, 2, 3, 4, 5, 6], acknowledged: [1, 2, 3, 4, 5], enabled: true)
        try db.replay(.unpin(.peer(db.peer(2))), enabled: true)
        XCTAssertTrue(try db.order().contains(2)) // provisional only
        let verify = try db.begin(enabled: true)
        let verified = try XCTUnwrap(try db.applyReply(verify, remote: [1, 3, 4, 5], enabled: true))
        XCTAssertFalse(verified.contains(2)) // actual remote absence wins after the read
        XCTAssertTrue(verified.contains(6)) // owned local-only pin remains local
        XCTAssertNil(try db.state()?.intentOrder)
    }

    func testIDS03NativeOperationWatermarkDetectsCommittedABAReturnToSameOrder() throws {
        let db = try DialogReviewPostboxFixture(account: 9004)
        defer { db.close() }
        try db.seedPins([1, 2, 3, 4, 5, 6])
        let old = try db.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        try db.reorder([6, 1, 2, 3, 4, 5])
        try db.reorder([1, 2, 3, 4, 5, 6])
        XCTAssertEqual(try db.order(), [1, 2, 3, 4, 5, 6])
        XCTAssertNil(try db.applyReply(old, remote: [1, 2, 3, 4, 5], enabled: true))
        XCTAssertGreaterThan(try XCTUnwrap(try db.state()).generation, old.generation)
        try db.complete(old, local: [1, 2, 3, 4, 5, 6], acknowledged: [1, 2, 3, 4, 5], enabled: true)
        XCTAssertNotNil(try db.state()?.intentOrder)
    }

    func testIDS03EchoBetweenRealAcknowledgementAndNativeLogCleanupGetsNewWork() throws {
        let db = try DialogReviewPostboxFixture(account: 9005)
        defer { db.close() }
        try db.seedPins([1, 2, 3, 4, 5, 6])
        let sent = try db.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        try db.complete(sent, local: [1, 2, 3, 4, 5, 6], acknowledged: [1, 2, 3, 4, 5], enabled: true, cleanup: false)
        let watermark = try db.watermark()
        try db.replay(.unpin(.peer(db.peer(2))), enabled: true)
        XCTAssertEqual(try db.watermark(), watermark + 1)
        // This is the native manager's separate, later cleanup transaction.
        try db.transaction { _ = $0.operationLogRemoveEntry(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats, tagLocalIndex: sent.operationIndex) }
        XCTAssertTrue(try db.hasOperation())
        let fresh = try db.begin(enabled: true)
        XCTAssertFalse(try XCTUnwrap(try db.applyReply(fresh, remote: [1, 3, 4, 5], enabled: true)).contains(2))
    }

    func testIDS03UnrelatedRemoteAdditionSurvivesButItsLaterExplicitLocalUnpinWins() throws {
        let db = try DialogReviewPostboxFixture(account: 9006)
        defer { db.close() }
        try db.seedPins([1, 2, 3, 4, 5, 6])
        _ = try db.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        try db.reorder([6, 1, 2, 3, 4, 5])
        try db.transaction { tx in
            tx.updatePeersInternal([db.user(db.peer(7))], update: { _, value in value })
            _ = tx.addMessages([db.message(db.peer(7), 1)], location: .Random)
            tx.updatePeerChatListInclusion(db.peer(7), inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
        }
        try db.replay(.pin(.peer(db.peer(7))), enabled: true)
        let sync = try db.begin(enabled: true)
        XCTAssertEqual(try db.applyReply(sync, remote: [7, 1, 2, 3, 4], enabled: true), [6, 1, 2, 3, 4, 5, 7])
        _ = try db.value(_internal_toggleItemPinned(postbox: db.postbox, accountPeerId: db.accountPeerId, location: .group(.root), itemId: .peer(db.peer(7))))
        let next = try db.begin(enabled: true)
        XCTAssertFalse(try XCTUnwrap(try db.applyReply(next, remote: [7, 1, 2, 3, 4], enabled: true)).contains(7))
    }

    func testIDS04DetachedAccountInitialFalseEnqueuesOnceAndReconcilesOnlyThatAccount() throws {
        let a = try DialogReviewPostboxFixture(account: 9101)
        let b = try DialogReviewPostboxFixture(account: 9102)
        defer { a.close(); b.close() }
        try a.seedPins([1, 2, 3, 4, 5, 6])
        try b.seedPins([1, 2]) // deliberately same peer numbers, different native store
        let sent = try a.sent(local: [1, 2, 3, 4, 5, 6], wire: [1, 2, 3, 4, 5])
        try a.complete(sent, local: [1, 2, 3, 4, 5, 6], acknowledged: [1, 2, 3, 4, 5], enabled: true)
        XCTAssertFalse(try a.hasOperation())
        XCTAssertFalse(try b.policy(true)) // A detached, B selected
        XCTAssertFalse(try b.policy(false)) // global off delivered only to B
        let aWatermark = try a.watermark()
        let bWatermark = try b.watermark()
        XCTAssertTrue(try a.policy(false)) // attach A with initial false
        XCTAssertEqual(try a.watermark(), aWatermark + 1)
        for _ in 0 ..< 4 { XCTAssertFalse(try a.policy(false)) }
        XCTAssertEqual(try a.watermark(), aWatermark + 1)
        XCTAssertEqual(try b.watermark(), bWatermark)
        XCTAssertEqual(try b.order(), [1, 2])
        let sync = try a.begin(enabled: false)
        // Reattach/unrelated calls while the matching read is in flight must not
        // replace it or manufacture another operation-log generation.
        for _ in 0 ..< 3 { XCTAssertFalse(try a.policy(false)) }
        XCTAssertEqual(try a.watermark(), aWatermark + 1)
        XCTAssertEqual(try a.applyReply(sync, remote: [1, 2, 3, 4, 5], enabled: false, acknowledgeMatchingRead: true), [1, 2, 3, 4, 5])
        XCTAssertFalse(try a.state()?.disablePending ?? true)
        XCTAssertEqual(try a.state()?.acknowledgedFromRead, true)
        XCTAssertFalse(try a.policy(false))
        XCTAssertFalse(try a.hasOperation())
        XCTAssertEqual(try a.watermark(), aWatermark + 1)
        XCTAssertEqual(try b.order(), [1, 2])
    }

    func testIDS05NativeIncludeChannelsMessagesChatsAndMuteMatrix() throws {
        let db = try DialogReviewPostboxFixture(account: 9201)
        defer { db.close() }
        try db.seedBadge()
        let before = try db.readSnapshot()
        for (globalEnabled, peerMute, includedByMute) in [(true, PeerMuteState.unmuted, true), (true, .muted(until: Int32.max), false), (false, .default, false), (false, .unmuted, true)] {
            try db.muteChannel(globalEnabled: globalEnabled, peer: peerMute)
            for includeChannels in [false, true] {
                let tags: PeerSummaryCounterTags = includeChannels ? .all : [.contact, .nonContact, .bot, .group]
                for chats in [false, true] {
                    let state = try db.badgeSnapshot(tags: tags, chats: chats)
                    let included = includeChannels && includedByMute
                    XCTAssertEqual(state.included, included)
                    XCTAssertEqual(state.total, chats ? (included ? 2 : 1) : (included ? 8 : 5))
                    XCTAssertEqual(exteralessDialogBackBadgeText(total: state.total, peerUnreadCount: 3, peerIsIncluded: state.included, peerIsMarkedUnread: state.marked, countChats: chats, entryPointAllowsBadge: true), chats ? "1" : "5")
                    XCTAssertNil(exteralessDialogBackBadgeText(total: state.total, peerUnreadCount: 3, peerIsIncluded: state.included, peerIsMarkedUnread: state.marked, countChats: chats, entryPointAllowsBadge: false))
                    let unknownPeerCount = exteralessDialogBackBadgeText(total: state.total, peerUnreadCount: nil, peerIsIncluded: state.included, peerIsMarkedUnread: state.marked, countChats: chats, entryPointAllowsBadge: true)
                    XCTAssertEqual(unknownPeerCount, included ? nil : (chats ? "1" : "5"))
                    XCTAssertNil(exteralessDialogBackBadgeText(total: nil, peerUnreadCount: 3, peerIsIncluded: state.included, peerIsMarkedUnread: state.marked, countChats: chats, entryPointAllowsBadge: true))
                }
            }
        }
        XCTAssertEqual(try db.readSnapshot(), before) // no read state or pts/seq change
    }

    func testIDS05UnknownPeerAndNativeGroupScopeAreNotInventedContributions() throws {
        let db = try DialogReviewPostboxFixture(account: 9202)
        defer { db.close() }
        try db.seedBadge()
        let unknown = try db.transaction { exteralessDialogBadgePeerState(transaction: $0, peerId: db.peer(999), includeTags: .all, includeArchived: false) }
        XCTAssertNil(unknown.isIncluded)
        XCTAssertNil(exteralessDialogBackBadgeText(total: 5, peerUnreadCount: 3, peerIsIncluded: unknown.isIncluded, peerIsMarkedUnread: false, countChats: false, entryPointAllowsBadge: true))
        try db.transaction { $0.updatePeerChatListInclusion(db.channel, inclusion: .ifHasMessagesOrOneOf(groupId: Namespaces.PeerGroup.archive, pinningIndex: nil, minTimestamp: nil)) }
        let root = try db.transaction { exteralessDialogBadgePeerState(transaction: $0, peerId: db.channel, includeTags: .all, includeArchived: false) }
        let projected = try db.transaction { exteralessDialogBadgePeerState(transaction: $0, peerId: db.channel, includeTags: .all, includeArchived: true) }
        XCTAssertEqual(root.isIncluded, false)
        XCTAssertEqual(projected.isIncluded, true)
    }
}

private final class DialogReviewPostboxFixture {
    enum Failure: Error { case timeout }
    struct ReadSnapshot: Equatable {
        let state: AuthorizedAccountState.State?
        let reads: [PeerId: CombinedPeerReadState]
    }
    let queue = Queue(name: "DialogReviewPostboxFixture")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dialog-review-" + UUID().uuidString, isDirectory: true)
    let accountPeerId: PeerId
    let channel = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(10))
    private static let suiteDeadline = ProcessInfo.processInfo.systemUptime + 20.0
    private let deadline: TimeInterval
    private var valueBox: SqliteValueBox?
    private(set) var postbox: Postbox!

    init(account: Int64) throws {
        deadline = Self.suiteDeadline
        accountPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(account))
        initializeAccountManagement()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("Dialog fixture attempted network/media fetch"); return .fail(.generic) }
    }

    func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure.timeout }
        let done = DispatchSemaphore(value: 0)
        var output: T?
        let disposable = signal.start(next: { output = $0; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + min(2.0, remaining)) == .success else { throw Failure.timeout }
        return try XCTUnwrap(output)
    }
    @discardableResult func transaction<T>(_ body: @escaping (Transaction) throws -> T) throws -> T { try value(postbox.transaction { tx in Result { try body(tx) } }).get() }
    func close() {
        _ = try? value(postbox.mediaBox.storageBox.totalSize())
        postbox = nil
        queue.sync { self.valueBox = nil }
        try? FileManager.default.removeItem(at: root)
    }
    func peer(_ value: Int64) -> PeerId { PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(value)) }
    func items(_ ids: [Int64]) -> [PinnedItemId] { ids.map { .peer(peer($0)) } }
    func packed(_ ids: [Int64]) -> [Int64] { ids.map { peer($0).toInt64() } }
    func numbers(_ items: [PinnedItemId]) -> [Int64] { items.map { if case let .peer(id) = $0 { return id.id._internalGetInt64Value() }; return -1 } }
    func user(_ id: PeerId) -> TelegramUser { TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil) }
    func message(_ peer: PeerId, _ id: Int32) -> StoreMessage { StoreMessage(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: id), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 100 + id, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer, text: "Synthetic", attributes: [], media: []) }
    func seedPins(_ ids: [Int64]) throws {
        try transaction { tx in
            tx.updatePeersInternal(ids.map { self.user(self.peer($0)) } + [self.user(self.accountPeerId)], update: { _, value in value })
            _ = tx.addMessages(ids.map { self.message(self.peer($0), 1) }, location: .Random)
            for id in ids { tx.updatePeerChatListInclusion(self.peer(id), inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil)) }
            tx.setPinnedItemIds(groupId: .root, itemIds: self.items(ids))
            tx.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2, peerId: self.accountPeerId, state: .init(pts: 71, qts: 9, date: 1000, seq: 21), invalidatedChannels: []))
        }
    }
    func order() throws -> [Int64] { try transaction { self.numbers($0.getPinnedItemIds(groupId: .root)) } }
    func state() throws -> ExteralessDialogPinState? { try transaction { exteralessDialogPinState(transaction: $0) } }
    func watermark() throws -> Int32 { try transaction { $0.operationLogGetNextEntryLocalIndex(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats) } }
    func hasOperation() throws -> Bool { try transaction { tx in var found = false; tx.operationLogEnumerateEntries(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats) { _ in found = true; return false }; return found } }
    func policy(_ enabled: Bool) throws -> Bool { try transaction { exteralessUpdateDialogPinPolicy(transaction: $0, accountPeerId: self.accountPeerId, enabled: enabled) } }
    func reorder(_ ids: [Int64]) throws { XCTAssertTrue(try transaction { _internal_reorderPinnedItemIds(transaction: $0, location: .group(.root), itemIds: self.items(ids)) }) }
    func replay(_ operation: AccountStateUpdatePinnedItemIdsOperation, enabled: Bool) throws { XCTAssertTrue(try transaction { exteralessReplayDialogPinUpdate(transaction: $0, accountPeerId: self.accountPeerId, groupId: .root, operation: operation, enabled: enabled) }) }
    func begin(enabled: Bool) throws -> ExteralessDialogPinSync {
        try transaction { tx in
            var index: Int32?
            tx.operationLogEnumerateEntries(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats) { index = $0.tagLocalIndex; return false }
            return try XCTUnwrap(exteralessBeginDialogPinSync(transaction: tx, accountPeerId: self.accountPeerId, groupId: .root, operationIndex: try XCTUnwrap(index), enabled: enabled))
        }
    }
    func sent(local: [Int64], wire: [Int64]) throws -> ExteralessDialogPinSync {
        _ = try policy(true)
        try transaction { addSynchronizePinnedChatsOperation(transaction: $0, groupId: .root) }
        let sync = try begin(enabled: true)
        XCTAssertEqual(try applyReply(sync, remote: local, enabled: true), local)
        _ = try record(sync, local: local, wire: wire)
        return sync
    }
    func applyReply(_ sync: ExteralessDialogPinSync, remote: [Int64], enabled: Bool, acknowledgeMatchingRead: Bool = false) throws -> [Int64]? {
        try transaction { tx in
            guard let order = exteralessResolveDialogPinSync(transaction: tx, accountPeerId: self.accountPeerId, sync: sync, remoteOrder: self.items(remote), nativeResult: self.items(remote), enabled: enabled) else { return nil }
            tx.setPinnedItemIds(groupId: .root, itemIds: order)
            if acknowledgeMatchingRead {
                XCTAssertEqual(exteralessDialogServerPinOrder(transaction: tx, accountPeerId: self.accountPeerId, groupId: .root, itemIds: order), self.items(remote))
                exteralessCompleteDialogPinSync(transaction: tx, accountPeerId: self.accountPeerId, sync: sync, localOrder: order, acknowledgedServerOrder: self.items(remote), enabled: enabled, appliedInCurrentTransaction: true)
                _ = tx.operationLogRemoveEntry(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats, tagLocalIndex: sync.operationIndex)
            }
            return self.numbers(order)
        }
    }
    func record(_ sync: ExteralessDialogPinSync, local: [Int64], wire: [Int64]) throws -> ExteralessDialogPinRequest { try transaction { try XCTUnwrap(exteralessRecordDialogPinRequest(transaction: $0, sync: sync, localOrder: self.items(local), serverOrder: self.items(wire))) } }
    func complete(_ sync: ExteralessDialogPinSync, local: [Int64], acknowledged: [Int64]?, enabled: Bool, cleanup: Bool = true) throws {
        try transaction { tx in
            exteralessCompleteDialogPinSync(transaction: tx, accountPeerId: self.accountPeerId, sync: sync, localOrder: self.items(local), acknowledgedServerOrder: acknowledged.map(self.items), enabled: enabled)
            if cleanup { _ = tx.operationLogRemoveEntry(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats, tagLocalIndex: sync.operationIndex) }
        }
    }
    func readSnapshot() throws -> ReadSnapshot {
        try transaction { tx in
            var reads: [PeerId: CombinedPeerReadState] = [:]
            for id in (1 ... 6).map({ self.peer(Int64($0)) }) + [self.channel] { if let read = tx.getCombinedPeerReadState(id) { reads[id] = read } }
            return ReadSnapshot(state: (tx.getState() as? AuthorizedAccountState)?.state, reads: reads)
        }
    }
    func seedBadge() throws {
        try transaction { tx in
            let channel = TelegramChannel(id: self.channel, accessHash: nil, title: "Synthetic channel", username: nil, photo: [], creationDate: 1, version: 0, participationStatus: .member, info: .broadcast(TelegramChannelBroadcastInfo(flags: [])), flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
            tx.updatePeersInternal([self.user(self.peer(1)), self.user(self.accountPeerId), channel], update: { _, value in value })
            for (peer, count) in [(self.peer(1), 5), (self.channel, 3)] {
                _ = tx.addMessages((1 ... count).map { self.message(peer, Int32($0)) }, location: .Random)
                tx.updatePeerChatListInclusion(peer, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
                tx.resetIncomingReadStates([peer: [Namespaces.Message.Cloud: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: Int32(count), count: Int32(count), markedUnread: false)]])
            }
            tx.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2, peerId: self.accountPeerId, state: .init(pts: 71, qts: 9, date: 1000, seq: 21), invalidatedChannels: []))
        }
    }
    func muteChannel(globalEnabled: Bool, peer: PeerMuteState) throws {
        try transaction { tx in
            var settings = GlobalNotificationSettings.defaultSettings
            settings.remote.channels.enabled = globalEnabled
            tx.setPreferencesEntry(key: PreferencesKeys.globalNotifications, value: PreferencesEntry(settings))
            tx.globalNotificationSettingsUpdated()
            tx.updateCurrentPeerNotificationSettings([self.channel: TelegramPeerNotificationSettings.defaultSettings.withUpdatedMuteState(peer)])
        }
    }
    func badgeSnapshot(tags: PeerSummaryCounterTags, chats: Bool) throws -> (total: Int32, included: Bool?, marked: Bool) {
        try transaction { tx in
            let peer = exteralessDialogBadgePeerState(transaction: tx, peerId: self.channel, includeTags: tags, includeArchived: false)
            let total = tx.getTotalUnreadState(groupId: .root).count(for: .filtered, in: chats ? .chats : .messages, with: tags)
            return (total, peer.isIncluded, peer.isMarkedUnread)
        }
    }
}
