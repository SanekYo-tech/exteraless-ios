import Foundation
import ExteralessCore
import Postbox
import SwiftSignalKit
internal import TelegramApi

public func exteralessToggleGhostMode(account: Account) -> Signal<Bool, ClientSettingsError> {
    return (Signal<Bool, ClientSettingsError> { subscriber in
        do {
            let enabled = try PrivacyGhostModeMutation.toggle(in: .shared)
            subscriber.putNext(enabled)
            subscriber.putCompletion()
        } catch let error as ClientSettingsError {
            subscriber.putError(error)
        } catch {
            subscriber.putError(.storageFailure(operation: "ghost toggle", code: 0))
        }
        return EmptyDisposable
    } |> runOn(Queue.concurrentDefaultQueue()))
    |> mapToSignal { enabled in
        return account.network.request(Api.functions.account.updateStatus(offline: PrivacyPolicy.current.sendOnlinePackets ? .boolFalse : .boolTrue))
        |> `catch` { _ in .single(.boolFalse) }
        |> castError(ClientSettingsError.self)
        |> map { _ in enabled }
    }
}

/// An explicit, peer-scoped read. It bypasses only this operation's automatic receipt
/// policy; no global "allow next packet" counter can be consumed by another account.
public func exteralessMarkReadOnServer(account: Account, peerId: PeerId, messageId: MessageId? = nil, threadId: Int64? = nil, contents: Bool = false) -> Signal<Bool, NoError> {
    return exteralessMarkReadOnServer(account: account, peerId: peerId, messageId: messageId, threadId: threadId, contents: contents, intent: .manual)
}

private func exteralessMarkReadOnServer(account: Account, peerId: PeerId, messageId: MessageId? = nil, threadId: Int64? = nil, contents: Bool = false, intent: ExteralessReadRequestIntent) -> Signal<Bool, NoError> {
    if let messageId, messageId.peerId != peerId { return .single(false) }
    let postbox = account.postbox
    let stateManager = account.stateManager
    return postbox.transaction { transaction -> (Peer?, MessageIndex?) in
        let index: MessageIndex?
        if let messageId { index = transaction.getMessage(messageId)?.index }
        else if peerId.namespace == Namespaces.Peer.SecretChat { index = transaction.getTopPeerMessageIndex(peerId: peerId) }
        else { index = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud) }
        return (transaction.getPeer(peerId), index)
    }
    |> mapToSignal { [weak account] peer, index -> Signal<Bool, NoError> in
        guard let account, let peer, let index else { return .single(false) }
        if let encrypted = apiInputSecretChat(peer) {
            guard index.timestamp > 0 else { return .single(false) }
            return exteralessOwnedReadRequest(account: account, Api.functions.messages.readEncryptedHistory(peer: encrypted, maxDate: index.timestamp), intent: intent)
            |> map { $0 == .boolTrue }
            |> `catch` { _ in .single(false) }
        }
        guard let inputPeer = apiInputPeer(peer), index.id.namespace == Namespaces.Message.Cloud else { return .single(false) }
        if let threadId {
            return exteralessOwnedReadRequest(account: account, Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: index.id.id), intent: intent)
            |> map { $0 == .boolTrue }
            |> `catch` { _ in .single(false) }
        }
        if let channel = apiInputChannel(peer) {
            let request = contents ? Api.functions.channels.readMessageContents(channel: channel, id: [index.id.id]) : Api.functions.channels.readHistory(channel: channel, maxId: index.id.id)
            return exteralessOwnedReadRequest(account: account, request, intent: intent)
            |> map { $0 == .boolTrue }
            |> `catch` { _ in .single(false) }
        }
        let request = contents ? Api.functions.messages.readMessageContents(id: [index.id.id]) : Api.functions.messages.readHistory(peer: inputPeer, maxId: index.id.id)
        return exteralessOwnedReadRequest(account: account, request, intent: intent)
        |> map { result -> Bool in
            if case let .affectedMessages(data) = result {
                stateManager?.addUpdateGroups([.updatePts(pts: data.pts, ptsCount: data.ptsCount)])
            }
            return true
        }
        |> `catch` { _ in .single(false) }
    }
}

private final class ExteralessPrivacyAccountLease: Disposable {
    weak var account: Account?
    private let lock = NSLock()
    private var disposed = false
    private var readRequests: [PeerId: MetaDisposable] = [:]
    private let offlineRequest = MetaDisposable()
    private var observation: ClientSettingsObservation?

    init(account: Account) {
        self.account = account
        observation = ClientSettings.shared.observe { [weak self] keys in
            let policyKeys: Set<String> = ["privacy.sendReadMessagePackets", "privacy.markReadAfterSend", "privacy.ghostModeReadExclusions", "privacy.sendOfflinePacketAfterOnline", "privacy.ghostModeTypingExclusions"]
            if keys.isEmpty || !keys.isDisjoint(with: policyKeys) { self?.cancelTransient() }
        }
    }

    deinit { self.dispose() }

    private func cancelTransient() {
        lock.lock()
        let requests = readRequests
        readRequests.removeAll()
        lock.unlock()
        for value in requests.values { value.dispose() }
        offlineRequest.set(nil)
    }

    func dispose() {
        lock.lock()
        disposed = true
        account = nil
        lock.unlock()
        observation?.cancel()
        observation = nil
        cancelTransient()
        offlineRequest.dispose()
    }

