import Foundation

/// Strict JSON readers for the portable, non-TL native services. No coercion of
/// booleans/floats to ids, and no interpretation of arbitrary dictionary tags.
public enum NativeServiceWire {
    public static let maximumRequestBytes = 1_048_576

    public static func object(_ value: PluginJSONValue, name: String, keys: Set<String>) throws -> [String: PluginJSONValue] {
        guard case let .object(result) = value else { throw BridgeFailure.malformed("\(name) must be an object") }
        guard Set(result.keys).isSubset(of: keys) else { throw BridgeFailure.malformed("\(name) has unsupported fields") }
        return result
    }

    public static func string(_ value: PluginJSONValue?, name: String, maximum: Int = 256, empty: Bool = false) throws -> String {
        guard case let .string(result)? = value, (empty || !result.isEmpty), result.utf8.count <= maximum,
              !result.contains("\0") else { throw BridgeFailure.malformed("\(name) must be a bounded string") }
        return result
    }

    public static func integer(_ value: PluginJSONValue?, name: String, range: ClosedRange<Int64> = Int64.min...Int64.max) throws -> Int64 {
        guard case let .integer(result)? = value, range.contains(result) else {
            throw BridgeFailure.malformed("\(name) must be an integer in \(range)")
        }
        return result
    }

    public static func bool(_ value: PluginJSONValue?, name: String) throws -> Bool {
        guard case let .bool(result)? = value else { throw BridgeFailure.malformed("\(name) must be a boolean") }
        return result
    }

    public static func strings(_ value: PluginJSONValue?, name: String, maximumCount: Int = 64, maximumLength: Int = 256) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard case let .array(array) = value, array.count <= maximumCount else { throw BridgeFailure.malformed("\(name) must be a bounded array") }
        return try array.map { try string($0, name: name, maximum: maximumLength) }
    }

    public static func callbackHandle(_ value: PluginJSONValue) throws -> Int64 {
        let object = try self.object(value, name: "callback", keys: ["__handle__", "__fqcn__", "__fqcn"])
        let handle = try integer(object["__handle__"], name: "callback.__handle__", range: 1...Int64.max)
        for key in ["__fqcn__", "__fqcn"] {
            if let value = object[key], value != .null { _ = try string(value, name: key, maximum: 512) }
        }
        if let first = object["__fqcn__"], let second = object["__fqcn"], first != second {
            throw BridgeFailure.malformed("Conflicting callback class tags")
        }
        return handle
    }

    public static func json(_ value: PluginJSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumRequestBytes else { throw BridgeFailure.malformed("Native service result exceeds 1 MiB") }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> PluginJSONValue {
        guard text.utf8.count <= maximumRequestBytes else { throw BridgeFailure.malformed("Native service JSON exceeds 1 MiB") }
        return try PluginJSONValue(jsonObject: JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
    }
}

public struct NativeServiceRequest: Sendable {
    public let member: String
    public let arguments: [PluginJSONValue]
    public let ownerToken: String?
    public let memberKind: Bool

    public init?(json: String, members: Set<String>) throws {
        // A composite may place us before the TL provider (which accepts 16 MiB).
        // Apply our smaller budget only after recognizing our own operation.
        guard json.utf8.count <= 16_777_216 else { throw BridgeFailure.malformed("Bridge request exceeds 16 MiB") }
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let header = raw as? [String: Any] else { throw BridgeFailure.malformed("Native service envelope must be an object") }
        guard header["fqcn"] as? String == "exteraless.ios.Runtime", let name = header["member"] as? String, members.contains(name) else { return nil }
        guard json.utf8.count <= NativeServiceWire.maximumRequestBytes else { throw BridgeFailure.malformed("Native service request exceeds 1 MiB") }
        let value = try PluginJSONValue(jsonObject: raw)
        guard case let .object(root) = value else { throw BridgeFailure.malformed("Native service envelope must be an object") }
        guard root["fqcn"] == .string("exteraless.ios.Runtime"), case let .string(member)? = root["member"], members.contains(member) else { return nil }
        _ = try NativeServiceWire.object(value, name: "Native service envelope", keys: ["op", "fqcn", "member", "args", "kwargs", "instance", "value", "pluginId", "ownerToken"])
        guard root["instance"] == nil || root["instance"] == .null,
              root["value"] == nil || root["value"] == .null,
              root["kwargs"] == nil || root["kwargs"] == .object([:]) else {
            throw BridgeFailure.malformed("Native service methods are static and positional")
        }
        guard case let .array(arguments) = root["args"] ?? .array([]), arguments.count <= 8 else {
            throw BridgeFailure.malformed("Native service args must be a bounded array")
        }
        let memberKind = root["op"] == .string("member_kind")
        guard (memberKind && arguments.isEmpty) || root["op"] == .string("call") else {
            throw BridgeFailure.memberError("Native service member is a callable read-only method")
        }
        self.member = member
        self.arguments = arguments
        self.memberKind = memberKind
        if let token = root["ownerToken"], token != .null {
            self.ownerToken = try NativeServiceWire.string(token, name: "ownerToken", maximum: 128)
        } else {
            self.ownerToken = nil
        }
    }

    public func requireArguments(_ count: Int) throws {
        guard arguments.count == count else { throw BridgeFailure.malformed("\(member) requires \(count) positional arguments") }
    }
}
