import Foundation

/// Only Core's extension points. App lifecycle and settings stay in the UI host.
public enum PluginHookKind: UInt32, CaseIterable, Hashable, Sendable {
    case sendMessage = 1
    case preRequest = 2
    case postRequest = 4
    case update = 8
    case updates = 16
}

public struct PluginHookDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case invalidSendResult
        case unsupportedSendModification
        case sendTimedOut
        case sendHandlerDetached
        case observationQueueFull
        case observationKindMismatch
    }

    public let code: Code
    /// A schema/field explanation, never message text, TL bytes or credentials.
    public let detail: String
    public let accountRecordId: Int64?

    public init(code: Code, detail: String, accountRecordId: Int64? = nil) {
        self.code = code
        self.detail = detail
        self.accountRecordId = accountRecordId
    }
}

/// Postbox's packed peer ID, namespace and message ID. This is not an Android dialog ID.
public struct PluginHookMessageId: Codable, Equatable, Sendable {
    public let peerId: Int64
    public let namespace: Int32
    public let id: Int32

    public init(peerId: Int64, namespace: Int32, id: Int32) {
        self.peerId = peerId
        self.namespace = namespace
        self.id = id
    }
}

/// One member of an enqueue batch, before media transformation or a Postbox transaction.
/// All fields except text/silent/disableLinkPreviews are read-only in a MODIFY result.
public struct PluginSendPayload: Codable, Equatable, Sendable {
    var ingressLifetime = PluginHookPayloadLifetime()
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, accountRecordId, peerId, messageIndex, messageCount, kind, text, silent,
             disableLinkPreviews, canModifyText, hasMedia, hasTextEntities, hasInlineStickers, hasRichText,
             attributeTypes, threadId, replyToMessageId, hasReplyQuote, hasReplyInnerSubject, hasReplyToStory,
             localGroupingKey, correlationId, scheduleTime, scheduleRepeatPeriod, forwardSource
    }
    public enum Kind: String, Codable, Sendable {
        case message
        case forward
    }

    public let schemaVersion: Int
    /// AccountRecordId.int64, never an Int32 account index or a Telegram user ID.
    public let accountRecordId: Int64
    /// PeerId.toInt64(), including its namespace.
    public let peerId: Int64
    public let messageIndex: Int
    public let messageCount: Int
    public let kind: Kind
    public let text: String?
    public let silent: Bool
    public let disableLinkPreviews: Bool
    public let canModifyText: Bool
    public let hasMedia: Bool
    public let hasTextEntities: Bool
    public let hasInlineStickers: Bool
    public let hasRichText: Bool
    public let attributeTypes: [String]
    public let threadId: Int64?
    public let replyToMessageId: PluginHookMessageId?
    public let hasReplyQuote: Bool
    public let hasReplyInnerSubject: Bool
    public let hasReplyToStory: Bool
    public let localGroupingKey: Int64?
    public let correlationId: Int64?
    public let scheduleTime: Int32?
    public let scheduleRepeatPeriod: Int32?
    public let forwardSource: PluginHookMessageId?

    public init(
        accountRecordId: Int64,
        peerId: Int64,
        messageIndex: Int = 0,
        messageCount: Int = 1,
        kind: Kind = .message,
        text: String? = nil,
        silent: Bool = false,
        disableLinkPreviews: Bool = false,
        canModifyText: Bool = false,
        hasMedia: Bool = false,
        hasTextEntities: Bool = false,
        hasInlineStickers: Bool = false,
        hasRichText: Bool = false,
        attributeTypes: [String] = [],
        threadId: Int64? = nil,
        replyToMessageId: PluginHookMessageId? = nil,
        hasReplyQuote: Bool = false,
        hasReplyInnerSubject: Bool = false,
        hasReplyToStory: Bool = false,
        localGroupingKey: Int64? = nil,
        correlationId: Int64? = nil,
        scheduleTime: Int32? = nil,
        scheduleRepeatPeriod: Int32? = nil,
        forwardSource: PluginHookMessageId? = nil
    ) {
        self.schemaVersion = 1
        self.accountRecordId = accountRecordId
        self.peerId = peerId
        self.messageIndex = messageIndex
        self.messageCount = messageCount
        self.kind = kind
        self.text = text
        self.silent = silent
        self.disableLinkPreviews = disableLinkPreviews
        self.canModifyText = canModifyText
        self.hasMedia = hasMedia
        self.hasTextEntities = hasTextEntities
        self.hasInlineStickers = hasInlineStickers
        self.hasRichText = hasRichText
        self.attributeTypes = attributeTypes
        self.threadId = threadId
        self.replyToMessageId = replyToMessageId
        self.hasReplyQuote = hasReplyQuote
        self.hasReplyInnerSubject = hasReplyInnerSubject
        self.hasReplyToStory = hasReplyToStory
        self.localGroupingKey = localGroupingKey
        self.correlationId = correlationId
        self.scheduleTime = scheduleTime
        self.scheduleRepeatPeriod = scheduleRepeatPeriod
        self.forwardSource = forwardSource
    }

    public func jsonString() throws -> String {
        if let credit = ingressLifetime.credit {
            // Reserve before JSONEncoder allocates (a control byte may expand to
            // six JSON bytes). Fixed metadata and per-name punctuation are bounded.
            var upperBound = 2048 + (text?.utf8.count ?? 0) * 6
            for name in attributeTypes {
                guard upperBound <= 16 * 1024 * 1024, name.utf8.count <= (16 * 1024 * 1024 - upperBound) / 6 else {
                    throw PluginHookIngressError.queueFull
                }
                upperBound += name.utf8.count * 6 + 3
            }
            guard credit.reserveDeliveryBytes(upperBound) else { throw PluginHookIngressError.queueFull }
        }
        let value = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        return value
    }
}

