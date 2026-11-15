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

    /// Decode original JSON bytes before any NSNumber/JSONSerialization pass.
    /// Integer-valued tokens must fit Int64. Fractional tokens must have the
    /// same decimal value as the Double's round-trip spelling; excess precision,
    /// overflow and underflow are rejected instead of silently changing data.
    public static func decodeJSON(_ data: Data) throws -> ClientSettingValue {
        guard data.count <= 8 * 1024 * 1024 else { throw ClientSettingsError.invalidJSON }
        var parser = ClientSettingJSONParser(bytes: Array(data))
        return try parser.parse()
    }

    public static func decodeJSON(_ text: String) throws -> ClientSettingValue {
        return try self.decodeJSON(Data(text.utf8))
    }

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 64 else {
            throw ClientSettingsError.invalidJSON
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            // Decimal is a range preflight, not the representation. It preserves
            // all 20 digits of the UInt64 / negative-Int64-overflow counterexamples
            // before a generic Decoder can round through Double. Raw boundaries
            // still use decodeJSON, since Decoder does not expose original bytes.
            if let decimal = try? container.decode(Decimal.self), !decimal.isNaN,
               decimal < Decimal(Int64.min) || decimal > Decimal(Int64.max) {
                throw ClientSettingsError.unsupportedNumber
            }
            if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                guard value.isFinite else { throw ClientSettingsError.nonFiniteNumber }
                guard value.rounded() != value else { throw ClientSettingsError.unsupportedNumber }
                self = .number(value)
            } else if let value = try? container.decode([ClientSettingValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: ClientSettingValue].self) {
                self = .object(value)
            } else {
                throw ClientSettingsError.invalidJSON
            }
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
            try Self.validateNumber(value)
            if let integer = Int64(exactly: value) {
                // JSONEncoder's shortest Double spelling can round a large
                // integral value's decimal digits. Encode its exact Int64 instead.
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
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
            try Self.validateNumber(value)
        case let .array(values):
            for value in values { try value.validateJSON(depth: depth + 1) }
        case let .object(values):
            for value in values.values { try value.validateJSON(depth: depth + 1) }
        default:
            break
        }
    }

    private static func validateNumber(_ value: Double) throws {
        guard value.isFinite else { throw ClientSettingsError.nonFiniteNumber }
        guard value.rounded() != value || Int64(exactly: value) != nil else {
            throw ClientSettingsError.unsupportedNumber
        }
    }

    /// CAS compares the JSON value on disk, not an encoder's choice of 1 vs 1.0.
    /// Exact conversion avoids equating Int64.max with a rounded Double. Unlike
    /// NSNumber equality, true and 1 remain different, including inside objects.
    func isSameJSONValue(as other: ClientSettingValue) -> Bool {
        switch (self, other) {
        case let (.integer(integer), .number(number)), let (.number(number), .integer(integer)):
            return Int64(exactly: number) == integer
        case let (.array(lhs), .array(rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in pair.0.isSameJSONValue(as: pair.1) }
        case let (.object(lhs), .object(rhs)):
            return lhs.count == rhs.count && lhs.allSatisfy { key, value in
                guard let other = rhs[key] else { return false }
                return value.isSameJSONValue(as: other)
            }
        default:
            return self == other
        }
    }
}

private struct ClientSettingJSONParser {
    let bytes: [UInt8]
    var index = 0

    mutating func parse() throws -> ClientSettingValue {
        let value = try self.value(depth: 0)
        self.whitespace()
        guard self.index == self.bytes.count else { throw ClientSettingsError.invalidJSON }
        return value
    }

    private mutating func value(depth: Int) throws -> ClientSettingValue {
        guard depth <= 64 else { throw ClientSettingsError.invalidJSON }
        self.whitespace()
        guard self.index < self.bytes.count else { throw ClientSettingsError.invalidJSON }
        switch self.bytes[self.index] {
        case 110: try self.literal("null"); return .null
        case 116: try self.literal("true"); return .bool(true)
        case 102: try self.literal("false"); return .bool(false)
        case 34: return .string(try self.string())
        case 91:
            self.index += 1
            self.whitespace()
            var values: [ClientSettingValue] = []
            if self.take(93) { return .array(values) }
            while true {
                values.append(try self.value(depth: depth + 1))
                self.whitespace()
                if self.take(93) { return .array(values) }
                guard self.take(44) else { throw ClientSettingsError.invalidJSON }
            }
        case 123:
            self.index += 1
            self.whitespace()
            var values: [String: ClientSettingValue] = [:]
            if self.take(125) { return .object(values) }
            while true {
                self.whitespace()
                let key = try self.string()
                self.whitespace()
                guard values[key] == nil, self.take(58) else { throw ClientSettingsError.invalidJSON }
                values[key] = try self.value(depth: depth + 1)
                self.whitespace()
                if self.take(125) { return .object(values) }
                guard self.take(44) else { throw ClientSettingsError.invalidJSON }
            }
        case 45, 48...57:
            return try self.number()
        default:
            throw ClientSettingsError.invalidJSON
        }
    }

