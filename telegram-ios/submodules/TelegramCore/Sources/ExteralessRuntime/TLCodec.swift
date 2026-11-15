import CoreFoundation
import Foundation

/// Errors describe the rejected schema path, never the contents of a TL byte/string field.
public struct ExteralessTLError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case malformed = "MalformedRequest"
        case unsupported = "Unimplemented"
        case limit = "ResourceLimit"
        case schema = "TLSchemaMismatch"
    }

    public let kind: Kind
    public let message: String
    public var description: String { self.message }

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// A deep value snapshot. It carries neither TelegramApi objects nor Python/JVM handles.
public indirect enum ExteralessTLValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case bytes(Data)
    case array([ExteralessTLValue])
    case object([String: ExteralessTLValue])

    public init(jsonObject: Any) throws {
        var remaining = ExteralessTLCodec.maximumValues
        self = try Self.readJSON(jsonObject, depth: 0, remaining: &remaining)
    }

    private static func readJSON(_ value: Any, depth: Int, remaining: inout Int) throws -> Self {
        guard depth <= ExteralessTLCodec.maximumDepth, remaining > 0 else {
            throw ExteralessTLError(.limit, "TL JSON nesting/value limit exceeded")
        }
        remaining -= 1
        if value is NSNull {
            return .null
        } else if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let encoding = String(cString: number.objCType)
            if encoding == "f" || encoding == "d" {
                guard number.doubleValue.isFinite else {
                    throw ExteralessTLError(.malformed, "TL double must be finite")
                }
                return .double(number.doubleValue)
            }
            guard let integer = Int64(number.stringValue) else {
                throw ExteralessTLError(.malformed, "TL integer does not fit Int64")
            }
            return .integer(integer)
        } else if let string = value as? String {
            guard string.utf8.count <= ExteralessTLCodec.maximumFieldBytes else {
                throw ExteralessTLError(.limit, "TL string limit exceeded")
            }
            return .string(string)
        } else if let array = value as? [Any] {
            guard array.count <= ExteralessTLCodec.maximumVectorCount else {
                throw ExteralessTLError(.limit, "TL vector limit exceeded")
            }
            return .array(try array.map { try Self.readJSON($0, depth: depth + 1, remaining: &remaining) })
        } else if let object = value as? [String: Any] {
            if Set(object.keys) == ["__bytes__"] {
                guard let encoded = object["__bytes__"] as? String,
                      encoded.utf8.count <= ((ExteralessTLCodec.maximumFieldBytes + 2) / 3) * 4,
                      let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded,
                      data.count <= ExteralessTLCodec.maximumFieldBytes else {
                    throw ExteralessTLError(.malformed, "TL bytes require bounded canonical base64")
                }
                return .bytes(data)
            }
            guard object.count <= 256, object.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw ExteralessTLError(.limit, "TL object field limit exceeded")
            }
            var result: [String: ExteralessTLValue] = [:]
            for (key, item) in object {
                result[key] = try Self.readJSON(item, depth: depth + 1, remaining: &remaining)
            }
            return .object(result)
        }
        throw ExteralessTLError(.malformed, "TL value must be JSON data")
    }

    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .integer(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .bytes(value): return ["__bytes__": value.base64EncodedString()]
        case let .array(value): return value.map(\.jsonObject)
        case let .object(value): return value.mapValues(\.jsonObject)
        }
    }

    public func jsonString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: self.jsonObject, options: [.fragmentsAllowed, .sortedKeys])
        guard data.count <= ExteralessTLCodec.maximumJSONBytes,
              let result = String(data: data, encoding: .utf8) else {
            throw ExteralessTLError(.limit, "TL JSON size limit exceeded")
        }
        return result
    }

    public subscript(_ key: String) -> ExteralessTLValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

public struct ExteralessTLRequest: Sendable {
    public let methodName: String
    public let resultType: String
    public let body: Data
    // Only the validating codec can construct a request.
    fileprivate init(methodName: String, resultType: String, body: Data) {
        self.methodName = methodName
        self.resultType = resultType
        self.body = body
    }
}

