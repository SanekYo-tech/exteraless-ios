import Foundation
import XCTest
@testable import ExteralessCore

final class RetentionPolicyTests: XCTestCase {
    private let key = RetentionMessageKey(peerId: 42, namespace: 0, id: 9)
    private func hash(_ byte: Character) -> String { String(repeating: String(byte), count: 64) }
    private func enabled(_ extra: [String: ClientSettingValue] = [:]) -> RetentionPolicy {
        var values: [String: ClientSettingValue] = ["privacy.enableSaveDeletedMessages": .bool(true), "privacy.enableSaveEditsHistory": .bool(true)]
        values.merge(extra) { _, value in value }
        return RetentionPolicy(values: values)
    }

    func testOriginalDefaultsAndSeparateNativeBounds() {
        let policy = RetentionPolicy()
        XCTAssertFalse(policy.saveDeleted)
        XCTAssertFalse(policy.saveEdits)
        XCTAssertFalse(policy.deletedOnlyMarked)
        XCTAssertFalse(policy.editedOnlyMarked)
        XCTAssertTrue(policy.savePrivate && policy.saveGroups && policy.saveChannels && policy.saveArchived)
        XCTAssertFalse(policy.saveBotDialogs || policy.saveBotSenders)
        XCTAssertTrue(policy.saveMedia && policy.mediaPrivate && policy.mediaPublicChannels && policy.mediaPrivateChannels && policy.mediaPublicGroups && policy.mediaPrivateGroups)
        XCTAssertTrue(policy.useDeletedIcon && policy.translucent && policy.menuViewDeleted && policy.menuClearDeleted)
        XCTAssertTrue(policy.useEditedIcon && policy.replyToDeletedAsQuote)
        XCTAssertFalse(policy.showMessageHide || policy.showViewHistory)
        XCTAssertEqual(policy.deletedMark, "")
        XCTAssertNil(policy.deletedColorARGB)
        XCTAssertEqual(policy.days, 30)
        XCTAssertEqual(policy.mediaByteLimit, 512 * 1024 * 1024)
        XCTAssertEqual(Set(RetentionFeatures.definitions.map(\.key)).count, RetentionFeatures.definitions.count)
    }

    func testAyuKnownSenderTakesPrecedenceOverBotDialogFallback() {
        let policy = enabled()
        XCTAssertFalse(policy.keepsDeleted(in: .init(kind: .privateChat, chatIsBot: true)))
        XCTAssertFalse(policy.keepsDeleted(in: .init(kind: .group(isPublic: true), senderIsBot: true)))
        // AyuSavePreferences.java:93-124 returns immediately for a resolved non-bot sender.
        XCTAssertTrue(policy.keepsDeleted(in: .init(kind: .privateChat, chatIsBot: true, senderIsBot: false)))
        XCTAssertTrue(enabled(["privacy.saveDeletedMessageForBotUser": .bool(true)]).keepsDeleted(in: .init(kind: .privateChat, chatIsBot: true, senderIsBot: true)))
        XCTAssertFalse(enabled(["privacy.saveDeletedMessageForBot": .bool(true)]).keepsDeleted(in: .init(kind: .privateChat, chatIsBot: true, senderIsBot: true)))
    }

    func testEditsDoNotInheritDeletedChatKindOrBotFiltersButDoHonorArchiveAndTheirOwnMarks() {
        let policy = enabled(["privacy.saveDeletedInPrivateChats": .bool(false), "privacy.saveDeletedInGroups": .bool(false), "privacy.saveDeletedInChannels": .bool(false), "privacy.saveInArchivedChats": .bool(false)])
        let peer = RetentionPeerFacts(kind: .channel(isPublic: false), chatIsBot: true, senderIsBot: true)
        XCTAssertFalse(policy.keepsDeleted(in: peer))
        XCTAssertTrue(policy.keepsEdits(in: peer))
        XCTAssertFalse(policy.keepsEdits(in: .init(kind: .privateChat, isArchived: true)))
        XCTAssertTrue(policy.keepsEdits(in: peer, chat: .init(deleted: true)))
        XCTAssertFalse(policy.keepsEdits(in: peer, sender: .init(edited: true)))
        let onlyMarked = enabled(["privacy.saveEditedExceptionsMode": .integer(1)])
        XCTAssertFalse(onlyMarked.keepsEdits(in: peer))
        XCTAssertTrue(onlyMarked.keepsEdits(in: peer, sender: .init(edited: true)))
    }

