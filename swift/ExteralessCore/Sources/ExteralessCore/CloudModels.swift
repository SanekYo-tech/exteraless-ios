import Foundation

public enum CloudError: String, Error, LocalizedError, Sendable {
    case network, timedOut, botUnavailable, unsupportedEnvironment, malformedRemote
    case conflict, noBackup, legacyArchive, sizeLimit, storageFull, unsupportedVersion
    case checksumMismatch, wrongAccount, busy, contextClosed, localStorage
    case secureStorage, invalidCredential, settingsChanged, maintenanceUnavailable
    case restorePartiallyApplied
    case nothingToRestore

    public var errorDescription: String? {
        switch self {
        case .network: return "Cloud storage did not complete the request. Try again when connected."
        case .timedOut: return "Cloud storage did not respond in time."
        case .botUnavailable: return "The original cloud storage bot could not be verified."
        case .unsupportedEnvironment: return "The original cloud storage bot is available only on Telegram's production server."
        case .malformedRemote: return "Cloud backup metadata is incomplete or invalid. It has not been applied."
        case .conflict: return "Cloud settings changed on another device. Preview the remote revisions before choosing Restore or Use this device."
        case .noBackup: return "There is no native settings backup for this account."
        case .legacyArchive: return "An Android cloud backup exists. Its preference format needs an explicit Android import adapter; it has not been overwritten."
        case .sizeLimit: return "This settings backup exceeds the bounded cloud storage size."
        case .storageFull: return "Cloud settings storage is full. Review and delete the native backup history before uploading a new backup."
        case .unsupportedVersion: return "This cloud backup requires a newer format reader."
        case .checksumMismatch: return "The cloud backup checksum does not match. No settings were applied."
        case .wrongAccount: return "This backup belongs to a different account or server environment."
        case .busy: return "Another cloud settings operation is still running."
        case .contextClosed: return "This account context has closed."
        case .localStorage: return "The local cloud sync state could not be saved. A successful sync has not been recorded."
        case .secureStorage: return "Service keys could not be accessed in Keychain. Unlock the device and retry."
        case .invalidCredential: return "The backup contains an invalid or unsupported credential entry."
        case .settingsChanged: return "Local settings changed after the preview. Preview again before restoring."
        case .maintenanceUnavailable: return "The application settings-maintenance binding is not ready."
        case .restorePartiallyApplied: return "Public settings were applied, but service-key restoration did not finish. Existing keys were retained. Preview and retry to add any remaining keys; no successful-sync date was recorded."
        case .nothingToRestore: return "No supported settings or missing service keys were applied. Review the skipped fields."
        }
    }
}

public struct CloudRemoteOwner: Hashable, Codable, Sendable {
    public let userId: Int64
    public let environment: ClientAPIEnvironment

    public init(userId: Int64, environment: ClientAPIEnvironment) {
        self.userId = userId
        self.environment = environment
    }
}

public struct CloudAccountScope: Hashable, Codable, Sendable {
    public let recordId: Int64
    public let owner: CloudRemoteOwner

    public init(recordId: Int64, userId: Int64, environment: ClientAPIEnvironment) {
        self.recordId = recordId
        self.owner = CloudRemoteOwner(userId: userId, environment: environment)
    }

    var stateFileName: String { "\(owner.environment.rawValue).\(owner.userId).\(recordId).json" }
}

public enum CloudProtocol {
    public static let botId: Int64 = 8_856_509_355
    public static let botName = "exteralesscloudbot"
    public static let encoding = "gzip_base64_v1"
    public static let chunkCharacters = 3_000
    public static let batchSize = 50
    public static let maximumChunks = 256
    public static let maximumKeys = 1_024
    public static let maximumRevisions = 128
    public static let maximumHeads = 8
    public static let maximumPayloadBytes = 1_024 * 1_024
    public static let maximumReplyBytes = 256 * 1_024
    public static let nativePrefix = "neko_ios_v1."

    public static func manifestKey(_ revision: UUID) -> String { nativePrefix + "r." + revision.uuidString.lowercased() }
    public static func chunkKey(_ revision: UUID, _ index: Int) -> String { nativePrefix + "c." + revision.uuidString.lowercased() + ".\(index)" }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, limit: Int) throws -> T {
        guard data.count <= limit else { throw CloudError.sizeLimit }
        do {
            try ToolsFileSafety.checkJSON(data, maximumBytes: limit)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CloudError { throw error }
        catch { throw CloudError.malformedRemote }
    }
}

public struct CloudRevision: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let parents: [UUID]
    public let owner: CloudRemoteOwner
    public let createdAtMilliseconds: Int64
    public let encoding: String
    public let chunks: Int
    public let encodedCharacters: Int
    public let sha256: String

    func validate(owner: CloudRemoteOwner) throws {
        guard version == 1, encoding == CloudProtocol.encoding else { throw CloudError.unsupportedVersion }
        guard self.owner == owner else { throw CloudError.wrongAccount }
        guard parents.count <= CloudProtocol.maximumHeads, Set(parents).count == parents.count, !parents.contains(id),
              createdAtMilliseconds > 0, chunks > 0, chunks <= CloudProtocol.maximumChunks,
              encodedCharacters > (chunks - 1) * CloudProtocol.chunkCharacters,
              encodedCharacters <= chunks * CloudProtocol.chunkCharacters,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CloudError.malformedRemote
        }
    }
}

public struct CloudCatalog: Sendable {
    public let revisions: [CloudRevision]
    public let heads: Set<UUID>
    public let hasAndroidBackup: Bool
    let allKeys: Set<String>

    public var hasNativeData: Bool { allKeys.contains { $0.hasPrefix(CloudProtocol.nativePrefix) } }

    public var headRevisions: [CloudRevision] {
        revisions.filter { heads.contains($0.id) }.sorted {
            if $0.createdAtMilliseconds != $1.createdAtMilliseconds { return $0.createdAtMilliseconds > $1.createdAtMilliseconds }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

public struct CloudCompression: Sendable {
    public let compress: @Sendable (Data) throws -> Data
    public let decompress: @Sendable (Data, Int) throws -> Data

    public init(compress: @escaping @Sendable (Data) throws -> Data,
                decompress: @escaping @Sendable (Data, Int) throws -> Data) {
        self.compress = compress
        self.decompress = decompress
    }
}

/// The native implementation is bound to one captured Account, never a global
/// selected-account lookup. Cancellation must cancel the underlying RPC wait.
public protocol CloudKeyValueTransport: Sendable {
    func keys() async throws -> [String]
    func get(_ keys: [String]) async throws -> [String: String]
    func set(key: String, value: String) async throws
    func remove(_ keys: [String]) async throws
}
