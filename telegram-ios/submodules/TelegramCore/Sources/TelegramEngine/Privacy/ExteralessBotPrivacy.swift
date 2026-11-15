import Foundation
import ExteralessCore
import Postbox
import SwiftSignalKit
internal import TelegramApi

public struct ExteralessBotConversationEvidence {
    public let established: Bool
    public let peer: EnginePeer
}

/// Resolves access hashes separately in each account. A cached user/empty dialog alone
/// is not evidence of prior contact. This path never starts a bot or sends a message.
public func exteralessBotConversationEvidence(account: Account, botId: PeerId, username: String?) -> Signal<ExteralessBotConversationEvidence?, NoError> {
    func inspectPeer() -> Signal<ExteralessBotConversationEvidence?, NoError> {
        return account.postbox.transaction { transaction -> (TelegramUser?, Bool) in
            let user = transaction.getPeer(botId) as? TelegramUser
            var established = transaction.getTopPeerMessageIndex(peerId: botId) != nil
            for (_, state) in transaction.getPeerReadStates(botId) ?? [] {
                if case let .idBased(inbox, outbox, _, _, _) = state, inbox > 0 || outbox > 0 { established = true }
            }
            return (user, established)
        }
        |> mapToSignal { user, established -> Signal<ExteralessBotConversationEvidence?, NoError> in
            guard let user, user.botInfo != nil, let peer = apiInputPeer(user) else { return .single(nil) }
            if established { return .single(ExteralessBotConversationEvidence(established: true, peer: EnginePeer(user))) }
            return account.network.request(Api.functions.messages.getPeerDialogs(peers: [.inputDialogPeer(.init(peer: peer))]))
            |> map { result -> ExteralessBotConversationEvidence? in
                switch result {
                case let .peerDialogs(data):
                    let established = data.dialogs.contains { dialog in
                        if case let .dialog(data) = dialog, data.peer.peerId == botId {
                            return data.topMessage != 0 || data.readInboxMaxId > 0 || data.readOutboxMaxId > 0
                        }
                        return false
                    }
                    return ExteralessBotConversationEvidence(established: established, peer: EnginePeer(user))
                }
            }
            |> `catch` { _ in .single(nil) }
        }
    }
    return account.postbox.transaction { transaction -> Bool in
        guard let user = transaction.getPeer(botId) as? TelegramUser, user.botInfo != nil else { return false }
        return apiInputPeer(user) != nil
    }
    |> mapToSignal { available -> Signal<ExteralessBotConversationEvidence?, NoError> in
        if available { return inspectPeer() }
        guard let username, !username.isEmpty else { return .single(nil) }
        return _internal_resolvePeerByName(account: account, name: username, referrer: nil, ageLimit: 0)
        |> mapToSignal { result -> Signal<ExteralessBotConversationEvidence?, NoError> in
            switch result {
            case .progress: return .complete()
            case let .result(id): return id == botId ? inspectPeer() : .single(nil)
            }
        }
        |> take(1)
    }
    |> timeout(15.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
}

/// Native composition installs the UI resolver. Background/extension sends never borrow
/// the foreground account's approval. A declined check emits false and completes.
public final class ExteralessBotSendAuthorization: @unchecked Sendable {
    public static let shared = ExteralessBotSendAuthorization()
    public typealias Handler = (Account, PeerId) -> Signal<Bool, NoError>
    private struct Key: Hashable {
        let accountId: Int64
        let identity: Int64
        let peerId: Int64
        let enabled: Bool
        let alwaysAsk: Bool
        let selectedUserId: Int64
    }
    private let lock = NSLock()
    private var handler: (UUID, Handler)?
    private var approved = Set<Key>()

    private func key(account: Account, peerId: PeerId, policy: PrivacyPolicy) -> Key {
        return Key(accountId: account.id.int64, identity: account.peerId.toInt64(), peerId: peerId.toInt64(), enabled: policy.botPrivacyEnabled, alwaysAsk: policy.botPrivacyAlwaysAsk, selectedUserId: policy.botPrivacyUserId)
    }

    public func install(_ handler: @escaping Handler) -> Disposable {
        let token = UUID()
        lock.lock()
        self.handler = (token, handler)
        approved.removeAll()
        lock.unlock()
        return ActionDisposable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.handler?.0 == token { self.handler = nil; self.approved.removeAll() }
            self.lock.unlock()
        }
    }

    @discardableResult public func approve(account: Account, peerId: PeerId, expectedPolicy: PrivacyPolicy? = nil) -> Bool {
        let policy = PrivacyPolicy.current
        if let expectedPolicy, !BotAccountPolicy.samePreferences(expectedPolicy, policy) { return false }
        let key = key(account: account, peerId: peerId, policy: policy)
        lock.lock()
        approved.insert(key)
        lock.unlock()
        return true
    }

    public func clear() {
        lock.lock()
        approved.removeAll()
        lock.unlock()
    }

    public func check(account: Account, peerId: PeerId) -> Signal<Bool, NoError> {
        return deferred {
            let policy = PrivacyPolicy.current
            if (!policy.botPrivacyEnabled && !policy.botPrivacyAlwaysAsk) || peerId.namespace != Namespaces.Peer.CloudUser || peerId == account.peerId { return .single(true) }
            let key = self.key(account: account, peerId: peerId, policy: policy)
            self.lock.lock()
            let approved = self.approved.contains(key)
            let handler = self.handler?.1
            self.lock.unlock()
            if approved { return .single(true) }
            return account.postbox.transaction { transaction -> TelegramUser? in transaction.getPeer(peerId) as? TelegramUser }
            |> mapToSignal { user -> Signal<Bool, NoError> in
                guard let user else { return .single(false) }
                if user.botInfo == nil { return .single(true) }
                guard let handler else { return .single(false) }
                return handler(account, peerId)
                |> take(1)
                |> timeout(30.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(false))
            }
        }
    }
}

let exteralessBotStartDeduplicator = BotStartDeduplicator()
