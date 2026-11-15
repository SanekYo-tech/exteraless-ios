import Foundation
import SwiftSignalKit

private final class ClientHarnessSignalReply<Value>: @unchecked Sendable {
    let disposable = MetaDisposable()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        guard let continuation else { return }
        self.disposable.dispose()
        continuation.resume(with: result)
    }
}

func clientHarnessFirst<Value>(_ signal: Signal<Value, NoError>, name: String) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let reply = ClientHarnessSignalReply(continuation)
        reply.disposable.set((signal |> take(1)).start(next: { reply.finish(.success($0)) }, completed: {
            reply.finish(.failure(ClientHarnessFailure(description: "signal completed without value: " + name)))
        }))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            reply.finish(.failure(ClientHarnessFailure(description: "signal deadline: " + name)))
        }
    }
}
