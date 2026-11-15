import Foundation
import Postbox
import SwiftSignalKit

/// The complete native read, including absent/undecodable state. Its exact stored
/// bytes and metadata are the CAS operand, not ChatInterfaceState's UI equality.
public struct OpaqueChatInterfaceStateSnapshot {
    public let accountId: Int64
    public let peerId: EnginePeer.Id
    public let threadId: Int64?
    public let state: OpaqueChatInterfaceState?
    public var isDecodable: Bool { self.storedState == nil || self.state != nil }
    let storedState: StoredPeerChatInterfaceState?

    init(accountId: Int64, peerId: PeerId, threadId: Int64?, storedState: StoredPeerChatInterfaceState?) {
        self.accountId = accountId
        self.peerId = peerId
        self.threadId = threadId
        self.storedState = storedState
        self.state = storedState.flatMap(_internal_decodeStoredChatInterfaceState)
    }
}

public enum ChatInterfaceStateWriteRejection: Equatable {
    case cancelled
    case alreadyCommitted
    case admissionDenied
    case identityMismatch
    case sourceChanged
    case copyProtected
    case destinationChanged
    case missingExpectedState
    case decodingFailed
    case encodingFailed
}

public struct ChatInterfaceStateWriteResult: Equatable {
    public let peerId: EnginePeer.Id
    public let threadId: Int64?
    public let rejection: ChatInterfaceStateWriteRejection?
    public var isWritten: Bool { self.rejection == nil }

    public init(peerId: EnginePeer.Id, threadId: Int64?, rejection: ChatInterfaceStateWriteRejection?) {
        self.peerId = peerId
        self.threadId = threadId
        self.rejection = rejection
    }
}

/// One destination write, bound to the original source and execution owner.
/// execute MUST synchronously invoke its body inside the original owner's permit.
/// It runs on the Postbox queue: no UI, MainActor hop, queue.sync, or Account is
/// part of this contract. The private claim lock never calls external code.
public final class ChatInterfaceStateWriteAdmission: @unchecked Sendable {
    public let accountId: Int64
    public let peerId: EnginePeer.Id
    public let threadId: Int64?
    public let sourceMessageIds: Set<EngineMessage.Id>
    private let sources: [EngineMessage]
    private let execute: @Sendable (_ write: () -> Void) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var claimed = false

    public init(accountId: Int64, peerId: EnginePeer.Id, threadId: Int64?, sourceMessages: [EngineMessage], execute: @escaping @Sendable (_ write: () -> Void) -> Void) {
        self.accountId = accountId
        self.peerId = peerId
        self.threadId = threadId
        self.sourceMessageIds = Set(sourceMessages.map(\.id))
        self.sources = sourceMessages.map { message in
            EngineMessage(message._asMessage().withUpdatedAttributes(message.attributes.map { attribute in
                if let rich = attribute as? RichTextMessageAttribute {
                    return RichTextMessageAttribute(instantPage: rich.instantPage, fullInstantPage: rich.fullInstantPage)
                }
                return attribute
            }))
        }
        self.execute = execute
    }

    public func cancel() {
        self.lock.lock()
        if !self.claimed { self.cancelled = true }
        self.lock.unlock()
    }

    private func claim() -> ChatInterfaceStateWriteRejection? {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.claimed { return .alreadyCommitted }
        if self.cancelled { return .cancelled }
        self.claimed = true
        return nil
    }

    func validate(transaction: Transaction, accountId: Int64, peerId: PeerId, threadId: Int64?) -> ChatInterfaceStateWriteRejection? {
        guard self.accountId == accountId, self.peerId == peerId, self.threadId == threadId,
              !self.sources.isEmpty, self.sources.count <= 100, self.sources.count == self.sourceMessageIds.count else { return .identityMismatch }
        for previous in self.sources {
            guard let current = transaction.getMessage(previous.id), chatInterfaceStateForwardSourceEqual(previous, EngineMessage(current)) else { return .sourceChanged }
            // Same native effective-peer/two-cached-flag policy as acquisition,
            // sampled in THIS transaction even if the UI observer is still queued.
            guard exteralessAIMessageExportable(transaction: transaction, message: current) else { return .copyProtected }
        }
        return nil
    }

    func perform(_ write: () -> Void) -> ChatInterfaceStateWriteRejection? {
        var rejection: ChatInterfaceStateWriteRejection? = .admissionDenied
        var written = false
        // Lock order is external permit -> private claim. cancel() takes only the
        // claim lock; no path holds it while calling execute or a Postbox method.
        self.execute {
            guard !written else { return }
            if let reason = self.claim() { rejection = reason; return }
            write()
            written = true
            rejection = nil
        }
        return rejection
    }
}