private indirect enum TLBridgeType {
    case int32, flags, int64, double, string, bytes, int128, int256, flagTrue
    case vector(TLBridgeType, boxed: Bool)
    case named(String)

    init(_ name: String) throws {
        switch name {
        case "int": self = .int32
        case "#": self = .flags
        case "long": self = .int64
        case "double": self = .double
        case "string": self = .string
        case "bytes": self = .bytes
        case "int128": self = .int128
        case "int256": self = .int256
        case "true": self = .flagTrue
        default:
            if (name.hasPrefix("Vector<") || name.hasPrefix("vector<")), name.hasSuffix(">") {
                self = .vector(try TLBridgeType(String(name.dropFirst(7).dropLast())), boxed: name.hasPrefix("Vector"))
            } else {
                guard !name.isEmpty, name.count <= 256, !name.contains("<"), !name.contains("?") else {
                    throw ExteralessTLError(.schema, "Invalid TL type expression")
                }
                self = .named(name)
            }
        }
    }

    var isFlagTrue: Bool {
        if case .flagTrue = self { return true }
        return false
    }
}

private struct TLBridgeField {
    let name: String
    let type: TLBridgeType
    let condition: (word: String, bit: UInt32)?

    init(_ source: Substring) throws {
        let parts = source.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { throw ExteralessTLError(.schema, "Invalid TL field record") }
        self.name = String(parts[0])
        let conditional = parts[1].split(separator: "?", maxSplits: 1)
        if conditional.count == 2 {
            let flag = conditional[0].split(separator: ".", maxSplits: 1)
            guard flag.count == 2, let bit = UInt32(flag[1]), bit < 32 else {
                throw ExteralessTLError(.schema, "Invalid TL flag record")
            }
            self.condition = (String(flag[0]), UInt32(1) << bit)
            self.type = try TLBridgeType(String(conditional[1]))
        } else {
            self.condition = nil
            self.type = try TLBridgeType(String(parts[1]))
        }
    }
}

private struct TLBridgeDefinition {
    let id: UInt32
    let name: String
    let isMethod: Bool
    let supported: Bool
    let result: String
    let fields: [TLBridgeField]
    let fieldNames: Set<String>
    let knownFlags: [String: UInt32]
    let nativeFieldNames: [String: String]

    init(_ source: Substring) throws {
        let columns = source.split(separator: "|", omittingEmptySubsequences: false)
        guard columns.count == 6, let id = Int32(columns[1]) else {
            throw ExteralessTLError(.schema, "Invalid TL definition record")
        }
        self.id = UInt32(bitPattern: id)
        self.name = String(columns[2])
        self.isMethod = columns[0] == "m"
        self.result = String(columns[3])
        self.supported = columns[4] == "1"
        if self.supported {
            self.fields = try columns[5].split(separator: " ").map(TLBridgeField.init)
        } else {
            self.fields = []
        }
        self.fieldNames = Set(self.fields.map(\.name)).union(["_"])
        var nativeNames: [String: String] = [:]
        for field in self.fields {
            let components = field.name.split(separator: "_", omittingEmptySubsequences: false)
            let camel = (components.first.map(String.init) ?? "") + components.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            nativeNames[camel] = field.name
            nativeNames[field.name] = field.name
        }
        self.nativeFieldNames = nativeNames
        var flags: [String: UInt32] = [:]
        for field in self.fields {
            if case .flags = field.type {
                flags[field.name] = 0
            }
            if let condition = field.condition {
                guard flags[condition.word] != nil else {
                    throw ExteralessTLError(.schema, "TL flag word must precede its field")
                }
                flags[condition.word, default: 0] |= condition.bit
            }
        }
        self.knownFlags = flags
    }
}

private struct TLBridgeSchema {
    let byName: [String: TLBridgeDefinition]
    let byId: [UInt32: TLBridgeDefinition]
    let types: Set<String>
    let androidHookNames: [String: String]

    init() throws {
        var names: [String: TLBridgeDefinition] = [:]
        var ids: [UInt32: TLBridgeDefinition] = [:]
        var types = Set<String>()
        for line in ExteralessTLSchemaGenerated.records.split(separator: "\n") {
            let definition = try TLBridgeDefinition(line)
            guard names[definition.name] == nil, ids[definition.id] == nil else {
                throw ExteralessTLError(.schema, "Duplicate TL definition")
            }
            names[definition.name] = definition
            ids[definition.id] = definition
            if !definition.isMethod && definition.supported { types.insert(definition.result) }
        }
        self.byName = names
        self.byId = ids
        self.types = types
        var hookNames: [String: String] = [:]
        for line in ExteralessTLSchemaGenerated.hookNames.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, names[String(parts[0])] != nil, !parts[1].isEmpty else {
                throw ExteralessTLError(.schema, "Invalid Android TL hook alias record")
            }
            hookNames[String(parts[0])] = String(parts[1])
        }
        self.androidHookNames = hookNames
    }
}

