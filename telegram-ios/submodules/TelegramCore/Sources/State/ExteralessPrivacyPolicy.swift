import Foundation
import ExteralessCore
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

enum ExteralessReadRequestIntent {
    case automatic(PrivacyPeerKey)
    case afterSend(PrivacyPeerKey)
    case manual
}

/// The generic identities permit a transport-free fixture; production instantiates
/// this with Account, Network and FunctionDescription, never peer/message erasure.
/// Automatic entries are revocable peer metadata, not a manual read grant.
final class ExteralessReadRequestAdmissions<Owner: AnyObject, Transport: AnyObject, Descriptor: AnyObject>: @unchecked Sendable {
    enum Admission: Equatable { case unregistered, allowed, denied }

    final class Lease: Disposable {
        fileprivate weak var owner: Owner?
        fileprivate weak var transport: Transport?
        fileprivate weak var descriptor: Descriptor?
        private let lock = NSLock()
        private let intent: ExteralessReadRequestIntent
        private let ownerIsCurrent: (Owner, Transport) -> Bool
        private var body: Data?
        private var begun = false
        private var admitted = false
        private var cancelled = false

        fileprivate init(owner: Owner, transport: Transport, descriptor: Descriptor, body: Data, intent: ExteralessReadRequestIntent, ownerIsCurrent: @escaping (Owner, Transport) -> Bool) {
            self.owner = owner
            self.transport = transport
            self.descriptor = descriptor
            self.body = body
            self.intent = intent
            self.ownerIsCurrent = ownerIsCurrent
        }

        func begin() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.begun, !self.cancelled, self.owner != nil, self.transport != nil, self.descriptor != nil else { return false }
            self.begun = true
            return true
        }

        fileprivate func admit(transport: Transport, descriptor: Descriptor, body: Data, policy: PrivacyPolicy, automaticMetadataAllows: Bool) -> Bool {
            self.lock.lock()
            let owner = self.owner
            let eligible = self.begun && !self.cancelled && !self.admitted && self.transport === transport && self.descriptor === descriptor && self.body == body
            self.lock.unlock()
            guard eligible, let owner, self.ownerIsCurrent(owner, transport) else { return false }
            // Read the policy supplied at FINAL admission, not the snapshot that
            // preceded a suspended prefix or the policy at grant construction.
            switch self.intent {
            case let .automatic(peer):
                guard policy.allowsMessageRead(peer), automaticMetadataAllows else { return false }
            case let .afterSend(peer):
                guard policy.allowsMessageRead(peer, intent: .afterSend) else { return false }
            case .manual:
                break
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.cancelled, !self.admitted, self.owner === owner, self.transport === transport, self.descriptor === descriptor, self.body == body else { return false }
            self.admitted = true
            self.body = nil
            return true
        }

        func dispose() {
            self.lock.lock()
            self.cancelled = true
            self.body = nil
            self.lock.unlock()
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Lease] = [:]

    func register(owner: Owner, transport: Transport, descriptor: Descriptor, body: Data, intent: ExteralessReadRequestIntent, ownerIsCurrent: @escaping (Owner, Transport) -> Bool) -> Lease {
        let lease = Lease(owner: owner, transport: transport, descriptor: descriptor, body: body, intent: intent, ownerIsCurrent: ownerIsCurrent)
        self.lock.lock()
        // Keep a denial tombstone while its descriptor remains alive: cancellation
        // or consumption must not turn an old manual grant into an unbound request.
        self.entries = self.entries.filter { $0.value.descriptor != nil && $0.value.transport != nil }
        let key = ObjectIdentifier(descriptor)
        let duplicate = self.entries[key] != nil
        if !duplicate { self.entries[key] = lease }
        self.lock.unlock()
        if duplicate { lease.dispose() }
        return lease
    }

    func admit(transport: Transport, descriptor: Descriptor, body: Data, policy: PrivacyPolicy, automaticMetadataAllows: Bool = true) -> Admission {
        self.lock.lock()
        let lease = self.entries[ObjectIdentifier(descriptor)]
        self.lock.unlock()
        guard let lease else { return .unregistered }
        return lease.admit(transport: transport, descriptor: descriptor, body: body, policy: policy, automaticMetadataAllows: automaticMetadataAllows) ? .allowed : .denied
    }
}

private let exteralessReadRequestAdmissions = ExteralessReadRequestAdmissions<Account, Network, FunctionDescription>()
private let exteralessScopedReadMethods: Set<String> = ["messages.readHistory", "messages.readEncryptedHistory", "messages.readDiscussion", "messages.readMessageContents", "channels.readHistory", "channels.readMessageContents", "messages.readSavedHistory"]

/// A single owned subscription and a single final-admission opportunity. Both
/// normal completion and cancellation retire the authorization/metadata lease.
func exteralessBoundReadRequest<T, Owner: AnyObject, Transport: AnyObject>(admissions: ExteralessReadRequestAdmissions<Owner, Transport, FunctionDescription>, owner: Owner, transport: Transport, request: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), intent: ExteralessReadRequestIntent, ownerIsCurrent: @escaping (Owner, Transport) -> Bool, submit: @escaping () -> Signal<T, MTRpcError>) -> Signal<T, MTRpcError> {
    let lease = admissions.register(owner: owner, transport: transport, descriptor: request.0, body: request.1.makeData(), intent: intent, ownerIsCurrent: ownerIsCurrent)
    return Signal { subscriber in
        guard lease.begin() else {
            subscriber.putError(MTRpcError(errorCode: 403, errorDescription: "EXTERALESS_READ_REQUEST_RETIRED"))
            return EmptyDisposable
        }
        let disposable = submit().start(next: subscriber.putNext, error: subscriber.putError, completed: subscriber.putCompletion)
        return ActionDisposable { lease.dispose(); disposable.dispose() }
    }
}

