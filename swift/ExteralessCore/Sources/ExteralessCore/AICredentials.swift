import Foundation

/// Only an explicit native credential edit removes/replaces a key. An unavailable
/// cache read must never be interpreted as the user's request to delete it.
public enum AICredentialUpdate: Equatable, Sendable {
    case unchanged
    case replace(String)
    case remove
}

/// The destination and credential share one Keychain item, never public metadata.
/// Include the setting identity, base path and wire protocol as well as the origin:
/// compatible multi-tenant endpoints on one host need separate authorizations too.
struct AICredentialDestination: Codable, Equatable {
    let settingKey: String
    let scheme: String
    let host: String
    let port: Int
    let path: String
    let wireProtocol: AIWireProtocol

    init(settingKey: String, baseURL: String, wireProtocol: AIWireProtocol) throws {
        let url = try AIRequestBuilder.normalizedBaseURL(baseURL)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { throw AIError.invalidURL }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1 ... 65535).contains(port) else { throw AIError.invalidURL }
        self.settingKey = settingKey
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
        self.path = components.percentEncodedPath
        self.wireProtocol = wireProtocol
    }
}

enum AICredentialBinding {
    // The newline also prevents an old raw-key consumer from accidentally sending
    // this envelope as an Authorization header (validatedKey rejects controls).
    private static let prefix = "exteraless.ai-credential.v1\n"
    private struct Record: Codable {
        let destination: AICredentialDestination
        let credential: String
    }

    static func read(_ raw: String, destination: AICredentialDestination) -> String {
        guard let record = decode(raw), record.destination == destination else { return "" }
        return record.credential
    }

    /// nil means no secret mutation. An unbound legacy raw key can only acquire a
    /// destination through this trusted native operation, never register/reload.
    static func updated(_ update: AICredentialUpdate, previous: String, destination: AICredentialDestination,
                        authorizeDestinationChange: Bool, multiple: Bool = false) throws -> String? {
        let credential: String
        switch update {
        case .remove: return ""
        case let .replace(value): credential = try validated(value, multiple: multiple)
        case .unchanged:
            guard authorizeDestinationChange, !previous.isEmpty else { return nil }
            if let record = decode(previous) {
                guard record.destination.settingKey == destination.settingKey else { throw AIError.configuration }
                credential = try validated(record.credential, multiple: multiple)
            } else {
                // A corrupt/future protected record is not an unbound raw key.
                guard !previous.hasPrefix("exteraless.ai-credential.") else { throw AIError.configuration }
                credential = try validated(previous, multiple: multiple)
            }
        }
        let data = try JSONEncoder().encode(Record(destination: destination, credential: credential))
        return prefix + String(decoding: data, as: UTF8.self)
    }

    static func validated(_ raw: String, multiple: Bool) throws -> String {
        guard raw.utf8.count <= 16_384 else { throw AIError.invalidKey }
        if !multiple { return try AIRequestBuilder.validatedKey(raw) }
        let values = try raw.split(separator: ",").map { try AIRequestBuilder.validatedKey(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !values.isEmpty else { throw AIError.missingKey }
        return values.joined(separator: ",")
    }

    static func keys(_ raw: String) -> [String] {
        guard let value = try? validated(raw, multiple: true) else { return [] }
        var seen = Set<String>()
        return value.split(separator: ",").map(String.init).filter { seen.insert($0).inserted }
    }

    private static func decode(_ raw: String) -> Record? {
        guard raw.utf8.count <= 128 * 1024, raw.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: Data(raw.dropFirst(prefix.count).utf8))
    }
}

extension AISettings {
    // Serializes native read/modify/write operations. Public writes cannot acquire
    // this privilege and are safe even when racing: every read matches the bound
    // destination against the exact service value used to build that request.
    static let credentialMutationLock = NSRecursiveLock()

    public func llmAPIKeys(for service: AIService) -> [String] {
        guard let preset = AILLMPreset.allCases.first(where: { service.id == "llm-\($0.rawValue)" }),
              let requested = try? AICredentialDestination(settingKey: preset.keySetting, baseURL: service.url, wireProtocol: service.wireProtocol) else { return [] }
        let raw = store.string(preset.keySetting)
        if preset == .custom { return AICredentialBinding.keys(AICredentialBinding.read(raw, destination: requested)) }
        guard let trusted = try? AICredentialDestination(settingKey: preset.keySetting, baseURL: preset.baseURL, wireProtocol: preset == .vertex ? .vertex : .openAI), requested == trusted else { return [] }
        return AICredentialBinding.keys(raw)
    }

    public func openAITranscriptionAPIKey(baseURL: String) -> String {
        let key = "ai.transcribeProviderOpenAiApiKey"
        guard let destination = try? AICredentialDestination(settingKey: key, baseURL: baseURL, wireProtocol: .openAI) else { return "" }
        return AICredentialBinding.read(store.string(key), destination: destination)
    }

    /// Native endpoint editor only. A metadata-only write leaves authorization
    /// unchanged; an explicit endpoint Save may rebind the existing stored key.
    public func saveCustomLLM(baseURL: String, credential: AICredentialUpdate, authorizeDestinationChange: Bool = false) throws {
        try saveEndpoint(baseURL, urlSetting: "ai.llmApiUrl", keySetting: AILLMPreset.custom.keySetting,
                         credential: credential, authorizeDestinationChange: authorizeDestinationChange, multiple: true)
    }

    public func saveOpenAITranscription(baseURL: String, credential: AICredentialUpdate, authorizeDestinationChange: Bool = false) throws {
        try saveEndpoint(baseURL, urlSetting: "ai.transcribeProviderOpenAiApiBase", keySetting: "ai.transcribeProviderOpenAiApiKey",
                         credential: credential, authorizeDestinationChange: authorizeDestinationChange, multiple: false)
    }

    public func saveLLMKey(preset: AILLMPreset, credential: AICredentialUpdate) throws {
        Self.credentialMutationLock.lock()
        defer { Self.credentialMutationLock.unlock() }
        try register()
        switch credential {
        case .unchanged: break
        case .remove: try store.set(.string(""), for: preset.keySetting)
        case let .replace(value):
            // A custom endpoint must be supplied from the native form's displayed
            // snapshot to saveCustomLLM, never looked up from mutable public state
            // while saving a credential entered for a different URL.
            guard preset != .custom else { throw AIError.configuration }
            try store.set(.string(AICredentialBinding.validated(value, multiple: true)), for: preset.keySetting)
        }
    }

    private func saveEndpoint(_ baseURL: String, urlSetting: String, keySetting: String, credential: AICredentialUpdate,
                              authorizeDestinationChange: Bool, multiple: Bool) throws {
        Self.credentialMutationLock.lock()
        defer { Self.credentialMutationLock.unlock() }
        try register()
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try AIRequestBuilder.normalizedBaseURL(baseURL).absoluteString
        let previous = store.string(keySetting)
        let next: String?
        if credential == .remove { next = "" }
        else if url.isEmpty, credential == .unchanged { next = nil }
        else {
            let destination = try AICredentialDestination(settingKey: keySetting, baseURL: url, wireProtocol: .openAI)
            next = try AICredentialBinding.updated(credential, previous: previous, destination: destination, authorizeDestinationChange: authorizeDestinationChange, multiple: multiple)
        }
        if let next { try store.set(.string(next), for: keySetting) }
        do { try store.set(.string(url), for: urlSetting) }
        catch {
            if next != nil { try? store.set(.string(previous), for: keySetting) }
            throw error
        }
    }
}
