import AccountContext
import ExteralessCore
import TelegramCore

/// Immutable value identifiers and two thread-safe gates only. In particular,
/// the executor is created OUTSIDE the MainActor access/controller implementation.
private struct ExteralessForwardDraftExecution: @unchecked Sendable {
    let permit: ExteralessContentExportPermit
    let lease: AINativeOperationLease
    let accountId: Int64
    let sourceIds: Set<EngineMessage.Id>
    let identityMatches: Bool

    func perform(_ write: () -> Void) {
        guard self.identityMatches else { return }
        // Order: permit -> operation lease -> native single-use claim. There is
        // no UI callback/queue hop, and claim unlocks before the native setters.
        self.permit.perform(accountId: self.accountId, messageIds: self.sourceIds, operation: .exportEffect, current: { !self.lease.isCancelled }) {
            _ = self.lease.withActive(write)
        }
    }
}

func exteralessMakeForwardDraftAdmission(accountId: Int64, peerId: EnginePeer.Id, threadId: Int64?, sourceMessages: [EngineMessage], sourceIds: Set<EngineMessage.Id>, permit: ExteralessContentExportPermit, lease: AINativeOperationLease, identityMatches: Bool) -> ChatInterfaceStateWriteAdmission {
    let execution = ExteralessForwardDraftExecution(permit: permit, lease: lease, accountId: accountId, sourceIds: sourceIds, identityMatches: identityMatches)
    return ChatInterfaceStateWriteAdmission(accountId: accountId, peerId: peerId, threadId: threadId, sourceMessages: sourceMessages, execute: { execution.perform($0) })
}

/// A refused CAS/admission completes its signal without authorizing navigation.
func exteralessForwardDraftCompletion(_ completed: @escaping () -> Void) -> (ChatInterfaceStateWriteResult) -> Void {
    return { result in
        if result.isWritten { completed() }
    }
}