func exteralessOwnedReadRequest<T>(account: Account, _ request: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), intent: ExteralessReadRequestIntent) -> Signal<T, MTRpcError> {
    guard exteralessScopedReadMethods.contains(request.0.name) else { return .fail(MTRpcError(errorCode: 400, errorDescription: "EXTERALESS_READ_INTENT_INVALID")) }
    let network = account.network
    return exteralessBoundReadRequest(admissions: exteralessReadRequestAdmissions, owner: account, transport: network, request: request, intent: intent, ownerIsCurrent: { account, network in
        account.network === network && exteralessTLRegisteredAccount(network) === account && exteralessTLAccountIsCurrent(network)
    }, submit: { [weak network] in
        guard let network else { return .fail(MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED")) }
        return network.request(request)
    })
}

// Legacy offline-presence callsite has no user read intent and receives no grant.
// Its offline=true request is permitted by the normal final presence policy.
func exteralessExplicitReadRequest<T>(network: Network, _ request: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>)) -> Signal<T, MTRpcError> {
    return network.request(request)
}

private let exteralessPrivacyGuardMethods: Set<String> = ["messages.readHistory", "messages.readEncryptedHistory", "messages.readDiscussion", "messages.readMessageContents", "channels.readHistory", "channels.readMessageContents", "messages.readSavedHistory", "messages.getMessagesViews", "stories.readStories", "stories.incrementStoryViews", "messages.setTyping", "messages.setEncryptedTyping", "account.updateStatus"]

/// FINAL admission only: a successful call consumes a manual/owned read lease.
/// Prefix/descriptor preparation must never use this as a speculative preflight.
func exteralessPrivacyRequestError(network: Network, description: FunctionDescription, body: Data) -> MTRpcError? {
    guard exteralessPrivacyGuardMethods.contains(description.name) else { return nil }
    let policy = PrivacyPolicy.current
    let metadata = exteralessTLPrivacyMetadata(network: network, description: description)
    let metadataAllows = metadata.map { metadata in
        policy.permitsRequest(method: description.name, peers: metadata.peerIds.map { exteralessPrivacyPeer(network: network, peerId: $0) }, allPeersResolved: metadata.allPeersResolved, incrementViews: metadata.incrementViews, requestsOnline: metadata.requestsOnline, ghostStorySession: ExteralessStoryPrivacySessions.shared.isActive(accountId: network.accountRecordId))
    }
    switch exteralessReadRequestAdmissions.admit(transport: network, descriptor: description, body: body, policy: policy, automaticMetadataAllows: metadataAllows ?? true) {
    case .allowed: return nil
    case .denied: return MTRpcError(errorCode: 403, errorDescription: "EXTERALESS_PRIVACY_SUPPRESSED")
    case .unregistered: break
    }
    if metadata != nil {
        // The TL owner binds this metadata to the exact Network + descriptor after
        // validating the final bytes. It contains no access hashes or message body.
        if metadataAllows == true { return nil }
        return MTRpcError(errorCode: 403, errorDescription: "EXTERALESS_PRIVACY_SUPPRESSED")
    }
    var peerId = exteralessOutgoingPeer(description)
    if peerId == nil, let channel = description.parameters.first(where: { $0.0 == "channel" })?.1.value as? Api.InputChannel {
        if case let .inputChannel(data) = channel { peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(data.channelId)) }
    }
    let increment = (description.parameters.first(where: { $0.0 == "increment" })?.1.value as? Api.Bool).map { $0 == .boolTrue }
    let online = (description.parameters.first(where: { $0.0 == "offline" })?.1.value as? Api.Bool).map { $0 == .boolFalse }
    if policy.permitsRequest(method: description.name, peer: peerId.map { exteralessPrivacyPeer(network: network, peerId: $0) }, incrementViews: increment, requestsOnline: online, ghostStorySession: ExteralessStoryPrivacySessions.shared.isActive(accountId: network.accountRecordId)) { return nil }
    return MTRpcError(errorCode: 403, errorDescription: "EXTERALESS_PRIVACY_SUPPRESSED")
}