/// A sparse patch, applied to the original EnqueueMessage rather than reconstructing it from JSON.
public struct PluginSendMessagePatch: Equatable, Sendable {
    public let text: String?
    public let silent: Bool?
    public let disableLinkPreviews: Bool?

    public init(text: String? = nil, silent: Bool? = nil, disableLinkPreviews: Bool? = nil) {
        self.text = text
        self.silent = silent
        self.disableLinkPreviews = disableLinkPreviews
    }
}

public enum PluginSendResult: Equatable, Sendable {
    case keepOriginal
    case cancel
    case modify(PluginSendMessagePatch)
    /// The host has already stopped its plugin chain; Core applies the same patch as MODIFY.
    case modifyFinal(PluginSendMessagePatch)
}

public enum PluginTLBytesEncoding: String, Codable, Sendable {
    /// The exact existing API-function Buffer used to submit the request, without MTProto framing.
    case requestBody
    /// The exact API-response body handed to the existing parser, after MTProto/gzip unwrapping.
    case responseBody
    /// Re-serialized with TelegramApi.serialize(buffer, true), not the original transport packet.
    case boxedTL
    /// E.g. a generic primitive/vector response for which this site has no boxed-object codec.
    case unavailable
}

public struct PluginRequestMetadata: Codable, Equatable, Sendable {
    public let accountRecordId: Int64
    /// Generated only when a request hook is enabled; correlates pre/post for this subscription.
    public let requestId: String
    public let requestName: String
    public let datacenterId: Int
    public let automaticFloodWait: Bool
    public let usesAdditionalInfo: Bool

    public init(accountRecordId: Int64, requestId: String, requestName: String, datacenterId: Int, automaticFloodWait: Bool, usesAdditionalInfo: Bool) {
        self.accountRecordId = accountRecordId
        self.requestId = requestId
        self.requestName = requestName
        self.datacenterId = datacenterId
        self.automaticFloodWait = automaticFloodWait
        self.usesAdditionalInfo = usesAdditionalInfo
    }
}

public struct PluginRPCResponseMetadata: Codable, Equatable, Sendable {
    public let timestamp: Double
    public let duration: Double
    public let networkType: Int32

    public init(timestamp: Double, duration: Double, networkType: Int32) {
        self.timestamp = timestamp
        self.duration = duration
        self.networkType = networkType
    }
}

public struct PluginRPCError: Codable, Equatable, Sendable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
}

