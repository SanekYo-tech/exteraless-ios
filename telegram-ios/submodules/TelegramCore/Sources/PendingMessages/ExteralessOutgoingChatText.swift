import ExteralessCore
import Foundation
import Postbox

/// One value-only stage before PluginHooks. Post-plugin values are not reformatted; MODIFY,
/// explicit notification/preview attributes and plugin-origin recursion bypass remain authoritative.
func exteralessPrepareOutgoingChatText(_ messages: [EnqueueMessage], peerId: PeerId, settings: ClientSettings = .shared) -> [EnqueueMessage] {
    let pangu = settings.bool("chats.enablePanguOnSending") && peerId.namespace != Namespaces.Peer.SecretChat
    let disablePreview = settings.bool("chats.disableLinkPreviewByDefault")
    return messages.map { original in
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = original else { return original }
        var result = original
        if pangu, !text.isEmpty, !text.hasPrefix("/"), text.utf16.count <= 4096, !attributes.contains(where: { $0 is RichTextMessageAttribute || $0 is InlineBotMessageAttribute }) {
            let entities = attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.flatMap(\.entities)
            if entities.count <= 256 {
                let source = NSMutableAttributedString(string: text)
                var protected: [NSRange] = []
                var valid = true
                for (index, entity) in entities.enumerated() {
                    let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
                    guard range.location >= 0, range.length > 0, range.location <= source.length, range.length <= source.length - range.location else { valid = false; break }
                    source.addAttribute(NSAttributedString.Key("entity.\(index)"), value: true, range: range)
                    switch entity.type {
                    case .Bold, .Italic, .Strikethrough, .Underline, .Spoiler, .BlockQuote: break
                    default: protected.append(range)
                    }
                }
                if valid {
                    let spaced = ChatPanguPolicy.applying(to: source, protectedRanges: protected)
                    // Do not create a now-oversize network message; the composer's native split has run.
                    if spaced.string != text, spaced.length <= 4096 {
                        var updatedEntities: [MessageTextEntity] = []
                        for (index, entity) in entities.enumerated() {
                            spaced.enumerateAttribute(NSAttributedString.Key("entity.\(index)"), in: NSRange(location: 0, length: spaced.length), options: []) { value, range, _ in
                                if value != nil { updatedEntities.append(MessageTextEntity(range: range.location ..< NSMaxRange(range), type: entity.type)) }
                            }
                        }
                        updatedEntities.sort { $0.range.lowerBound < $1.range.lowerBound }
                        var updatedAttributes = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
                        if !updatedEntities.isEmpty { updatedAttributes.append(TextEntitiesMessageAttribute(entities: updatedEntities)) }
                        result = .message(text: spaced.string, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
                    }
                }
            }
        }
        if disablePreview, !result.attributes.contains(where: { $0 is OutgoingContentInfoMessageAttribute || $0 is WebpagePreviewMessageAttribute }) {
            result = result.withLinkPreviewOverride(disabled: true)
        }
        return result
    }
}