/// Public, body-free policy query for a native validated metadata producer. This
/// grants no exemption and cannot register a bypass; Network still runs its guard.
public func exteralessPrivacyRequestIsAllowed(accountId: Int64, method: String, peerIds: [EnginePeer.Id], allPeersResolved: Bool, incrementViews: Bool?, requestsOnline: Bool?) -> Bool {
    return PrivacyPolicy.current.permitsRequest(method: method, peers: peerIds.map { PrivacyPeerKey(accountId: accountId, peerId: $0.toInt64()) }, allPeersResolved: allPeersResolved, incrementViews: incrementViews, requestsOnline: requestsOnline, ghostStorySession: ExteralessStoryPrivacySessions.shared.isActive(accountId: accountId))
}

func exteralessPrivacyPeer(network: Network, peerId: PeerId) -> PrivacyPeerKey {
    return PrivacyPeerKey(accountId: network.accountRecordId, peerId: peerId.toInt64())
}

func exteralessAllowsMessageRead(network: Network, peerId: PeerId) -> Bool {
    return PrivacyPolicy.current.allowsMessageRead(exteralessPrivacyPeer(network: network, peerId: peerId))
}

func exteralessAllowsStoryRead(network: Network, peerId: PeerId) -> Bool {
    return PrivacyPolicy.current.allowsStoryRead(exteralessPrivacyPeer(network: network, peerId: peerId), ghostSession: ExteralessStoryPrivacySessions.shared.isActive(accountId: network.accountRecordId))
}

func exteralessAllowsTyping(network: Network, peerId: PeerId) -> Bool {
    return PrivacyPolicy.current.allowsTyping(exteralessPrivacyPeer(network: network, peerId: peerId))
}

public func exteralessShouldHidePhone(accountPeerId: PeerId, peerId: PeerId) -> Bool {
    return accountPeerId == peerId && PrivacyPolicy.current.hidePhone
}

public func exteralessShowGhostStatus() -> Bool {
    return ClientSettings.shared.bool("privacy.showGhostModeStatus") && PrivacyPolicy.current.ghostModeActive
}

public func exteralessShowGhostShortcut() -> Bool {
    return ClientSettings.shared.bool("privacy.showGhostInDrawer")
}

public func exteralessGhostModeIsActive() -> Bool { PrivacyPolicy.current.ghostModeActive }

public func exteralessShouldAskBeforeOpeningStory(accountPeerId: PeerId, focusedPeerId: PeerId?) -> Bool {
    return ClientSettings.shared.bool("privacy.askBeforeOpeningStory") && PrivacyPolicy.current.sendReadStoriesPackets && focusedPeerId != accountPeerId
}

/// Lazy so an operation queued before changing a setting checks it at subscription time.
/// A suppressed response still emits and completes: callers' local transactions must run.
func exteralessPrivacyRequest<T, E>(allow: @escaping () -> Bool, suppressed: @escaping () -> T, request: @escaping () -> Signal<T, E>) -> Signal<T, E> {
    return deferred {
        if allow() { return request() }
        return .single(suppressed())
    }
}

