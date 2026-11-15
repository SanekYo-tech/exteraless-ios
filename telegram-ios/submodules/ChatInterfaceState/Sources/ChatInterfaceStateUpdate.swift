import Foundation
import SwiftSignalKit
import TelegramCore

/// The native state-store boundary. Production uses TelegramEngine.Peers; tests
/// supply the same Postbox read/write bodies without constructing an Account.
public protocol ChatInterfaceStateUpdating {
    func getOpaqueChatInterfaceStateSnapshot(peerId: EnginePeer.Id, threadId: Int64?) -> Signal<OpaqueChatInterfaceStateSnapshot, NoError>
    func setOpaqueChatInterfaceStateWithResult(peerId: EnginePeer.Id, threadId: Int64?, state: OpaqueChatInterfaceState, expectedState: OpaqueChatInterfaceStateSnapshot?, admission: ChatInterfaceStateWriteAdmission?) -> Signal<ChatInterfaceStateWriteResult, NoError>
}

extension TelegramEngine.Peers: ChatInterfaceStateUpdating {
}

public extension ChatInterfaceState {
    /// Supplying admission enables strict decode/encode and read-snapshot CAS.
    /// An explicit expectedState enables CAS even without an export admission.
    /// With both nil, the legacy update remains an unconditional native write.
    static func update(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?, admission: ChatInterfaceStateWriteAdmission?, expectedState: OpaqueChatInterfaceStateSnapshot? = nil, _ transform: @escaping (ChatInterfaceState) -> ChatInterfaceState) -> Signal<ChatInterfaceStateWriteResult, NoError> {
        return self.update(source: engine.peers, peerId: peerId, threadId: threadId, admission: admission, expectedState: expectedState, transform)
    }

    static func update(source: ChatInterfaceStateUpdating, peerId: EnginePeer.Id, threadId: Int64?, admission: ChatInterfaceStateWriteAdmission?, expectedState: OpaqueChatInterfaceStateSnapshot? = nil, _ transform: @escaping (ChatInterfaceState) -> ChatInterfaceState) -> Signal<ChatInterfaceStateWriteResult, NoError> {
        let guarded = admission != nil || expectedState != nil
        let read = expectedState.map { Signal<OpaqueChatInterfaceStateSnapshot, NoError>.single($0) } ?? source.getOpaqueChatInterfaceStateSnapshot(peerId: peerId, threadId: threadId)
        let operation = read |> mapToSignal { previous -> Signal<ChatInterfaceStateWriteResult, NoError> in
            func rejected(_ reason: ChatInterfaceStateWriteRejection) -> Signal<ChatInterfaceStateWriteResult, NoError> {
                .single(ChatInterfaceStateWriteResult(peerId: peerId, threadId: threadId, rejection: reason))
            }
            guard previous.peerId == peerId, previous.threadId == threadId else { return rejected(.identityMismatch) }
            if guarded {
                guard previous.isDecodable else { return rejected(.decodingFailed) }
                if let opaque = previous.state?.opaqueData, (try? EngineDecoder.decode(ChatInterfaceState.self, from: opaque)) == nil { return rejected(.decodingFailed) }
            }
            let state = previous.state.map(ChatInterfaceState.parse) ?? ChatInterfaceState()
            let updated = transform(state)
            let opaqueData: Data?
            do { opaqueData = try EngineEncoder.encode(updated) }
            catch {
                if guarded { return rejected(.encodingFailed) }
                opaqueData = nil
            }
            var mediaDraft: MediaDraftState?
            if let value = updated.mediaDraftState {
                mediaDraft = MediaDraftState(contentType: value.contentType, timestamp: Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970))
            }
            return source.setOpaqueChatInterfaceStateWithResult(peerId: peerId, threadId: threadId, state: OpaqueChatInterfaceState(opaqueData: opaqueData, historyScrollMessageIndex: updated.historyScrollMessageIndex, mediaDraftState: mediaDraft, synchronizeableInputState: updated.synchronizeableInputState), expectedState: guarded ? previous : nil, admission: admission)
        }
        return Signal { subscriber in
            let pending = operation.start(next: subscriber.putNext, completed: subscriber.putCompletion)
            return ActionDisposable { admission?.cancel(); pending.dispose() }
        }
    }
}
