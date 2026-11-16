import ExteralessCore
import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox
@testable import TelegramCore

/// IDS-06: real disposable Postbox views/transactions and the shipping adapter.
/// There is no Account, Network, state manager or operation-log consumer.
final class ExteralessStickerRecentsReviewTests: XCTestCase {
    func testCloud999PrecedesFullLocalTailAt20_21_200WithFreshReferences() throws {
        let db = try StickerReviewPostboxFixture()
        defer { db.close() }
        try db.seed(local: Array(1...200), cloud: [999] + Array(1...19))
        for count in [20, 21, 200] {
            try db.settings.set(.integer(Int64(count)), for: "chats.maxRecentStickerCount")
            let items = try db.value(db.items() |> take(1))
            XCTAssertEqual(items.map { $0.media.fileId.id }, [999] + Array(1..<count).map(Int64.init))
            XCTAssertEqual((items[1].media._parse().resource as? CloudDocumentMediaResource)?.accessHash, 2)
            XCTAssertEqual((items[1].media._parse().resource as? CloudDocumentMediaResource)?.fileReference, Data([2]))
        }
    }

    func testLocalSendRemoveClearRunThroughRealRecentStorageAndAdapter() throws {
        let db = try StickerReviewPostboxFixture()
        defer { db.close() }
        try db.settings.set(.integer(200), for: "chats.maxRecentStickerCount")
        try db.seed(local: Array(1...200), cloud: [999] + Array(1...19))
        let sent = db.file(1000, hash: 3)
        // Same capture -> cloud-add transaction as addRecentlyUsedSticker, with
        // the isolated settings store injected into the actual capture helper.
        XCTAssertTrue(try db.transaction { transaction in
            let captured = exteralessRememberRecentSticker(transaction: transaction, file: sent, settings: db.settings)
            transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.CloudRecentStickers,
                item: OrderedItemListEntry(id: RecentMediaItemId(sent.fileId).rawValue, contents: CodableEntry(RecentMediaItem(sent))!), removeTailIfCountExceeds: 20)
            return captured
        })
        var items = try db.value(db.items() |> take(1))
        XCTAssertEqual(items.map { $0.media.fileId.id }, [1000, 999] + Array(1...198).map(Int64.init))
        XCTAssertEqual((items[0].media._parse().resource as? CloudDocumentMediaResource)?.accessHash, 3)

        try db.transaction { _internal_removeRecentlyUsedSticker(transaction: $0, fileReference: .recentSticker(media: sent)) }
        items = try db.value(db.items() |> take(1))
        XCTAssertEqual(items.map { $0.media.fileId.id }, [999] + Array(1...198).map(Int64.init))
        try db.transaction { _internal_clearRecentlyUsedStickers(transaction: $0) }
        XCTAssertTrue(try db.value(db.items() |> take(1)).isEmpty)
        XCTAssertNil(try db.transaction { $0.getPreferencesEntry(key: ValueBoxKey("exteraless.stickers.recents.v1")) })
    }

    func testLiveResetReturnsCloudOnlyAndDisposalStopsDelivery() throws {
        let db = try StickerReviewPostboxFixture()
        defer { db.close() }
        try db.settings.set(.integer(200), for: "chats.maxRecentStickerCount")
        try db.seed(local: Array(1...200), cloud: [999] + Array(1...19))
        let initial = DispatchSemaphore(value: 0), reset = DispatchSemaphore(value: 0)
        let values = Atomic<[Int]>(value: [])
        let subscription = db.items().start(next: { items in
            _ = values.modify { $0 + [items.count] }
            if items.count == 200 { initial.signal() }
            if items.count == 20 { reset.signal() }
        })
        defer { subscription.dispose() }
        XCTAssertEqual(initial.wait(timeout: .now() + 1), .success)
        try db.settings.reset("chats.maxRecentStickerCount")
        XCTAssertEqual(reset.wait(timeout: .now() + 1), .success)
        let cloudOnly = try db.value(db.items() |> take(1))
        XCTAssertEqual(cloudOnly.map { $0.media.fileId.id }, [999] + Array(1...19).map(Int64.init))
        subscription.dispose()
        let count = values.with { $0.count }
        try db.settings.set(.integer(21), for: "chats.maxRecentStickerCount")
        _ = try db.value(db.items() |> take(1))
        XCTAssertEqual(values.with { $0.count }, count)
    }
}

