import Foundation

/// Data-only codec for the exact original bot storage methods. Production injects
/// an account-owned native TL request; offline fixtures inspect these same bytes.
public struct CloudBotStorageTransport: CloudKeyValueTransport {
    public typealias Invoke = @Sendable (String, Data) async throws -> Data
    private let invoke: Invoke

    public init(invoke: @escaping Invoke) { self.invoke = invoke }

    public func keys() async throws -> [String] {
        let data = try await invoke("getStorageKeys", Data("{}".utf8))
        let values = try CloudProtocol.decode([String].self, data, limit: CloudProtocol.maximumReplyBytes)
        guard values.count <= CloudProtocol.maximumKeys, Set(values).count == values.count,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw CloudError.malformedRemote }
        return values
    }

    public func get(_ keys: [String]) async throws -> [String: String] {
        guard !keys.isEmpty, keys.count <= CloudProtocol.batchSize, Set(keys).count == keys.count,
              keys.allSatisfy(Self.readableKey) else { throw CloudError.malformedRemote }
        let data = try await invoke("getStorageValues", CloudProtocol.encode(Keys(keys: keys)))
        let raw = try CloudProtocol.decode([String: String?].self, data, limit: CloudProtocol.maximumReplyBytes)
        guard Set(raw.keys).isSubset(of: Set(keys)) else { throw CloudError.malformedRemote }
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let value {
                let legacyChunk = key.hasPrefix("neko_settings_") && Int(key.dropFirst("neko_settings_".count)) != nil
                guard (legacyChunk ? value.utf16.count <= CloudProtocol.chunkCharacters : value.utf8.count <= CloudProtocol.chunkCharacters) else { throw CloudError.sizeLimit }
                result[key] = value
            }
        }
        return result
    }

    public func set(key: String, value: String) async throws {
        guard Self.writableKey(key), value.utf8.count <= CloudProtocol.chunkCharacters else { throw CloudError.sizeLimit }
        let response = try await invoke("saveStorageValue", CloudProtocol.encode(Value(key: key, value: value)))
        guard response.count <= CloudProtocol.maximumReplyBytes else { throw CloudError.sizeLimit }
        // Android ignores this value. Publication verifies stored bytes by reading
        // them back rather than inventing a server success-response schema.
    }

    public func remove(_ keys: [String]) async throws {
        guard !keys.isEmpty, keys.count <= CloudProtocol.batchSize, Set(keys).count == keys.count,
              keys.allSatisfy(Self.writableKey) else { throw CloudError.malformedRemote }
        let response = try await invoke("deleteStorageValues", CloudProtocol.encode(Keys(keys: keys)))
        guard response.count <= CloudProtocol.maximumReplyBytes else { throw CloudError.sizeLimit }
    }

    private struct Keys: Encodable { let keys: [String] }
    private struct Value: Encodable { let key: String; let value: String }

    private static func writableKey(_ key: String) -> Bool {
        key.hasPrefix(CloudProtocol.nativePrefix) && key.utf8.count <= 128 && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private static func readableKey(_ key: String) -> Bool {
        if writableKey(key) { return true }
        if ["neko_settings", "neko_settings_encoding", "neko_settings_updated_at"].contains(key) { return true }
        guard key.hasPrefix("neko_settings_"), let index = Int(key.dropFirst("neko_settings_".count)) else { return false }
        return (0..<CloudProtocol.maximumChunks).contains(index)
    }
}
