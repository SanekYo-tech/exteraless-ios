import Foundation
import XCTest
@testable import ExteralessCore

final class ChatPhase2PolicyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testForwardBatchesKeepCommentsAndEveryAlbumMemberInOrder() {
        let values = [("comment", 0), ("A1", 1), ("A2", 1), ("B1", 2), ("A3", 1)]
        let ordered = ChatComposerPolicy.ordering(values, commentAfterForward: true, isForward: { $0.1 != 0 })
        XCTAssertEqual(ordered.map { $0.0 }, ["A1", "A2", "B1", "A3", "comment"])
        let groups = ChatComposerPolicy.batches(ordered, key: { $0.1 })
        XCTAssertEqual(groups.map { $0.map { $0.0 } }, [["A1", "A2"], ["B1"], ["A3"], ["comment"]])
        XCTAssertEqual(ChatComposerPolicy.ordering(values, commentAfterForward: false, isForward: { $0.1 != 0 }).map { $0.0 }, values.map { $0.0 })
    }

    func testBaselineFeedPlayerPillWritesStillRegisterAndPersist() throws {
        let url = try directory().appendingPathComponent("settings.json")
        let settings = try ClientSettings(storageURL: url)
        try settings.register(ChatFeatures.definitions)
        let patch: [String: ClientSettingValue] = [
            "chats.wideFeedPosts": .bool(true), "chats.includeArchived": .object(["7": .bool(true)]),
            "chats.addNewChannels": .object(["7": .bool(false)]), "chats.excludedChannels": .object(["7": .array([.string("9223372036854775806")])]),
            "chats.knownChannels": .object(["7": .array([])]), "chats.pauseOnMinimizeVoice": .bool(true),
            "chats.pauseOnMinimizeRound": .bool(true), "chats.dontAutoPlayNextVoice": .bool(true),
            "chats.disableProximityEvents": .bool(true), "chats.preferOriginalQuality": .bool(true),
            "chats.doubleTapSeekDuration": .integer(3), "chats.musicPlaybackSpeed": .number(1.7),
            "chats.activePillsRaw": .string("5,88,6"), "chats.hiddenPillsRaw": .string("6"),
            "chats.lastActivePillId": .integer(5), "chats.infiniteScrolling": .bool(false)
        ]
        try settings.applyPublic(patch)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(ChatFeatures.definitions)
        for (key, value) in patch { XCTAssertEqual(reopened.value(key), value, key) }
        XCTAssertEqual(Set(ChatFeatures.definitions.map(\.key)).count, ChatFeatures.definitions.count)
    }

    func testScheduleDefaultRoundsUpButDoesNotOverrideAnExplicitDate() {
        XCTAssertEqual(ChatComposerPolicy.scheduleMinutes.count, 30)
        XCTAssertEqual(ChatComposerPolicy.initialScheduleTime(current: nil, now: 1001, minutes: 10), 1620)
        XCTAssertEqual(ChatComposerPolicy.initialScheduleTime(current: Int32.max - 1, now: 1001, minutes: 61), 4620)
        XCTAssertEqual(ChatComposerPolicy.initialScheduleTime(current: 2222, now: 1001, minutes: 10), 2222)
        XCTAssertNil(ChatComposerPolicy.initialScheduleTime(current: nil, now: .nan, minutes: Int.max))
        XCTAssertNil(ChatComposerPolicy.initialScheduleTime(current: nil, now: Double(Int32.max), minutes: 10))
    }

    func testPreviewOverrideIsPerDraftAndIndividualDismissalWins() {
        let link = "https://example.test/a"
        XCTAssertTrue(ChatComposerPolicy.disablesPreview(url: link, overrides: [], defaultDisabled: true))
        XCTAssertFalse(ChatComposerPolicy.disablesPreview(url: link, overrides: [ChatComposerPolicy.allowPreviewMarker], defaultDisabled: true))
        XCTAssertTrue(ChatComposerPolicy.disablesPreview(url: link, overrides: [ChatComposerPolicy.allowPreviewMarker, link], defaultDisabled: false))
        XCTAssertFalse(ChatComposerPolicy.disablesPreview(url: link, overrides: [], defaultDisabled: false))
    }

    func testPreviewOnlyHostRewritePreservesQueryBytesAndSignedNavigation() {
        XCTAssertEqual(ChatPreviewLinkRules.previewURL("https://x.com/u/status/1"), "https://fixupx.com/u/status/1")
        XCTAssertEqual(ChatPreviewLinkRules.previewURL("https://x.com/u/status/1?q=a%2Bb#s"), "https://fixupx.com/u/status/1?q=a%2Bb#s")
        for value in ["https://x.com/a?sig=abc&utm_source=x", "https://u@x.com/a", "tg://proxy?server=x.com", "https://x.com.evil.test/a"] {
            XCTAssertEqual(ChatPreviewLinkRules.previewURL(value), value)
        }
    }

    func testPanguRetainsAttributedContentUTF16AndProtectedCodeURLs() {
        let marker = NSAttributedString.Key("fixture.style")
        let text = NSMutableAttributedString(string: "😀漢ABC code漢A https://x.test/漢A")
        text.addAttribute(marker, value: "bold", range: NSRange(location: 2, length: 4))
        let protected = (text.string as NSString).range(of: "code漢A")
        let result = ChatPanguPolicy.applying(to: text, protectedRanges: [protected])
        XCTAssertEqual(result.string, "😀漢\u{2009}ABC code漢A https://x.test/漢A")
        XCTAssertEqual(result.attribute(marker, at: 2, effectiveRange: nil) as? String, "bold")
        XCTAssertEqual(result.attribute(marker, at: 6, effectiveRange: nil) as? String, "bold")
        XCTAssertEqual(ChatPanguPolicy.applying(to: result, protectedRanges: [(result.string as NSString).range(of: "code漢A")]).string, result.string)
    }

    func testStickerTimeAndShareMoveTogetherOrBothKeepNativeFrames() {
        let sticker = ChatLayoutRect(x: 50, y: 0, width: 120, height: 120)
        let time = ChatLayoutRect(x: 110, y: 100, width: 40, height: 20)
        let share = ChatLayoutRect(x: 178, y: 100, width: 32, height: 32)
        let fit = ChatStickerLayoutPolicy.timeFrames(sticker: sticker, time: time, share: share, obstacles: [], incoming: true, left: 0, right: 320, enabled: true)
        XCTAssertEqual(fit.time.x, 178)
        XCTAssertEqual(fit.share?.x, 226)
        let narrow = ChatStickerLayoutPolicy.timeFrames(sticker: sticker, time: time, share: share, obstacles: [], incoming: true, left: 0, right: 230, enabled: true)
        XCTAssertEqual(narrow.time, time)
        XCTAssertEqual(narrow.share, share)
        let name = ChatLayoutRect(x: 170, y: 99, width: 100, height: 25)
        let obstructed = ChatStickerLayoutPolicy.timeFrames(sticker: sticker, time: time, share: share, obstacles: [name], incoming: true, left: 0, right: 320, enabled: true)
        XCTAssertEqual(obstructed.time, time)
        XCTAssertEqual(obstructed.share, share)
    }

    func testBookmarksPersistLosslessIDsAndAccountIsolationWithoutSavingMessageText() throws {
        let root = try directory()
        let store = ChatBookmarkStore(directory: root)
        let item = ChatBookmarkStore.Bookmark(peerKey: Int64.max - 1, namespace: 0, messageId: 33, timestamp: 100)
        XCTAssertTrue(try store.toggle(item, account: 1))
        XCTAssertEqual(try ChatBookmarkStore(directory: root).list(account: 1), [item])
        XCTAssertEqual(try store.list(account: 2), [])
        XCTAssertFalse(try store.toggle(item, account: 1))
        XCTAssertEqual(try store.list(account: 1), [])
        try Data("broken".utf8).write(to: root.appendingPathComponent("1.json"))
        XCTAssertThrowsError(try store.toggle(item, account: 1))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("1.json"), encoding: .utf8), "broken")
    }

    func testCanonicalTranslationMigrationDrivesBothRealConsumers() throws {
        let url = try directory().appendingPathComponent("settings.json")
        try Data("{\"ai.showTextTranslate\":false}".utf8).write(to: url)
        let settings = try ClientSettings(storageURL: url)
        try settings.register(ChatFeatures.definitions)
        try ChatFeatures.migrateSettings(in: settings)
        XCTAssertFalse(ChatFormattingPolicy.translationActionEnabled(in: settings))
        // Pins the coordinator AI hunk: this must fail until AI reads the canonical key too.
        XCTAssertFalse(AITranslationPolicy(store: settings).showTextTranslate)
        try settings.set(.bool(true), for: "chats.showTextTranslate")
        XCTAssertTrue(ChatFormattingPolicy.translationActionEnabled(in: settings))
        XCTAssertTrue(AITranslationPolicy(store: settings).showTextTranslate)
        try ChatFeatures.migrateSettings(in: settings)
        XCTAssertTrue(ChatFormattingPolicy.translationActionEnabled(in: settings))
    }

    func testCanonicalTranslationExplicitTrueWinsLegacyFalse() throws {
        let url = try directory().appendingPathComponent("settings.json")
        try Data("{\"ai.showTextTranslate\":false,\"chats.showTextTranslate\":true}".utf8).write(to: url)
        let settings = try ClientSettings(storageURL: url)
        try settings.register(ChatFeatures.definitions)
        try ChatFeatures.migrateSettings(in: settings)
        XCTAssertTrue(ChatFormattingPolicy.translationActionEnabled(in: settings))
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(ChatFeatures.definitions)
        XCTAssertTrue(ChatFormattingPolicy.translationActionEnabled(in: reopened))
    }
}
