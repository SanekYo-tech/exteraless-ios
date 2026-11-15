import Foundation

/// Structured events live in the existing native PluginServiceLogBuffer. The
/// canonical JSON message also keeps debug severity, phase and traceback intact
/// without introducing a second logger or exporting native account credentials.
public struct NativeServiceLogEvent: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case debug, info, warning, error }
    public let level: Severity
    public let message: String
    public let phase: String
    public let traceback: String?

    public init(_ value: PluginJSONValue) throws {
        let model = try NativeServiceWire.object(value, name: "logEvent", keys: ["level", "message", "phase", "traceback"])
        let rawLevel = try NativeServiceWire.string(model["level"], name: "level", maximum: 16).lowercased()
        switch rawLevel {
        case "d", "debug": level = .debug
        case "i", "info": level = .info
        case "w", "warn", "warning": level = .warning
        case "e", "error", "fatal", "critical": level = .error
        default: throw BridgeFailure.malformed("Unsupported native log severity")
        }
        let message = try NativeServiceWire.string(model["message"], name: "message", maximum: 65_536, empty: true)
        let phase = try NativeServiceWire.string(model["phase"], name: "phase", maximum: 256)
        var traceback: String?
        if let value = model["traceback"], value != .null {
            traceback = try NativeServiceWire.string(value, name: "traceback", maximum: 131_072, empty: true)
        }
        self.message = Self.redacted(message, maximumBytes: 1024)
        self.phase = Self.redacted(phase, maximumBytes: 128)
        self.traceback = traceback.map { Self.redacted($0, maximumBytes: 2048) }
    }

    public static func redacted(_ text: String, maximumBytes: Int) -> String {
        // Bound the work before regex. The patterns have no nested repetition.
        var result = boundedUTF8(text, maximumBytes: 16_384)
        for (pattern, replacement) in [
            (#"(?i)\b(authorization\s*[:=]\s*)(?:bearer|basic)\s+[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)\b((?:api[_-]?key|api[_-]?hash|access[_-]?token|refresh[_-]?token|bot[_-]?token|auth[_-]?key|password|secret)\s*[\"']?\s*[:=]\s*[\"']?)[^\s\"'&,;}]+"#, "$1<redacted>"),
            (#"(?i)([a-z][a-z0-9+.-]*://)[^\s/@]+:[^\s/@]+@"#, "$1<redacted>@")
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return boundedUTF8(result, maximumBytes: maximumBytes)
    }

    private static func boundedUTF8(_ text: String, maximumBytes: Int) -> String {
        var bytes = Array(text.utf8.prefix(maximumBytes))
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    public var bufferLevel: PluginServiceLogEntry.Level {
        switch level {
        case .debug, .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }

    /// Escaping can expand a string up to sixfold. Shrink fields until the whole
    /// event fits the existing default 4096-byte buffer record, keeping valid JSON.
    public func encodedRecord() -> String {
        var value: [String: PluginJSONValue] = ["level": .string(level.rawValue), "phase": .string(phase), "message": .string(message)]
        if let traceback { value["traceback"] = .string(traceback) }
        while true {
            let data = try? JSONEncoder().encode(PluginJSONValue.object(value))
            if let data, data.count <= 4000 { return String(decoding: data, as: UTF8.self) }
            if case let .string(trace)? = value["traceback"], !trace.isEmpty {
                value["traceback"] = .string(Self.boundedUTF8(trace, maximumBytes: trace.utf8.count / 2))
            } else if case let .string(message)? = value["message"], !message.isEmpty {
                value["message"] = .string(Self.boundedUTF8(message, maximumBytes: message.utf8.count / 2))
            } else {
                return "{\"level\":\"error\",\"phase\":\"native.log\",\"message\":\"LOG_ENCODING_FAILED\"}"
            }
        }
    }
}

public extension PluginServiceLogBuffer {
    func append(pluginId: String, event: NativeServiceLogEvent) {
        append(pluginId: pluginId, level: event.bufferLevel, message: event.encodedRecord())
    }
}

public extension PluginServiceLogEntry {
    var nativeServiceEvent: NativeServiceLogEvent? {
        try? JSONDecoder().decode(NativeServiceLogEvent.self, from: Data(message.utf8))
    }
}
