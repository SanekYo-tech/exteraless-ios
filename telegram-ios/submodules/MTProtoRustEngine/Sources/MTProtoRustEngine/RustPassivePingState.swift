import Foundation
import MTProtoRustEngineMapping
import TelegramCore

/// Session-queue-only projection of the already matched native pong event.
/// It neither sends a ping nor derives RTT from RPC or server-activity timing.
struct RustPassivePingState {
    private var sample: ExteralessPillPassivePingSample?
    private var hasAnsweredConnection = false

    mutating func invalidate() {
        sample = nil
        hasAnsweredConnection = false
    }

    mutating func consume(_ event: RustEngineEvent, isMain: Bool, active: Bool, receivedAt: Date) {
        guard isMain, active else { invalidate(); return }
        guard let kind = event.kind else { return }
        switch kind {
        case .connectionState:
            hasAnsweredConnection = rustEngineHasAnsweredConnection(RustEngineConnectionFlags(rawValue: event.flags))
            if !hasAnsweredConnection { sample = nil }
        case .pong:
            // FFI kind 17/value1 is seconds for a matched native ping. Timestamp
            // the event receipt once; a later snapshot must not refresh its age.
            // Answered flags can follow that event; snapshot still gates on them.
            sample = ExteralessPillPassivePingSample(roundTripSeconds: event.value1, sampledAt: receivedAt)
        case .connectionDropped, .closed:
            invalidate()
        default:
            break
        }
    }

    func snapshot(now: Date = Date()) -> ExteralessPillPassivePingSample? {
        guard hasAnsweredConnection, let sample, sample.isFresh(now: now) else { return nil }
        return sample
    }
}
