import Foundation
import PluginHooks
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// Native-only provenance retained as an UpdateGroup sidecar. Object identity is
/// used only in Core, never exported as a Python handle or substituted for TL data.
final class ExteralessTLUpdateContainer {
    let original: Api.Updates
    let members: [ObjectIdentifier]
    private let retainedMembers: [Api.Update]
    let seq: Int32?

    init(original: Api.Updates, normalizedUpdates: [Api.Update]) {
        self.original = original
        let members: [Api.Update]
        switch original {
        case let .updates(data):
            self.seq = data.seq == 0 ? nil : data.seq
            members = data.updates
        case let .updatesCombined(data):
            self.seq = data.seq == 0 ? nil : data.seq
            members = data.updates
        case let .updateShort(data):
            self.seq = nil
            members = [data.update]
        default:
            self.seq = nil
            members = normalizedUpdates
        }
        // groupUpdates partitions pts/qts/seq and changes vector order. Preserve
        // the original container order for matching a plugin's returned vector.
        self.retainedMembers = members // short-message synthetic objects must not die/reuse an address
        self.members = members.map { ObjectIdentifier($0.tlBackingObject) }
    }
}

func exteralessTLWantsContainerTransforms() -> Bool {
    return PluginHookRouter.hasSubscribers(.updates) && PluginTLTransformRouter.hasSubscribers(.updates)
}

private let tlUpdateBarrierQueue = Queue(name: "Exteraless.TLUpdateBarrier", qos: .userInitiated)

private func tlTransformDecision(_ payload: PluginTLTransformPayload) -> Signal<PluginTLTransformResult, NoError> {
    return Signal { subscriber in
        let cancellation = PluginTLTransformRouter.intercept(payload) { result in
            subscriber.putNext(result)
            subscriber.putCompletion()
        }
        return ActionDisposable { cancellation?.cancel() }
    }
}

private func tlUpdateMetadata(network: Network, state: AccountMutableState, id: String, index: Int?, count: Int) -> ExteralessTLValue {
    let before = state.initialState.state
    let accepted = state.state
    var fields: [String: ExteralessTLValue] = ["accountRecordId": .integer(network.accountRecordId), "batchId": .string(id),
        "stage": .string("afterContinuityBeforeSemantics"), "count": .integer(Int64(count)),
        "initial": .object(["pts": .integer(Int64(before.pts)), "qts": .integer(Int64(before.qts)), "seq": .integer(Int64(before.seq)), "date": .integer(Int64(before.date))]),
        "accepted": .object(["pts": .integer(Int64(accepted.pts)), "qts": .integer(Int64(accepted.qts)), "seq": .integer(Int64(accepted.seq)), "date": .integer(Int64(accepted.date))])]
    if let index { fields["index"] = .integer(Int64(index)) }
    return .object(fields)
}

private func tlObserveUpdate(_ update: Api.Update, network: Network, index: Int, count: Int) {
    guard PluginHookRouter.hasSubscribers(.update) else { return }
    let accountId = network.accountRecordId
    PluginHookRouter.observe(.update) {
        let buffer = Buffer()
        update.serialize(buffer, true)
        return .update(PluginUpdateObservation(accountRecordId: accountId, name: update.description,
            source: .acceptedUpdateBatch, stage: .beforeUpdateApplication, serializedTLBytes: buffer.makeData(), batchIndex: index, batchCount: count))
    }
}

private func tlObserveContainer(_ container: Api.Updates, network: Network) {
    guard PluginHookRouter.hasSubscribers(.updates) else { return }
    let accountId = network.accountRecordId
    PluginHookRouter.observe(.updates) {
        let buffer = Buffer()
        container.serialize(buffer, true)
        return .updates(PluginUpdateObservation(accountRecordId: accountId, name: container.description,
            source: .incomingContainer, stage: .beforeUpdateApplication, serializedTLBytes: buffer.makeData()))
    }
}

private func tlObserveDifference(_ difference: Api.updates.Difference, network: Network) {
    guard PluginHookRouter.hasSubscribers(.updates) else { return }
    let accountId = network.accountRecordId
    PluginHookRouter.observe(.updates) {
        let buffer = Buffer()
        difference.serialize(buffer, true)
        return .updates(PluginUpdateObservation(accountRecordId: accountId, name: difference.description,
            source: .difference, stage: .beforeDifferenceApplication, serializedTLBytes: buffer.makeData()))
    }
}