private func chatInterfaceStateForwardSourceEqual(_ previous: EngineMessage, _ current: EngineMessage) -> Bool {
    guard previous.stableId == current.stableId, previous == current, previous.attributes.count == current.attributes.count else { return false }
    for (lhs, rhs) in zip(previous.attributes, current.attributes) where lhs !== rhs {
        if let lhs = lhs as? RichTextMessageAttribute {
            guard let rhs = rhs as? RichTextMessageAttribute, lhs == rhs else { return false }
        } else {
            let a = PostboxEncoder(), b = PostboxEncoder()
            a.encodeRootObject(lhs)
            b.encodeRootObject(rhs)
            if a.makeData() != b.makeData() { return false }
        }
    }
    return true
}

func _internal_chatInterfaceStateSnapshot(transaction: Transaction, accountId: Int64, peerId: PeerId, threadId: Int64?) -> OpaqueChatInterfaceStateSnapshot {
    let stored: StoredPeerChatInterfaceState?
    if let threadId { stored = transaction.getPeerChatThreadInterfaceState(peerId, threadId: threadId) }
    else { stored = transaction.getPeerChatInterfaceState(peerId) }
    return OpaqueChatInterfaceStateSnapshot(accountId: accountId, peerId: peerId, threadId: threadId, storedState: stored)
}

/// The ONE production native writer, shared by the legacy facade and guarded
/// update. Rejection precedes BOTH synchronization operations and native setters.
func _internal_writeChatInterfaceState(transaction: Transaction, accountId: Int64, peerId: PeerId, threadId: Int64?, state: OpaqueChatInterfaceState, expectedState: OpaqueChatInterfaceStateSnapshot?, admission: ChatInterfaceStateWriteAdmission?) -> ChatInterfaceStateWriteResult {
    func result(_ rejection: ChatInterfaceStateWriteRejection?) -> ChatInterfaceStateWriteResult {
        ChatInterfaceStateWriteResult(peerId: peerId, threadId: threadId, rejection: rejection)
    }
    let current = _internal_chatInterfaceStateSnapshot(transaction: transaction, accountId: accountId, peerId: peerId, threadId: threadId)
    if admission != nil && expectedState == nil { return result(.missingExpectedState) }
    if let expectedState {
        guard expectedState.accountId == accountId, expectedState.peerId == peerId, expectedState.threadId == threadId else { return result(.identityMismatch) }
        guard expectedState.storedState == current.storedState else { return result(.destinationChanged) }
    }
    if let admission, let rejection = admission.validate(transaction: transaction, accountId: accountId, peerId: peerId, threadId: threadId) { return result(rejection) }
    guard let data = try? AdaptedPostboxEncoder().encode(InternalChatInterfaceState(synchronizeableInputState: state.synchronizeableInputState, historyScrollMessageIndex: state.historyScrollMessageIndex, mediaDraftState: state.mediaDraftState, opaqueData: state.opaqueData)) else { return result(.encodingFailed) }
    #if DEBUG
    let _ = try! AdaptedPostboxDecoder().decode(InternalChatInterfaceState.self, from: data)
    #endif
    var overrideChatTimestamp = state.synchronizeableInputState?.timestamp
    if let mediaDraft = state.mediaDraftState {
        if let current = overrideChatTimestamp, mediaDraft.timestamp < current {
        } else {
            overrideChatTimestamp = mediaDraft.timestamp
        }
    }
    let storedState = StoredPeerChatInterfaceState(overrideChatTimestamp: overrideChatTimestamp, historyScrollMessageIndex: state.historyScrollMessageIndex, associatedMessageIds: (state.synchronizeableInputState?.replySubject?.messageId).flatMap { [$0] } ?? [], data: data)
    let needsSynchronization = current.state?.synchronizeableInputState != state.synchronizeableInputState && [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudChannel, Namespaces.Peer.CloudGroup].contains(peerId.namespace)
    let write = {
        if needsSynchronization {
            addSynchronizeChatInputStateOperation(transaction: transaction, peerId: peerId, threadId: threadId)
        }
        if let threadId { transaction.setPeerChatThreadInterfaceState(peerId, threadId: threadId, state: storedState) }
        else { transaction.setPeerChatInterfaceState(peerId, state: storedState) }
    }
    if let admission { return result(admission.perform(write)) }
    write()
    return result(nil)
}

func _internal_setOpaqueChatInterfaceState(postbox: Postbox, accountId: Int64, peerId: PeerId, threadId: Int64?, state: OpaqueChatInterfaceState, expectedState: OpaqueChatInterfaceStateSnapshot?, admission: ChatInterfaceStateWriteAdmission?, observeWriteBody: (@Sendable (ChatInterfaceStateWriteResult) -> Void)? = nil) -> Signal<ChatInterfaceStateWriteResult, NoError> {
    return Signal { subscriber in
        let pending = postbox.transaction { transaction in
            let result = _internal_writeChatInterfaceState(transaction: transaction, accountId: accountId, peerId: peerId, threadId: threadId, state: state, expectedState: expectedState, admission: admission)
            // Internal native-fixture receipt. It observes actual execution even
            // when a disposed Postbox subscriber cannot receive the result.
            observeWriteBody?(result)
            return result
        }.start(next: subscriber.putNext, completed: subscriber.putCompletion)
        return ActionDisposable { admission?.cancel(); pending.dispose() }
    }
}
