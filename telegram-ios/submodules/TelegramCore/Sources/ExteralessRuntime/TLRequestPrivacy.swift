import Foundation
import MtProtoKit
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// Privacy-only, checked metadata. No access hash, message text or TL body is kept
/// in FunctionDescription.parameters (the logger reads those parameters).
struct ExteralessTLPrivacyMetadata {
    let peerIds: [PeerId]
    let allPeersResolved: Bool
    let incrementViews: Bool?
    let requestsOnline: Bool?
    var outgoingPeerId: PeerId? { self.peerIds.count == 1 ? self.peerIds.first : nil }
}

private final class TLPrivacyDescriptorStore: @unchecked Sendable {
    static let shared = TLPrivacyDescriptorStore()
    private final class Entry {
        weak var description: FunctionDescription?
        weak var network: Network?
        let value: ExteralessTLPrivacyMetadata
        init(_ description: FunctionDescription, network: Network, value: ExteralessTLPrivacyMetadata) {
            self.description = description
            self.network = network
            self.value = value
        }
    }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func put(_ description: FunctionDescription, network: Network, value: ExteralessTLPrivacyMetadata) {
        self.lock.lock()
        self.entries = self.entries.filter { $0.value.description != nil && $0.value.network != nil }
        self.entries[ObjectIdentifier(description)] = Entry(description, network: network, value: value)
        self.lock.unlock()
    }

    func get(_ description: FunctionDescription, network: Network) -> ExteralessTLPrivacyMetadata? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.entries[ObjectIdentifier(description)], entry.description === description, entry.network === network else { return nil }
        return entry.value
    }
}

private final class TLAccountLease: Disposable, @unchecked Sendable {
    private let lock = NSLock()
    private weak var account: Account?
    private weak var network: Network?
    private var disposed = false
    init(_ account: Account) { self.account = account; self.network = account.network }
    func get() -> Account? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.disposed ? nil : self.account
    }
    func dispose() {
        self.lock.lock()
        let network = self.disposed ? nil : self.network
        self.disposed = true
        self.account = nil
        self.network = nil
        self.lock.unlock()
        if let network { TLAccountStore.shared.retire(self, network: network) }
    }
}

private final class TLAccountStore: @unchecked Sendable {
    static let shared = TLAccountStore()
    private final class Entry {
        weak var network: Network?
        let lease: TLAccountLease
        init(_ network: Network, lease: TLAccountLease) { self.network = network; self.lease = lease }
    }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func install(_ account: Account) -> Disposable {
        let lease = TLAccountLease(account)
        self.lock.lock()
        self.entries = self.entries.filter { $0.value.network != nil }
        let old = self.entries.updateValue(Entry(account.network, lease: lease), forKey: ObjectIdentifier(account.network))
        self.lock.unlock()
        old?.lease.dispose()
        return lease
    }

    func entry(_ network: Network) -> (registered: Bool, account: Account?) {
        self.lock.lock()
        let entry = self.entries[ObjectIdentifier(network)]
        self.lock.unlock()
        guard let entry, entry.network === network else { return (false, nil) }
        return (true, entry.lease.get())
    }

    func retire(_ lease: TLAccountLease, network: Network) {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.entries[ObjectIdentifier(network)], entry.network === network, entry.lease === lease else { return }
        exteralessTLRetireRequestOrigins(network: network)
    }
}

/// Install beside exteralessInstallPrivacyAccount in Account.managedOperations.
/// A retired account remains distinguishable from an unregistered login Network.
func exteralessInstallTLAccount(account: Account) -> Disposable {
    return TLAccountStore.shared.install(account)
}

func exteralessTLAccountIsCurrent(_ network: Network) -> Bool {
    let entry = TLAccountStore.shared.entry(network)
    return !entry.registered || entry.account != nil
}

func exteralessTLRegisteredAccount(_ network: Network) -> Account? {
    return TLAccountStore.shared.entry(network).account
}

func exteralessTLPrivacyMetadata(network: Network, description: FunctionDescription) -> ExteralessTLPrivacyMetadata? {
    return TLPrivacyDescriptorStore.shared.get(description, network: network)
}

private func tlPrivacyBool(_ value: ExteralessTLValue?) -> Bool? {
    if case let .bool(value)? = value { return value }
    switch value?["_"]?.stringValue {
    case "boolTrue": return true
    case "boolFalse": return false
    default: return nil
    }
}