private struct TLUpdatePlan {
    var updates: [Api.Update?]
    var values: [ExteralessTLValue]
    var suppressed = Set<Int>()
}

private func tlCancelUpdate(_ value: ExteralessTLValue) throws -> Api.Update? {
    return try ExteralessTLUpdatePolicy.cancelledValue(value).map(exteralessTLParseUpdate)
}

private func tlBarrierVersionMatches(postbox: Postbox, state: AccountMutableState) -> Signal<Bool, NoError> {
    return postbox.transaction { transaction in
        guard (transaction.getState() as? AuthorizedAccountState)?.state == state.initialState.state else { return false }
        for (peerId, initial) in state.initialState.channelStates {
            guard (transaction.getPeerChatState(peerId) as? ChannelState)?.pts == initial.pts else { return false }
        }
        return true
    }
}

private func tlContainerMembers(_ value: ExteralessTLValue) -> [ExteralessTLValue]? {
    if case let .array(values)? = value["updates"] { return values }
    if let update = value["update"] { return [update] }
    return nil
}

/// Returns normalized member changes; missing members mean semantic cancellation.
/// Container counters/peer cache are immutable and NEVER reconstructed from a
/// filtered vector. Core already accepted their ORIGINAL ledger before this call.
private func tlValidateContainer(_ source: String, original: ExteralessTLValue, members: [ExteralessTLValue],
                                 metadata: ExteralessTLValue) throws -> (ExteralessTLValue, [Int: ExteralessTLValue]) {
    let codec = ExteralessTLCodec.shared
    let candidate = try ExteralessTLTransformCodec.candidate(source, metadata: metadata, phase: "updates",
        canCancel: members.allSatisfy(ExteralessTLUpdatePolicy.canMutate))
    let normalized = try codec.normalize(candidate, as: "Updates")
    guard case let .object(old) = original, case let .object(new) = normalized, old["_"] == new["_"] else {
        throw ExteralessTLError(.malformed, "Container constructor is read-only")
    }
    if let changedMembers = tlContainerMembers(normalized) {
        for key in Set(old.keys).union(new.keys) where key != "updates" && key != "update" {
            guard old[key] == new[key] else { throw ExteralessTLError(.malformed, "Container counter/cache field \(key) is read-only") }
        }
        return (normalized, try ExteralessTLUpdatePolicy.matchMembers(original: members, changed: changedMembers))
    }
    // Short-message containers become a real synthesized updateNewMessage in Core.
    // Copy only text/entities into that actual message, retaining its stored fromId,
    // peerId and all fields (a naive boxed roundtrip of short flags loses fromId).
    guard ["updateShortMessage", "updateShortChatMessage"].contains(old["_"]?.stringValue ?? ""), members.count == 1 else {
        throw ExteralessTLError(.unsupported, "Counter-only/reset container has no mutable semantic members")
    }
    for key in Set(old.keys).union(new.keys) where !["message", "entities", "flags"].contains(key) {
        guard old[key] == new[key] else { throw ExteralessTLError(.malformed, "Short container identity/counters are read-only") }
    }
    let oldFlags = old["flags"]?.integerValue ?? 0
    let newFlags = new["flags"]?.integerValue ?? 0
    guard (oldFlags ^ newFlags) & ~(Int64(1) << 7) == 0,
          case var .object(update) = members[0], case var .object(message)? = update["message"] else {
        throw ExteralessTLError(.malformed, "Short container flags or normalized message are invalid")
    }
    message["message"] = new["message"]
    message["entities"] = new["entities"]
    let flags = message["flags"]?.integerValue ?? 0
    message["flags"] = .integer((flags & ~(Int64(1) << 7)) | (newFlags & (Int64(1) << 7)))
    update["message"] = .object(message)
    let changed = try codec.normalize(.object(update), as: "Update")
    try ExteralessTLTransformCodec.preserveContinuity(members[0], changed)
    try ExteralessTLTransformCodec.preserveReferences(members[0], changed)
    return (normalized, [0: changed])
}

