import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine.Messages {
    /// Commits an externally generated summary to this engine's account. The
    /// version and cancellation predicate are checked on the transaction queue;
    /// a missing, changed or cancelled message emits false without being written.
    /// canCommit must be a cheap thread-safe predicate, without UIKit access.
    func storeExteralessAISummary(
        scope: ExteralessAIScope,
        summary: SummarizationMessageAttribute.Summary,
        toLanguage: String?,
        canCommit: @escaping @Sendable () -> Bool
    ) -> Signal<Bool, NoError> {
        let accountId = self.account.id.int64
        return self.account.postbox.transaction { transaction -> Bool in
            exteralessAIStoreSummary(transaction: transaction, accountId: accountId, scope: scope, summary: summary, toLanguage: toLanguage, canCommit: canCommit)
        }
    }

    /// Stores the exact native text/poll/rich translation result. No network
    /// request is made, and no generic attribute or Postbox handle is exposed.
    func storeExteralessAITranslation(
        scope: ExteralessAIScope,
        translation: TranslationMessageAttribute,
        translatedSummary: SummarizationMessageAttribute.Summary? = nil,
        canCommit: @escaping @Sendable () -> Bool
    ) -> Signal<Bool, NoError> {
        let accountId = self.account.id.int64
        return self.account.postbox.transaction { transaction -> Bool in
            exteralessAIStoreTranslation(transaction: transaction, accountId: accountId, scope: scope, translation: translation, translatedSummary: translatedSummary, canCommit: canCommit)
        }
    }

    /// Uses the same account/permission/version lease as translation. Resource
    /// identity is checked inside the real transaction, including media-only edits.
    func storeExteralessAITranscription(scope: ExteralessAIScope, expectedResourceId: EngineMediaResource.Id, text: String) -> Signal<Bool, NoError> {
        let accountId = self.account.id.int64
        return self.account.postbox.transaction { transaction in
            exteralessAIStoreTranscription(transaction: transaction, accountId: accountId, scope: scope, expectedResourceId: expectedResourceId, text: text)
        }
    }

    /// The native Telegram fallback retains its real response/trial semantics,
    /// with this operation's lease carried through to its queued transaction.
    func transcribeExteralessAITelegramAudio(scope: ExteralessAIScope, expectedResourceId: EngineMediaResource.Id) -> Signal<EngineAudioTranscriptionResult, NoError> {
        guard scope.accountId == self.account.id.int64, let messageId = scope.source?.id else { return .single(.error) }
        return _internal_transcribeAudio(postbox: self.account.postbox, network: self.account.network, messageId: messageId, commitScope: scope, expectedResourceId: expectedResourceId)
    }

    func storeExteralessAILocalTranscription(scope: ExteralessAIScope, expectedResourceId: EngineMediaResource.Id, text: String, isFinal: Bool) -> Signal<Bool, NoError> {
        guard scope.accountId == self.account.id.int64, let messageId = scope.source?.id else { return .single(false) }
        return self.account.postbox.transaction { transaction in
            let result = exteralessAICommitNativeAudio(transaction: transaction, scope: scope, messageId: messageId, expectedResourceId: expectedResourceId) {
                guard text.utf16.count <= AILimits.responseUTF16 else { return .error }
                transaction.updateMessage(messageId, update: { current in
                    let attributes = current.attributes.filter { !($0 is AudioTranscriptionMessageAttribute) && !($0 is TranslationMessageAttribute) }
                        + [AudioTranscriptionMessageAttribute(id: 0, text: text, isPending: !isFinal, didRate: false, error: nil)]
                    return .update(exteralessAIMessageWithAttributes(current, attributes: attributes))
                })
                return .success
            }
            if case .success = result { return true }
            return false
        }
    }

    /// The same one-shot local history window used by the AI context builder.
    /// Exposes engine messages/indexes, preserves thread/ordering and disables hole
    /// tracking so context acquisition does not start unrelated history fetches.
    func localExteralessAIContextMessages(
        peerId: EnginePeer.Id,
        threadId: Int64?,
        around index: EngineMessage.Index,
        count: Int
    ) -> Signal<[EngineMessage], NoError> {
        return self.account.viewTracker.aroundMessageHistoryViewForLocation(
            .peer(peerId: peerId, threadId: threadId),
            index: .message(index),
            anchorIndex: .message(index),
            count: count,
            trackHoles: false,
            fixedCombinedReadStates: nil
        )
        |> take(1)
        |> map { view, _, _ in view.entries.map { EngineMessage($0.message) } }
    }
}

// Kept below the facade so accountless Postbox fixtures exercise the exact closure
// used in production rather than a second simulation of the mutation policy.
func exteralessAIInvalidateDerivedAttributes(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    var result: [MessageAttribute] = []
    for attribute in attributes {
        if attribute is TranslationMessageAttribute { continue }
        if let summary = attribute as? SummarizationMessageAttribute {
            result.append(SummarizationMessageAttribute(fromLang: summary.fromLang))
        } else {
            result.append(attribute)
        }
    }
    return result
}

func exteralessAIStoreSummary(transaction: Transaction, accountId: Int64, scope: ExteralessAIScope, summary: SummarizationMessageAttribute.Summary, toLanguage: String?, canCommit: @Sendable () -> Bool) -> Bool {
    exteralessAICommit(transaction: transaction, accountId: accountId, scope: scope, canCommit: canCommit) { current in
        let old = current.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute
        let attribute: SummarizationMessageAttribute
        if let toLanguage {
            var translated = old?.translated ?? [:]
            translated[toLanguage] = summary
            attribute = SummarizationMessageAttribute(fromLang: old?.fromLang ?? "", summary: old?.summary, translated: translated)
        } else {
            attribute = SummarizationMessageAttribute(fromLang: old?.fromLang ?? "", summary: summary, translated: old?.translated ?? [:])
        }
        return current.attributes.filter { !($0 is SummarizationMessageAttribute) } + [attribute]
    }
}

