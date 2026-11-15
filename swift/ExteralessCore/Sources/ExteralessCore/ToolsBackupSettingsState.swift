import Foundation

/// Presence is part of a setting's state: an absent override is not the same as
/// a persisted value which happens to equal today's default.
public struct ToolsBackupSettingsState: Codable, Equatable, Sendable {
    public let values: [String: ClientSettingValue]
    public let storedKeys: Set<String>

    public init(values: [String: ClientSettingValue], storedKeys: Set<String>) throws {
        guard storedKeys.isSubset(of: Set(values.keys)), values.count <= 4_096,
              values.keys.allSatisfy(ClientSettingDefinition.isValidKey) else {
            throw ToolsError.invalidArchive("Invalid settings presence state.")
        }
        self.values = values
        self.storedKeys = storedKeys
    }

    public var resetting: Set<String> { Set(values.keys).subtracting(storedKeys) }
    public var overrides: [String: ClientSettingValue] { values.filter { storedKeys.contains($0.key) } }

    public func expectedSnapshot(definitions: [ClientSettingDefinition], secretKeys: Set<String>) -> ClientSettingsSnapshot {
        ClientSettingsSnapshot(definitions: definitions, values: values, storedKeys: storedKeys,
                               secretKeys: secretKeys, lastError: nil)
    }

}

/// A binding distinguishes a pre-write rejection (including CAS conflicts) from
/// an uncertain/durability failure. An unclassified error is treated as uncertain.
public enum ToolsBackupWriteFailure: Error, LocalizedError, Sendable {
    case rejected(String)
    case durability(String)

    public var errorDescription: String? {
        switch self {
        case let .rejected(message), let .durability(message): return message
        }
    }
}

public enum ToolsBackupFaultPoint: Sendable {
    case afterPrepared, beforeClientCommit, afterClientCommit, beforeCommitMarker, beforeRollback
}