func exteralessReadMessageContents(network: Network, peerId: PeerId, ids: [Int32]) -> Signal<Api.messages.AffectedMessages?, MTRpcError> {
    return exteralessPrivacyRequest(allow: { exteralessAllowsMessageRead(network: network, peerId: peerId) }, suppressed: { nil }, request: { [network] in
        guard let account = exteralessTLRegisteredAccount(network) else { return .fail(MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED")) }
        return exteralessAutomaticReadMessageContents(admissions: exteralessReadRequestAdmissions, owner: account, transport: network, accountId: network.accountRecordId, peerId: peerId, ids: ids, ownerIsCurrent: { account, network in
            account.network === network && exteralessTLRegisteredAccount(network) === account && exteralessTLAccountIsCurrent(network)
        }, submit: { [weak network] request in
            guard let network else { return .fail(MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED")) }
            return network.request(request)
        })
    })
}

/// Shared typed adapter used by the native caller and the finite prefix fixture.
/// The annotation is automatic even when a per-peer exception allowed the start.
func exteralessAutomaticReadMessageContents<Owner: AnyObject, Transport: AnyObject>(admissions: ExteralessReadRequestAdmissions<Owner, Transport, FunctionDescription>, owner: Owner, transport: Transport, accountId: Int64, peerId: PeerId, ids: [Int32], ownerIsCurrent: @escaping (Owner, Transport) -> Bool, submit: @escaping ((FunctionDescription, Buffer, DeserializeFunctionResponse<Api.messages.AffectedMessages>)) -> Signal<Api.messages.AffectedMessages, MTRpcError>) -> Signal<Api.messages.AffectedMessages?, MTRpcError> {
    let request = Api.functions.messages.readMessageContents(id: ids)
    return exteralessBoundReadRequest(admissions: admissions, owner: owner, transport: transport, request: request, intent: .automatic(PrivacyPeerKey(accountId: accountId, peerId: peerId.toInt64())), ownerIsCurrent: ownerIsCurrent, submit: { submit(request) })
    |> map(Optional.init)
}

func exteralessReadChannelMessageContents(network: Network, peerId: PeerId, channel: Api.InputChannel, ids: [Int32]) -> Signal<Api.Bool, MTRpcError> {
    return exteralessPrivacyRequest(allow: { exteralessAllowsMessageRead(network: network, peerId: peerId) }, suppressed: { .boolFalse }, request: {
        network.request(Api.functions.channels.readMessageContents(channel: channel, id: ids))
    })
}

func exteralessReadDiscussion(network: Network, peerId: PeerId, peer: Api.InputPeer, threadId: Int32, maxId: Int32) -> Signal<Api.Bool, MTRpcError> {
    return exteralessPrivacyRequest(allow: { exteralessAllowsMessageRead(network: network, peerId: peerId) }, suppressed: { .boolFalse }, request: {
        network.request(Api.functions.messages.readDiscussion(peer: peer, msgId: threadId, readMaxId: maxId))
    })
}

func exteralessReadSavedHistory(network: Network, peerId: PeerId, parentPeer: Api.InputPeer, peer: Api.InputPeer, maxId: Int32) -> Signal<Api.Bool, MTRpcError> {
    return exteralessPrivacyRequest(allow: { exteralessAllowsMessageRead(network: network, peerId: peerId) }, suppressed: { .boolFalse }, request: {
        network.request(Api.functions.messages.readSavedHistory(parentPeer: parentPeer, peer: peer, maxId: maxId))
    })
}

public func exteralessPrivacySettingsChanges() -> Signal<Void, NoError> {
    return Signal { subscriber in
        let observation = ClientSettings.shared.observe { keys in
            if keys.isEmpty || keys.contains(where: { $0.hasPrefix("privacy.") }) { subscriber.putNext(()) }
        }
        subscriber.putNext(())
        return ActionDisposable { observation.cancel() }
    }
}

/// A viewer lease belongs to an account, never the currently selected global identity.
public final class ExteralessStoryPrivacySessions: @unchecked Sendable {
    public static let shared = ExteralessStoryPrivacySessions()
    private let lock = NSLock()
    private var sessions: [Int64: Set<UUID>] = [:]

    public func begin(accountId: Int64) -> Disposable {
        let token = UUID()
        lock.lock()
        sessions[accountId, default: []].insert(token)
        lock.unlock()
        return ActionDisposable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.sessions[accountId]?.remove(token)
            if self.sessions[accountId]?.isEmpty == true { self.sessions.removeValue(forKey: accountId) }
            self.lock.unlock()
        }
    }

    public func isActive(accountId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(sessions[accountId]?.isEmpty ?? true)
    }

    public func clear(accountId: Int64) {
        lock.lock()
        sessions.removeValue(forKey: accountId)
        lock.unlock()
    }
}
