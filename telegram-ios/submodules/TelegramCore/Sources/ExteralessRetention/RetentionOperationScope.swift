import Foundation
import Postbox
import SwiftSignalKit

/// Cancels work admitted before an explicit clear or account disposal, without invalidating it
/// for unrelated received messages. Holds no account/message contents or global preferences.
final class RetentionOperationScope {
    private let lock = NSLock()
    private var epoch = UUID()
    private var closed = false

    func makeWork() -> RetentionOperationWork {
        self.lock.lock()
        let epoch = self.epoch
        self.lock.unlock()
        return RetentionOperationWork(scope: self, epoch: epoch)
    }

    func invalidate(close: Bool = false) {
        self.lock.lock()
        self.epoch = UUID()
        self.closed = self.closed || close
        self.lock.unlock()
    }

    fileprivate func isCurrent(_ epoch: UUID) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.closed && self.epoch == epoch
    }
}

final class RetentionOperationWork {
    private let scope: RetentionOperationScope
    private let epoch: UUID
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(scope: RetentionOperationScope, epoch: UUID) { self.scope = scope; self.epoch = epoch }
    var isCurrent: Bool {
        self.lock.lock()
        let cancelled = self.cancelled
        self.lock.unlock()
        return !cancelled && self.scope.isCurrent(self.epoch)
    }
    func cancel() { self.lock.lock(); self.cancelled = true; self.lock.unlock() }
}

/// Checks admission inside the real transaction: Postbox may run its body after disposal.
/// The second check prevents an older read result from being delivered after a clear.
func exteralessRetentionScopedTransaction<T>(postbox: Postbox, accountPeerId: PeerId, testingEnvironment: Bool, work: RetentionOperationWork, _ body: @escaping (Transaction) -> Result<T, ExteralessRetentionError>) -> Signal<Result<T, ExteralessRetentionError>, NoError> {
    return Signal { subscriber in
        let disposable = postbox.transaction { transaction -> Result<T, ExteralessRetentionError> in
            guard work.isCurrent else { return .failure(.cancelled) }
            guard let state = transaction.getState() as? AuthorizedAccountState,
                  state.peerId == accountPeerId, state.isTestingEnvironment == testingEnvironment else { return .failure(.unavailable) }
            return body(transaction)
        }.start(next: { result in
            subscriber.putNext(work.isCurrent ? result : .failure(.cancelled))
        }, completed: subscriber.putCompletion)
        return ActionDisposable { work.cancel(); disposable.dispose() }
    }
}

func exteralessRetentionScopedTransaction<T>(account: Account, _ body: @escaping (Transaction) -> Result<T, ExteralessRetentionError>) -> Signal<Result<T, ExteralessRetentionError>, NoError> {
    return Signal { subscriber in
        guard let owner = ExteralessRetentionAccount.get(mediaBox: account.postbox.mediaBox) else {
            subscriber.putNext(.failure(.unavailable)); subscriber.putCompletion(); return EmptyDisposable
        }
        return exteralessRetentionScopedTransaction(postbox: account.postbox, accountPeerId: account.peerId, testingEnvironment: account.testingEnvironment, work: owner.operationScope.makeWork(), body).start(next: subscriber.putNext, completed: subscriber.putCompletion)
    }
}