/// IDS-07: the real signal reads the real local ClientSettings store. Barriers
/// control the old-read/new-commit ordering; no clocks or scheduler sleeps change.
final class ExteralessStickerPolicyReviewTests: XCTestCase {
    func testLateOldReadCannotPublishAfterNewTrue() throws {
        let fixture = try StickerReviewSettingsFixture()
        defer { fixture.close() }
        let store = fixture.store, queue = Queue(name: "StickerPolicyOrderFixture")
        try store.set(.bool(false), for: "chats.disableTrending")
        let initial = DispatchSemaphore(value: 0), oldRead = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0), latest = DispatchSemaphore(value: 0)
        let writerACompleted = DispatchSemaphore(value: 0)
        let writerAResult = Atomic<Result<Void, Error>?>(value: nil)
        let blocked = Atomic(value: false), values = Atomic<[Bool]>(value: [])
        let subscription = _internal_exteralessStickerPolicy(settings: store, queue: queue, didRead: { policy in
            if policy.hideGroupPack && !policy.hideTrending && !blocked.swap(true) {
                oldRead.signal()
                XCTAssertEqual(releaseOld.wait(timeout: .now() + 1), .success)
            }
        }).start(next: { policy in
            _ = values.modify { $0 + [policy.hideTrending] }
            initial.signal()
            if policy.hideTrending { latest.signal() }
        })
        defer { releaseOld.signal(); subscription.dispose() }
        XCTAssertEqual(initial.wait(timeout: .now() + 1), .success)
        // justDispatch forwards to the same global queue without running inline;
        // Atomic carries the write result back to the test's throwing context.
        Queue(queue: DispatchQueue.global()).justDispatch {
            // A can remain inside its callback in the broken implementation;
            // writer B below must still be able to commit independently.
            let result = Result { try store.set(.bool(true), for: "chats.hideGroupSticker") }
            _ = writerAResult.swap(result)
            writerACompleted.signal()
        }
        XCTAssertEqual(oldRead.wait(timeout: .now() + 1), .success)
        try store.set(.bool(true), for: "chats.disableTrending") // B commits while A is paused.
        XCTAssertTrue(store.bool("chats.disableTrending"), "The subscriber/read hook must not hold the store writer lock")
        releaseOld.signal()
        XCTAssertEqual(latest.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(writerACompleted.wait(timeout: .now() + 1), .success)
        queue.sync {}
        let writeResult = try XCTUnwrap(writerAResult.with { $0 })
        XCTAssertNoThrow(try writeResult.get())
        let delivered = values.with { $0 }
        XCTAssertEqual(delivered.last, true)
        if let firstTrue = delivered.firstIndex(of: true) { XCTAssertTrue(delivered[firstTrue...].allSatisfy { $0 }) }
    }

    func testInitialReadUsesLatestValueAndResetIsPublished() throws {
        let fixture = try StickerReviewSettingsFixture()
        defer { fixture.close() }
        let store = fixture.store, queue = Queue(name: "StickerPolicyInitialFixture")
        try store.set(.bool(false), for: "chats.disableTrending")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.justDispatch { entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 1), .success) }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let values = Atomic<[Bool]>(value: []), changed = DispatchSemaphore(value: 0)
        let subscription = _internal_exteralessStickerPolicy(settings: store, queue: queue).start(next: { policy in
            _ = values.modify { $0 + [policy.hideTrending] }; changed.signal()
        })
        defer { release.signal(); subscription.dispose() }
        try store.set(.bool(true), for: "chats.disableTrending")
        release.signal()
        XCTAssertEqual(changed.wait(timeout: .now() + 1), .success)
        queue.sync {}
        XCTAssertEqual(values.with { $0 }, [true])
        try store.set(.bool(false), for: "chats.disableTrending")
        XCTAssertEqual(changed.wait(timeout: .now() + 1), .success)
        try store.reset("chats.disableTrending")
        XCTAssertEqual(changed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(values.with { $0 }, [true, false, true])
    }

    func testDisposeWhileReadIsPausedAndLaterInvalidationsDoNotDeliver() throws {
        let fixture = try StickerReviewSettingsFixture()
        defer { fixture.close() }
        let queue = Queue(name: "StickerPolicyDisposeFixture")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let reads = Atomic(value: 0), deliveries = Atomic(value: 0)
        let subscription = _internal_exteralessStickerPolicy(settings: fixture.store, queue: queue, didRead: { _ in
            _ = reads.modify { $0 + 1 }; entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 1), .success)
        }).start(next: { _ in _ = deliveries.modify { $0 + 1 } })
        defer { release.signal(); subscription.dispose() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        subscription.dispose()
        release.signal()
        try fixture.store.set(.bool(false), for: "chats.disableTrending")
        queue.sync {}
        XCTAssertEqual(reads.with { $0 }, 1)
        XCTAssertEqual(deliveries.with { $0 }, 0)
    }

    func testSubscriberWriteIsQueuedInsteadOfReentrant() throws {
        let fixture = try StickerReviewSettingsFixture()
        defer { fixture.close() }
        let store = fixture.store, queue = Queue(name: "StickerPolicyReentryFixture")
        try store.set(.bool(false), for: "chats.disableTrending")
        let delivering = Atomic(value: false), values = Atomic<[Bool]>(value: [])
        let resetResult = Atomic<Result<Void, Error>?>(value: nil)
        let done = DispatchSemaphore(value: 0)
        let subscription = _internal_exteralessStickerPolicy(settings: store, queue: queue).start(next: { policy in
            XCTAssertFalse(delivering.swap(true))
            defer { _ = delivering.swap(false) }
            _ = values.modify { $0 + [policy.hideTrending] }
            if !policy.hideTrending {
                let result = Result { try store.reset("chats.disableTrending") }
                _ = resetResult.swap(result)
            } else { done.signal() }
        })
        defer { subscription.dispose() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        queue.sync {}
        let writeResult = try XCTUnwrap(resetResult.with { $0 })
        XCTAssertNoThrow(try writeResult.get())
        XCTAssertEqual(values.with { $0 }, [false, true])
    }
}

