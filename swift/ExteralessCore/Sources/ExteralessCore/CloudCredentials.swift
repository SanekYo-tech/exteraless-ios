import Foundation
#if canImport(Security)
import Security
#endif

public enum CloudTranslationCredential: String, Codable, CaseIterable, Sendable {
    case googleCloud, googleExperimental, lingo, deepL, cloudflareAudio, geminiAudio, openAIAudio

    var settingKey: String {
        switch self {
        case .googleCloud: return "ai.googleCloudTranslateKey"
        case .googleExperimental: return "ai.googleTranslateExperimentalKey"
        case .lingo: return "ai.lingoApiKey"
        case .deepL: return "ai.deepLTranslateKey"
        case .cloudflareAudio: return "ai.transcribeProviderCfApiToken"
        case .geminiAudio: return "ai.transcribeProviderGeminiApiKey"
        case .openAIAudio: return "ai.transcribeProviderOpenAiApiKey"
        }
    }
}

/// A closed native whitelist. There is intentionally no arbitrary Keychain key,
/// Telegram App hash, GitHub token, account auth key, passcode or history case.
public enum CloudCredentialID: Hashable, Codable, Sendable {
    case assistant(serviceId: String)
    case llm(preset: AILLMPreset)
    case translation(CloudTranslationCredential)

    var settingKey: String {
        switch self {
        case let .assistant(id): return "ai.serviceKey." + id
        case let .llm(preset): return preset.keySetting
        case let .translation(key): return key.settingKey
        }
    }

    func validate() throws {
        if case let .assistant(id) = self {
            guard !id.isEmpty, id.utf8.count <= 100, id.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
            }) else { throw CloudError.invalidCredential }
        }
    }
}

public struct CloudCredentialEntry: Codable, Sendable, CustomStringConvertible, CustomReflectable {
    public let id: CloudCredentialID
    private let value: String

    public init(id: CloudCredentialID, value: String) throws {
        try id.validate()
        guard !value.isEmpty, value.utf8.count <= 128 * 1_024, !value.contains("\0") else { throw CloudError.invalidCredential }
        self.id = id
        self.value = value
    }

    func validated() throws -> Self { try Self(id: id, value: value) }
    func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result { try body(value) }
    public var description: String { "CloudCredentialEntry(value: redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "redacted"]) }
}

public enum CloudCredentialInsertResult: Sendable { case inserted, alreadyPresent }

/// No query can enumerate Keychain. Add-only restoration preserves a credential
/// concurrently edited by the native AI editor, even across processes.
public protocol CloudCredentialStorage: Sendable {
    func read(_ id: CloudCredentialID) throws -> String?
    func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult
}

public enum CloudCredentials {
    public static func systemStorage(accessGroup: String? = nil) -> any CloudCredentialStorage {
        #if canImport(Security)
        return CloudKeychainCredentials(accessGroup: accessGroup)
        #else
        return CloudUnavailableCredentials()
        #endif
    }

    public static func export(snapshot: ClientSettingsSnapshot, includeApiKeys: Bool,
                              storage: any CloudCredentialStorage) throws -> [CloudCredentialEntry] {
        guard includeApiKeys else { return [] } // Crucially, zero Keychain reads.
        let admitted = try admittedIDs(publicValues: snapshot.values)
        let secretKeys = snapshot.secretKeys.union(snapshot.definitions.filter(\.isSecret).map(\.key))
        var result: [CloudCredentialEntry] = []
        for id in admitted.sorted(by: { $0.settingKey < $1.settingKey }) where secretKeys.contains(id.settingKey) {
            guard let value = try storage.read(id), !value.isEmpty else { continue }
            do {
                guard let exported = try CloudAICredentialBridge.exportValue(value, id: id, metadata: snapshot.values) else { continue }
                result.append(try CloudCredentialEntry(id: id, value: exported))
            } catch { throw CloudError.invalidCredential }
        }
        return result
    }

    static func admittedIDs(publicValues: [String: ClientSettingValue]) throws -> Set<CloudCredentialID> {
        var result = Set(CloudTranslationCredential.allCases.map(CloudCredentialID.translation))
        result.formUnion(AILLMPreset.allCases.map { .llm(preset: $0) })
        result.insert(.assistant(serviceId: "default"))
        for service in try CloudArchivePolicy.services(publicValues["ai.services"]) {
            let id = CloudCredentialID.assistant(serviceId: service.id)
            try id.validate()
            result.insert(id)
        }
        return result
    }

    static func validate(_ entries: [CloudCredentialEntry], publicValues: [String: ClientSettingValue]) throws {
        let admitted = try admittedIDs(publicValues: publicValues)
        guard entries.count <= 128, Set(entries.map(\.id)).count == entries.count else { throw CloudError.invalidCredential }
        for entry in entries {
            guard admitted.contains(entry.id) else { throw CloudError.invalidCredential }
            _ = try entry.validated()
            try CloudAICredentialBridge.validate(entry, metadata: publicValues)
        }
    }

    static func register(_ entries: [CloudCredentialEntry], settings: ClientSettings) throws {
        var definitions: [ClientSettingDefinition] = []
        for entry in entries {
            if case .assistant = entry.id {
                definitions.append(.init(key: entry.id.settingKey, title: "Service API key", section: "AI credentials",
                    defaultValue: .string(""), isSecret: true, androidSymbols: ["Service.key"]))
            }
        }
        if !definitions.isEmpty { try settings.register(definitions) }
        let snapshot = settings.readSnapshot()
        guard entries.allSatisfy({ snapshot.secretKeys.contains($0.id.settingKey) }) else { throw CloudError.invalidCredential }
    }
}

#if canImport(Security)
private final class CloudKeychainCredentials: CloudCredentialStorage, Sendable {
    private let accessGroup: String?
    private let service = "exteraless.client-settings"

    init(accessGroup: String?) { self.accessGroup = accessGroup }

    func read(_ id: CloudCredentialID) throws -> String? {
        var query = try query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw CloudError.secureStorage }
        guard bytes.count <= 256 * 1_024, let value = try? JSONDecoder().decode(ClientSettingValue.self, from: bytes),
              case let .string(string) = value else { throw CloudError.invalidCredential }
        return string
    }

    func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult {
        _ = try entry.validated()
        var query = try query(entry.id)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = try entry.withValue { try JSONEncoder().encode(ClientSettingValue.string($0)) }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return .alreadyPresent }
        guard status == errSecSuccess else { throw CloudError.secureStorage }
        return .inserted
    }

    private func query(_ id: CloudCredentialID) throws -> [String: Any] {
        try id.validate()
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.settingKey,
            kSecAttrSynchronizable as String: false]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
#else
private struct CloudUnavailableCredentials: CloudCredentialStorage {
    func read(_ id: CloudCredentialID) throws -> String? { throw CloudError.secureStorage }
    func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult { throw CloudError.secureStorage }
}
#endif