    func testDeletedAllowListMatchesChatOrAuthorAndCannotOverrideDisabledKind() {
        let peer = RetentionPeerFacts(kind: .group(isPublic: false))
        let policy = enabled(["privacy.saveDeletedExceptionsMode": .integer(1)])
        XCTAssertFalse(policy.keepsDeleted(in: peer))
        XCTAssertTrue(policy.keepsDeleted(in: peer, chat: .init(deleted: true)))
        XCTAssertTrue(policy.keepsDeleted(in: peer, sender: .init(deleted: true)))
        XCTAssertFalse(enabled(["privacy.saveDeletedExceptionsMode": .integer(1), "privacy.saveDeletedInGroups": .bool(false)]).keepsDeleted(in: peer, chat: .init(deleted: true)))
    }

    func testEveryMediaKindAndMasterGate() {
        let cases: [(RetentionPeerFacts.Kind, String)] = [
            (.privateChat, "saveMediaInPrivateChats"), (.group(isPublic: true), "saveMediaInPublicGroups"),
            (.group(isPublic: false), "saveMediaInPrivateGroups"), (.channel(isPublic: true), "saveMediaInPublicChannels"),
            (.channel(isPublic: false), "saveMediaInPrivateChannels")
        ]
        for (kind, field) in cases {
            XCTAssertTrue(enabled().keepsMedia(in: .init(kind: kind)))
            XCTAssertFalse(enabled(["privacy.\(field)": .bool(false)]).keepsMedia(in: .init(kind: kind)))
            XCTAssertFalse(enabled(["privacy.messageSavingSaveMedia": .bool(false)]).keepsMedia(in: .init(kind: kind)))
        }
    }

    func testSignedAndroidARGBAndSingleLineMark() {
        let policy = RetentionPolicy(values: ["chats.deletedMarkColor": .integer(-65536), "chats.customDeletedMark": .string("deleted\n\r\0label")])
        XCTAssertEqual(policy.deletedColorARGB, 0xffff0000)
        XCTAssertEqual(policy.deletedMark, "deletedlabel")
        XCTAssertNil(RetentionPolicy(values: ["chats.deletedMarkColor": .integer(Int64.max)]).deletedColorARGB)
    }

    func testNativeLimitsDoNotOverflowForImportedSettings() {
        let policy = RetentionPolicy(values: ["privacy.retentionDays": .integer(Int64.max), "privacy.retentionMessageLimit": .integer(-1), "privacy.retentionMediaMegabytes": .integer(Int64.max)])
        XCTAssertEqual(policy.days, 365)
        XCTAssertEqual(policy.messageLimit, 100)
        XCTAssertEqual(policy.mediaByteLimit, 2048 * 1024 * 1024)
    }

