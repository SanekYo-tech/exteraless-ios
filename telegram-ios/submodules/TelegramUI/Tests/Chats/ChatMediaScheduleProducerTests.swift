import AccountContext
import ChatScheduleTimeController
import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import XCTest
@testable import ChatSendMessageActionUI
@testable import MediaPickerUI
@testable import TelegramUI

@MainActor
final class ChatMediaScheduleProducerTests: XCTestCase {
    private let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))

    private func media(_ id: Int64) -> EnqueueMessage {
        let mediaId = MediaId(namespace: Namespaces.Media.LocalImage, id: id)
        let image = TelegramMediaImage(imageId: mediaId, representations: [
            TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 16, height: 16), resource: LocalFileMediaResource(fileId: id), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
        ], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let attributes: [MessageAttribute] = [
            TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 2 ..< 6, type: .Bold)]),
            MediaSpoilerMessageAttribute(),
            PaidStarsMessageAttribute(stars: StarsAmount(value: 3, nanos: 0), postponeSending: true),
            SendAsMessageAttribute(peerId: peer),
            RichTextMessageAttribute(instantPage: InstantPage(blocks: [.paragraph(.plain("caption"))], media: [mediaId: image], isComplete: true, rtl: false, url: "", views: nil), fullInstantPage: nil)
        ]
        return .message(text: "😀漢ABC", attributes: attributes, inlineStickers: [:], mediaReference: .standalone(media: image), threadId: 42, replyToMessageId: .init(messageId: MessageId(peerId: peer, namespace: 0, id: 9), quote: nil, innerSubject: nil), replyToStoryId: nil, localGroupingKey: 100, correlationId: id, bubbleUpEmojiOrStickersets: [])
    }

    /// This is the production parameter conversion used by commitEnqueueMediaMessages,
    /// followed by the sound stage used on sendMessages re-entry and the real batch
    /// ingress. Only the final local enqueue is replaced; no Account is constructed.
    private func enqueue(_ original: [EnqueueMessage], silently: Bool, time: Int32?, parameters: ChatSendMessageActionSheetController.SendParameters?, native: Bool, global: Bool) -> [EnqueueMessage] {
        let parameters = mediaPickerSendParameters(parameters, textIsAboveMedia: false)
        let converted = ChatControllerImpl.prepareMediaEnqueueMessages(original, silentPosting: silently, scheduleTime: time, parameters: parameters, transform: { messages, intent, time, period in
            let options = ExteralessChatSendOptions(silentPosting: intent, nativeSilent: native, defaultSilent: global, scheduleTime: time, repeatPeriod: period)
            return messages.map { options.applying(to: $0) }
        })
        let secondTransform = ExteralessChatSendOptions(silentPosting: nil, nativeSilent: !native, defaultSilent: !global)
        let sent = converted.map { secondTransform.applying(to: $0) }
        var observed: [EnqueueMessage] = []
        var enqueueCount = 0
        let disposable = exteralessSubmitChatBatch(messages: sent, operation: nil, enqueue: { messages in
            enqueueCount += 1
            observed = messages
            return .single(.committed(messageIds: messages.indices.map { MessageId(peerId: self.peer, namespace: Namespaces.Message.Local, id: Int32($0 + 1)) }))
        }).start()
        disposable.dispose()
        XCTAssertEqual(enqueueCount, 1)
        XCTAssertEqual(observed.count, original.count)
        return observed
    }

    private func assertMessage(_ actual: EnqueueMessage, original: EnqueueMessage, silent: Bool, time: Int32?, period: Int32?, effect: Int64?, above: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let notifications = actual.attributes.compactMap { $0 as? NotificationInfoMessageAttribute }
        XCTAssertEqual(notifications.count, 1, file: file, line: line)
        XCTAssertEqual(notifications.first?.flags.contains(.muted), silent, file: file, line: line)
        let schedules = actual.attributes.compactMap { $0 as? OutgoingScheduleInfoMessageAttribute }
        XCTAssertEqual(schedules.count, time == nil ? 0 : 1, file: file, line: line)
        XCTAssertEqual(schedules.first?.scheduleTime, time, file: file, line: line)
        XCTAssertEqual(schedules.first?.repeatPeriod, period, file: file, line: line)
        XCTAssertEqual(actual.attributes.compactMap { ($0 as? EffectMessageAttribute)?.id }, effect.map { [$0] } ?? [], file: file, line: line)
        XCTAssertEqual(actual.attributes.filter { $0 is InvertMediaMessageAttribute }.count, above ? 1 : 0, file: file, line: line)
        for attribute in original.attributes where !(attribute is OutgoingScheduleInfoMessageAttribute) && !(attribute is NotificationInfoMessageAttribute) {
            XCTAssertTrue(actual.attributes.contains { ($0 as AnyObject) === (attribute as AnyObject) }, file: file, line: line)
        }
        guard case let .message(text, _, _, media, thread, reply, _, group, correlation, _) = actual,
              case let .message(oldText, _, _, oldMedia, oldThread, oldReply, _, oldGroup, oldCorrelation, _) = original else {
            return XCTFail("Media envelope changed", file: file, line: line)
        }
        XCTAssertEqual(text, oldText, file: file, line: line)
        XCTAssertEqual(thread, oldThread, file: file, line: line)
        XCTAssertEqual(reply?.messageId, oldReply?.messageId, file: file, line: line)
        XCTAssertEqual(group, oldGroup, file: file, line: line)
        XCTAssertEqual(correlation, oldCorrelation, file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(media, file: file, line: line).media.isEqual(to: XCTUnwrap(oldMedia, file: file, line: line).media), file: file, line: line)
    }

    func testActualMediaScheduleCompletionOverridesOldIntentAcrossBothDefaults() throws {
        let original = [media(8), media(9)]
        for native in [false, true] {
            for global in [false, true] {
                for choice in [false, true] {
                    for oldIntent in [nil, false, true] as [Bool?] {
                        var parameters = chatSendMessageScheduleParameters(effectId: 71, textIsAboveMedia: true)
                        XCTAssertNil(parameters.notificationOverride)
                        XCTAssertNil(parameters.schedule)
                        parameters.notificationOverride = oldIntent
                        var observed: [EnqueueMessage] = []
                        let pickerCompletion = mediaPickerScheduleCompletion(parameters: parameters, textIsAboveMedia: false, send: { silent, time, parameters in
                            XCTAssertEqual(parameters.notificationOverride, choice)
                            XCTAssertEqual(parameters.schedule?.repeatPeriod, 3600)
                            observed = self.enqueue(original, silently: silent, time: time, parameters: parameters, native: native, global: global)
                        })
                        // The menu's effect/caption are captured before the picker returns.
                        parameters.effect = .init(id: 99)
                        parameters.textIsAboveMedia = false
                        let actualScheduleCompletion = exteralessMediaScheduleCompletion(pickerCompletion)
                        actualScheduleCompletion(ChatScheduleTimeScreen.Result(time: 1_800_000_001, repeatPeriod: 3600, silentPosting: choice))
                        XCTAssertEqual(observed.count, 2)
                        for (value, source) in zip(observed, original) {
                            try assertMessage(value, original: source, silent: choice, time: 1_800_000_001, period: 3600, effect: 71, above: true)
                        }
                    }
                }
            }
        }
    }

    func testOrdinaryTapKeepsAbsentOverrideAndUsesDefaultsOnce() throws {
        let original = [media(10)]
        for native in [false, true] {
            for global in [false, true] {
                // The same nil-parameter normalization as MediaPickerScreen.Node.send.
                let parameters = mediaPickerSendParameters(nil, textIsAboveMedia: true)
                XCTAssertNil(parameters.notificationOverride)
                XCTAssertNil(parameters.schedule)
                let actual = enqueue(original, silently: false, time: nil, parameters: parameters, native: native, global: global)
                try assertMessage(XCTUnwrap(actual.first), original: original[0], silent: native || global, time: nil, period: nil, effect: nil, above: true)
            }
        }
    }

    func testFullNewResultReplacesStaleTimePeriodAndNotificationParameters() throws {
        let original = [media(11).withUpdatedAttributes { $0 + [OutgoingScheduleInfoMessageAttribute(scheduleTime: 100, repeatPeriod: 86400)] }]
        let old = ChatSendMessageActionSheetController.SendParameters(effect: .init(id: 72), textIsAboveMedia: false, schedule: .init(time: 100, repeatPeriod: 86400, silentPosting: true))
        var observed: [EnqueueMessage] = []
        let pickerCompletion = mediaPickerScheduleCompletion(parameters: old, textIsAboveMedia: true, send: { _, _, parameters in
            var conflicting = parameters
            conflicting.notificationOverride = true
            // The full result also outranks a stale legacy Bool/time pair.
            observed = self.enqueue(original, silently: true, time: 100, parameters: conflicting, native: true, global: true)
        })
        exteralessMediaScheduleCompletion(pickerCompletion)(.init(time: 200, repeatPeriod: nil, silentPosting: false))
        try assertMessage(XCTUnwrap(observed.first), original: original[0], silent: false, time: 200, period: nil, effect: 72, above: false)
    }

    func testLegacyGalleryScheduleKeepsFullResultOnlyInsideItsCompletion() throws {
        let original = [media(12)]
        let bridge = MediaPickerLegacyScheduleBridge()
        for choice in [false, true] {
            var observed: [EnqueueMessage] = []
            let completion = exteralessMediaScheduleCompletion { result in
                bridge.complete(result, legacyCompletion: { time, silent in
                    let parameters = bridge.parameters(textIsAboveMedia: true)
                    XCTAssertEqual(parameters?.notificationOverride, choice)
                    observed = self.enqueue(original, silently: silent, time: time, parameters: parameters, native: true, global: true)
                })
            }
            completion(.init(time: 300, repeatPeriod: 7200, silentPosting: choice))
            try assertMessage(XCTUnwrap(observed.first), original: original[0], silent: choice, time: 300, period: 7200, effect: nil, above: true)
            XCTAssertNil(bridge.parameters(textIsAboveMedia: true))
        }
        let ordinary = enqueue(original, silently: false, time: nil, parameters: bridge.parameters(textIsAboveMedia: false), native: true, global: false)
        try assertMessage(XCTUnwrap(ordinary.first), original: original[0], silent: true, time: nil, period: nil, effect: nil, above: false)
    }
}