/// Schema-driven TL binary serialization. No request executes while validating or parsing.
public final class ExteralessTLCodec: @unchecked Sendable {
    public static let shared = ExteralessTLCodec()
    public static let maximumBinaryBytes = 8 * 1024 * 1024
    public static let maximumJSONBytes = 16 * 1024 * 1024
    public static let maximumFieldBytes = 4 * 1024 * 1024
    public static let maximumVectorCount = 100_000
    public static let maximumValues = 200_000
    public static let maximumDepth = 64

    private let schema: Result<TLBridgeSchema, Error>

    public init() {
        self.schema = Result { try TLBridgeSchema() }
    }

    public var sourceSHA256: String { ExteralessTLSchemaGenerated.sourceSHA256 }
    public var nativeLayoutHash: UInt64 { ExteralessTLSchemaGenerated.nativeLayoutHash }

    public func typeOfConstructor(_ name: String) -> String? {
        guard let definition = try? self.schema.get().byName[name], definition.supported, !definition.isMethod else { return nil }
        return definition.result
    }

    public func resultTypeOfMethod(_ name: String) throws -> String {
        guard let definition = try self.schema.get().byName[name], definition.supported, definition.isMethod else {
            throw ExteralessTLError(.unsupported, "Unsupported TL method: \(name)")
        }
        return definition.result
    }

    public func canonicalNativeField(_ nativeName: String, constructor: String) throws -> String {
        let name = nativeName.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard let field = try self.schema.get().byName[constructor]?.nativeFieldNames[name] else {
            throw ExteralessTLError(.schema, "Native TL field has no schema mapping")
        }
        return field
    }

    /// Native synthesized Api.Message values can store a real fromId while their
    /// short-update flags omit bit 8. Include the actual stored optionals rather
    /// than dropping them through serialize/parse. Boolean-only flag bits survive.
    public func reconcileNativePresence(_ object: [String: ExteralessTLValue]) throws -> ExteralessTLValue {
        guard let name = object["_"]?.stringValue, let definition = try self.schema.get().byName[name], !definition.isMethod else {
            throw ExteralessTLError(.schema, "Unknown native TL constructor")
        }
        var result = object
        for word in definition.knownFlags.keys {
            guard let original = object[word]?.integerValue, original >= Int64(Int32.min), original <= Int64(UInt32.max) else {
                throw ExteralessTLError(.schema, "Native TL flags are missing")
            }
            var mask = UInt32(truncatingIfNeeded: original)
            var groups: [UInt32: [TLBridgeField]] = [:]
            for field in definition.fields where !field.type.isFlagTrue {
                if let condition = field.condition, condition.word == word { groups[condition.bit, default: []].append(field) }
            }
            for (bit, fields) in groups {
                let present = fields.map { object[$0.name] != nil && object[$0.name] != .null }
                guard present.allSatisfy({ $0 }) || present.allSatisfy({ !$0 }) else {
                    throw ExteralessTLError(.schema, "Native TL shared presence bit is inconsistent")
                }
                if present.first == true { mask |= bit } else { mask &= ~bit }
            }
            result[word] = .integer(Int64(Int32(bitPattern: mask)))
        }
        return .object(result)
    }

    /// Actual Android Class.getSimpleName() for the id-matched native definition.
    /// New native-only constructors keep their canonical name, rather than acquiring
    /// a guessed TL_ class. The generated Python registry lists all matching names.
    public func androidHookName(_ canonicalName: String) -> String {
        guard let schema = try? self.schema.get() else { return canonicalName }
        return schema.androidHookNames[canonicalName] ?? canonicalName
    }