    func readAfterSend(peerId: PeerId) {
        lock.lock()
        guard !disposed, let account else { lock.unlock(); return }
        let disposable = readRequests[peerId] ?? MetaDisposable()
        readRequests[peerId] = disposable
        lock.unlock()
        let policy = PrivacyPolicy.current
        let key = PrivacyPeerKey(accountId: account.id.int64, peerId: peerId.toInt64())
        guard !policy.sendReadMessagePackets, policy.markReadAfterSend, !policy.readExcluded(key) else { return }
        disposable.set(exteralessMarkReadOnServer(account: account, peerId: peerId, intent: .afterSend(key)).start())
    }

    func offlineAfterSend(peerId: PeerId?) {
        lock.lock()
        let account = disposed ? nil : self.account
        lock.unlock()
        guard let account else { return }
        let key = peerId.map { PrivacyPeerKey(accountId: account.id.int64, peerId: $0.toInt64()) }
        guard PrivacyPolicy.current.goOfflineAfterSend(to: key) else { return }
        let request: Signal<Never, NoError> = Signal<Never, NoError>.complete()
        |> suspendAwareDelay(1.0, queue: Queue.concurrentDefaultQueue())
        |> then(deferred { [weak self, weak account] in
            guard let self, let account, self.account === account, PrivacyPolicy.current.goOfflineAfterSend(to: key) else { return Signal<Never, NoError>.complete() }
            return account.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
            |> `catch` { _ in .single(.boolFalse) }
            |> ignoreValues
        })
        offlineRequest.set(request.start())
    }
}

private final class ExteralessPrivacyAccountLeases: @unchecked Sendable {
    static let shared = ExteralessPrivacyAccountLeases()
    private final class WeakLease { weak var value: ExteralessPrivacyAccountLease?; init(_ value: ExteralessPrivacyAccountLease) { self.value = value } }
    private let lock = NSLock()
    private var leases: [ObjectIdentifier: WeakLease] = [:]
    func install(account: Account) -> Disposable {
        let lease = ExteralessPrivacyAccountLease(account: account)
        lock.lock()
        leases = leases.filter { $0.value.value != nil }
        leases[ObjectIdentifier(account.network)] = WeakLease(lease)
        lock.unlock()
        return lease
    }
    func get(network: Network) -> ExteralessPrivacyAccountLease? {
        lock.lock()
        defer { lock.unlock() }
        return leases[ObjectIdentifier(network)]?.value
    }
}

func exteralessInstallPrivacyAccount(account: Account) -> Disposable {
    return ExteralessPrivacyAccountLeases.shared.install(account: account)
}

private let exteralessMessageSendMethods: Set<String> = ["messages.sendMessage", "messages.sendMedia", "messages.sendMultiMedia", "messages.forwardMessages", "messages.sendInlineBotResult", "messages.sendScheduledMessages"]
private let exteralessOtherOnlineMethods: Set<String> = ["messages.editMessage", "messages.sendEncrypted", "messages.sendEncryptedFile", "messages.sendEncryptedMultiMedia", "messages.sendEncryptedService"]

func exteralessOutgoingPeer(_ description: FunctionDescription) -> PeerId? {
    let argument = description.parameters.first(where: { $0.0 == "toPeer" || $0.0 == "to_peer" })?.1.value ?? description.parameters.first(where: { $0.0 == "peer" })?.1.value
    if let peer = argument as? Api.InputPeer {
        switch peer {
        case let .inputPeerUser(data): return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(data.userId))
        case let .inputPeerChat(data): return PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(data.chatId))
        case let .inputPeerChannel(data): return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(data.channelId))
        case let .inputPeerUserFromMessage(data): return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(data.userId))
        case let .inputPeerChannelFromMessage(data): return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(data.channelId))
        default: return nil
        }
    }
    if let peer = argument as? Api.InputEncryptedChat, case let .inputEncryptedChat(data) = peer {
        return PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(Int64(data.chatId)))
    }
    return nil
}

func exteralessOutgoingPeer(network: Network, description: FunctionDescription) -> PeerId? {
    if let metadata = exteralessTLPrivacyMetadata(network: network, description: description) {
        // An intentionally unresolved/multi-peer result must not fall back to an
        // older pre-mutation descriptor's parameters.
        return metadata.allPeersResolved ? metadata.outgoingPeerId : nil
    }
    return exteralessOutgoingPeer(description)
}

func exteralessPrivacyWillSubmit(network: Network, description: FunctionDescription) {
    guard exteralessMessageSendMethods.contains(description.name) else { return }
    let policy = PrivacyPolicy.current
    guard !policy.sendReadMessagePackets, policy.markReadAfterSend, let peerId = exteralessOutgoingPeer(network: network, description: description) else { return }
    ExteralessPrivacyAccountLeases.shared.get(network: network)?.readAfterSend(peerId: peerId)
}

func exteralessPrivacyDidComplete(network: Network, description: FunctionDescription) {
    guard PrivacyPolicy.current.sendOfflinePacketAfterOnline,
          exteralessMessageSendMethods.contains(description.name) || exteralessOtherOnlineMethods.contains(description.name) else { return }
    ExteralessPrivacyAccountLeases.shared.get(network: network)?.offlineAfterSend(peerId: exteralessOutgoingPeer(network: network, description: description))
}
