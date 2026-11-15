import Foundation
import Postbox

// One account-local record, beside the native pinned order. No global account
// cache, synthetic navigation identity, or remote-success flag in ClientSettings.
private let dialogPinStateId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.dialog.pins.reconciliation.v1"))

struct ExteralessDialogPinRequest: Codable, Equatable {
    let id: Int64
    let generation: Int64
    let revision: Int64
    let localOrder: [Int64]
    let serverOrder: [Int64]
}

struct ExteralessDialogPinState: Codable {
    var generation: Int64 = 0
    var revision: Int64 = 0
    var nextRequestId: Int64 = 0
    var observedOperationWatermark: Int32
    var observedOrder: [Int64]
    var enabled: Bool
    var localOnly: [Int64]
    var intentOrder: [Int64]? = nil
    var intentRemoved: [Int64] = []
    var disablePending = false
    var verificationPending = false
    var activeRequestId: Int64? = nil
    var activeRevision: Int64? = nil
    var activeGeneration: Int64? = nil
    var claimedOperationIndex: Int32? = nil
    var lastSent: ExteralessDialogPinRequest? = nil
    var acknowledgedRequestId: Int64? = nil
    var acknowledgedGeneration: Int64? = nil
    var acknowledgedRevision: Int64? = nil
    var acknowledgedFromRead: Bool? = nil
    var acknowledgedServerOrder: [Int64]? = nil
}

struct ExteralessDialogPinSync {
    let id: Int64
    let operationIndex: Int32
    let generation: Int64
    let revision: Int64
    let localOrder: [PinnedItemId]
    let enabled: Bool
}

func exteralessDialogPinOperationPeerId() -> PeerId {
    // The existing native operation-log address for PeerGroupId.root, not a chat.
    PeerId(namespace: ._internalFromInt32Value(0), id: ._internalFromInt64Value(Int64(PeerGroupId.root.rawValue)))
}

private func pinIds(_ items: [PinnedItemId]) -> [Int64] {
    items.map { item in switch item { case let .peer(id): return id.toInt64() } }
}

private func pinnedItems(_ ids: [Int64]) -> [PinnedItemId] { ids.map { .peer(PeerId($0)) } }

private func cloudPins(_ ids: [Int64]) -> [Int64] { ids.filter { PeerId($0).namespace != Namespaces.Peer.SecretChat } }

private func operationWatermark(_ transaction: Transaction) -> Int32 {
    transaction.operationLogGetNextEntryLocalIndex(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats)
}

func exteralessDialogPinState(transaction: Transaction) -> ExteralessDialogPinState? {
    transaction.retrieveItemCacheEntry(id: dialogPinStateId)?.get(ExteralessDialogPinState.self)
}

private func storePinState(_ state: ExteralessDialogPinState, transaction: Transaction) {
    guard let entry = CodableEntry(state) else { preconditionFailure("Invalid dialog pin reconciliation state") }
    transaction.putItemCacheEntry(id: dialogPinStateId, entry: entry)
}

private func currentPinState(transaction: Transaction, accountPeerId: PeerId, enabled: Bool) -> ExteralessDialogPinState? {
    let order = transaction.getPinnedItemIds(groupId: .root)
    let ids = pinIds(order)
    let server = pinIds(exteralessDialogServerPinOrder(transaction: transaction, accountPeerId: accountPeerId, groupId: .root, itemIds: order))
    let watermark = operationWatermark(transaction)
    let previous = exteralessDialogPinState(transaction: transaction)
    guard previous != nil || enabled || cloudPins(ids).count > server.count else { return nil }
    var state = previous ?? ExteralessDialogPinState(observedOperationWatermark: watermark, observedOrder: ids, enabled: enabled, localOnly: cloudPins(ids).filter { !server.contains($0) })

    // Both native local pin/unpin and reorder commit a fresh operation-log index.
    // Owned replay/reconciliation enqueues record this watermark themselves. It
    // therefore catches a local ABA too, without changing the frozen local APIs.
    if previous != nil && watermark != state.observedOperationWatermark {
        state.generation += 1
        state.revision += 1
        state.intentRemoved = Array(Set(state.intentRemoved).union(Set(state.observedOrder).subtracting(ids)).subtracting(ids)).sorted()
        state.intentOrder = ids
    } else if previous == nil {
        transaction.operationLogEnumerateEntries(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats) { entry in
            if let operation = entry.contents as? SynchronizePinnedChatsOperation, pinIds(operation.previousItemIds) != ids {
                state.generation += 1
                state.revision += 1
                state.intentRemoved = Array(Set(pinIds(operation.previousItemIds)).subtracting(ids)).sorted()
                state.intentOrder = ids
            }
            return false
        }
    }
    if state.enabled != enabled {
        state.enabled = enabled
        state.revision += 1
    }
    state.observedOrder = ids
    state.observedOperationWatermark = watermark
    state.localOnly.removeAll { !ids.contains($0) }
    if !enabled && (!state.localOnly.isEmpty || cloudPins(ids).count > server.count) { state.disablePending = true }
    return state
}

