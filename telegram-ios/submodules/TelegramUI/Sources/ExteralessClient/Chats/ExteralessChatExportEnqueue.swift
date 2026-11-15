import AccountContext
import SwiftSignalKit
import TelegramCore

func exteralessExportEnqueueCommit(permit: ExteralessContentExportPermit, accountId: Int64, sourceMessageIds: Set<EngineMessage.Id>) -> ExteralessTLEnqueueCommit {
    ExteralessTLEnqueueCommit(canCommit: {
        permit.allows(accountId: accountId, messageIds: sourceMessageIds, operation: .exportEffect)
    }, cancelProvisional: {})
}

/// FU-02's exact inherited permit reaches the existing transaction's commit gate.
/// A cancelled subscriber owns provisional work only; a claimed commit still runs
/// the native postcommit publication. No second transaction or origin registry.
func exteralessEnqueueWithExportPermit(context: AccountContext, peerId: EnginePeer.Id, messages: [EnqueueMessage], permit: ExteralessContentExportPermit?, sourceMessageIds: Set<EngineMessage.Id>? = nil) -> Signal<EnqueueMessagesResult, NoError> {
    guard let permit else { return enqueueMessagesWithAdmission(account: context.account, peerId: peerId, messages: messages) }
    let accountId = context.account.id.int64
    let sources = sourceMessageIds ?? Set(messages.compactMap { message -> EngineMessage.Id? in
        if case let .forward(source, _, _, _, _) = message { return source }
        return nil
    })
    return Signal { subscriber in
        guard permit.allows(accountId: accountId, messageIds: sources, operation: .exportEffect) else {
            subscriber.putNext(.rejected(count: messages.count, reason: .cancelledBeforeCommit))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let pending = MetaDisposable()
        let commit = exteralessExportEnqueueCommit(permit: permit, accountId: accountId, sourceMessageIds: sources)
        commit.bindCancellation { pending.dispose() }
        let revoked = permit.onRevocation { commit.cancelSubscriber(); subscriber.putCompletion() }
        guard commit.allowsContinuation() else {
            revoked.dispose()
            subscriber.putCompletion()
            return EmptyDisposable
        }
        pending.set(enqueueMessagesWithAdmission(account: context.account, peerId: peerId, messages: messages, tlCommit: commit).start(next: { result in
            if commit.complete(track: { _ in }) == true {
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
        }, completed: {
            if commit.complete(track: { _ in }) == true {
                subscriber.putNext(.rejected(count: messages.count, reason: .localEnqueueUnavailable))
                subscriber.putCompletion()
            }
        }))
        return ActionDisposable { commit.cancelSubscriber(); revoked.dispose() }
    }
}