    func testRealCodableRoundTripReplayAndSameSecondEditOrder() throws {
        var record = RetentionPolicyRecord(key: key)
        XCTAssertTrue(try record.captureEdit(payload: Data("first".utf8), fingerprint: hash("a"), resourceIds: ["file-a"], previousVersionDate: 100, incomingFingerprint: hash("b"), incomingEditDate: 101, now: 1000))
        record = try JSONDecoder().decode(RetentionPolicyRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(try record.captureEdit(payload: Data("first".utf8), fingerprint: hash("a"), resourceIds: ["file-a"], previousVersionDate: 100, incomingFingerprint: hash("b"), incomingEditDate: 101, now: 9999))
        XCTAssertTrue(try record.captureEdit(payload: Data("second".utf8), fingerprint: hash("b"), resourceIds: ["file-a"], previousVersionDate: 101, incomingFingerprint: hash("c"), incomingEditDate: 101, now: 1001))
        XCTAssertTrue(try record.captureEdit(payload: Data("third".utf8), fingerprint: hash("c"), resourceIds: ["file-b"], previousVersionDate: 101, incomingFingerprint: hash("d"), incomingEditDate: 101, now: 1002))
        XCTAssertEqual(record.chronologicalVersions.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(record.versions.first?.capturedAt, 1000)
        XCTAssertEqual(record.resourceIds, ["file-a", "file-b"])
    }

    func testDeleteEditRaceNeverResurrectsOrRenewsDeletion() throws {
        var record = RetentionPolicyRecord(key: key)
        XCTAssertTrue(try record.captureDeletion(payload: Data("received".utf8), fingerprint: hash("a"), resourceIds: [], messageVersionDate: 100, now: 1000))
        XCTAssertFalse(try record.captureEdit(payload: Data("late".utf8), fingerprint: hash("b"), resourceIds: [], previousVersionDate: 101, incomingFingerprint: hash("c"), incomingEditDate: 102, now: 1001))
        XCTAssertFalse(try record.captureDeletion(payload: Data("replay".utf8), fingerprint: hash("d"), resourceIds: [], messageVersionDate: 102, now: 1002))
        XCTAssertEqual(record.deletedAt, 1000)
        record.prune(cutoff: 1000)
        XCTAssertTrue(record.versions.isEmpty)
        XCTAssertNil(record.deletedAt)
    }

    func testStaleEditsDoNotChangeArchiveAndNativePayloadIsBounded() throws {
        var record = RetentionPolicyRecord(key: key)
        XCTAssertFalse(try record.captureEdit(payload: Data([1]), fingerprint: hash("a"), resourceIds: [], previousVersionDate: 200, incomingFingerprint: hash("b"), incomingEditDate: 100, now: 1000))
        XCTAssertThrowsError(try record.captureDeletion(payload: Data(repeating: 0, count: RetentionPolicy.maximumVersionBytes + 1), fingerprint: hash("a"), resourceIds: [], messageVersionDate: 100, now: 1000))
        XCTAssertTrue(record.versions.isEmpty)
        XCTAssertThrowsError(try record.captureDeletion(payload: Data([1]), fingerprint: hash("a"), resourceIds: ["../outside"], messageVersionDate: 100, now: 1000))
    }

    func testVersionOneMigrationRejectsUnknownFieldsAndPreservesDedup() throws {
        var original = RetentionPolicyRecord(key: key)
        try original.captureEdit(payload: Data([1]), fingerprint: hash("a"), resourceIds: [], previousVersionDate: 100, incomingFingerprint: hash("b"), incomingEditDate: 101, now: 1000)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["formatVersion"] = 1
        object.removeValue(forKey: "nextSequence")
        object.removeValue(forKey: "events")
        object.removeValue(forKey: "lastEditDate")
        var migrated = try JSONDecoder().decode(RetentionPolicyRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.nextSequence, 2)
        XCTAssertFalse(try migrated.captureEdit(payload: Data([1]), fingerprint: hash("a"), resourceIds: [], previousVersionDate: 100, incomingFingerprint: hash("b"), incomingEditDate: 101, now: 1001))
        object["unknown"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(RetentionPolicyRecord.self, from: JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "unknown")
        object["formatVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(RetentionPolicyRecord.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testReplyQuoteUTF16OffsetAndTruncationDoNotSplitEmojiOrDropBody() throws {
        let value = try RetentionPolicyQuote.prefix(author: "A🙂", quote: "first🙂second", body: "reply", maximumLength: 16)
        XCTAssertTrue(value.text.hasSuffix("\nreply"))
        XCTAssertEqual(value.authorLength, 3)
        XCTAssertEqual(value.bodyOffset + "reply".utf16.count, value.text.utf16.count)
        XCTAssertLessThanOrEqual(value.text.utf16.count, 16)
        XCTAssertFalse(value.text.contains("�"))
        XCTAssertThrowsError(try RetentionPolicyQuote.prefix(author: "author", quote: "text", body: "a full body", maximumLength: 5))
    }
}
