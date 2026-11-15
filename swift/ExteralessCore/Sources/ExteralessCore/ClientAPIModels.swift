import Foundation

public enum ClientAPIError: String, Error, LocalizedError, Sendable {
    case invalidAppId, invalidAppHash, missingAppHash, builtInUnavailable
    case secureStorageUnavailable, invalidSecureRecord, settingsUnavailable
    case incompleteSave, concurrentEdit, bootstrapRequired

    public var errorDescription: String? {
        switch self {
        case .invalidAppId: return "Enter a positive 32-bit Telegram App ID."
        case .invalidAppHash: return "Enter the 32 hexadecimal characters of your Telegram App hash."
        case .missingAppHash: return "Enter an App hash for this App ID. An existing hash is retained only for the same ID."
        case .builtInUnavailable: return "The build does not contain a valid API identity. Supply the build credentials through the build configuration."
        case .secureStorageUnavailable: return "API Keychain storage is unavailable. Unlock the device and restart before beginning a new login; no other API identity was selected."
        case .invalidSecureRecord: return "The saved API identity could not be read. Its record has been preserved."
        case .settingsUnavailable: return "Client API settings could not be read."
        case .incompleteSave: return "The API draft was not fully saved. Reopen the Client API editor and save it again before starting a new login. Existing account identities are retained."
        case .concurrentEdit: return "The API draft changed in another editor. Review it and save again."
        case .bootstrapRequired: return "Client API configuration must finish before an account network is created."
        }
    }
}

public struct ClientAPIAccountScope: Hashable, Codable, Sendable {
    public let recordId: Int64
    public let environment: ClientAPIEnvironment

    public init(recordId: Int64, environment: ClientAPIEnvironment) {
        self.recordId = recordId
        self.environment = environment
    }
}

/// An opaque native credential. It deliberately has no public Codable conformance,
/// raw hash property, JSON description or reflection containing the hash.
public struct ClientAPICredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let apiId: Int32
    public let mode: ClientAPIMode
    public let generation: UUID
    private let appHash: String

    public init(apiId: Int32, apiHash: String, mode: ClientAPIMode, generation: UUID = UUID()) throws {
        guard apiId > 0 else { throw mode == .builtIn ? ClientAPIError.builtInUnavailable : .invalidAppId }
        guard Self.validHash(apiHash) else { throw mode == .builtIn ? ClientAPIError.builtInUnavailable : .invalidAppHash }
        self.apiId = apiId
        self.appHash = apiHash
        self.mode = mode
        self.generation = generation
    }

    /// Use only at the native environment/auth factory, never a diagnostics bridge.
    public func withAPITuple<Result>(_ factory: (Int32, String) throws -> Result) rethrows -> Result {
        try factory(apiId, appHash)
    }

    public var description: String { "ClientAPICredentials(mode: \(mode.rawValue), appHash: set)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["mode": mode.rawValue as Any, "appHashSet": true as Any]) }

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

public struct ClientAPIDraftSummary: Sendable {
    public let mode: ClientAPIMode
    public let apiId: Int32
    public let hashIsSet: Bool
    public let requiresRepair: Bool
}

enum ClientAPISelection: Sendable {
    case builtIn
    case custom(ClientAPICredentials)
}

// These records only enter native Keychain. They never enter ClientSettings JSON,
// Tools/cloud archives, logger descriptions or an SDK response.
struct ClientAPIStoredCredential: Codable, Sendable {
    let version: Int
    let apiId: Int32
    let apiHash: String
    let mode: ClientAPIMode
    let generation: UUID

    init(_ credentials: ClientAPICredentials) {
        self.version = 1
        self.apiId = credentials.apiId
        self.apiHash = credentials.withAPITuple { _, hash in hash }
        self.mode = credentials.mode
        self.generation = credentials.generation
    }

    func credentials() throws -> ClientAPICredentials {
        guard version == 1 else { throw ClientAPIError.invalidSecureRecord }
        return try ClientAPICredentials(apiId: apiId, apiHash: apiHash, mode: mode, generation: generation)
    }
}

struct ClientAPIPendingDraft: Codable, Sendable {
    let version: Int
    let mode: ClientAPIMode
    let apiId: Int32
    let replacementHash: String?
}
