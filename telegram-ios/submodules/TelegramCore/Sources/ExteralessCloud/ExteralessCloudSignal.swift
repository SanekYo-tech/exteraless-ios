import ExteralessCore
import Foundation
import SwiftSignalKit

private final class ExteralessCloudWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let disposable = MetaDisposable()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    func start(_ signal: Signal<Value, CloudError>, continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        disposable.set((signal |> take(1) |> timeout(12.0, queue: .concurrentDefaultQueue(), alternate: .fail(.timedOut))).start(
            next: { self.finish(.success($0)) }, error: { self.finish(.failure($0)) },
            completed: { self.finish(.failure(CloudError.malformedRemote)) }))
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        disposable.dispose()
        continuation?.resume(with: result)
    }
}

func exteralessCloudFirst<Value: Sendable>(_ signal: Signal<Value, CloudError>) async throws -> Value {
    let waiter = ExteralessCloudWaiter<Value>()
    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { waiter.start(signal, continuation: $0) }
    }, onCancel: { waiter.cancel() })
}
