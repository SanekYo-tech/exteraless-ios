import Foundation

/// Revocable, lock-only admission for one queued native writer. No MainActor
/// callback or lock is held while writing. Retirement before admission has zero
/// effects; a writer that won admission finishes its complete transaction once.
public final class CloudWriteAdmission: @unchecked Sendable {
    private enum Phase { case pending, admitted, finished }
    public let contextIdentity: ObjectIdentifier
    private let lock = NSLock()
    private var phase = Phase.pending
    private var revoked = false

    public init(contextIdentity: ObjectIdentifier) { self.contextIdentity = contextIdentity }

    public var hasAdmittedWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase != .pending
    }

    public func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }

    public func checkPending(contextIdentity: ObjectIdentifier) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, phase == .pending, self.contextIdentity == contextIdentity else { throw CancellationError() }
    }

    public func withAdmittedWrite<Value>(contextIdentity: ObjectIdentifier, _ body: () throws -> Value) throws -> Value {
        lock.lock()
        guard !revoked, phase == .pending, self.contextIdentity == contextIdentity else {
            lock.unlock()
            throw CancellationError()
        }
        phase = .admitted
        lock.unlock()
        defer {
            lock.lock()
            phase = .finished
            lock.unlock()
        }
        return try body()
    }

    public func perform<Value: Sendable>(contextIdentity: ObjectIdentifier,
                                        _ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                try self.withAdmittedWrite(contextIdentity: contextIdentity, body)
            }
            return try await worker.value
        }, onCancel: { self.revoke() })
    }
}