/// `updates` MUST be the existing sortedUpdates(collectedUpdates) order, after
/// global pts/qts/seq acceptance. Channel counters are previewed below. The caller
/// retains state.initialState and must keep replayFinalState(skipVerification:false).
func exteralessTLAcceptedUpdateBarrier(accountPeerId: PeerId, postbox: Postbox, network: Network,
                                      state: AccountMutableState, updates: [Api.Update],
                                      containers: [ExteralessTLUpdateContainer]) -> Signal<[Api.Update], NoError> {
    let transformSingle = PluginHookRouter.hasSubscribers(.update) && PluginTLTransformRouter.hasSubscribers(.update)
    let transformContainers = exteralessTLWantsContainerTransforms()
    guard transformSingle || transformContainers else {
        for (index, update) in updates.enumerated() { tlObserveUpdate(update, network: network, index: index, count: updates.count) }
        for container in containers { tlObserveContainer(container.original, network: network) }
        return .single(updates)
    }
    return deferred { () -> Signal<[Api.Update], NoError> in
        do {
            guard updates.count <= 4096 else { throw ExteralessTLError(.limit, "Accepted update batch exceeds 4096 items") }
            let values = try updates.map(exteralessTLNativeSnapshot)
            var ledger: [Int64: Int32] = [:]
            for (peerId, channel) in state.channelStates { ledger[peerId.id._internalGetInt64Value()] = channel.pts }
            var eligible = Set<Int>()
            for (index, value) in values.enumerated() {
                var messageIsValid = true
                switch updates[index] {
                case let .updateNewChannelMessage(data):
                    messageIsValid = StoreMessage(apiMessage: data.message, accountPeerId: accountPeerId,
                        peerIsForum: data.message.peerId.map { state.isPeerForum(peerId: $0) } ?? false) != nil
                case let .updateEditChannelMessage(data):
                    messageIsValid = StoreMessage(apiMessage: data.message, accountPeerId: accountPeerId,
                        peerIsForum: data.message.peerId.map { state.isPeerForum(peerId: $0) } ?? false) != nil
                default: break
                }
                if messageIsValid, ExteralessTLUpdatePolicy.acceptChannel(value, ledger: &ledger) { eligible.insert(index) }
            }
            let batchId = UUID().uuidString
            var source: Signal<TLUpdatePlan, NoError> = .single(TLUpdatePlan(updates: updates.map(Optional.init), values: values))
            var claimed = Set<Int>()
            for container in containers {
                var indices: [Int] = []
                for identity in container.members {
                    if let index = updates.indices.first(where: { !claimed.contains($0) && !indices.contains($0) && ObjectIdentifier(updates[$0].tlBackingObject) == identity }) { indices.append(index) }
                }
                let sequenceAccepted = container.seq.map { $0 > state.initialState.state.seq && $0 <= state.state.seq } ?? true
                guard transformContainers, !indices.isEmpty, indices.count == container.members.count,
                      indices.allSatisfy(eligible.contains), sequenceAccepted else {
                    source = source |> map { plan in
                        tlObserveContainer(container.original, network: network)
                        return plan
                    }
                    continue
                }
                claimed.formUnion(indices)
                let original = try exteralessTLNativeSnapshot(container.original)
                let members = indices.map { values[$0] }
                let metadata = tlUpdateMetadata(network: network, state: state, id: batchId, index: nil, count: members.count)
                let payload = PluginTLTransformPayload(kind: .updates, accountRecordId: network.accountRecordId, correlationId: batchId,
                    name: original["_"]?.stringValue ?? container.original.description, valueJSON: try original.jsonString(),
                    metadataJSON: try metadata.jsonString(), canCancel: members.allSatisfy(ExteralessTLUpdatePolicy.canMutate),
                    normalize: { json in try tlValidateContainer(json, original: original, members: members, metadata: metadata).0.jsonString() })
                source = source |> mapToSignal { plan -> Signal<TLUpdatePlan, NoError> in
                    return tlTransformDecision(payload) |> map { decision in
                        var updated = plan
                        do {
                            switch decision {
                            case .cancel:
                                for index in indices {
                                    updated.updates[index] = try tlCancelUpdate(values[index])
                                    updated.suppressed.insert(index)
                                }
                            case let .modify(json), let .modifyFinal(json):
                                let (_, changes) = try tlValidateContainer(json, original: original, members: members, metadata: metadata)
                                for (localIndex, index) in indices.enumerated() {
                                    if let value = changes[localIndex] {
                                        updated.updates[index] = try exteralessTLParseUpdate(value)
                                        updated.values[index] = value
                                    } else {
                                        updated.updates[index] = try tlCancelUpdate(values[index])
                                        updated.suppressed.insert(index)
                                    }
                                }
                            default: break
                            }
                            return updated
                        } catch {
                            PluginTLTransformRouter.report("TL_CONTAINER_REPLACEMENT_REJECTED", payload: payload)
                            return plan
                        }
                    }
                }
            }
            for index in updates.indices {
                source = source |> mapToSignal { plan -> Signal<TLUpdatePlan, NoError> in
                    if plan.suppressed.contains(index) { return .single(plan) }
                    if ExteralessTLUpdatePolicy.isCounterOnly(plan.values[index]) { return .single(plan) }
                    guard transformSingle, eligible.contains(index), ExteralessTLUpdatePolicy.canMutate(plan.values[index]) else {
                        tlObserveUpdate(plan.updates[index] ?? updates[index], network: network, index: index, count: updates.count)
                        return .single(plan)
                    }
                    do {
                        let original = values[index]
                        let metadata = tlUpdateMetadata(network: network, state: state, id: batchId, index: index, count: updates.count)
                        let payload = PluginTLTransformPayload(kind: .update, accountRecordId: network.accountRecordId, correlationId: batchId,
                            name: original["_"]?.stringValue ?? updates[index].description, valueJSON: try plan.values[index].jsonString(),
                            metadataJSON: try metadata.jsonString(), normalize: { json in
                                let body = try ExteralessTLTransformCodec.update(json, original: original, metadata: metadata)
                                return try ExteralessTLCodec.shared.decode(body, as: "Update").jsonString()
                            })
                        return tlTransformDecision(payload) |> map { decision in
                            var updated = plan
                            do {
                                switch decision {
                                case .cancel:
                                    updated.updates[index] = try tlCancelUpdate(original)
                                case let .modify(json), let .modifyFinal(json):
                                    let body = try ExteralessTLTransformCodec.update(json, original: original, metadata: metadata)
                                    let value = try ExteralessTLCodec.shared.decode(body, as: "Update")
                                    updated.updates[index] = try exteralessTLParseUpdate(value)
                                default: break
                                }
                                return updated
                            } catch {
                                PluginTLTransformRouter.report("TL_UPDATE_REPLACEMENT_REJECTED", payload: payload)
                                return plan
                            }
                        }
                    } catch { return .single(plan) }
                }
            }
            return source |> mapToSignal { plan -> Signal<[Api.Update], NoError> in
                return tlBarrierVersionMatches(postbox: postbox, state: state) |> map { valid in
                    // A changed snapshot discards plugin edits. The caller still
                    // performs its existing replay verification/resynchronization.
                    if !valid {
                        PluginTLTransformRouter.report("TL_UPDATE_STATE_VERSION_CHANGED", kind: .update,
                            name: "acceptedUpdateBatch", accountRecordId: network.accountRecordId)
                    }
                    return valid ? plan.updates.compactMap { $0 } : updates
                }
            }
        } catch {
            for (index, update) in updates.enumerated() { tlObserveUpdate(update, network: network, index: index, count: updates.count) }
            for container in containers { tlObserveContainer(container.original, network: network) }
            return .single(updates)
        }
    } |> runOn(tlUpdateBarrierQueue)
}