    public func encodeRequest(_ value: ExteralessTLValue) throws -> ExteralessTLRequest {
        let schema = try self.schema.get()
        guard case let .object(fields) = value, let name = fields["_"]?.stringValue, name.utf8.count <= 256 else {
            throw ExteralessTLError(.malformed, "tlRequest requires a bounded TL method constructor name")
        }
        guard let definition = schema.byName[name], definition.isMethod else {
            throw ExteralessTLError(.unsupported, "Unsupported TL request method: \(name)")
        }
        var writer = TLBridgeWriter()
        try self.writeObject(fields, definition: definition, boxed: true, schema: schema, writer: &writer, depth: 0)
        return ExteralessTLRequest(methodName: name, resultType: definition.result, body: writer.data)
    }

    public func decodeRequest(_ data: Data) throws -> ExteralessTLValue {
        let schema = try self.schema.get()
        var reader = try TLBridgeReader(data)
        let id = try reader.uint32()
        guard let definition = schema.byId[id], definition.isMethod else {
            throw ExteralessTLError(.unsupported, "Unknown TL method id")
        }
        let value = try self.readObject(definition, schema: schema, reader: &reader, depth: 0)
        try reader.requireEnd()
        return value
    }

    public func encode(_ value: ExteralessTLValue, as type: String) throws -> Data {
        var writer = TLBridgeWriter()
        try self.write(value, type: TLBridgeType(type), schema: self.schema.get(), writer: &writer, depth: 0)
        return writer.data
    }

    public func decode(_ data: Data, as type: String) throws -> ExteralessTLValue {
        var reader = try TLBridgeReader(data)
        let value = try self.read(type: TLBridgeType(type), schema: self.schema.get(), reader: &reader, depth: 0)
        try reader.requireEnd()
        return value
    }

    public func decodeMethodResponse(_ data: Data, methodName: String) throws -> ExteralessTLValue {
        guard let definition = try self.schema.get().byName[methodName], definition.isMethod, definition.supported else {
            throw ExteralessTLError(.unsupported, "Unknown/unsupported TL method response")
        }
        return try self.decode(data, as: definition.result)
    }

    public func decodeBoxedObject(_ data: Data) throws -> ExteralessTLValue {
        let schema = try self.schema.get()
        var reader = try TLBridgeReader(data)
        let id = try reader.uint32()
        guard let definition = schema.byId[id], !definition.isMethod else {
            throw ExteralessTLError(.unsupported, "Unknown TL object signature")
        }
        let result = try self.readObject(definition, schema: schema, reader: &reader, depth: 0)
        try reader.requireEnd()
        return result
    }

    /// Returns a new snapshot with canonical flags; read-only metadata cannot be smuggled in.
    public func normalize(_ value: ExteralessTLValue, as type: String) throws -> ExteralessTLValue {
        return try self.decode(self.encode(value, as: type), as: type)
    }

    private func masks(_ values: [String: ExteralessTLValue], definition: TLBridgeDefinition) throws -> [String: UInt32] {
        var result: [String: UInt32] = [:]
        for (word, knownBits) in definition.knownFlags {
            if let supplied = values[word], supplied != .null {
                guard let integer = supplied.integerValue, integer >= Int64(Int32.min), integer <= Int64(UInt32.max) else {
                    throw ExteralessTLError(.malformed, "\(definition.name).\(word): expected a 32-bit flags word")
                }
                let bits = UInt32(truncatingIfNeeded: integer)
                guard bits & ~knownBits == 0 else {
                    throw ExteralessTLError(.malformed, "\(definition.name).\(word): unknown flag bits")
                }
                result[word] = bits
            } else {
                var bits: UInt32 = 0
                for field in definition.fields where field.condition?.word == word {
                    guard let condition = field.condition else { continue }
                    if field.type.isFlagTrue {
                        if values[field.name] == .bool(true) { bits |= condition.bit }
                    } else if let value = values[field.name], value != .null {
                        bits |= condition.bit
                    }
                }
                result[word] = bits
            }
        }
        for field in definition.fields {
            guard let condition = field.condition else { continue }
            let enabled = (result[condition.word, default: 0] & condition.bit) != 0
            let value = values[field.name]
            if field.type.isFlagTrue {
                if let value, value != .null, value != .bool(enabled) {
                    throw ExteralessTLError(.malformed, "\(definition.name).\(field.name): Boolean flag disagrees with mask")
                }
            } else if (value != nil && value != .null) != enabled {
                throw ExteralessTLError(.malformed, "\(definition.name).\(field.name): optional field disagrees with mask/shared bit")
            }
        }
        return result
    }

