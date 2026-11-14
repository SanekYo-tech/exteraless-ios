import Foundation

/// A JSON value, without NSNumber's ambiguity between booleans and integers.
/// JSON integer tokens decode as Int64 when representable. A definition restores
/// its declared numeric kind when a JSON encoder writes an integral Double as 1.
public enum ClientSettingValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ClientSettingValue])
    case object([String: ClientSettingValue])

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 64 else {
            throw ClientSettingsError.invalidJSON
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else { throw ClientSettingsError.nonFiniteNumber }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClientSettingValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ClientSettingValue].self) {
            self = .object(value)
        } else {
            // Do not include the rejected payload in the error (it may be secret).
            throw ClientSettingsError.invalidJSON
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard encoder.codingPath.count <= 64 else {
            throw ClientSettingsError.invalidJSON
        }
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else { throw ClientSettingsError.nonFiniteNumber }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    /// Also checks nested values before a mutation reaches either storage backend.
    func validateJSON(depth: Int = 0) throws {
        guard depth <= 60 else { throw ClientSettingsError.invalidJSON }
        switch self {
        case let .number(value):
            guard value.isFinite else { throw ClientSettingsError.nonFiniteNumber }
        case let .array(values):
            for value in values { try value.validateJSON(depth: depth + 1) }
        case let .object(values):
            for value in values.values { try value.validateJSON(depth: depth + 1) }
        default:
            break
        }
    }
}
