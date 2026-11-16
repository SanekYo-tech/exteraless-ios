import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import XCTest
@testable import TelegramUI

@MainActor
final class ChatSoundProducerTests: XCTestCase {
    private let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))
    private func message(kind: Int) -> EnqueueMessage {
        let id = MediaId(namespace: Namespaces.Media.LocalFile, id: 8)
        let resource = LocalFileMediaResource(fileId: 8)
        let image = TelegramMediaImage(imageId: id, representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 32, height: 32), resource: resource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        var attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 2 ..< 6, type: .Bold)])]
        var media: AnyMediaReference?
        if kind == 1 { media = .standalone(media: image) }
        if kind == 2 || kind == 3 {
            var fileAttributes: [TelegramMediaFileAttribute] = [.Video(duration: 20, size: PixelDimensions(width: 32, height: 32), flags: kind == 2 ? [.instantRoundVideo] : [], preloadSize: nil, coverTime: nil, videoCodec: nil)]
            if kind == 3 { fileAttributes.append(.Animated) }
            media = .standalone(media: TelegramMediaFile(fileId: id, partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: 128, attributes: fileAttributes, alternativeRepresentations: []))
        }
        if kind == 4 { attributes.append(OutgoingChatContextResultMessageAttribute(queryId: 1, id: "inline", hideVia: true, webpageUrl: nil)) }
        if kind == 5 { return .forward(source: MessageId(peerId: peer, namespace: 0, id: 3), threadId: 42, grouping: .auto, attributes: attributes, correlationId: 200) }
        if kind == 6 {
            attributes.append(RichTextMessageAttribute(instantPage: InstantPage(blocks: [.paragraph(.plain("rich"))], media: [id: .image(image)], isComplete: true, rtl: false, url: "", views: nil), fullInstantPage: nil))
        }
        return .message(text: kind == 6 ? "" : "😀漢ABC", attributes: attributes, inlineStickers: [:], mediaReference: media, threadId: 42, replyToMessageId: .init(messageId: MessageId(peerId: peer, namespace: 0, id: 9), quote: nil, innerSubject: nil), replyToStoryId: nil, localGroupingKey: 100, correlationId: 200, bubbleUpEmojiOrStickersets: [])
    }

    func testTextPhotoRoundGIFInlineForwardRichProducerMatrixResolvesSoundOnce() throws {
        let intents: [Bool?] = [nil, false, true]
        for kind in 0 ..< 7 {
            for native in [false, true] {
                for global in [false, true] {
                    for intent in intents {
                        let original = message(kind: kind)
                        let options = ExteralessChatSendOptions(silentPosting: intent, nativeSilent: native, defaultSilent: global, scheduleTime: 12345, repeatPeriod: 3600)
                        let prepared = options.applying(to: original)
                        // Re-entering sendMessages uses defaults only, even if settings changed.
                        let sent = ExteralessChatSendOptions(silentPosting: nil, nativeSilent: !native, defaultSilent: !global).applying(to: prepared)
                        var observed: EnqueueMessage?
                        let subscription = exteralessSubmitChatBatch(messages: [sent], operation: nil, enqueue: { values in
                            observed = values.first
                            return .single(.committed(messageIds: [MessageId(peerId: self.peer, namespace: Namespaces.Message.Local, id: 1)]))
                        }).start()
                        let actual = try XCTUnwrap(observed)
                        let sound = try XCTUnwrap(actual.attributes.compactMap { $0 as? NotificationInfoMessageAttribute }.first)
                        XCTAssertEqual(sound.flags.contains(.muted), intent ?? (native || global))
                        XCTAssertEqual(actual.attributes.filter { $0 is NotificationInfoMessageAttribute }.count, 1)
                        let schedule = try XCTUnwrap(actual.attributes.compactMap { $0 as? OutgoingScheduleInfoMessageAttribute }.first)
                        XCTAssertEqual(schedule.scheduleTime, 12345); XCTAssertEqual(schedule.repeatPeriod, 3600)
                        XCTAssertTrue(actual.attributes.contains { ($0 as? TextEntitiesMessageAttribute) === (original.attributes.first as? TextEntitiesMessageAttribute) })
                        if case let .message(text, attributes, _, media, thread, reply, _, group, correlation, _) = actual,
                           case let .message(oldText, oldAttributes, _, oldMedia, _, _, _, _, _, _) = original {
                            XCTAssertEqual(text, oldText); XCTAssertEqual(thread, 42); XCTAssertEqual(group, 100); XCTAssertEqual(correlation, 200)
                            XCTAssertEqual(reply?.messageId.id, 9)
                            if let oldMedia { XCTAssertTrue(media?.media.isEqual(to: oldMedia.media) == true) }
                            else { XCTAssertNil(media) }
                            if kind == 6 { XCTAssertTrue((attributes.compactMap { $0 as? RichTextMessageAttribute }.first) === oldAttributes.compactMap { $0 as? RichTextMessageAttribute }.first) }
                        }
                        subscription.dispose()
                    }
                }
            }
        }
    }

    func testScheduleSeedIncludesBothDefaultsAndExplicitAudibleWins() {
        XCTAssertTrue(ExteralessChatSendOptions.scheduleSilent(nativeSilent: false, defaultSilent: true))
        XCTAssertTrue(ExteralessChatSendOptions.scheduleSilent(nativeSilent: true, defaultSilent: false))
        XCTAssertFalse(ExteralessChatSendOptions.scheduleSilent(nativeSilent: true, defaultSilent: true, explicit: false))
        let audible = ExteralessChatSendOptions(silentPosting: false, nativeSilent: true, defaultSilent: true).applying(to: message(kind: 1))
        XCTAssertEqual(ExteralessChatSendOptions.existingSilent(in: [audible]), false)
    }
}
