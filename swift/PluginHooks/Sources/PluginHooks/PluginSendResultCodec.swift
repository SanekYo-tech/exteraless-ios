import Foundation

public enum PluginSendCodecError: Error, Equatable, CustomStringConvertible {
    case malformedResult
    case unknownStrategy
    case missingParams
    case unsupportedField(String)
    case readOnlyField(String)
    case invalidFieldType(String)
    case textModificationUnavailable
    case emptyText
    case forwardModificationUnavailable

    public var description: String {
        switch self {
        case .malformedResult: return "Expected a JSON object containing strategy and optional params"
        case .unknownStrategy: return "Unknown send strategy"
        case .missingParams: return "MODIFY requires a params object"
        case let .unsupportedField(field): return "Unsupported send field: \(field.prefix(80))"
        case let .readOnlyField(field): return "Read-only send field changed: \(field)"
        case let .invalidFieldType(field): return "Invalid send field type: \(field)"
        case .textModificationUnavailable: return "Text replacement needs plain text without media, entities, rich text or opaque attributes"
        case .emptyText: return "A plain-text replacement cannot be empty"
        case .forwardModificationUnavailable: return "Forward parameters cannot be modified by this codec"
        }
    }
}

/// Strict send-message adapter. A full echoed snapshot or a sparse params object is accepted.
/// Unknown keys and changes to read-only data fail as a whole; no entity list is ever discarded.
public enum PluginSendResultCodec {
    public static func decode(_ json: String, original: PluginSendPayload) throws -> PluginSendResult {
        let value: SendJSONValue
        do {
            value = try JSONDecoder().decode(SendJSONValue.self, from: Data(json.utf8))
        } catch {
            throw PluginSendCodecError.malformedResult
        }
        guard case let .object(envelope) = value,
              case let .string(strategy)? = envelope["strategy"] else {
            throw PluginSendCodecError.malformedResult
        }
        for key in envelope.keys where key != "strategy" && key != "params" {
            throw PluginSendCodecError.unsupportedField(key)
        }
        switch strategy {
        case "DEFAULT":
            return .keepOriginal
        case "CANCEL":
            return .cancel
        case "MODIFY", "MODIFY_FINAL":
            guard case let .object(params)? = envelope["params"] else {
                throw PluginSendCodecError.missingParams
            }
            let originalValue = try JSONDecoder().decode(SendJSONValue.self, from: JSONEncoder().encode(original))
            guard case let .object(originalFields) = originalValue else {
                throw PluginSendCodecError.malformedResult
            }
            let readOnlyFields: Set<String> = [
                "schemaVersion", "accountRecordId", "peerId", "messageIndex", "messageCount",
                "kind", "canModifyText", "hasMedia", "hasTextEntities", "hasInlineStickers",
                "hasRichText", "attributeTypes", "threadId", "replyToMessageId", "hasReplyQuote",
                "hasReplyInnerSubject", "hasReplyToStory", "localGroupingKey", "correlationId",
                "scheduleTime", "scheduleRepeatPeriod", "forwardSource",
            ]
            var text: String?
            var silent: Bool?
            var disableLinkPreviews: Bool?
            for (key, value) in params {
                switch key {
                case "text":
                    if value == (originalFields[key] ?? .null) {
                        continue
                    }
                    guard case let .string(newText) = value else {
                        throw PluginSendCodecError.invalidFieldType(key)
                    }
                    text = newText
                case "silent":
                    guard case let .bool(newValue) = value else {
                        throw PluginSendCodecError.invalidFieldType(key)
                    }
                    if newValue != original.silent {
                        silent = newValue
                    }
                case "disableLinkPreviews":
                    guard case let .bool(newValue) = value else {
                        throw PluginSendCodecError.invalidFieldType(key)
                    }
                    if newValue != original.disableLinkPreviews {
                        disableLinkPreviews = newValue
                    }
                default:
                    guard readOnlyFields.contains(key) else {
                        throw PluginSendCodecError.unsupportedField(key)
                    }
                    guard value == (originalFields[key] ?? .null) else {
                        throw PluginSendCodecError.readOnlyField(key)
                    }
                }
            }
            let patch = PluginSendMessagePatch(text: text, silent: silent, disableLinkPreviews: disableLinkPreviews)
            try validate(patch, original: original)
            return strategy == "MODIFY_FINAL" ? .modifyFinal(patch) : .modify(patch)
        default:
            throw PluginSendCodecError.unknownStrategy
        }
    }

    /// Host convenience: fail open with a diagnostic, never lose the original EnqueueMessage.
    public static func decodeOrKeepOriginal(_ json: String, original: PluginSendPayload) -> PluginSendResult {
        do {
            return try decode(json, original: original)
        } catch {
            PluginHookRouter.reportDiagnostic(PluginHookDiagnostic(
                code: .invalidSendResult,
                detail: (error as? PluginSendCodecError)?.description ?? "Invalid send result",
                accountRecordId: original.accountRecordId
            ))
            return .keepOriginal
        }
    }

    /// Also used by the router for typed handlers that bypass JSON decoding.
    public static func validate(_ patch: PluginSendMessagePatch, original: PluginSendPayload) throws {
        if let text = patch.text, text != original.text {
            guard original.kind == .message && original.canModifyText && !original.hasMedia && !original.hasTextEntities && !original.hasInlineStickers && !original.hasRichText else {
                throw PluginSendCodecError.textModificationUnavailable
            }
            guard !text.isEmpty else {
                throw PluginSendCodecError.emptyText
            }
        }
        if original.kind == .forward {
            if let silent = patch.silent, silent != original.silent {
                throw PluginSendCodecError.forwardModificationUnavailable
            }
            if let disableLinkPreviews = patch.disableLinkPreviews, disableLinkPreviews != original.disableLinkPreviews {
                throw PluginSendCodecError.forwardModificationUnavailable
            }
        }
    }
}

/// The send schema has integral numbers only. In particular, never round Int64 identity via Double
/// or compare NSNumber booleans and integers as if they were interchangeable.
private enum SendJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([SendJSONValue])
    case object([String: SendJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SendJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SendJSONValue].self))
        }
    }
}
