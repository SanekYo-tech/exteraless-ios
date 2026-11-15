import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

public enum ExteralessAIRichSource {
    /// A whole-message operation uses the best available source, not its preview.
    public static func wholePage(_ attribute: RichTextMessageAttribute) -> InstantPage {
        attribute.fullInstantPage ?? attribute.instantPage
    }

    public static func displayedOriginal(_ attribute: RichTextMessageAttribute, expanded: Bool) -> InstantPage {
        expanded ? wholePage(attribute) : attribute.instantPage
    }

    /// Older cached preview translations cannot stand in for a complete source.
    public static func isUsableTranslation(_ translation: TranslationMessageAttribute, for source: RichTextMessageAttribute?) -> Bool {
        guard let source else { return true }
        guard let page = translation.instantPage else { return false }
        return page.isComplete || !wholePage(source).isComplete
    }

    public static func needsShowMore(source: RichTextMessageAttribute, displayedPage: InstantPage) -> Bool {
        !source.instantPage.isComplete && !displayedPage.isComplete
    }
}

public extension TelegramEngine.Messages {
    /// Uses the same native getRichMessage implementation as Show more. Its own
    /// committed source expansion advances only this lease, inside the transaction.
    func loadExteralessAIFullRichSource(scope: ExteralessAIScope) -> Signal<RichTextMessageAttribute?, NoError> {
        guard scope.accountId == self.account.id.int64, let id = scope.source?.id else { return .single(nil) }
        return _internal_requestExteralessFullRichText(account: self.account, id: id, scope: scope)
    }
}

func _internal_requestExteralessFullRichText(account: Account, id: MessageId, scope: ExteralessAIScope? = nil) -> Signal<RichTextMessageAttribute?, NoError> {
    guard id.namespace == Namespaces.Message.Cloud else { return .single(nil) }
    return account.postbox.transaction { transaction -> (Api.InputPeer, UInt32)? in
        guard let message = transaction.getMessage(id), message.richText != nil,
              let peer = transaction.getPeer(id.peerId).flatMap(apiInputPeer) else { return nil }
        if let scope, !exteralessAIValidateScope(transaction: transaction, accountId: account.id.int64, scope: scope) { return nil }
        return (peer, message.stableVersion)
    }
    |> mapToSignal { captured -> Signal<RichTextMessageAttribute?, NoError> in
        guard let (peer, version) = captured, scope?.lease.isCancelled != true else { return .single(nil) }
        return account.network.request(Api.functions.messages.getRichMessage(peer: peer, id: id.id))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.Messages?, NoError> in .single(nil) }
        |> mapToSignal { result -> Signal<RichTextMessageAttribute?, NoError> in
            guard let result else { return .single(nil) }
            let messages: [Api.Message]
            let users: [Api.User]
            let chats: [Api.Chat]
            switch result {
            case let .channelMessages(value): messages = value.messages; users = value.users; chats = value.chats
            case let .messages(value): messages = value.messages; users = value.users; chats = value.chats
            case let .messagesSlice(value): messages = value.messages; users = value.users; chats = value.chats
            case .messagesNotModified: return .single(nil)
            }
            return account.postbox.transaction { transaction -> RichTextMessageAttribute? in
                func commit() -> RichTextMessageAttribute? {
                    guard let current = transaction.getMessage(id), current.stableVersion == version else { return nil }
                    if let scope, !exteralessAIValidateScope(transaction: transaction, accountId: account.id.int64, scope: scope) { return nil }
                    let peerIsForum = transaction.getPeer(id.peerId)?.isForum ?? false
                    guard let parsed = messages.compactMap({ StoreMessage(apiMessage: $0, accountPeerId: account.peerId, peerIsForum: peerIsForum) }).first(where: {
                        if case let .Id(value) = $0.id { return value == id }; return false
                    }), let rich = parsed.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute else { return nil }
                    updatePeers(transaction: transaction, accountPeerId: account.peerId, peers: AccumulatedPeers(chats: chats, users: users))
                    let language = (parsed.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute)?.fromLang
                    return exteralessAIStoreFullRichSource(transaction: transaction, messageId: id, expectedVersion: version, fullPage: ExteralessAIRichSource.wholePage(rich), summaryFromLanguage: language, scope: scope, accountId: account.id.int64)
                }
                if let scope { return scope.lease.withActive(commit) ?? nil }
                return commit()
            }
        }
    }
}

/// Shared by native request completion and bounded in-memory fixtures. Any edit
/// during the request refuses the response; source changes drop only cached output.
func exteralessAIStoreFullRichSource(transaction: Transaction, messageId: MessageId, expectedVersion: UInt32, fullPage: InstantPage, summaryFromLanguage: String?, scope: ExteralessAIScope?, accountId: Int64) -> RichTextMessageAttribute? {
    func commit() -> RichTextMessageAttribute? {
        guard fullPage.isComplete else { return nil }
        if let scope, !exteralessAIValidateScope(transaction: transaction, accountId: accountId, scope: scope) { return nil }
        var accepted = false
        var changed = false
        transaction.updateMessage(messageId, update: { current in
            guard current.stableVersion == expectedVersion, let old = current.richText, scope?.lease.isCancelled != true else { return .skip }
            accepted = true
            if old.fullInstantPage == fullPage { return .skip }
            var attributes = exteralessAIInvalidateDerivedAttributes(current.attributes)
            if let index = attributes.firstIndex(where: { $0 is RichTextMessageAttribute }) {
                attributes[index] = RichTextMessageAttribute(instantPage: old.instantPage, fullInstantPage: fullPage)
            }
            if let summaryFromLanguage {
                attributes.removeAll { $0 is SummarizationMessageAttribute }
                attributes.append(SummarizationMessageAttribute(fromLang: summaryFromLanguage))
            }
            changed = true
            return .update(exteralessAIMessageWithAttributes(current, attributes: attributes))
        })
        guard accepted, let updated = transaction.getMessage(messageId) else { return nil }
        if changed { scope?.didCommit(updated, expectedVersion: expectedVersion) }
        return updated.richText
    }
    if let scope { return scope.lease.withActive(commit) ?? nil }
    return commit()
}