    private func writeObject(_ values: [String: ExteralessTLValue], definition: TLBridgeDefinition,
                             boxed: Bool, schema: TLBridgeSchema, writer: inout TLBridgeWriter, depth: Int) throws {
        try writer.visit(depth)
        guard definition.supported else {
            throw ExteralessTLError(.unsupported, "Unsupported TL operation: \(definition.name) (generic envelope)")
        }
        guard values["_"] == .string(definition.name), Set(values.keys).isSubset(of: definition.fieldNames) else {
            throw ExteralessTLError(.malformed, "\(definition.name): unknown/read-only field or wrong constructor")
        }
        let flags = try self.masks(values, definition: definition)
        if boxed { try writer.integer(definition.id) }
        for field in definition.fields {
            if case .flags = field.type {
                try writer.visit(depth + 1)
                try writer.integer(flags[field.name, default: 0])
                continue
            }
            if let condition = field.condition {
                if field.type.isFlagTrue {
                    // A true flag occupies no binary bytes but becomes a Boolean
                    // field on decode. Count it to bound schema expansion too.
                    try writer.visit(depth + 1)
                    continue
                }
                if flags[condition.word, default: 0] & condition.bit == 0 { continue }
            }
            guard let value = values[field.name], value != .null else {
                throw ExteralessTLError(.malformed, "\(definition.name).\(field.name): required TL field is missing")
            }
            try self.write(value, type: field.type, schema: schema, writer: &writer, depth: depth + 1)
        }
    }

    private func write(_ value: ExteralessTLValue, type: TLBridgeType, schema: TLBridgeSchema,
                       writer: inout TLBridgeWriter, depth: Int) throws {
        try writer.visit(depth)
        switch type {
        case .int32:
            guard let integer = value.integerValue, let int32 = Int32(exactly: integer) else {
                throw ExteralessTLError(.malformed, "TL int requires an exact Int32")
            }
            try writer.integer(int32)
        case .int64:
            guard let integer = value.integerValue else { throw ExteralessTLError(.malformed, "TL long requires an exact Int64") }
            try writer.integer(integer)
        case .double:
            let number: Double
            switch value {
            case let .double(v): number = v
            case let .integer(v): number = Double(v)
            default: throw ExteralessTLError(.malformed, "TL double requires a finite number")
            }
            guard number.isFinite else { throw ExteralessTLError(.malformed, "TL double must be finite") }
            try writer.integer(number.bitPattern)
        case .string:
            guard case let .string(string) = value else { throw ExteralessTLError(.malformed, "TL string requires UTF-8 text") }
            try writer.bytes(Data(string.utf8))
        case .bytes, .int128, .int256:
            guard case let .bytes(bytes) = value else { throw ExteralessTLError(.malformed, "TL bytes require the __bytes__ marker") }
            switch type {
            case .int128:
                guard bytes.count == 16 else { throw ExteralessTLError(.malformed, "TL int128 requires 16 bytes") }
                try writer.append(bytes)
            case .int256:
                guard bytes.count == 32 else { throw ExteralessTLError(.malformed, "TL int256 requires 32 bytes") }
                try writer.append(bytes)
            default: try writer.bytes(bytes)
            }
        case .flagTrue:
            guard value == .bool(true) else { throw ExteralessTLError(.malformed, "TL true requires true") }
        case let .vector(element, boxed):
            guard case let .array(items) = value, items.count <= Self.maximumVectorCount else {
                throw ExteralessTLError(.malformed, "TL vector requires a bounded array")
            }
            if boxed { try writer.integer(UInt32(0x1cb5c415)) }
            try writer.integer(Int32(items.count))
            for item in items { try self.write(item, type: element, schema: schema, writer: &writer, depth: depth + 1) }
        case let .named(name):
            let fields: [String: ExteralessTLValue]
            if name == "Bool", case let .bool(flag) = value {
                fields = ["_": .string(flag ? "boolTrue" : "boolFalse")]
            } else if case let .object(object) = value {
                fields = object
            } else {
                throw ExteralessTLError(.malformed, "TL \(name) requires a constructor object")
            }
            guard let constructor = fields["_"]?.stringValue, let definition = schema.byName[constructor], !definition.isMethod else {
                throw ExteralessTLError(.unsupported, "Unknown TL value constructor for \(name)")
            }
            let isBare = schema.byName[name]?.isMethod == false
            guard (isBare && constructor == name) || (!isBare && definition.result == name) else {
                throw ExteralessTLError(.malformed, "TL constructor does not produce \(name)")
            }
            try self.writeObject(fields, definition: definition, boxed: !isBare, schema: schema, writer: &writer, depth: depth)
        case .flags:
            throw ExteralessTLError(.malformed, "TL flags can only occur in a constructor layout")
        }
    }

