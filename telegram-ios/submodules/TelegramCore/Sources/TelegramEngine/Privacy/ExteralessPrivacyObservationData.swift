import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

/// Narrow data projection for the privacy screens. Postbox handles and raw peers
/// stay inside TelegramCore; IDs retain their existing engine typealiases.
public func exteralessPrivacyOwnLastSeen(engine: TelegramEngine) -> Signal<Int32?, NoError> {
    return exteralessPrivacyObservationTransaction(account: engine.account, fallback: nil) { transaction in
        return exteralessOwnLastSeen(transaction: transaction)
    }
}

public func exteralessPrivacyPeerObservationData(engine: TelegramEngine, peerId: EnginePeer.Id) -> Signal<(peer: EnginePeer?, lastSeen: Int32?, readDates: [(id: EngineMessage.Id, dates: PrivacyObservations.Read)]), NoError> {
    return exteralessPrivacyObservationTransaction(account: engine.account, fallback: (nil, nil, [])) { transaction in
        let namespace = peerId.namespace == Namespaces.Peer.SecretChat ? Namespaces.Message.Local : Namespaces.Message.Cloud
        let messages = transaction.getMessages(peerId: peerId, namespace: namespace, from: MessageIndex.upperBound(peerId: peerId, namespace: namespace), includeFrom: false, to: MessageIndex.lowerBound(peerId: peerId, namespace: namespace), limit: 100)
        let savedDates = exteralessObservedReadDates(transaction: transaction, messageIds: messages.map(\.id))
        let dates = messages.compactMap { message -> (id: EngineMessage.Id, dates: PrivacyObservations.Read)? in
            guard let date = savedDates[message.id] else { return nil }
            return (message.id, PrivacyObservations.Read(readAt: date.readAt, playedAt: date.playedAt))
        }
        return (
            transaction.getPeer(peerId).map(EnginePeer.init),
            exteralessObservedLastSeen(transaction: transaction, peerId: peerId, now: Int32(clamping: Int64(Date().timeIntervalSince1970))),
            dates
        )
    }
}

public func exteralessMaintainPrivacyObservations(engine: TelegramEngine) -> Signal<Void, NoError> {
    return exteralessPrivacyObservationTransaction(account: engine.account, fallback: ()) { transaction in
        exteralessMaintainPrivacyObservations(transaction: transaction)
    }
}
