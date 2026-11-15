import Foundation
import MtProtoKit
import Postbox
import SwiftSignalKit
internal import TelegramApi

public struct ExteralessTLServiceError: Error, Equatable, Sendable {
    public let code: Int32
    public let text: String

    public init(code: Int32, text: String) {
        self.code = code
        self.text = text
    }

    public static func local(_ reason: String) -> Self {
        return Self(code: -1, text: "EXTERALESS_" + reason)
    }

    public var value: ExteralessTLValue {
        return .object(["_": .string("error"), "code": .integer(Int64(self.code)), "text": .string(self.text)])
    }
}

private enum TLBridgeParsedResponse: TypeConstructorDescription {
    case value(ExteralessTLValue, Api.Updates?)
    case failure(ExteralessTLServiceError)

    func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
        // Network's BoxedMessage logger otherwise reflects enum associated values,
        // outside TelegramApi's field-redaction table. Log constructor names only.
        switch self {
        case let .value(value, _): return (value["_"]?.stringValue ?? "vector", [])
        case .failure: return ("error", [])
        }
    }
}

/// Uses the account's real cold Network.request Signal. Disposal cancels the native
/// request; no queue waits on Python, and a plugin request never changes account.
/// Raw RPC responses are returned as data, as in Android RequestDelegate. The
/// explicit applyUpdates option forwards intact native Updates to the state manager.
public func exteralessTLRequest(account: Account, request: ExteralessTLRequest,
                                automaticFloodWait: Bool = false,
                                applyUpdates: Bool = false, origin: ExteralessTLRequestOrigin? = nil,
                                isCancelled: @escaping @Sendable () -> Bool = { false }) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    guard !isCancelled() else { return .fail(.local("EXECUTION_REVOKED")) }
    let codec = ExteralessTLCodec.shared
    guard !applyUpdates || request.resultType == "Updates" else {
        return .fail(.local("APPLY_UPDATES_REQUIRES_UPDATES_RESULT"))
    }
    let parser = DeserializeFunctionResponse<TLBridgeParsedResponse> { buffer in
        do {
            let value = try codec.decode(buffer.makeData(), as: request.resultType)
            var updates: Api.Updates?
            if applyUpdates {
                let reader = BufferReader(buffer)
                guard let signature = reader.readInt32(), let parsed = Api.parse(reader, signature: signature) as? Api.Updates else {
                    return .failure(.local("NATIVE_UPDATES_PARSE_FAILED"))
                }
                updates = parsed
            }
            return .value(value, updates)
        } catch let error as ExteralessTLError {
            // Keep this a terminal parse failure. Returning nil here would let
            // transport verification/retry policy hide the named codec error.
            return .failure(.local("TL_PARSE_\(error.kind.rawValue): \(error.message)"))
        } catch {
            return .failure(.local("TL_PARSE_ERROR"))
        }
    }
    return exteralessTLPrepareDescriptor(network: account.network, request: request, account: account)
    |> mapToSignal { description -> Signal<TLBridgeParsedResponse, MTRpcError> in
        guard !isCancelled() else {
            let error: MTRpcError = MTRpcError(errorCode: -1, errorDescription: "EXTERALESS_EXECUTION_REVOKED")
            return .fail(error)
        }
        exteralessTLBindRequestExecution(network: account.network, description: description, permits: { !isCancelled() })
        exteralessTLBindRequestOrigin(origin, network: account.network, description: description)
        return account.network.request((description, Buffer(data: request.body), parser), automaticFloodWait: automaticFloodWait)
    }
    |> mapError { (error: MTRpcError) -> ExteralessTLServiceError in
        return ExteralessTLServiceError(code: error.errorCode, text: error.errorDescription ?? "RPC_ERROR")
    }
    |> mapToSignal { response -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        switch response {
        case let .value(value, updates):
            if let updates { account.stateManager.addUpdates(updates) }
            return .single(value)
        case let .failure(error): return .fail(error)
        }
    }
}

public struct ExteralessTLPeerReference: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user
        case group
        case channel
        case secret
    }

    public let kind: Kind
    public let id: Int64

    public init(kind: Kind, id: Int64) throws {
        guard id > 0, id <= 0x00ff_ffff_ffff_ffff else {
            throw ExteralessTLError(.malformed, "Peer id must be a positive raw Telegram id fitting 56 bits")
        }
        if kind == .secret, id > Int64(Int32.max) { throw ExteralessTLError(.malformed, "Secret chat id must fit positive Int32") }
        self.kind = kind
        self.id = id
    }

    var peerId: PeerId {
        let namespace: PeerId.Namespace
        switch self.kind {
        case .user: namespace = Namespaces.Peer.CloudUser
        case .group: namespace = Namespaces.Peer.CloudGroup
        case .channel: namespace = Namespaces.Peer.CloudChannel
        case .secret: namespace = Namespaces.Peer.SecretChat
        }
        return PeerId(namespace: namespace, id: ._internalFromInt64Value(self.id))
    }

    public var value: ExteralessTLValue {
        return .object(["type": .string(self.kind.rawValue), "id": .integer(self.id)])
    }
}

private func tlBridgeSnapshot<T: TLObjectBacked>(_ value: T, type: String) throws -> ExteralessTLValue {
    let buffer = Buffer()
    value.serialize(buffer, true)
    return try ExteralessTLCodec.shared.decode(buffer.makeData(), as: type)
}