private func tlDifferenceCanCancelSemantics(_ value: ExteralessTLValue) -> Bool {
    guard case let .array(messages)? = value["new_messages"],
          case let .array(encrypted)? = value["new_encrypted_messages"], encrypted.isEmpty,
          case let .array(updates)? = value["other_updates"] else { return false }
    return messages.allSatisfy(ExteralessTLUpdatePolicy.canMutate) && updates.allSatisfy(ExteralessTLUpdatePolicy.canMutate)
}

private func tlDifferenceCandidate(_ json: String, original: ExteralessTLValue, metadata: ExteralessTLValue) throws -> ExteralessTLValue {
    let canCancel = tlDifferenceCanCancelSemantics(original)
    let value = try ExteralessTLTransformCodec.candidate(json, metadata: metadata, phase: "updates", canCancel: canCancel)
    let normalized = try ExteralessTLCodec.shared.normalize(value, as: "updates.Difference")
    guard case let .object(old) = original, case let .object(new) = normalized else { throw ExteralessTLError(.malformed, "Difference must be a TL object") }
    for key in Set(old.keys).union(new.keys) where key != "new_messages" && key != "other_updates" {
        guard old[key] == new[key] else { throw ExteralessTLError(.malformed, "Difference counters/cache/encryption fields are read-only") }
    }
    for key in ["new_messages", "other_updates"] {
        if case let .array(before)? = old[key], case let .array(after)? = new[key] {
            _ = try ExteralessTLUpdatePolicy.matchMembers(original: before, changed: after)
        }
    }
    return normalized
}