    private func readObject(_ definition: TLBridgeDefinition, schema: TLBridgeSchema,
                            reader: inout TLBridgeReader, depth: Int) throws -> ExteralessTLValue {
        try reader.visit(depth)
        guard definition.supported else { throw ExteralessTLError(.unsupported, "Unsupported TL constructor: \(definition.name)") }
        var fields: [String: ExteralessTLValue] = ["_": .string(definition.name)]
        var flags: [String: UInt32] = [:]
        for field in definition.fields {
            if case .flags = field.type {
                try reader.visit(depth + 1)
                let bits = try reader.uint32()
                guard bits & ~definition.knownFlags[field.name, default: 0] == 0 else {
                    throw ExteralessTLError(.schema, "\(definition.name).\(field.name): unknown response flag bits")
                }
                flags[field.name] = bits
                fields[field.name] = .integer(Int64(Int32(bitPattern: bits)))
                continue
            }
            if let condition = field.condition {
                let enabled = flags[condition.word, default: 0] & condition.bit != 0
                if field.type.isFlagTrue {
                    try reader.visit(depth + 1)
                    fields[field.name] = .bool(enabled)
                    continue
                }
                if !enabled { continue }
            }
            fields[field.name] = try self.read(type: field.type, schema: schema, reader: &reader, depth: depth + 1)
        }
        return .object(fields)
    }

    private func read(type: TLBridgeType, schema: TLBridgeSchema, reader: inout TLBridgeReader,
                      depth: Int) throws -> ExteralessTLValue {
        try reader.visit(depth)
        switch type {
        case .int32: return .integer(Int64(Int32(bitPattern: try reader.uint32())))
        case .int64: return .integer(Int64(bitPattern: try reader.uint64()))
        case .double:
            let value = Double(bitPattern: try reader.uint64())
            guard value.isFinite else { throw ExteralessTLError(.malformed, "Nonfinite TL response double") }
            return .double(value)
        case .string:
            guard let value = String(data: try reader.bytes(), encoding: .utf8) else {
                throw ExteralessTLError(.malformed, "Invalid TL UTF-8 response string")
            }
            return .string(value)
        case .bytes: return .bytes(try reader.bytes())
        case .int128: return .bytes(try reader.take(16))
        case .int256: return .bytes(try reader.take(32))
        case .flagTrue: return .bool(true)
        case let .vector(element, boxed):
            if boxed, try reader.uint32() != 0x1cb5c415 { throw ExteralessTLError(.malformed, "Invalid TL vector signature") }
            let count = try reader.uint32()
            guard count <= UInt32(Self.maximumVectorCount) else { throw ExteralessTLError(.limit, "Invalid/oversized TL vector count") }
            var values: [ExteralessTLValue] = []
            values.reserveCapacity(Int(count))
            for _ in 0 ..< count { values.append(try self.read(type: element, schema: schema, reader: &reader, depth: depth + 1)) }
            return .array(values)
        case let .named(name):
            let definition: TLBridgeDefinition
            if let bare = schema.byName[name], !bare.isMethod {
                definition = bare
            } else {
                guard schema.types.contains(name) else { throw ExteralessTLError(.unsupported, "Unknown TL result type: \(name)") }
                let id = try reader.uint32()
                guard let boxed = schema.byId[id], !boxed.isMethod, boxed.result == name else {
                    throw ExteralessTLError(.malformed, "Invalid TL constructor signature for \(name)")
                }
                definition = boxed
            }
            return try self.readObject(definition, schema: schema, reader: &reader, depth: depth)
        case .flags: throw ExteralessTLError(.malformed, "TL flags require a constructor layout")
        }
    }
}

private struct TLBridgeWriter {
    var data = Data()
    private var remaining = ExteralessTLCodec.maximumValues

