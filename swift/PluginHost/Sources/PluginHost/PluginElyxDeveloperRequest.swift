import Foundation

/// Original Elyx wire commands. Authentication is exclusively the native
/// PluginDeveloperProtocol/Session ingress; this value contains no credential.
public struct PluginElyxDeveloperRequest: Sendable {
    public enum Kind: String, Sendable {
        case ping = "elyx_ping", list = "get_elyx_plugins"
        case compare = "elyx_compare_folder", changes = "elyx_changes"
    }

    public static let maximumRequestBytes = 512 * 1024
    public static let maximumChanges = 128
    public static let maximumChangedBytes = 256 * 1024
    public let kind: Kind
    public let pluginId: String?
    public let hashes: [String: String]
    public let changes: [PluginElyxChange]

    public static func recognizes(_ name: String) -> Bool {
        name.hasPrefix("elyx_") || name == Kind.list.rawValue
    }

    /// Caller strips only top-level token/# after native authentication.
    public init(json: String) throws {
        guard json.utf8.count <= Self.maximumRequestBytes else { throw PluginElyxDeveloperError.malformed("request exceeds 512 KiB") }
        let root = try NativeServiceWire.decode(json)
        guard case let .object(raw) = root, case let .string(name)? = raw["@"] else {
            throw PluginElyxDeveloperError.malformed("missing @ command")
        }
        guard let kind = Kind(rawValue: name) else { throw PluginElyxDeveloperError.unsupported("unknown Elyx command: \(name)") }
        let keys: Set<String>
        switch kind {
        case .ping, .list: keys = ["@"]
        case .compare: keys = ["@", "plugin_id", "hashes"]
        case .changes: keys = ["@", "plugin_id", "changes"]
        }
        guard Set(raw.keys).isSubset(of: keys) else { throw PluginElyxDeveloperError.malformed("unsupported Elyx request fields") }
        self.kind = kind
        if kind == .compare || kind == .changes {
            guard case let .string(id)? = raw["plugin_id"], Plugin.isValidID(id, format: .elyx), !Plugin.isReservedID(id) else {
                throw PluginElyxDeveloperError.malformed("plugin_id must be an Elyx archive ID")
            }
            pluginId = id
        } else { pluginId = nil }
        var hashes: [String: String] = [:]
        if kind == .compare {
            let value = raw["hashes"] == .null ? .object([:]) : raw["hashes"] ?? .object([:])
            guard case let .object(entries) = value, entries.count <= 2048 else { throw PluginElyxDeveloperError.malformed("hashes must be a mapping of at most 2048 paths") }
            for (name, value) in entries {
                let path = try Self.path(name)
                guard hashes[path] == nil, case let .string(hash) = value, Self.isDigest(hash) else {
                    throw PluginElyxDeveloperError.malformed("hashes require unique normalized paths and SHA-256 strings")
                }
                hashes[path] = hash
            }
        }
        self.hashes = hashes
        var changes: [PluginElyxChange] = []
        if kind == .changes {
            guard case let .array(entries)? = raw["changes"], entries.count <= Self.maximumChanges else {
                throw PluginElyxDeveloperError.malformed("changes must be an array of at most 128 entries")
            }
            var bytes = 0
            for entry in entries {
                let change = try PluginElyxChange(entry)
                bytes += change.content.count
                guard bytes <= Self.maximumChangedBytes else { throw PluginElyxDeveloperError.malformed("changes exceed 256 KiB decoded content") }
                changes.append(change)
            }
        }
        self.changes = changes
    }

    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    /// Same relative-path convention as Original _safe_join, with the archive
    /// owner's portable filename/alias limits enforced before any staging write.
    public static func path(_ value: String) throws -> String {
        let value = value.replacingOccurrences(of: "\\", with: "/")
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let devices = Set(["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] })
        guard !value.isEmpty, value.utf8.count <= 512, parts.count <= 16,
              !value.unicodeScalars.contains(where: { $0.value < 32 || ":<>\"|?*".unicodeScalars.contains($0) }),
              parts.allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 255
                    && !part.hasSuffix(".") && !part.hasSuffix(" ")
                    && !devices.contains(String(part.split(separator: ".").first ?? part).lowercased())
              }) else { throw PluginElyxDeveloperError.malformed("unsafe or ambiguous relative archive path") }
        return value
    }
}

public struct PluginElyxChange: Sendable {
    public enum Kind: String, Sendable { case created, modified, deleted, moved }
    public let kind: Kind
    public let path: String
    public let destination: String?
    public let directory: Bool
    public let content: Data

    init(_ value: PluginJSONValue) throws {
        guard case let .object(raw) = value, Set(raw.keys).isSubset(of: ["#", "type", "path", "dest_path", "is_directory", "content"]),
              case let .string(name)? = raw["#"] ?? raw["type"], let kind = Kind(rawValue: name),
              raw["#"] == nil || raw["type"] == nil || raw["#"] == raw["type"],
              case let .string(path)? = raw["path"] else { throw PluginElyxDeveloperError.malformed("invalid or ambiguous change entry") }
        self.kind = kind
        if let flag = raw["is_directory"], flag != .null {
            guard case let .bool(value) = flag else { throw PluginElyxDeveloperError.malformed("is_directory must be Bool") }
            directory = value
        } else { directory = false }
        self.path = try PluginElyxDeveloperRequest.path(directory && path.hasSuffix("/") ? String(path.dropLast()) : path)
        if kind == .moved {
            guard case let .string(path)? = raw["dest_path"] else { throw PluginElyxDeveloperError.malformed("moved requires dest_path") }
            destination = try PluginElyxDeveloperRequest.path(directory && path.hasSuffix("/") ? String(path.dropLast()) : path)
        } else {
            guard raw["dest_path"] == nil else { throw PluginElyxDeveloperError.malformed("dest_path is only valid for moved") }
            destination = nil
        }
        if kind == .created || kind == .modified {
            let value = raw["content"] == .null ? .string("") : raw["content"] ?? .string("")
            guard case let .string(text) = value, text.utf8.count <= (PluginElyxDeveloperRequest.maximumChangedBytes + 2) / 3 * 4,
                  let data = Data(base64Encoded: text), !directory || data.isEmpty else {
                throw PluginElyxDeveloperError.malformed("content must be bounded base64; directories have no content")
            }
            content = data
        } else {
            guard raw["content"] == nil else { throw PluginElyxDeveloperError.malformed("content is only valid for created/modified") }
            content = Data()
        }
    }
}

public struct PluginElyxDeveloperError: Error, Sendable, CustomStringConvertible {
    public let kind: String
    public let message: String
    public var description: String { "\(kind): \(message)" }
    public static func malformed(_ message: String) -> Self { .init(kind: "MalformedRequest", message: message) }
    public static func unsupported(_ message: String) -> Self { .init(kind: "Unimplemented", message: message) }
    public static func stale(_ message: String) -> Self { .init(kind: "Superseded", message: message) }
    public static func unavailable(_ message: String) -> Self { .init(kind: "ServiceUnavailable", message: message) }

    public static func response(_ error: Error, request: PluginElyxDeveloperRequest?) -> [String: PluginJSONValue] {
        let failure = error as? Self
        var value: [String: PluginJSONValue] = ["ok": .bool(false), "error": .string(String(describing: error)),
                                               "error_kind": .string(failure?.kind ?? "RuntimeError")]
        if request?.kind == .changes {
            value["plugin_id"] = request?.pluginId.map(PluginJSONValue.string) ?? .null
            value["reloaded"] = .bool(false)
            value["errors"] = .array([.string(String(describing: error))])
        }
        return value
    }
}
