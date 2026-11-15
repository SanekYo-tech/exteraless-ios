import ExteralessCore
import Foundation
import PluginHooks
import Postbox
import XCTest
@testable import TelegramCore

/// Value transforms only: no Account, network, Postbox transaction, send or delete is constructed.
final class ExteralessOutgoingChatTextTests: XCTestCase {
    private let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))
    private func message(attributes: [MessageAttribute] = []) -> EnqueueMessage {
        .message(text: "漢ABC", attributes: attributes, inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaMap(latitude: 0, longitude: 0, heading: nil, accuracyRadius: nil, venue: nil)), threadId: 42, replyToMessageId: .init(messageId: MessageId(peerId: peer, namespace: 0, id: 8), quote: .init(text: "quote", offset: 1, entities: [], media: nil), innerSubject: nil), replyToStoryId: nil, localGroupingKey: 100, correlationId: 200, bubbleUpEmojiOrStickersets: [])
    }
    private func settings() throws -> ClientSettings {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let settings = try ClientSettings(storageURL: folder.appendingPathComponent("settings.json"))
        try settings.register(ChatFeatures.definitions)
        return settings
    }
    func testExplicitAudibleAndPluginModifyWinSilentDefaultWithoutLosingMediaReplyOrGrouping() throws {
        let original = message(attributes: [NotificationInfoMessageAttribute(flags: [.personal, .automaticMessage])])
        let audible = exteralessDefaultSendNotifications([original.withNotificationOverride(silent: false)], defaultSilent: true)[0]
        let flags = try XCTUnwrap(audible.attributes.compactMap { $0 as? NotificationInfoMessageAttribute }.first?.flags)
        XCTAssertFalse(flags.contains(.muted))
        XCTAssertTrue(flags.contains(.personal)); XCTAssertTrue(flags.contains(.automaticMessage))
        let muted = exteralessDefaultSendNotifications([message()], defaultSilent: true)[0]
        let changed = try XCTUnwrap(exteralessApplyPluginSendResult(.modifyFinal(.init(silent: false)), to: muted))
        guard case let .message(text, attributes, _, media, thread, reply, _, grouping, correlation, _) = changed else { return XCTFail() }
        XCTAssertEqual(text, "漢ABC")
        XCTAssertTrue(media?.media is TelegramMediaMap)
        XCTAssertEqual(thread, 42); XCTAssertEqual(grouping, 100); XCTAssertEqual(correlation, 200)
        XCTAssertEqual(reply?.quote?.text, "quote")
        XCTAssertFalse(try XCTUnwrap(attributes.compactMap { $0 as? NotificationInfoMessageAttribute }.first).flags.contains(.muted))
    }
    func testCancelIsOmittedBeforeEffectsAndKeepsOriginalResultSlots() {
        XCTAssertNil(exteralessApplyPluginSendResult(.cancel, to: message()))
        let id = MessageId(peerId: peer, namespace: 0, id: 9)
        XCTAssertEqual(exteralessPluginSendResultSlots(count: 3, acceptedIndices: [1], ids: [id]), [nil, id, nil])
        XCTAssertEqual(exteralessPluginSendResultSlots(count: 2, acceptedIndices: [], ids: []), [nil, nil])
    }
    func testPanguRemapsEntitiesAndNeverRewritesRichPayloadOrSecretChatText() throws {
        let store = try settings()
        try store.set(.bool(true), for: "chats.enablePanguOnSending")
        let entities = TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< 4, type: .Bold)])
        let transformed = exteralessPrepareOutgoingChatText([message(attributes: [entities])], peerId: peer, settings: store)[0]
        guard case let .message(text, attributes, _, _, _, reply, _, grouping, correlation, _) = transformed else { return XCTFail() }
        XCTAssertEqual(text, "漢\u{2009}ABC")
        XCTAssertEqual(attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities.first?.range, 0 ..< 5)
        XCTAssertNotNil(reply); XCTAssertEqual(grouping, 100); XCTAssertEqual(correlation, 200)
        let page = InstantPage(blocks: [.paragraph(.plain("漢ABC"))], media: [:], isComplete: true, rtl: false, url: "", views: nil)
        let rich = RichTextMessageAttribute(instantPage: page, fullInstantPage: nil)
        let untouched = exteralessPrepareOutgoingChatText([message(attributes: [rich])], peerId: peer, settings: store)[0]
        XCTAssertTrue((untouched.attributes.first as? RichTextMessageAttribute) === rich)
        let secret = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(7))
        if case let .message(text, _, _, _, _, _, _, _, _, _) = exteralessPrepareOutgoingChatText([message()], peerId: secret, settings: store)[0] { XCTAssertEqual(text, "漢ABC") }
        else { XCTFail() }
    }

    func testWholeBotCommandIncludingStyledArgumentsBypassesPangu() throws {
        let store = try settings()
        try store.set(.bool(true), for: "chats.enablePanguOnSending")
        let text = "/run 😀漢ABC"
        let styled = MessageTextEntity(range: 7 ..< 11, type: .Bold)
        for entities in [[], [styled], [MessageTextEntity(range: 0 ..< 4, type: .BotCommand), styled]] {
            let attribute = TextEntitiesMessageAttribute(entities: entities)
            let original = EnqueueMessage.message(text: text, attributes: [attribute], inlineStickers: [:], mediaReference: nil, threadId: 42, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: 100, correlationId: 200, bubbleUpEmojiOrStickersets: [])
            let result = exteralessPrepareOutgoingChatText([original], peerId: peer, settings: store)[0]
            guard case let .message(actual, attributes, _, _, thread, _, _, group, correlation, _) = result else { return XCTFail() }
            XCTAssertEqual(Array(actual.utf16), Array(text.utf16))
            XCTAssertTrue((attributes.first as? TextEntitiesMessageAttribute) === attribute)
            XCTAssertEqual((attributes.first as? TextEntitiesMessageAttribute)?.entities, entities)
            XCTAssertEqual(thread, 42); XCTAssertEqual(group, 100); XCTAssertEqual(correlation, 200)
        }
        guard case let .message(prose, _, _, _, _, _, _, _, _, _) = exteralessPrepareOutgoingChatText([message()], peerId: peer, settings: store)[0] else { return XCTFail() }
        XCTAssertEqual(prose, "漢\u{2009}ABC")
    }
}
