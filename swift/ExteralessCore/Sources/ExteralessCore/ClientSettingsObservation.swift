import Foundation

/// Keep this token alive for the subscription's lifetime. Cancellation is
/// idempotent; an already-running callback may finish after cancel returns.
public final class ClientSettingsObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        self.lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        self.lock.unlock()
        cancellation?()
    }

    deinit {
        self.cancel()
    }
}

final class ClientSettingsObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Set<String>) -> Void)?

    init(_ callback: @escaping @Sendable (Set<String>) -> Void) {
        self.callback = callback
    }

    func notify(_ keys: Set<String>) {
        self.lock.lock()
        let callback = self.callback
        self.lock.unlock()
        callback?(keys)
    }

    func cancel() {
        self.lock.lock()
        self.callback = nil
        self.lock.unlock()
    }
}
