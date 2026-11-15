import ExteralessCore
import Foundation
import MtProtoKit
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// The original Mini App cloud storage protocol, on one captured account network.
/// This never sends a message/document, opens a WebView, uses a bot token, or reads
/// an unrelated chat/document. The bot's immutable ID is verified after resolution.
public final class ExteralessCloudTransport: CloudKeyValueTransport, @unchecked Sendable {
    public let scope: CloudAccountScope
    private let account: Account

    public init(account: Account) {
        self.account = account
        self.scope = CloudAccountScope(recordId: account.id.int64, userId: account.peerId.id._internalGetInt64Value(),
            environment: account.testingEnvironment ? .test : .production)
    }

    public static var compression: CloudCompression {
        CloudCompression(compress: { data in
            guard data.count <= CloudProtocol.maximumPayloadBytes, let compressed = MTGzip.compress(data) else { throw CloudError.sizeLimit }
            return compressed
        }, decompress: { data, limit in
            guard let maximumLength = UInt(exactly: limit), let result = MTGzip.decompress(data, maxOutputLength: maximumLength) else { throw CloudError.malformedRemote }
            return result
        })
    }

    public func keys() async throws -> [String] {
        try await storage.keys()
    }

    public func get(_ keys: [String]) async throws -> [String: String] {
        try await storage.get(keys)
    }

    public func set(key: String, value: String) async throws {
        try await storage.set(key: key, value: value)
    }

    public func remove(_ keys: [String]) async throws {
        try await storage.remove(keys)
    }

    private var storage: CloudBotStorageTransport {
        CloudBotStorageTransport { [self] method, params in try await invoke(method: method, params: params) }
    }

    private func invoke(method: String, params: Data) async throws -> Data {
        guard scope.owner.environment == .production else { throw CloudError.unsupportedEnvironment }
        try Task.checkCancellation()
        guard params.count <= 32_768 else { throw CloudError.sizeLimit }
        let account = self.account
        let request = inputBot() |> mapToSignal { inputBot -> Signal<String, CloudError> in
            let data = Api.functions.bots.invokeWebViewCustomMethod(bot: inputBot, customMethod: method,
                params: .dataJSON(.init(data: String(decoding: params, as: UTF8.self))))
            return exteralessCloudPrivateRequest(network: account.network, data: data)
        }
        let raw = try await exteralessCloudFirst(request)
        guard raw.utf8.count <= CloudProtocol.maximumReplyBytes else { throw CloudError.sizeLimit }
        return Data(raw.utf8)
    }

    private func inputBot() -> Signal<Api.InputUser, CloudError> {
        let account = self.account
        let botId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(CloudProtocol.botId))
        func cached() -> Signal<Api.InputUser?, NoError> {
            account.postbox.transaction { transaction -> Api.InputUser? in
                guard let user = transaction.getPeer(botId) as? TelegramUser, user.botInfo != nil else { return nil }
                return apiInputUser(user)
            }
        }
        return cached() |> castError(CloudError.self) |> mapToSignal { user -> Signal<Api.InputUser, CloudError> in
            if let user { return .single(user) }
            return _internal_resolvePeerByName(account: account, name: CloudProtocol.botName, referrer: nil, ageLimit: 0)
            |> castError(CloudError.self)
            |> mapToSignal { result -> Signal<Api.InputUser, CloudError> in
                switch result {
                case .progress: return .complete()
                case let .result(id):
                    guard id == botId else { return .fail(.botUnavailable) }
                    return cached() |> castError(CloudError.self) |> mapToSignal { user in
                        guard let user else { return .fail(.botUnavailable) }
                        return .single(user)
                    }
                }
            }
            |> take(1)
        }
    }

}

private final class ExteralessCloudReply: CustomStringConvertible, CustomReflectable {
    let value: String
    init(_ value: String) { self.value = value }
    var description: String { "Cloud storage reply (redacted)" }
    var customMirror: Mirror { Mirror(self, children: ["reply": "redacted"]) }
}

/// Credential-bearing cloud values bypass the generic plugin request/response
/// snapshots. Use the SAME account request service/MTProto engine, but name-only
/// metadata and a redacted reply wrapper even when verbose network logging is on.
private func exteralessCloudPrivateRequest(network: Network,
    data: (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.DataJSON>)) -> Signal<String, CloudError> {
    let service = network.requestService
    return Signal { [weak network, service] subscriber in
        guard network != nil else { subscriber.putError(.contextClosed); return EmptyDisposable }
        let request = NetworkEngineRequest(payload: data.1.makeData(), name: "bots.invokeWebViewCustomMethod", parse: { bytes in
            guard bytes.count <= CloudProtocol.maximumReplyBytes + 16,
                  let response = data.2.parse(Buffer(data: bytes)), case let .dataJSON(value) = response,
                  value.data.utf8.count <= CloudProtocol.maximumReplyBytes else { return nil }
            return ExteralessCloudReply(value.data)
        }, shouldContinueAfterError: { _ in false }, completed: { result in
            switch result {
            case let .success(response):
                guard let reply = response.result as? ExteralessCloudReply else { subscriber.putError(.malformedRemote); return }
                subscriber.putNext(reply.value)
                subscriber.putCompletion()
            case .failure:
                // Server strings can echo submitted values. Do not propagate them.
                subscriber.putError(.network)
            }
        })
        return service.add(request)
    }
}
