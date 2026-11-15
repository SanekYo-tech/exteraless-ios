import ExteralessCore
import Foundation
import Postbox

struct ExteralessRetentionCaptureResult {
    var captured = 0
    var rejected = 0
    var bounded = false
    var error: ExteralessRetentionError?
}

/// Call BEFORE the stock delete, in its existing transaction. The original operation, its
/// read/thread bookkeeping, and every real pts/seq are then applied unchanged by the caller.
/// Unknown ids are not tombstoned and never cause a getMessages/getHistory recovery request.
@discardableResult
func exteralessRetainBeforeDelete(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId], policy: RetentionPolicy? = nil) -> ExteralessRetentionCaptureResult {
    guard let owner = ExteralessRetentionAccount.get(mediaBox: mediaBox), let loadedPolicy = owner.loadedPolicy else { return ExteralessRetentionCaptureResult(error: .unavailable) }
    let policy = policy ?? loadedPolicy
    guard policy.saveDeleted else { return ExteralessRetentionCaptureResult() }
    var result = ExteralessRetentionCaptureResult()
    do {
        let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: owner.accountPeerId, policy: policy, now: owner.clock())
        for id in Set(ids).sorted() {
            guard let message = transaction.getMessage(id) else { continue }
            do { if try store.captureDeleted(message, mediaBox: mediaBox) { result.captured += 1 } }
            catch { result.rejected += 1; result.error = exteralessRetentionError(error); owner.report(error) }
        }
        if result.captured > 0 { owner.didMutate(try store.finish()) }
    } catch { result.captured = 0; result.error = exteralessRetentionError(error); owner.report(error) }
    return result
}

@discardableResult
func exteralessRetainBeforeEdit(transaction: Transaction, mediaBox: MediaBox, previous: Message, updated: StoreMessage, policy: RetentionPolicy? = nil) -> ExteralessRetentionCaptureResult {
    return exteralessRetainVersion(transaction: transaction, mediaBox: mediaBox, previous: previous, updated: updated, expired: false, policy: policy)
}

/// Ayu's onMessageEditedForce counterpart: capture the known file/metadata before TTL replaces
/// it with TelegramMediaExpiredContent. This does not re-enable expired media on the server row.
@discardableResult
func exteralessRetainBeforeMediaExpiry(transaction: Transaction, mediaBox: MediaBox, previous: Message, policy: RetentionPolicy? = nil) -> ExteralessRetentionCaptureResult {
    return exteralessRetainVersion(transaction: transaction, mediaBox: mediaBox, previous: previous, updated: nil, expired: true, policy: policy)
}

private func exteralessRetainVersion(transaction: Transaction, mediaBox: MediaBox, previous: Message, updated: StoreMessage?, expired: Bool, policy: RetentionPolicy?) -> ExteralessRetentionCaptureResult {
    guard let owner = ExteralessRetentionAccount.get(mediaBox: mediaBox), let loadedPolicy = owner.loadedPolicy else { return ExteralessRetentionCaptureResult(error: .unavailable) }
    let policy = policy ?? loadedPolicy
    guard policy.saveEdits else { return ExteralessRetentionCaptureResult() }
    do {
        let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: owner.accountPeerId, policy: policy, now: owner.clock())
        if try store.captureEdit(previous: previous, updated: updated, mediaBox: mediaBox, expired: expired) {
            owner.didMutate(try store.finish())
            return ExteralessRetentionCaptureResult(captured: 1)
        }
        return ExteralessRetentionCaptureResult()
    } catch {
        owner.report(error)
        return ExteralessRetentionCaptureResult(rejected: 1, error: exteralessRetentionError(error))
    }
}

/// updateChannelAvailableMessages and server history clears have an explicit range, unlike
/// a missing message in a fetched page. Capture only local rows in that range, bounded by the
/// account retention limit. The result exposes truncation; it cannot report unseen recovery.
@discardableResult
func exteralessRetainBeforeRangeDeletion(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, namespace: Int32, maxId: Int32, threadId: Int64? = nil, policy: RetentionPolicy? = nil) -> ExteralessRetentionCaptureResult {
    exteralessRetainBeforeRangeDeletion(transaction: transaction, mediaBox: mediaBox, peerId: peerId, namespaces: [namespace], maxId: maxId, threadId: threadId, policy: policy)
}

@discardableResult
func exteralessRetainBeforeRangeDeletion(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, namespaces: [Int32], maxId: Int32, threadId: Int64? = nil, policy: RetentionPolicy? = nil, scanLimit: Int = exteralessRetentionSlotCount) -> ExteralessRetentionCaptureResult {
    guard let owner = ExteralessRetentionAccount.get(mediaBox: mediaBox), let loadedPolicy = owner.loadedPolicy else { return ExteralessRetentionCaptureResult(error: .unavailable) }
    let policy = policy ?? loadedPolicy
    guard policy.saveDeleted else { return ExteralessRetentionCaptureResult() }
    var result = ExteralessRetentionCaptureResult()
    do {
        let store = try ExteralessRetentionStore(transaction: transaction, accountPeerId: owner.accountPeerId, policy: policy, now: owner.clock())
        var inspected = 0
        let scanLimit = max(0, min(exteralessRetentionSlotCount, scanLimit))
        // Imported/cloud histories need not be monotonic by original timestamp. Keep the
        // server's ID predicate authoritative rather than narrowing at maxId's timestamp.
        for namespace in Set(namespaces).sorted() {
            if inspected >= scanLimit || result.captured >= policy.messageLimit { result.bounded = true; break }
            var from = MessageIndex.upperBound(peerId: peerId, namespace: namespace)
            let lowerBound = MessageIndex.lowerBound(peerId: peerId, namespace: namespace)
            while inspected < scanLimit && result.captured < policy.messageLimit {
                let page = transaction.getMessages(peerId: peerId, namespace: namespace, from: from, includeFrom: false, to: lowerBound, limit: min(128, scanLimit - inspected))
                if page.isEmpty { break }
                for message in page where message.id.id <= maxId && (threadId == nil || message.threadId == threadId) {
                    if result.captured >= policy.messageLimit { break }
                    do { if try store.captureDeleted(message, mediaBox: mediaBox) { result.captured += 1 } }
                    catch { result.rejected += 1; result.error = exteralessRetentionError(error); owner.report(error) }
                }
                inspected += page.count
                guard let last = page.last, last.index < from else { break }
                from = last.index
                if inspected == scanLimit || result.captured == policy.messageLimit { result.bounded = true }
            }
        }
        if result.captured > 0 { owner.didMutate(try store.finish()) }
    } catch { result.captured = 0; result.error = exteralessRetentionError(error); owner.report(error) }
    return result
}

/// Use for stock force-removal sites, including locally initiated deletions. A resource can be
/// owned by OTHER retained messages/versions: checking only the message currently deleted loses it.
/// The final MediaBox keepResource lease also protects against normal cache eviction.
func exteralessRetentionUnownedResources(transaction: Transaction, mediaBox: MediaBox, ids: [MediaResourceId]) -> [MediaResourceId] {
    guard let owner = ExteralessRetentionAccount.get(mediaBox: mediaBox) else { return ids }
    do {
        let index = try ExteralessRetentionIndex.load(transaction: transaction, accountPeerId: owner.accountPeerId)
        var kept = Set<String>()
        for entry in index?.media.values.map({ $0 }) ?? [] {
            kept.insert(entry.cacheId.stringRepresentation)
            if entry.state != .stored { kept.insert(entry.id) }
        }
        return ids.filter { !kept.contains($0.stringRepresentation) }
    } catch {
        owner.report(error)
        return ids
    }
}