func tlPrivacyPeer(_ value: ExteralessTLValue?, account: Account?) throws -> PeerId? {
    guard let name = value?["_"]?.stringValue else { return nil }
    let namespace: PeerId.Namespace
    let id: Int64?
    switch name {
    case "inputPeerSelf", "inputUserSelf": return account?.peerId
    case "inputPeerUser", "inputPeerUserFromMessage", "inputUser", "inputUserFromMessage", "peerUser":
        namespace = Namespaces.Peer.CloudUser; id = value?["user_id"]?.integerValue
    case "inputPeerChat", "peerChat":
        namespace = Namespaces.Peer.CloudGroup; id = value?["chat_id"]?.integerValue
    case "inputPeerChannel", "inputPeerChannelFromMessage", "inputChannel", "inputChannelFromMessage", "peerChannel":
        namespace = Namespaces.Peer.CloudChannel; id = value?["channel_id"]?.integerValue
    case "inputEncryptedChat":
        namespace = Namespaces.Peer.SecretChat; id = value?["chat_id"]?.integerValue
    default: return nil
    }
    guard let id, id > 0, id <= 0x00ff_ffff_ffff_ffff else { throw ExteralessTLError(.malformed, "Invalid privacy peer reference") }
    return PeerId(namespace: namespace, id: ._internalFromInt64Value(id))
}

/// A checked factory extension on the Core side of TelegramApi. It validates the
/// final wire bytes and derives privacy-only fields from THEM, not a caller claim.
/// Reuse the original descriptor only for byte-identical requests: an explicit
/// read exemption keyed by descriptor identity cannot migrate to modified params.
func exteralessTLPrepareDescriptor(network: Network, request: ExteralessTLRequest,
                                   preserving original: FunctionDescription? = nil,
                                   account suppliedAccount: Account? = nil) -> Signal<FunctionDescription, MTRpcError> {
    do {
        let codec = ExteralessTLCodec.shared
        let value = try codec.decodeRequest(request.body)
        guard value["_"]?.stringValue == request.methodName else { throw ExteralessTLError(.schema, "Request method/body mismatch") }
        try ExteralessTLTransformCodec.validateNativeValues(value)
        guard let checked = tlBridgeFunctionDescription(name: request.methodName, expectedSchemaHash: codec.nativeLayoutHash) else {
            throw ExteralessTLError(.schema, "TL schema differs from native build")
        }
        let description = original ?? checked
        guard description.name == request.methodName else { throw ExteralessTLError(.schema, "Descriptor method/body mismatch") }
        let entry = TLAccountStore.shared.entry(network)
        let account = suppliedAccount ?? entry.account
        guard !entry.registered || entry.account != nil else {
            let error: MTRpcError = MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED")
            return .fail(error)
        }
        let target = value["to_peer"] ?? value["peer"] ?? value["channel"]
        let peerId = try tlPrivacyPeer(target, account: account)
        let increment = tlPrivacyBool(value["increment"])
        let online = tlPrivacyBool(value["offline"]).map { !$0 }
        let finish: ([PeerId], Bool) -> FunctionDescription = { peerIds, resolved in
            TLPrivacyDescriptorStore.shared.put(description, network: network, value: ExteralessTLPrivacyMetadata(
                peerIds: peerIds, allPeersResolved: resolved, incrementViews: increment, requestsOnline: online))
            return description
        }
        if request.methodName == "messages.readMessageContents", case let .array(values)? = value["id"] {
            let ids = values.compactMap { $0.integerValue.flatMap(Int32.init(exactly:)) }
            guard ids.count == values.count, ids.count <= 10_000 else { throw ExteralessTLError(.limit, "Read-contents privacy lookup exceeds 10000 ids") }
            guard let account else { return .single(finish([], false)) }
            return account.postbox.transaction { transaction -> FunctionDescription in
                let resolved = transaction.messageIdsForGlobalIds(ids)
                let requestedIds = Set(ids)
                let resolvedIds = Set(resolved.map(\.id))
                let peers = Array(Set(resolved.map(\.peerId))).sorted()
                return finish(peers, requestedIds == resolvedIds)
            }
            |> castError(MTRpcError.self)
        }
        return .single(finish(peerId.map { [$0] } ?? [], target == nil || peerId != nil))
    } catch let error as ExteralessTLError {
        let error: MTRpcError = MTRpcError(errorCode: 400, errorDescription: "EXTERALESS_TL_PRIVACY_\(error.kind.rawValue)")
        return .fail(error)
    } catch {
        let error: MTRpcError = MTRpcError(errorCode: 400, errorDescription: "EXTERALESS_TL_PRIVACY_INVALID")
        return .fail(error)
    }
}
