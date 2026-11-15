import Foundation
import Postbox
import SwiftSignalKit

/// File-worker bridge only. No Postbox transaction takes the OS file lock or waits on a file
/// worker, so a lock holder may read/acknowledge authoritative ownership without lock inversion.
func retentionFileValue<T>(_ signal: Signal<T, NoError>, cancelled: @escaping () -> Bool, timeout: Double = 5) throws -> T {
    precondition(!Thread.isMainThread)
    let value = Atomic<T?>(value: nil)
    let done = DispatchSemaphore(value: 0)
    let disposable = (signal |> take(1)).start(next: { result in _ = value.swap(result) }, completed: { done.signal() })
    defer { disposable.dispose() }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while done.wait(timeout: .now() + 0.02) != .success {
        if cancelled() { throw ExteralessRetentionError.cancelled }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ExteralessRetentionError.mediaIO }
    }
    if cancelled() { throw ExteralessRetentionError.cancelled }
    guard let result = value.with({ $0 }) else { throw ExteralessRetentionError.mediaIO }
    return result
}

func retentionFileTransaction<T>(postbox: Postbox, cancelled: @escaping () -> Bool, _ body: @escaping (Transaction) throws -> T) throws -> T {
    let retired = Atomic<Bool>(value: false)
    defer { _ = retired.swap(true) }
    let result: Result<T, Error> = try retentionFileValue(postbox.transaction { transaction in
        Result {
            guard !retired.with({ $0 }), !cancelled() else { throw ExteralessRetentionError.cancelled }
            return try body(transaction)
        }
    }, cancelled: cancelled)
    return try result.get()
}