/// Cache-only lookup. `cached` is deliberately partial: e.g. TelegramUser has no
/// bot_info_version, so reconstructing a purported complete Api.User would invent it.
public func exteralessTLGetPeer(account: Account, reference: ExteralessTLPeerReference,
                                isCancelled: @escaping @Sendable () -> Bool = { false }) -> Signal<ExteralessTLValue, ExteralessTLServiceError> {
    return account.postbox.transaction { transaction -> Result<ExteralessTLValue, ExteralessTLServiceError> in
        guard !isCancelled() else { return .failure(.local("EXECUTION_REVOKED")) }
        guard let peer = transaction.getPeer(reference.peerId) else {
            return .failure(.local("PEER_NOT_CACHED"))
        }
        do {
            var cached: [String: ExteralessTLValue] = ["id": .integer(reference.id)]
            let title: String
            switch peer {
            case let user as TelegramUser:
                title = user.nameOrPhone
                cached["first_name"] = user.firstName.map(ExteralessTLValue.string)
                cached["last_name"] = user.lastName.map(ExteralessTLValue.string)
                cached["username"] = user.username.map(ExteralessTLValue.string)
                cached["phone"] = user.phone.map(ExteralessTLValue.string)
                cached["access_hash"] = user.accessHash.map { .integer($0.value) }
                cached["self"] = .bool(user.id == account.peerId)
                cached["bot"] = .bool(user.botInfo != nil)
                cached["deleted"] = .bool(user.isDeleted)
                cached["verified"] = .bool(user.flags.contains(.isVerified))
                cached["premium"] = .bool(user.flags.contains(.isPremium))
                cached["support"] = .bool(user.flags.contains(.isSupport))
                cached["scam"] = .bool(user.flags.contains(.isScam))
                cached["fake"] = .bool(user.flags.contains(.isFake))
                cached["mutual_contact"] = .bool(user.flags.contains(.mutualContact))
            case let group as TelegramGroup:
                title = group.title
                cached["title"] = .string(group.title)
                cached["participants_count"] = .integer(Int64(group.participantCount))
                cached["date"] = .integer(Int64(group.creationDate))
                cached["version"] = .integer(Int64(group.version))
            case let channel as TelegramChannel:
                title = channel.title
                cached["title"] = .string(channel.title)
                cached["username"] = channel.username.map(ExteralessTLValue.string)
                cached["access_hash"] = channel.accessHash.map { .integer($0.value) }
                cached["date"] = .integer(Int64(channel.creationDate))
                cached["forum"] = .bool(channel.flags.contains(.isForum))
                cached["monoforum"] = .bool(channel.flags.contains(.isMonoforum))
                cached["creator"] = .bool(channel.flags.contains(.isCreator))
                switch channel.info {
                case .broadcast:
                    cached["broadcast"] = .bool(true)
                    cached["megagroup"] = .bool(false)
                case .group:
                    cached["broadcast"] = .bool(false)
                    cached["megagroup"] = .bool(true)
                }
            case let community as TelegramCommunity:
                title = community.title
                cached["title"] = .string(community.title)
                cached["access_hash"] = community.accessHash.map { .integer($0.value) }
                cached["date"] = .integer(Int64(community.creationDate))
            case let secret as TelegramSecretChat:
                title = (transaction.getPeer(secret.regularPeerId) as? TelegramUser)?.nameOrPhone ?? ""
                cached["regular_peer_id"] = .integer(secret.regularPeerId.toInt64())
                cached["date"] = .integer(Int64(secret.creationDate))
                cached["active"] = .bool(secret.embeddedState == .active)
            default:
                return .failure(.local("PEER_KIND_UNSUPPORTED"))
            }
            var result: [String: ExteralessTLValue] = ["peer": reference.value,
                "peerId": .integer(peer.id.toInt64()), "title": .string(title),
                "cached": .object(cached), "partial": .bool(true)]
            if let inputPeer = apiInputPeerOrSelf(peer, accountPeerId: account.peerId) {
                result["inputPeer"] = try tlBridgeSnapshot(inputPeer, type: "InputPeer")
            }
            if peer.id == account.peerId {
                result["inputUser"] = try tlBridgeSnapshot(Api.InputUser.inputUserSelf, type: "InputUser")
            } else if let inputUser = apiInputUser(peer) {
                result["inputUser"] = try tlBridgeSnapshot(inputUser, type: "InputUser")
            }
            if let inputChannel = apiInputChannel(peer) {
                result["inputChannel"] = try tlBridgeSnapshot(inputChannel, type: "InputChannel")
            }
            return .success(.object(result))
        } catch {
            return .failure(.local("PEER_TL_SCHEMA_MISMATCH"))
        }
    }
    |> castError(ExteralessTLServiceError.self)
    |> mapToSignal { result -> Signal<ExteralessTLValue, ExteralessTLServiceError> in
        switch result {
        case let .success(value): return .single(value)
        case let .failure(error): return .fail(error)
        }
    }
}

/// Decode an observational body without changing its processing/pts semantics.
/// The coordinator can attach this deep value to the existing observation DTO.
public func exteralessTLObservationValue(body: Data, requestBody: Bool, methodName: String? = nil,
                                         resultType: String? = nil) throws -> ExteralessTLValue {
    let codec = ExteralessTLCodec.shared
    if requestBody { return try codec.decodeRequest(body) }
    if let resultType { return try codec.decode(body, as: resultType) }
    if let methodName {
        return try codec.decodeMethodResponse(body, methodName: methodName)
    }
    return try codec.decodeBoxedObject(body)
}