private func tlDifferenceRetainingChannelCounters(_ candidate: ExteralessTLValue, original: ExteralessTLValue) throws -> ExteralessTLValue {
    guard case var .object(fields) = candidate, case let .array(before)? = original["other_updates"],
          case let .array(after)? = candidate["other_updates"] else { return candidate }
    let matched = try ExteralessTLUpdatePolicy.matchMembers(original: before, changed: after)
    var updates: [ExteralessTLValue] = []
    for index in before.indices {
        if let replacement = matched[index] { updates.append(replacement) }
        else if let counter = try ExteralessTLUpdatePolicy.cancelledValue(before[index]) { updates.append(counter) }
    }
    fields["other_updates"] = .array(updates)
    return .object(fields)
}

/// Called after AccountStateManager's initialState == authorizedState check, but
/// before new_messages/other_updates are turned into state operations. Authoritative
/// difference state and encrypted payloads remain intact; replay still verifies.
func exteralessTLDifferenceBarrier(postbox: Postbox, network: Network, state: AccountMutableState, difference: Api.updates.Difference) -> Signal<Api.updates.Difference, NoError> {
    guard exteralessTLWantsContainerTransforms() else {
        tlObserveDifference(difference, network: network)
        return .single(difference)
    }
    return deferred { () -> Signal<Api.updates.Difference, NoError> in
        do {
            let original = try exteralessTLNativeSnapshot(difference)
            let metadata = tlUpdateMetadata(network: network, state: state, id: UUID().uuidString, index: nil, count: 1)
            let canCancel = tlDifferenceCanCancelSemantics(original)
            let payload = PluginTLTransformPayload(kind: .updates, accountRecordId: network.accountRecordId, correlationId: UUID().uuidString,
                name: original["_"]?.stringValue ?? difference.description, valueJSON: try original.jsonString(), metadataJSON: try metadata.jsonString(),
                canCancel: canCancel, normalize: { json in try tlDifferenceCandidate(json, original: original, metadata: metadata).jsonString() })
            return tlTransformDecision(payload) |> map { result in
                do {
                    let candidate: ExteralessTLValue
                    switch result {
                    case .cancel:
                        guard case var .object(fields) = original, canCancel else { return difference }
                        fields["new_messages"] = .array([])
                        fields["other_updates"] = .array([])
                        candidate = .object(fields)
                    case let .modify(json), let .modifyFinal(json): candidate = try tlDifferenceCandidate(json, original: original, metadata: metadata)
                    default: return difference
                    }
                    let retained = try tlDifferenceRetainingChannelCounters(candidate, original: original)
                    let bytes = try ExteralessTLCodec.shared.encode(retained, as: "updates.Difference")
                    let reader = BufferReader(Buffer(data: bytes))
                    guard let signature = reader.readInt32(), let parsed = Api.parse(reader, signature: signature) as? Api.updates.Difference else {
                        throw ExteralessTLError(.schema, "Native Difference parser rejected replacement")
                    }
                    return parsed
                } catch {
                    PluginTLTransformRouter.report("TL_DIFFERENCE_REPLACEMENT_REJECTED", payload: payload)
                    return difference
                }
            } |> mapToSignal { transformed -> Signal<Api.updates.Difference, NoError> in
                return tlBarrierVersionMatches(postbox: postbox, state: state) |> map { valid in
                    if !valid { PluginTLTransformRouter.report("TL_DIFFERENCE_STATE_VERSION_CHANGED", payload: payload) }
                    return valid ? transformed : difference
                }
            }
        } catch {
            PluginTLTransformRouter.report("TL_DIFFERENCE_SNAPSHOT_UNAVAILABLE", kind: .updates,
                name: difference.description, accountRecordId: network.accountRecordId)
            tlObserveDifference(difference, network: network)
            return .single(difference)
        }
    } |> runOn(tlUpdateBarrierQueue)
}