func exteralessAIStoreTranslation(transaction: Transaction, accountId: Int64, scope: ExteralessAIScope, translation: TranslationMessageAttribute, translatedSummary: SummarizationMessageAttribute.Summary? = nil, canCommit: @Sendable () -> Bool) -> Bool {
    exteralessAICommit(transaction: transaction, accountId: accountId, scope: scope, canCommit: canCommit) { current in
        var attributes = current.attributes.filter { !($0 is TranslationMessageAttribute) } + [translation]
        if let translatedSummary {
            let old = current.attributes.first { $0 is SummarizationMessageAttribute } as? SummarizationMessageAttribute
            var translated = old?.translated ?? [:]
            translated[translation.toLang] = translatedSummary
            attributes.removeAll { $0 is SummarizationMessageAttribute }
            attributes.append(SummarizationMessageAttribute(fromLang: old?.fromLang ?? "", summary: old?.summary, translated: translated))
        }
        return attributes
    }
}

func exteralessAICommit(transaction: Transaction, accountId: Int64, scope: ExteralessAIScope, canCommit: @Sendable () -> Bool, attributes: (Message) -> [MessageAttribute]?) -> Bool {
    return scope.lease.withActive {
        guard canCommit(), scope.allowsExternalProcessing,
              exteralessAIValidateScope(transaction: transaction, accountId: accountId, scope: scope),
              let messageId = scope.source?.id, let expectedVersion = scope.expectedVersions[messageId] else { return false }
        var changed = false
        transaction.updateMessage(messageId, update: { current in
            guard canCommit(), !scope.lease.isCancelled, current.stableVersion == expectedVersion,
                  exteralessAIMessageExportable(transaction: transaction, message: current),
                  let attributes = attributes(current) else { return .skip }
            changed = true
            return .update(exteralessAIMessageWithAttributes(current, attributes: attributes))
        })
        if changed, let updated = transaction.getMessage(messageId) { scope.didCommit(updated, expectedVersion: expectedVersion) }
        return changed
    } ?? false
}

func exteralessAIStoreTranscription(transaction: Transaction, accountId: Int64, scope: ExteralessAIScope, expectedResourceId: EngineMediaResource.Id, text: String) -> Bool {
    guard !text.isEmpty, text.utf16.count <= AILimits.responseUTF16 else { return false }
    return exteralessAICommit(transaction: transaction, accountId: accountId, scope: scope, canCommit: { true }) { current in
        guard current.effectiveMedia.contains(where: { media in
            guard let file = media as? TelegramMediaFile else { return false }
            return (file.isVoice || file.isInstantVideo) && EngineMediaResource.Id(file.resource.id) == expectedResourceId
        }) else { return nil }
        return current.attributes.filter { !($0 is AudioTranscriptionMessageAttribute) && !($0 is TranslationMessageAttribute) }
            + [AudioTranscriptionMessageAttribute(id: 0, text: text, isPending: false, didRate: false, error: nil)]
    }
}

func exteralessAIValidateAudioScope(transaction: Transaction, scope: ExteralessAIScope, messageId: MessageId, expectedResourceId: EngineMediaResource.Id?) -> Bool {
    guard scope.source?.id == messageId, let expectedResourceId,
          exteralessAIValidateScope(transaction: transaction, accountId: scope.accountId, scope: scope),
          let message = transaction.getMessage(messageId), messageId.peerId.namespace != Namespaces.Peer.SecretChat,
          !message.containsSecretMedia else { return false }
    return message.effectiveMedia.contains { media in
        guard let file = media as? TelegramMediaFile else { return false }
        return (file.isVoice || file.isInstantVideo) && EngineMediaResource.Id(file.resource.id) == expectedResourceId
    }
}

/// Wraps the stock response transaction, including trial-state changes. Returning
/// its actual .error is important: a denied/cancelled commit is never a success.
func exteralessAICommitNativeAudio(transaction: Transaction, scope: ExteralessAIScope, messageId: MessageId, expectedResourceId: EngineMediaResource.Id?, commit: () -> EngineAudioTranscriptionResult) -> EngineAudioTranscriptionResult {
    scope.lease.withActive {
        guard exteralessAIValidateAudioScope(transaction: transaction, scope: scope, messageId: messageId, expectedResourceId: expectedResourceId) else { return .error }
        guard let expectedVersion = scope.expectedVersions[messageId] else { return .error }
        let result = commit()
        if let updated = transaction.getMessage(messageId) { scope.didCommit(updated, expectedVersion: expectedVersion) }
        return result
    } ?? .error
}

/// Identical reconstruction to the former UI transaction: content, reply/forward
/// attributes, media, grouping, timestamps, tags and flags retain their values.
func exteralessAIMessageWithAttributes(_ message: Message, attributes: [MessageAttribute]) -> StoreMessage {
    return StoreMessage(
        id: message.id,
        customStableId: nil,
        globallyUniqueId: message.globallyUniqueId,
        groupingKey: message.groupingKey,
        threadId: message.threadId,
        timestamp: message.timestamp,
        flags: StoreMessageFlags(message.flags),
        tags: message.tags,
        globalTags: message.globalTags,
        localTags: message.localTags,
        forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
        authorId: message.author?.id,
        text: message.text,
        attributes: attributes,
        media: message.media
    )
}