/// Coalesce with the actual native operation log, including an in-flight owner.
/// No Boolean is treated as an acknowledgement and no unrelated callback loops.
@discardableResult
private func queuePinReconciliation(transaction: Transaction, state: inout ExteralessDialogPinState) -> Bool {
    var hasQueued = false
    transaction.operationLogEnumerateEntries(peerId: exteralessDialogPinOperationPeerId(), tag: OperationLogTags.SynchronizePinnedChats) { entry in
        if entry.tagLocalIndex != state.claimedOperationIndex { hasQueued = true }
        return !hasQueued
    }
    if !hasQueued { addSynchronizePinnedChatsOperation(transaction: transaction, groupId: .root) }
    state.observedOperationWatermark = operationWatermark(transaction)
    return !hasQueued
}

/// Called on attach as well as on a global flag transition. A detached account's
/// pending local-only state survives the UI lease and is reconciled on reattach.
@discardableResult
func exteralessUpdateDialogPinPolicy(transaction: Transaction, accountPeerId: PeerId, enabled: Bool) -> Bool {
    guard var state = currentPinState(transaction: transaction, accountPeerId: accountPeerId, enabled: enabled) else { return false }
    let needsRead = (state.disablePending && !enabled) || state.verificationPending || state.intentOrder != nil
    let hasCoveringWork = state.activeRequestId != nil && state.activeRevision == state.revision && state.activeGeneration == state.generation
    let queued = needsRead && !hasCoveringWork ? queuePinReconciliation(transaction: transaction, state: &state) : false
    storePinState(state, transaction: transaction)
    return queued
}

func exteralessBeginDialogPinSync(transaction: Transaction, accountPeerId: PeerId, groupId: PeerGroupId, operationIndex: Int32, enabled: Bool) -> ExteralessDialogPinSync? {
    guard groupId == .root, var state = currentPinState(transaction: transaction, accountPeerId: accountPeerId, enabled: enabled) else { return nil }
    state.nextRequestId += 1
    state.activeRequestId = state.nextRequestId
    state.activeRevision = state.revision
    state.activeGeneration = state.generation
    state.claimedOperationIndex = operationIndex
    storePinState(state, transaction: transaction)
    return ExteralessDialogPinSync(id: state.nextRequestId, operationIndex: operationIndex, generation: state.generation, revision: state.revision, localOrder: pinnedItems(state.observedOrder), enabled: enabled)
}

/// The native getPinnedDialogs reply is authoritative except for pending local
/// intent and explicitly owned local-only pins. An ordinary remote unpin is NOT
/// ignored forever: the verification read removes it when no newer intent owns it.
func exteralessResolveDialogPinSync(transaction: Transaction, accountPeerId: PeerId, sync: ExteralessDialogPinSync, remoteOrder: [PinnedItemId], nativeResult: [PinnedItemId], enabled: Bool) -> [PinnedItemId]? {
    guard var state = currentPinState(transaction: transaction, accountPeerId: accountPeerId, enabled: enabled) else { return nil }
    guard state.activeRequestId == sync.id, state.generation == sync.generation, state.revision == sync.revision,
          transaction.getPinnedItemIds(groupId: .root) == sync.localOrder else {
        queuePinReconciliation(transaction: transaction, state: &state)
        storePinState(state, transaction: transaction)
        return nil
    }
    let current = state.observedOrder
    var result: [Int64]
    if let intent = state.intentOrder {
        // The native local operation writes a complete order. Preserve that
        // committed intent through the older remote reply, including removals.
        result = intent
        // Retain unrelated remote additions as the native three-way merge does.
        // Only an explicitly removed member is excluded, not every unseen peer.
        for id in pinIds(remoteOrder) where !result.contains(id) && !state.intentRemoved.contains(id) { result.append(id) }
    } else if state.verificationPending || state.disablePending {
        result = pinIds(remoteOrder)
    } else {
        result = pinIds(nativeResult)
    }
    let retained = current.filter { id in
        PeerId(id).namespace == Namespaces.Peer.SecretChat || (enabled && state.localOnly.contains(id))
    }
    for id in retained where !result.contains(id) {
        result.insert(id, at: min(current.firstIndex(of: id) ?? result.count, result.count))
    }
    if !enabled {
        // A disabled local-only shelf cannot leak back into the server request or
        // remain displayed just because a previously queued local intent had it.
        let server = pinIds(exteralessDialogServerPinOrder(transaction: transaction, accountPeerId: accountPeerId, groupId: .root, itemIds: pinnedItems(result)))
        result.removeAll { PeerId($0).namespace != Namespaces.Peer.SecretChat && !server.contains($0) }
    }
    state.observedOrder = result // passed-through logical order; no read-your-writes assumption
    storePinState(state, transaction: transaction)
    return pinnedItems(result)
}