/// Observation only: no result channel exists for replacing/cancelling an RPC or its response.
public struct PluginRequestObservation: Codable, Equatable, Sendable {
    var ingressLifetime = PluginHookPayloadLifetime()
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, observational, phase, metadata, serializedTLBytes, tlBytesEncoding,
             responseTypeName, response, error
    }
    public enum Phase: String, Codable, Sendable {
        case beforeSubmission
        case completed
    }

    public let schemaVersion: Int
    public let observational: Bool
    public let phase: Phase
    public let metadata: PluginRequestMetadata
    public let serializedTLBytes: Data?
    public let tlBytesEncoding: PluginTLBytesEncoding
    public let responseTypeName: String?
    public let response: PluginRPCResponseMetadata?
    public let error: PluginRPCError?

    public init(phase: Phase, metadata: PluginRequestMetadata, serializedTLBytes: Data? = nil, tlBytesEncoding: PluginTLBytesEncoding = .unavailable, responseTypeName: String? = nil, response: PluginRPCResponseMetadata? = nil, error: PluginRPCError? = nil) {
        self.schemaVersion = 1
        self.observational = true
        self.phase = phase
        self.metadata = metadata
        self.serializedTLBytes = serializedTLBytes
        self.tlBytesEncoding = tlBytesEncoding
        self.responseTypeName = responseTypeName
        self.response = response
        self.error = error
    }
}

/// An immutable TL snapshot; the callback may run after Core has advanced/committed its state.
public struct PluginUpdateObservation: Codable, Equatable, Sendable {
    var ingressLifetime = PluginHookPayloadLifetime()
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, observational, accountRecordId, name, source, stage, serializedTLBytes,
             tlBytesEncoding, batchIndex, batchCount
    }
    public enum Source: String, Codable, Sendable {
        case incomingContainer
        case difference
        case acceptedUpdateBatch
    }

    public enum Stage: String, Codable, Sendable {
        case beforeGrouping
        case beforeDifferenceApplication
        case beforeUpdateApplication
    }

    public let schemaVersion: Int
    public let observational: Bool
    public let accountRecordId: Int64
    /// TelegramApi's schema constructor name, not a hash or a debug description of fields.
    public let name: String
    public let source: Source
    public let stage: Stage
    public let serializedTLBytes: Data
    public let tlBytesEncoding: PluginTLBytesEncoding
    public let batchIndex: Int?
    public let batchCount: Int?

    public init(accountRecordId: Int64, name: String, source: Source, stage: Stage, serializedTLBytes: Data, batchIndex: Int? = nil, batchCount: Int? = nil) {
        self.schemaVersion = 1
        self.observational = true
        self.accountRecordId = accountRecordId
        self.name = name
        self.source = source
        self.stage = stage
        self.serializedTLBytes = serializedTLBytes
        self.tlBytesEncoding = .boxedTL
        self.batchIndex = batchIndex
        self.batchCount = batchCount
    }
}

public enum PluginHookObservation: Equatable, Sendable {
    case preRequest(PluginRequestObservation)
    case postRequest(PluginRequestObservation)
    case update(PluginUpdateObservation)
    case updates(PluginUpdateObservation)

    public var kind: PluginHookKind {
        switch self {
        case .preRequest: return .preRequest
        case .postRequest: return .postRequest
        case .update: return .update
        case .updates: return .updates
        }
    }

    /// Claim the encoded payload before retaining it in a MainActor/other Task.
    /// Exactly one delivery claim per observation. The event copy carries credit.
    public func reserveDeliveryBytes(_ bytes: Int) -> Bool {
        switch self {
        case .preRequest(let value), .postRequest(let value):
            return value.ingressLifetime.credit?.reserveDeliveryBytes(bytes) ?? false
        case .update(let value), .updates(let value):
            return value.ingressLifetime.credit?.reserveDeliveryBytes(bytes) ?? false
        }
    }

    func retaining(_ credit: PluginHookIngressCredit) -> PluginHookObservation? {
        switch self {
        case .preRequest(var value), .postRequest(var value):
            let bytes = (value.serializedTLBytes?.count ?? 0) + value.metadata.requestId.utf8.count
                + value.metadata.requestName.utf8.count + (value.responseTypeName?.utf8.count ?? 0)
                + (value.error?.message.utf8.count ?? 0)
            guard credit.addRawBytes(bytes) else { return nil }
            value.ingressLifetime.credit = credit
            return kind == .preRequest ? .preRequest(value) : .postRequest(value)
        case .update(var value), .updates(var value):
            guard credit.addRawBytes(value.serializedTLBytes.count + value.name.utf8.count) else { return nil }
            value.ingressLifetime.credit = credit
            return kind == .update ? .update(value) : .updates(value)
        }
    }

    /// Encodes the associated payload directly. Data is RFC 4648 base64; Int64 stays an integer.
    public func jsonString() throws -> String {
        let data: Data
        switch self {
        case let .preRequest(value), let .postRequest(value):
            data = try JSONEncoder().encode(value)
        case let .update(value), let .updates(value):
            data = try JSONEncoder().encode(value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
