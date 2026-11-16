import Foundation

/// A root action waits for its place in the same FIFO as accepted inline edits.
/// Cancellation revokes that captured invocation, never captures a new page.
final class PluginUIManagerEventReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    private let cancelInvocation: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) { self.cancelInvocation = cancel }

    func finish(_ result: Result<Void, Error>) {
        self.lock.lock()
        guard self.result == nil else { self.lock.unlock(); return }
        self.result = result
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume(with: result)
    }

    func cancel() {
        self.cancelInvocation()
        self.finish(.failure(CancellationError()))
    }

    func value() async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if let result = self.result {
                    self.lock.unlock()
                    continuation.resume(with: result)
                } else if self.waiter != nil {
                    self.lock.unlock()
                    continuation.resume(throwing: PluginUIFailure.invalidHandle("Settings event already has a waiter"))
                } else {
                    self.waiter = continuation
                    self.lock.unlock()
                }
            }
        }, onCancel: { self.cancel() })
    }
}

/// Shipping bounded FIFO shared by inline changes and root Custom actions.
/// The running item keeps its credit through the actual awaited operation, even
/// when close() discards the rest. A closed queue never accepts a new generation.
@MainActor final class PluginUIManagerEventFIFO {
    private struct Work {
        let bytes: Int
        let receipt: PluginUIManagerEventReceipt
        let isCurrent: @Sendable () -> Bool
        let operation: @MainActor () async throws -> Void
        let failed: @MainActor (Error) -> Void
    }
    private var pending: [Work] = []
    private var running: Work?
    private var worker: Task<Void, Never>?
    private var closed = false
    private(set) var retainedBytes = 0
    var retainedCount: Int { self.pending.count + (self.running == nil ? 0 : 1) }

    func enqueue(bytes: Int, isCurrent: @escaping @Sendable () -> Bool, cancel: @escaping @Sendable () -> Void,
                 operation: @escaping @MainActor () async throws -> Void,
                 failed: @escaping @MainActor (Error) -> Void = { _ in }) throws -> PluginUIManagerEventReceipt {
        guard !self.closed, isCurrent() else { throw PluginUIFailure.invalidHandle("Settings page FIFO expired") }
        guard bytes >= 0, bytes <= 512 * 1024, self.retainedCount < 128,
              self.retainedBytes <= 512 * 1024 - bytes else {
            throw PluginUIFailure.unavailable("Custom event queue exceeds 128 entries or 512 KiB")
        }
        let receipt = PluginUIManagerEventReceipt(cancel: cancel)
        self.pending.append(Work(bytes: bytes, receipt: receipt, isCurrent: isCurrent, operation: operation, failed: failed))
        self.retainedBytes += bytes
        if self.worker == nil {
            self.worker = Task { @MainActor [weak self] in
                while let self, !self.closed, !Task.isCancelled {
                    guard !self.pending.isEmpty else { self.worker = nil; return }
                    let work = self.pending.removeFirst()
                    self.running = work
                    do {
                        guard work.isCurrent() else { throw PluginUIFailure.invalidHandle("Settings event authority expired in FIFO") }
                        try await work.operation()
                        try Task.checkCancellation()
                        guard work.isCurrent() else { throw PluginUIFailure.invalidHandle("Settings event authority expired after execution") }
                        work.receipt.finish(.success(()))
                    } catch {
                        work.receipt.finish(.failure(error))
                        if !self.closed, !Task.isCancelled, work.isCurrent() { work.failed(error) }
                    }
                    self.retainedBytes -= work.bytes
                    self.running = nil
                }
                self?.worker = nil
            }
        }
        return receipt
    }

    func close() {
        guard !self.closed else { return }
        self.closed = true
        for work in self.pending {
            self.retainedBytes -= work.bytes
            work.receipt.cancel()
        }
        self.pending.removeAll()
        self.running?.receipt.cancel()
        self.worker?.cancel()
    }

    deinit { self.worker?.cancel() }
}