    private mutating func string() throws -> String {
        let start = self.index
        guard self.take(34) else { throw ClientSettingsError.invalidJSON }
        while self.index < self.bytes.count {
            let byte = self.bytes[self.index]
            self.index += 1
            if byte == 34 {
                // Foundation sees only a string literal here, never a number.
                do { return try JSONDecoder().decode(String.self, from: Data(self.bytes[start..<self.index])) }
                catch { throw ClientSettingsError.invalidJSON }
            }
            guard byte >= 32 else { throw ClientSettingsError.invalidJSON }
            if byte == 92 {
                guard self.index < self.bytes.count else { throw ClientSettingsError.invalidJSON }
                self.index += 1
            }
        }
        throw ClientSettingsError.invalidJSON
    }

    private mutating func number() throws -> ClientSettingValue {
        let start = self.index
        _ = self.take(45)
        if !self.take(48) {
            guard self.index < self.bytes.count, (49...57).contains(self.bytes[self.index]) else {
                throw ClientSettingsError.invalidJSON
            }
            self.digits()
        }
        if self.take(46) {
            let fraction = self.index
            self.digits()
            guard self.index > fraction else { throw ClientSettingsError.invalidJSON }
        }
        if self.take(101) || self.take(69) {
            if !self.take(43) { _ = self.take(45) }
            let exponent = self.index
            self.digits()
            guard self.index > exponent else { throw ClientSettingsError.invalidJSON }
        }
        let token = String(decoding: self.bytes[start..<self.index], as: UTF8.self)
        let decimal = try ClientSettingJSONNumber(token)
        if decimal.digits == "0" { return .integer(0) }
        if decimal.scale >= 0 {
            guard decimal.digits.count + decimal.scale <= 19 else { throw ClientSettingsError.unsupportedNumber }
            let text = (decimal.negative ? "-" : "") + decimal.digits + String(repeating: "0", count: decimal.scale)
            guard let integer = Int64(text) else { throw ClientSettingsError.unsupportedNumber }
            return .integer(integer)
        }
        guard let number = Double(token), number.isFinite else {
            throw ClientSettingsError.unsupportedNumber
        }
        let canonical = try ClientSettingJSONNumber(String(number))
        guard canonical == decimal else {
            throw ClientSettingsError.unsupportedNumber
        }
        return .number(number)
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard self.take(byte) else { throw ClientSettingsError.invalidJSON }
        }
    }

    private mutating func digits() {
        while self.index < self.bytes.count && (48...57).contains(self.bytes[self.index]) { self.index += 1 }
    }

    private mutating func whitespace() {
        while self.index < self.bytes.count {
            switch self.bytes[self.index] {
            case 9, 10, 13, 32: self.index += 1
            default: return
            }
        }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard self.index < self.bytes.count, self.bytes[self.index] == byte else { return false }
        self.index += 1
        return true
    }
}

/// Canonical decimal digits × 10^scale. No floating-point conversion here.
private struct ClientSettingJSONNumber: Equatable {
    let negative: Bool
    let digits: String
    let scale: Int

    init(_ token: String) throws {
        let bytes = Array(token.utf8)
        let exponentIndex = bytes.firstIndex(where: { $0 == 101 || $0 == 69 }) ?? bytes.count
        let mantissa = bytes[..<exponentIndex]
        let fractionCount = mantissa.firstIndex(of: 46).map { exponentIndex - $0 - 1 } ?? 0
        let digits = mantissa.filter { (48...57).contains($0) }
        var first = 0
        var last = digits.count
        while first < last && digits[first] == 48 { first += 1 }
        if first == last {
            self.negative = false
            self.digits = "0"
            self.scale = 0
            return
        }
        let exponent: Int
        if exponentIndex < bytes.count {
            guard let parsed = Int(String(decoding: bytes[(exponentIndex + 1)...], as: UTF8.self)),
                  (-1_000_000...1_000_000).contains(parsed) else { throw ClientSettingsError.unsupportedNumber }
            exponent = parsed
        } else {
            exponent = 0
        }
        var scale = exponent - fractionCount
        while last > first && digits[last - 1] == 48 { last -= 1; scale += 1 }
        self.negative = bytes.first == 45
        self.digits = String(decoding: digits[first..<last], as: UTF8.self)
        self.scale = scale
    }
}
