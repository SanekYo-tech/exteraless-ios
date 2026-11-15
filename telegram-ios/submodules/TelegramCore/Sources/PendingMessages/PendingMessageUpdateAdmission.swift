import SwiftSignalKit

/// Called on the manager queue after its source-version transaction. The token's
/// claim is immediately adjacent to installing the optimistic pending update.
func admitPendingMessageUpdate(sourceMatches: Signal<Bool, NoError>, token: PendingMessageUpdateAdmissionToken, queue: Queue, install: @escaping () -> Void) -> Signal<PendingMessageUpdateAdmission, NoError> {
    return sourceMatches |> take(1) |> deliverOn(queue) |> map { sourceMatches -> PendingMessageUpdateAdmission in
        guard token.isPending else { return .rejected(.cancelledBeforeCommit) }
        guard sourceMatches else { return .rejected(.localEnqueueUnavailable) }
        guard token.claimCommit() else { return .rejected(.cancelledBeforeCommit) }
        install()
        return .admitted
    }
}
