import ExteralessCore
import Foundation
import Postbox

/// New-send transaction hook. Resends keep their already stored quote. No server reply to a
/// deleted id is fabricated; threadId still directs the send to its actual forum/discussion.
func exteralessRewriteDeletedReplies(transaction: Transaction, accountPeerId: PeerId, messages: [(Bool, EnqueueMessage)], policy: RetentionPolicy = .current) -> Result<[(Bool, EnqueueMessage)], ExteralessRetentionError> {
    guard policy.replyToDeletedAsQuote else { return .success(messages) }
    guard messages.contains(where: { _, value in
        if case let .message(_, _, _, _, _, reply?, _, _, _, _) = value { return transaction.getMessage(reply.messageId) == nil }
        return false
    }) else { return .success(messages) }
    do {
        let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: accountPeerId, policy: policy, now: Int64(Date().timeIntervalSince1970))
        let configuration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue
        let limits = UserLimitsConfiguration(appConfiguration: configuration, isPremium: (transaction.getPeer(accountPeerId) as? TelegramUser)?.isPremium ?? false)
        var quotedGroups = Set<Int64>()
        return .success(try messages.map { transformed, value in
            guard case let .message(text, attributes, stickers, media, threadId, reply, story, groupingKey, correlation, bubbleUp) = value,
                  let reply, transaction.getMessage(reply.messageId) == nil else { return (transformed, value) }
            let key = RetentionMessageKey(peerId: reply.messageId.peerId.toInt64(), namespace: reply.messageId.namespace, id: reply.messageId.id)
            guard let record = try store.record(key), record.deletedAt != nil,
                  let version = record.versions.last(where: { $0.reason == .deleted }) else { return (transformed, value) }
            let snapshot = try JSONDecoder().decode(ExteralessRetentionSnapshot.self, from: version.payload)
            let source = try snapshot.render(version: version)
            if let groupingKey, !quotedGroups.insert(groupingKey).inserted {
                return (transformed, value.withUpdatedReplyToMessageId(nil))
            }
            let author = source.author ?? source.forwardInfo?.author ?? transaction.getPeer(accountPeerId)
            let authorName = exteralessRetentionAuthorName(author) ?? source.forwardInfo?.authorSignature ?? "Deleted message"
            let quote = reply.quote?.text ?? (source.text.isEmpty ? source.richText.map { exteralessRetentionRichText($0.fullInstantPage ?? $0.instantPage) } ?? "" : source.text)
            let prefix = try RetentionPolicyQuote.prefix(author: authorName, quote: quote, body: text, maximumLength: max(1, Int(media == nil ? limits.maxMessageLength : limits.maxCaptionLength)))
            var rewritten: [MessageAttribute] = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
            let bodyEntities = attributes.compactMap { ($0 as? TextEntitiesMessageAttribute)?.entities }.flatMap { $0 }
            guard bodyEntities.allSatisfy({ $0.range.lowerBound >= 0 && $0.range.upperBound <= text.utf16.count }) else { throw ExteralessRetentionError.invalidArchive }
            var entities = bodyEntities.map { MessageTextEntity(range: ($0.range.lowerBound + prefix.bodyOffset) ..< ($0.range.upperBound + prefix.bodyOffset), type: $0.type) }
            entities.append(MessageTextEntity(range: 0 ..< prefix.quoteLength, type: .BlockQuote(isCollapsed: true)))
            entities.append(MessageTextEntity(range: 0 ..< prefix.authorLength, type: .Bold))
            if let author, author.id.namespace == Namespaces.Peer.CloudUser, transaction.getPeer(author.id) != nil {
                entities.append(MessageTextEntity(range: 0 ..< prefix.authorLength, type: .TextMention(peerId: author.id)))
            }
            rewritten.append(TextEntitiesMessageAttribute(entities: entities))
            if let rich = attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute {
                let prefixString = prefix.text as NSString
                let header = prefixString.substring(with: NSRange(location: 0, length: prefix.authorLength))
                let quotedText = prefixString.substring(with: NSRange(location: prefix.authorLength + 1, length: prefix.quoteLength - prefix.authorLength - 1))
                let quoteBlock = InstantPageBlock.blockQuote(blocks: [.paragraph(.bold(.plain(header))), .paragraph(.plain(quotedText))], caption: .empty, collapsed: true)
                func page(_ page: InstantPage) -> InstantPage {
                    InstantPage(blocks: [quoteBlock] + page.blocks, rawMedia: page.rawMedia, isComplete: page.isComplete, rtl: page.rtl, url: page.url, views: page.views)
                }
                rewritten.removeAll { $0 is RichTextMessageAttribute }
                rewritten.append(RichTextMessageAttribute(instantPage: page(rich.instantPage), fullInstantPage: rich.fullInstantPage.map(page)))
            }
            return (transformed, .message(text: prefix.text, attributes: rewritten, inlineStickers: stickers, mediaReference: media, threadId: threadId, replyToMessageId: nil, replyToStoryId: story, localGroupingKey: groupingKey, correlationId: correlation, bubbleUpEmojiOrStickersets: bubbleUp))
        })
    } catch { return .failure(exteralessRetentionError(error)) }
}

func exteralessRetentionAuthorName(_ peer: Peer?) -> String? {
    if let user = peer as? TelegramUser {
        let name = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    } else if let channel = peer as? TelegramChannel { return channel.title }
    else if let group = peer as? TelegramGroup { return group.title }
    return nil
}
