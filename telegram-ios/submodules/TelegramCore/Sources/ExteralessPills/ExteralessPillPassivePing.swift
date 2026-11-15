import Foundation
import SwiftSignalKit

/// A completed native ping/pong measurement, not RPC latency or time since server activity.
public struct ExteralessPillPassivePingSample: Sendable, Equatable {
    public let roundTripSeconds: Double
    public let sampledAt: Date
    public init?(roundTripSeconds: Double, sampledAt: Date) {
        guard roundTripSeconds.isFinite, roundTripSeconds > 0, (roundTripSeconds * 1000).isFinite,
              sampledAt.timeIntervalSince1970.isFinite, sampledAt.timeIntervalSince1970 > 0 else { return nil }
        self.roundTripSeconds = roundTripSeconds; self.sampledAt = sampledAt
    }
    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(self.sampledAt)
        return age.isFinite && age >= 0 && age <= 120
    }
}

/// Optional capability: engines/wrappers without a native passive sample return unavailable.
/// The Network owner forwards this through Recording/Switching session wrappers.
public protocol ExteralessPillPassivePingSource: AnyObject {
    func exteralessPillPassivePingSnapshot(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void)
}

public func exteralessPillPassivePing(account: Account) -> Signal<ExteralessPillPassivePingSample?, NoError> {
    guard let source = account.network.mainSession as? ExteralessPillPassivePingSource else { return .single(nil) }
    return Signal<ExteralessPillPassivePingSample?, NoError> { subscriber in
        let cancelled = Atomic<Bool>(value: false)
        source.exteralessPillPassivePingSnapshot { sample in
            guard !cancelled.with({ $0 }) else { return }
            subscriber.putNext(sample.flatMap { $0.isFresh() ? $0 : nil })
            subscriber.putCompletion()
        }
        return ActionDisposable { _ = cancelled.swap(true) }
    }
    |> timeout(2, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
    |> take(1)
}
