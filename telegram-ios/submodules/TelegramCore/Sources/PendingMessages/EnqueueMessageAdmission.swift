import Foundation
import Postbox

public enum EnqueueMessageRejectionReason: Equatable {
    case pluginCancelled
    case botAuthorizationDenied
    case retainedReplyUnavailable
    case cancelledBeforeCommit
    case localEnqueueUnavailable
}

public enum EnqueueMessageAdmission: Equatable {
    case enqueued(MessageId)
    case rejected(EnqueueMessageRejectionReason)
}

/// Local transaction admission, never a server-delivery acknowledgement.
public struct EnqueueMessagesResult: Equatable {
    public let slots: [EnqueueMessageAdmission]
    public init(slots: [EnqueueMessageAdmission]) { self.slots = slots }
    public var messageIds: [MessageId?] {
        slots.map { if case let .enqueued(id) = $0 { return id }; return nil }
    }
    public var hasEnqueuedMessages: Bool { slots.contains { if case .enqueued = $0 { return true }; return false } }
    public var allEnqueued: Bool { !slots.isEmpty && slots.allSatisfy { if case .enqueued = $0 { return true }; return false } }
    public var firstRejection: EnqueueMessageRejectionReason? {
        for slot in slots { if case let .rejected(reason) = slot { return reason } }
        return nil
    }
    public static func rejected(count: Int, reason: EnqueueMessageRejectionReason) -> Self {
        Self(slots: Array(repeating: .rejected(reason), count: max(0, count)))
    }
    public static func committed(messageIds: [MessageId?]) -> Self {
        Self(slots: messageIds.map { $0.map(EnqueueMessageAdmission.enqueued) ?? .rejected(.localEnqueueUnavailable) })
    }
    public func restoringSlots(count: Int, acceptedIndices: [Int]) -> Self {
        var result = Array(repeating: EnqueueMessageAdmission.rejected(.pluginCancelled), count: max(0, count))
        for (index, slot) in zip(acceptedIndices, slots) where result.indices.contains(index) { result[index] = slot }
        return Self(slots: result)
    }
}

public enum PendingMessageUpdateAdmission: Equatable {
    case admitted
    case unchanged
    case rejected(EnqueueMessageRejectionReason)
}

/// Cancellation wins until the pending-update manager claims local installation.
/// Once claimed, later disposal cannot relabel a committed operation as refused.
public final class PendingMessageUpdateAdmissionToken: @unchecked Sendable {
    private enum State { case pending, cancelled, committed }
    private let lock = NSLock()
    private var state = State.pending
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        if case .pending = state { state = .cancelled }
    }
    public var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .pending = state { return true }
        return false
    }
    public func claimCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .committed
        return true
    }
}