/// Record the ACTUAL encoded order before starting reorderPinnedDialogs. Keeping
/// the sent local snapshot is what makes a late unpin independent of today's prefix.
func exteralessRecordDialogPinRequest(transaction: Transaction, sync: ExteralessDialogPinSync, localOrder: [PinnedItemId], serverOrder: [PinnedItemId]) -> ExteralessDialogPinRequest? {
    guard var state = exteralessDialogPinState(transaction: transaction), state.activeRequestId == sync.id else { return nil }
    let request = ExteralessDialogPinRequest(id: sync.id, generation: sync.generation, revision: sync.revision, localOrder: pinIds(localOrder), serverOrder: pinIds(serverOrder))
    state.lastSent = request
    if sync.enabled { state.localOnly = cloudPins(request.localOrder).filter { !request.serverOrder.contains($0) } }
    storePinState(state, transaction: transaction)
    return request
}

/// Only a matching authoritative read or true native RPC result can acknowledge
/// this generation. Failed, retired and older responses cannot clear newer intent.
func exteralessCompleteDialogPinSync(transaction: Transaction, accountPeerId: PeerId, sync: ExteralessDialogPinSync, localOrder: [PinnedItemId], acknowledgedServerOrder: [PinnedItemId]?, enabled: Bool, appliedInCurrentTransaction: Bool = false) {
    // A matching read can finish in the same transaction as setPinnedItemIds.
    // That table's existing-pin ranks are materialized at commit; use the logical
    // order already checked/stored by resolve, not a premature read-back.
    let current = appliedInCurrentTransaction ? exteralessDialogPinState(transaction: transaction) : currentPinState(transaction: transaction, accountPeerId: accountPeerId, enabled: enabled)
    guard var state = current, state.activeRequestId == sync.id else { return }
    if let acknowledgedServerOrder {
        state.acknowledgedRequestId = sync.id
        state.acknowledgedGeneration = sync.generation
        state.acknowledgedRevision = sync.revision
        state.acknowledgedFromRead = appliedInCurrentTransaction
        state.acknowledgedServerOrder = pinIds(acknowledgedServerOrder)
    }
    let unchanged = state.generation == sync.generation && state.revision == sync.revision && state.observedOrder == pinIds(localOrder)
    let expectedServerOrder = exteralessDialogServerPinOrder(transaction: transaction, accountPeerId: accountPeerId, groupId: .root, itemIds: localOrder)
    if unchanged, acknowledgedServerOrder == expectedServerOrder {
        state.intentOrder = nil
        state.intentRemoved = []
        state.disablePending = false
        state.verificationPending = false
        state.localOnly = state.enabled ? cloudPins(state.observedOrder).filter { !pinIds(expectedServerOrder).contains($0) } : []
    }
    state.activeRequestId = nil
    state.activeRevision = nil
    state.activeGeneration = nil
    // Keep the claim until the next begin. The native log entry is removed by
    // managedSynchronize's *following* transaction; an echo between completion
    // and cleanup must queue a new entry, not mistake this finished one for work.
    storePinState(state, transaction: transaction)
}

/// Actual AccountStateUpdatePinnedItemIdsOperation adapter. It returns false for
/// unmanaged/native-only groups so their original replay remains exactly native.
/// Handling a pin projection does not consume or rewrite the enclosing pts/seq.
func exteralessReplayDialogPinUpdate(transaction: Transaction, accountPeerId: PeerId, groupId: PeerGroupId, operation: AccountStateUpdatePinnedItemIdsOperation, enabled: Bool) -> Bool {
    guard groupId == .root, var state = currentPinState(transaction: transaction, accountPeerId: accountPeerId, enabled: enabled) else { return false }
    var order = transaction.getPinnedItemIds(groupId: groupId)
    let ids = pinIds(order)
    var needsRead = false
    switch operation {
    case let .pin(item):
        if state.intentRemoved.contains(pinIds([item])[0]) {
            needsRead = true
        } else if case let .peer(peerId) = item {
            if transaction.getPeer(peerId) == nil || transaction.getPeerChatListInclusion(peerId) == .notIncluded {
                needsRead = true
            } else if !order.contains(item) { order.insert(item, at: 0) }
        }
    case let .unpin(item):
        let id = pinIds([item])[0]
        let locallyOwned = state.localOnly.contains(id) || state.lastSent?.localOrder.contains(id) == true
        if ids.contains(id) && ((enabled && locallyOwned) || state.intentOrder?.contains(id) == true) {
            // Provisional until a fresh authoritative read; queue at most once.
            // Explicit local Unpin is already absent from ids and is never restored.
            needsRead = true
        } else if let index = order.firstIndex(of: item) { order.remove(at: index) }
        else { needsRead = true }
    case let .reorder(remote):
        if state.intentOrder != nil || Set(remote) != Set(order) { needsRead = true }
        else { order = remote }
    case .sync:
        needsRead = true
    }
    if needsRead {
        state.revision += 1
        state.verificationPending = true
        queuePinReconciliation(transaction: transaction, state: &state)
    } else {
        if order != transaction.getPinnedItemIds(groupId: groupId) { transaction.setPinnedItemIds(groupId: groupId, itemIds: order) }
        let appliedIds = pinIds(order)
        state.observedOrder = appliedIds
        state.localOnly.removeAll { !appliedIds.contains($0) }
        state.observedOperationWatermark = operationWatermark(transaction)
    }
    storePinState(state, transaction: transaction)
    return true
}
