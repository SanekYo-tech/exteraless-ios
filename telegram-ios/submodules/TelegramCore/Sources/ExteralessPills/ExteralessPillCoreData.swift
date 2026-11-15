import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public struct ExteralessPillOwnStatus {
    public enum Presence { case online(until: Int32), lastSeen(Int32), recently, lastWeek, lastMonth, unknown }
    public let presence: Presence
    public let locallyObservedLastSeen: Int32?
}

/// Subscribes to this account's existing presence observations. No user-status RPC or presence packet is sent.
public func exteralessPillOwnStatus(engine: TelegramEngine) -> Signal<ExteralessPillOwnStatus?, NoError> {
    let account = engine.account
    return engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Presence(id: account.peerId))
    |> mapToSignal { _ -> Signal<ExteralessPillOwnStatus?, NoError> in
        return exteralessPrivacyObservationTransaction(account: account, fallback: nil) { transaction in
            let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
            let presence = transaction.getPeerPresence(account.peerId) as? TelegramUserPresence
            let value: ExteralessPillOwnStatus.Presence
            switch presence?.status {
            case let .present(until)?: value = until > now ? .online(until: until) : until > 0 ? .lastSeen(until) : .unknown
            case .recently?: value = .recently
            case .lastWeek?: value = .lastWeek
            case .lastMonth?: value = .lastMonth
            default: value = .unknown
            }
            let observed = exteralessOwnLastSeen(transaction: transaction).flatMap { $0 > 0 && $0 <= now ? $0 : nil }
            return ExteralessPillOwnStatus(presence: value, locallyObservedLastSeen: observed)
        }
    }
}

public struct ExteralessPillConnectionActivity {
    public let datacenterId: Int
    public let answered: Bool
    public let silentSeconds: Double?
    public let waitingSeconds: Double?
}

/// A passive read of the existing MTProto main session, not a new socket/ping/request.
/// This engine interface exposes readiness/activity, NOT RTT. Never label silentFor as a ping.
public func exteralessPillConnectionActivity(account: Account) -> Signal<ExteralessPillConnectionActivity?, NoError> {
    return Signal<ExteralessPillConnectionActivity?, NoError> { subscriber in
        let cancelled = Atomic<Bool>(value: false)
        account.network.mainSession.serverActivity { activity in
            guard !cancelled.with({ $0 }) else { return }
            func duration(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
            subscriber.putNext(activity.map { ExteralessPillConnectionActivity(datacenterId: account.network.datacenterId, answered: $0.connected, silentSeconds: duration($0.silentFor), waitingSeconds: duration($0.waitingFor)) })
            subscriber.putCompletion()
        }
        return ActionDisposable { _ = cancelled.swap(true) }
    }
    |> timeout(2, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
    |> take(1)
}
