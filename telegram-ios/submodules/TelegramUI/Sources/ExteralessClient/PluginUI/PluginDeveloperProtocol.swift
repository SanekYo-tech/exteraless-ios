import Foundation

public struct PluginDeveloperConnectionState: Equatable, Sendable {
    public let status: String
    public let token: String?
    public init(status: String, token: String?) { self.status = status; self.token = token }
}

/// Revoked synchronously before an account/mode change reaches the network queue.
final class PluginDeveloperSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.active }
    func cancel() { self.lock.lock(); self.active = false; self.lock.unlock() }
}

/// Original dev_server.py line protocol. Authentication and framing are pure so
/// fixtures exercise them without opening a socket or executing plugin code.
enum PluginDeveloperProtocol {
    static let maximumLineBytes = 512 * 1024
    static let maximumSourceBytes = 256 * 1024

    static func takeLine(from buffer: inout Data) -> Data? {
        let bytes = buffer
        var cursor = bytes.startIndex
        var result: Data?
        while cursor < bytes.endIndex, let newline = bytes[cursor...].firstIndex(of: 10) {
            let line = bytes[cursor..<newline]
            cursor = bytes.index(after: newline)
            if !line.allSatisfy({ $0 == 9 || $0 == 13 || $0 == 32 }) { result = Data(line); break }
        }
        if cursor > bytes.startIndex { buffer.removeSubrange(bytes.startIndex..<cursor) }
        return result
    }

    static func request(_ line: Data, token: String) throws -> [String: PluginUIJSON] {
        guard line.count <= self.maximumLineBytes, let text = String(data: line, encoding: .utf8),
              let request = try PluginUIJSON.decode(text).object,
              let command = request["@"]?.string, !command.isEmpty else {
            throw PluginUIFailure.malformed("Malformed developer request")
        }
        if command != "ping" {
            guard let supplied = request["token"]?.string, self.matches(supplied, token) else {
                throw PluginUIFailure.permission("Bad or missing developer session token")
            }
        }
        let id = request["#"] ?? .null
        guard try id.encoded().utf8.count <= 1024 else { throw PluginUIFailure.malformed("Developer request id is too large") }
        return request
    }

    static func response(id: PluginUIJSON, value: [String: PluginUIJSON]? = nil, error: String? = nil) -> PluginUIJSON {
        var result = value ?? [:]
        result["#"] = id
        if error != nil { result["ok"] = .bool(false) }
        else if result["ok"] == nil { result["ok"] = .bool(true) }
        else if result["ok"]?.bool == nil {
            result["ok"] = .bool(false)
            result["error"] = .string("Malformed developer response status")
        }
        if let error { result["error"] = .string(error) }
        return .object(result)
    }

    static func echoedId(_ line: Data) -> PluginUIJSON {
        guard line.count <= self.maximumLineBytes, let text = String(data: line, encoding: .utf8),
              let value = try? PluginUIJSON.decode(text).object?["#"],
              let bytes = try? value.encoded().utf8.count, bytes <= 1024 else { return .null }
        return value
    }

    static func source(_ request: [String: PluginUIJSON]) throws -> (pluginId: String, filename: String, data: Data) {
        let id = try self.pluginId(request)
        guard let text = request["content"]?.string, let data = Data(base64Encoded: text), !data.isEmpty,
              data.count <= self.maximumSourceBytes else { throw PluginUIFailure.malformed("Developer content must be base64 source of at most 256 KiB") }
        let filename = request["filename"]?.string ?? id + ".py"
        guard !filename.isEmpty, filename.utf8.count <= 255, !filename.contains("\0"),
              filename == (filename as NSString).lastPathComponent, !filename.contains("\\"),
              ["plugin", "py"].contains((filename as NSString).pathExtension.lowercased()) else {
            throw PluginUIFailure.unsupported("Native developer upload supports .plugin/.py source files")
        }
        return (id, filename, data)
    }

    static func pluginId(_ request: [String: PluginUIJSON]) throws -> String {
        guard let id = request["plugin_id"]?.string, (2...32).contains(id.utf8.count), let first = id.utf8.first,
              (65...90).contains(first) || (97...122).contains(first),
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw PluginUIFailure.malformed("Developer request requires a valid plugin_id")
        }
        return id
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
