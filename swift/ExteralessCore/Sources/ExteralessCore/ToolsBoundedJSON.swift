import Foundation

/// Appends only after checking remaining space. It does not construct a whole
/// oversized JSON object/string and then ask JSONEncoder whether it was too large.
struct ToolsBoundedJSONWriter {
    private let maximum: Int
    private(set) var data = Data()
    private var nodes = 0
    var remaining: Int { maximum - data.count }
    init(maximumBytes: Int) { maximum = max(0, maximumBytes) }

    mutating func append(_ bytes: Data) throws {
        guard bytes.count <= remaining else { throw ToolsError.sizeLimit }
        data.append(bytes)
    }
    mutating func literal(_ value: String) throws {
        guard value.utf8.count <= remaining else { throw ToolsError.sizeLimit }
        data.append(contentsOf: value.utf8)
    }
    private mutating func byte(_ value: UInt8) throws {
        guard remaining > 0 else { throw ToolsError.sizeLimit }
        data.append(value)
    }
    mutating func string(_ value: String) throws {
        guard remaining >= 2, value.utf8.count <= remaining - 2 else { throw ToolsError.sizeLimit }
        try byte(34)
        for value in value.utf8 {
            switch value {
            case 34: try literal("\\\"")
            case 92: try literal("\\\\")
            case 8: try literal("\\b")
            case 9: try literal("\\t")
            case 10: try literal("\\n")
            case 12: try literal("\\f")
            case 13: try literal("\\r")
            case 0..<32: try literal(String(format: "\\u%04x", Int(value)))
            default: try byte(value)
            }
        }
        try byte(34)
    }
    mutating func value(_ value: ClientSettingValue, depth: Int = 0) throws {
        guard depth <= 24, nodes < 100_000, remaining > 0 else { throw ToolsError.sizeLimit }
        nodes += 1
        switch value {
        case .null: try literal("null")
        case let .bool(value): try literal(value ? "true" : "false")
        case let .integer(value): try literal(String(value))
        case .number: try append(ToolsFileSafety.encode(value)) // One bounded scalar, preserving Core's exact numeric encoding.
        case let .string(value): try string(value)
        case let .array(values):
            guard values.count <= 100_000 - nodes, values.count <= remaining else { throw ToolsError.sizeLimit }
            try literal("[")
            for (index, value) in values.enumerated() {
                if index != 0 { try literal(",") }
                try self.value(value, depth: depth + 1)
            }
            try literal("]")
        case let .object(values):
            guard values.count <= 4_096, values.count <= remaining / 4 else { throw ToolsError.sizeLimit }
            try literal("{")
            for (index, key) in values.keys.sorted().enumerated() {
                if index != 0 { try literal(",") }
                try string(key); try literal(":")
                if let value = values[key] { try self.value(value, depth: depth + 1) }
            }
            try literal("}")
        }
    }
}

public struct ToolsBackupLimits: Sendable {
    public let payloadBytes: Int
    public let archiveBytes: Int
    public let pluginFileBytes: Int
    public init(payloadBytes: Int = ToolsBackupPolicy.maximumPayloadBytes,
                archiveBytes: Int = ToolsBackupPolicy.maximumArchiveBytes,
                pluginFileBytes: Int = ToolsBackupPolicy.maximumPluginFileBytes) {
        self.payloadBytes = payloadBytes; self.archiveBytes = archiveBytes; self.pluginFileBytes = pluginFileBytes
    }
    func validate() throws {
        guard payloadBytes > 0, payloadBytes <= ToolsBackupPolicy.maximumPayloadBytes,
              archiveBytes > 0, archiveBytes <= ToolsBackupPolicy.maximumArchiveBytes,
              pluginFileBytes > 0, pluginFileBytes <= ToolsBackupPolicy.maximumPluginFileBytes else { throw ToolsError.sizeLimit }
    }
}
