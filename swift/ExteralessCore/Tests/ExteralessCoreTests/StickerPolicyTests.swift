import Foundation
import XCTest
@testable import ExteralessCore

final class StickerPolicyTests: XCTestCase {
    func testSizeIsIdentityAtDefaultAndFitsNarrowMessages() {
        let policy = StickerPolicy(values: [:])
        XCTAssertEqual(policy.stickerSide(stock: 184, available: 250, isTablet: false), 184)
        XCTAssertEqual(policy.stickerSide(stock: 180, available: 250, isTablet: true), 180)
        let large = StickerPolicy(values: ["chats.stickerSize": .number(20)])
        XCTAssertEqual(large.stickerSide(stock: 180, available: 190, isTablet: false), 190)
        XCTAssertEqual(large.stickerSide(stock: 180, available: 400, isTablet: false), 252, accuracy: 0.0001)
        XCTAssertEqual(large.stickerSide(stock: 180, available: 400, isTablet: true), 247.5)
        XCTAssertEqual(large.stickerSide(stock: 180, available: -.infinity, isTablet: false), 0)
    }

    func testRecentsKeepFreshCloudOrderThenLocalOnlyTail() {
        struct Item: Equatable { let id: Int; let reference: String }
        let local = [Item(id: 3, reference: "old"), Item(id: 1, reference: "local")]
        let cloud = [Item(id: 2, reference: "cloud"), Item(id: 3, reference: "fresh")]
        let merged = StickerCollectionPolicy.recent(local: local, cloud: cloud, limit: 3, id: { $0.id })
        XCTAssertEqual(merged, [.init(id: 2, reference: "cloud"), .init(id: 3, reference: "fresh"), .init(id: 1, reference: "local")])
        XCTAssertEqual(StickerCollectionPolicy.recent(local: local, cloud: cloud, limit: 1, id: { $0.id }).map(\.id), [2])
        XCTAssertEqual(cloud.map(\.id), [2, 3])
        XCTAssertEqual(local.map(\.reference), ["old", "local"])
    }

    func testFullRecentTailCannotDisplaceCrossDeviceUseAt20_21_200() {
        let local = Array(1...200)
        let cloud = [999] + Array(1...19)
        for count in [20, 21, 200] {
            XCTAssertEqual(StickerCollectionPolicy.recent(local: local, cloud: cloud, limit: count, id: { $0 }), [999] + Array(1..<count))
        }
    }

    func testGifShelfStillKeepsLocalOrderAndRefreshesReferences() {
        struct Item: Equatable { let id: Int; let reference: String }
        let local = [Item(id: 3, reference: "old"), Item(id: 1, reference: "local")]
        let cloud = [Item(id: 2, reference: "cloud"), Item(id: 3, reference: "fresh")]
        let merged = StickerCollectionPolicy.merged(local: local, cloud: cloud, limit: 3, id: { $0.id })
        XCTAssertEqual(merged, [.init(id: 3, reference: "fresh"), .init(id: 1, reference: "local"), .init(id: 2, reference: "cloud")])
        XCTAssertEqual(StickerCollectionPolicy.merged(local: local, cloud: cloud, limit: 1, id: { $0.id }).map(\.id), [3])
        XCTAssertEqual(cloud.map(\.id), [2, 3])
    }

    func testLockedEmojiConversionHonorsFormatAndContext() {
        let policy = StickerPolicy(values: [:])
        XCTAssertTrue(policy.canUploadLockedEmoji(mimeType: "image/webp", isPremium: false, isSavedMessages: false, isGroupEmoji: false))
        XCTAssertFalse(policy.canUploadLockedEmoji(mimeType: "application/x-tgsticker", isPremium: false, isSavedMessages: false, isGroupEmoji: false))
        XCTAssertFalse(policy.canUploadLockedEmoji(mimeType: "image/webp", isPremium: false, isSavedMessages: true, isGroupEmoji: false))
        XCTAssertFalse(policy.canUploadLockedEmoji(mimeType: "video/webm", isPremium: false, isSavedMessages: false, isGroupEmoji: true))
        XCTAssertFalse(StickerPolicy(values: ["chats.sendLockedCustomEmojiAsSticker": .bool(false)]).canUploadLockedEmoji(mimeType: "image/webp", isPremium: false, isSavedMessages: false, isGroupEmoji: false))
    }

    func testOriginalPinsKeepInt64ZWJAndFilterBeforeOrdering() throws {
        let pins = StickerReactionPolicy.decode(#"[{"emoticon":"👩🏽‍💻"},{"document_id":9223372036854775807},{"emoticon":"👩🏽‍💻"},{"emoticon":"12"},{"document_id":0}]"#)
        XCTAssertEqual(pins, [.emoji("👩🏽‍💻"), .custom(Int64.max)])
        XCTAssertEqual(StickerReactionPolicy.decode(try StickerReactionPolicy.encode(pins)), pins)
        XCTAssertEqual(StickerReactionPolicy.ordered(available: [.emoji("👍"), .custom(Int64.max), .emoji("👩🏽‍💻")], pins: pins, allowed: [.emoji("👍"), .custom(Int64.max)], canUseCustom: false), [.emoji("👍")])
        XCTAssertTrue(StickerReactionPolicy.decode(String(repeating: " ", count: 8193)).isEmpty)
        XCTAssertThrowsError(try StickerReactionPolicy.encode([.emoji("👍"), .emoji("👍")]))
    }

    func testResetRestoresBehaviorAndDoesNotDuplicateChatDefinitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("settings.json"))
        try settings.register(StickerFeatures.definitions)
        try settings.applyPublic(["chats.stickerSize": .number(20), "chats.disableChoosingSticker": .bool(true), "chats.unlimitedSavedGifs": .bool(true)])
        XCTAssertTrue(StickerPolicy(settings: settings).localGifs)
        XCTAssertTrue(StickerPolicy(settings: settings).hideChoosingActivity)
        try settings.applyPublic([:], resetting: ["chats.stickerSize", "chats.disableChoosingSticker", "chats.unlimitedSavedGifs"])
        XCTAssertEqual(StickerPolicy(settings: settings), StickerPolicy(values: [:]))
        XCTAssertTrue(StickerFeatures.keys.isDisjoint(with: ["chats.stickerShape", "chats.stickerTimeSide", "chats.hideTimeForSticker", "chats.useCustomEmoji"]))
    }

    func testRetiredOperationCannotCommitAfterCancellation() throws {
        let lease = EmojiPackLease()
        var writes = 0
        try lease.commit { writes += 1 }
        lease.invalidate()
        XCTAssertThrowsError(try lease.commit { writes += 1 }) { XCTAssertEqual($0 as? EmojiPackError, .cancelled) }
        XCTAssertEqual(writes, 1)
    }
}