private final class StickerReviewSettingsFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-settings-review-" + UUID().uuidString)
    let store: ClientSettings
    init() throws {
        self.store = try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: StickerReviewMemorySecrets())
        try self.store.register(StickerFeatures.definitions)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}

private enum StickerReviewFixtureError: Error { case timeout }
private final class StickerReviewMemorySecrets: ClientSecretStore, @unchecked Sendable {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { preconditionFailure("Sticker fixtures have no secret definitions") }
}

private final class StickerReviewPostboxFixture {
    private let queue = Queue(name: "StickerRecentsPostboxFixture")
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-recents-review-" + UUID().uuidString)
    private let preferences: StickerReviewSettingsFixture
    var settings: ClientSettings { self.preferences.store }
    private var valueBox: SqliteValueBox?
    private var postbox: Postbox!

    init() throws {
        initializeAccountManagement()
        self.preferences = try StickerReviewSettingsFixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("db"), withIntermediateDirectories: true)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: root.path + "/db", queue: queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        self.postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        self.postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("Sticker fixture attempted network/media fetch"); return .fail(.generic) }
    }

    func file(_ id: Int64, hash: Int64) -> TelegramMediaFile {
        let resource = CloudDocumentMediaResource(datacenterId: 1, fileId: id, accessHash: hash, size: 128, fileReference: Data([UInt8(truncatingIfNeeded: hash)]), fileName: "fixture.webp")
        return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: 128, attributes: [.FileName(fileName: "fixture.webp"), .Sticker(displayText: "😀", packReference: .id(id: 77, accessHash: 88), maskData: nil), .ImageSize(size: PixelDimensions(width: 64, height: 64))], alternativeRepresentations: [])
    }

    func seed(local: [Int], cloud: [Int]) throws {
        // Documented native preference wire shape; the real RecentMediaItem
        // encoder creates trusted fixture FlatBuffers, never imported user bytes.
        struct Record: Codable { let version: Int; let items: [RecentMediaItem] }
        let local = local.map { RecentMediaItem(file(Int64($0), hash: 1)) }
        let cloud = cloud.map { file(Int64($0), hash: 2) }
        try transaction { transaction in
            transaction.updatePreferencesEntry(key: ValueBoxKey("exteraless.stickers.recents.v1"), { _ in PreferencesEntry(Record(version: 1, items: local)) })
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.CloudRecentStickers, items: cloud.map {
                OrderedItemListEntry(id: RecentMediaItemId($0.fileId).rawValue, contents: CodableEntry(RecentMediaItem($0))!)
            })
        }
    }

    func items() -> Signal<[RecentMediaItem], NoError> {
        _internal_exteralessRecentStickerItems(postbox: postbox, policy: exteralessStickerPolicy(settings: settings))
    }
    @discardableResult func transaction<T>(_ body: @escaping (Transaction) -> T) throws -> T { try value(postbox.transaction(body)) }
    func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var output: T?
        let disposable = signal.start(next: { output = $0; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 1) == .success else { throw StickerReviewFixtureError.timeout }
        return try XCTUnwrap(output)
    }
    func close() {
        _ = try? value(postbox.mediaBox.storageBox.totalSize())
        postbox = nil
        queue.sync { valueBox = nil }
        preferences.close()
        try? FileManager.default.removeItem(at: root)
    }
}