    mutating func visit(_ depth: Int) throws {
        guard depth <= ExteralessTLCodec.maximumDepth, self.remaining > 0 else { throw ExteralessTLError(.limit, "TL nesting/value limit exceeded") }
        self.remaining -= 1
    }

    mutating func integer<T: FixedWidthInteger>(_ value: T) throws {
        var value = value.littleEndian
        try withUnsafeBytes(of: &value) { bytes in
            guard self.data.count <= ExteralessTLCodec.maximumBinaryBytes - bytes.count else { throw ExteralessTLError(.limit, "TL binary size limit exceeded") }
            self.data.append(contentsOf: bytes)
        }
    }

    mutating func append(_ value: Data) throws {
        guard value.count <= ExteralessTLCodec.maximumBinaryBytes - self.data.count else { throw ExteralessTLError(.limit, "TL binary size limit exceeded") }
        self.data.append(value)
    }

    mutating func bytes(_ bytes: Data) throws {
        guard bytes.count <= ExteralessTLCodec.maximumFieldBytes else { throw ExteralessTLError(.limit, "TL bytes/string size limit exceeded") }
        let prefix: Int
        if bytes.count < 254 {
            prefix = 1
            try self.integer(UInt8(bytes.count))
        } else {
            prefix = 4
            try self.integer(UInt8(254))
            try self.integer(UInt8(bytes.count & 255))
            try self.integer(UInt8((bytes.count >> 8) & 255))
            try self.integer(UInt8((bytes.count >> 16) & 255))
        }
        try self.append(bytes)
        let padding = (4 - (prefix + bytes.count) % 4) % 4
        try self.append(Data(repeating: 0, count: padding))
    }
}

private struct TLBridgeReader {
    private let data: Data
    private var offset = 0
    private var remaining = ExteralessTLCodec.maximumValues

    init(_ data: Data) throws {
        guard data.count <= ExteralessTLCodec.maximumBinaryBytes else { throw ExteralessTLError(.limit, "TL binary size limit exceeded") }
        self.data = Data(data)
    }

    mutating func visit(_ depth: Int) throws {
        guard depth <= ExteralessTLCodec.maximumDepth, self.remaining > 0 else { throw ExteralessTLError(.limit, "TL nesting/value limit exceeded") }
        self.remaining -= 1
    }

    func requireEnd() throws {
        guard self.offset == self.data.count else { throw ExteralessTLError(.malformed, "Trailing TL bytes") }
    }

    private func require(_ size: Int) throws {
        guard size >= 0, size <= self.data.count - self.offset else { throw ExteralessTLError(.malformed, "Truncated TL data") }
    }

    mutating func uint32() throws -> UInt32 {
        try self.require(4)
        let value = self.data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: self.offset, as: UInt32.self)) }
        self.offset += 4
        return value
    }

    mutating func uint64() throws -> UInt64 {
        try self.require(8)
        let value = self.data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: self.offset, as: UInt64.self)) }
        self.offset += 8
        return value
    }

    mutating func take(_ size: Int) throws -> Data {
        try self.require(size)
        let value = self.data.subdata(in: self.offset ..< self.offset + size)
        self.offset += size
        return value
    }

    mutating func bytes() throws -> Data {
        try self.require(1)
        let first = Int(self.data[self.offset])
        self.offset += 1
        let size: Int
        let prefix: Int
        if first < 254 {
            size = first
            prefix = 1
        } else {
            guard first == 254 else { throw ExteralessTLError(.malformed, "Invalid TL byte length prefix") }
            try self.require(3)
            size = Int(self.data[self.offset]) | (Int(self.data[self.offset + 1]) << 8) | (Int(self.data[self.offset + 2]) << 16)
            self.offset += 3
            prefix = 4
            guard size >= 254 else { throw ExteralessTLError(.malformed, "Noncanonical TL byte length") }
        }
        guard size <= ExteralessTLCodec.maximumFieldBytes else { throw ExteralessTLError(.limit, "TL bytes/string size limit exceeded") }
        let result = try self.take(size)
        let padding = (4 - (size + prefix) % 4) % 4
        guard try self.take(padding).allSatisfy({ $0 == 0 }) else { throw ExteralessTLError(.malformed, "Invalid TL byte padding") }
        return result
    }
}
