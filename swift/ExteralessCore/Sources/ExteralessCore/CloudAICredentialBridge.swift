import Foundation

/// The single Cloud -> native AI credential boundary. Binding records are created
/// and checked by AICredentials.swift, never recreated from a copied JSON schema.
/// Public metadata alone cannot authorize/rebind an existing native credential.
enum CloudAICredentialBridge {
    static func exportValue(_ raw: String, id: CloudCredentialID,
                            metadata: [String: ClientSettingValue]) throws -> String? {
        if isVariable(id) {
            guard let destination = try destination(id, metadata: metadata) else { return nil }
            let key = AICredentialBinding.read(raw, destination: destination)
            guard !key.isEmpty else { return nil } // Unbound or another origin: do not leak it.
            _ = try AICredentialBinding.validated(key, multiple: multiple(id))
            return raw // Preserve the complete native destination-bound value.
        }
        guard !raw.isEmpty else { return nil }
        _ = try AICredentialBinding.validated(raw, multiple: multiple(id))
        return raw
    }

    /// Called only for an inline key from a selected Android backup. The new key
    /// is bound to THAT validated snapshot, never a mutable live URL or an old key.
    static func importedAndroid(_ raw: String, id: CloudCredentialID,
                                metadata: [String: ClientSettingValue]) throws -> CloudCredentialEntry {
        let value: String
        if isVariable(id) {
            guard let destination = try destination(id, metadata: metadata),
                  let bound = try AICredentialBinding.updated(.replace(raw), previous: "", destination: destination,
                    authorizeDestinationChange: false, multiple: multiple(id)) else { throw CloudError.invalidCredential }
            value = bound
        } else {
            value = try AICredentialBinding.validated(raw, multiple: multiple(id))
        }
        let account: String?
        if id == CloudCloudflareMetadata.credential { account = try CloudCloudflareMetadata.account(in: metadata) }
        else { account = nil }
        return try CloudCredentialEntry(id: id, value: value, cloudflareAccountID: account)
    }

    static func validate(_ entry: CloudCredentialEntry, metadata: [String: ClientSettingValue]) throws {
        let value = try entry.withValue { try exportValue($0, id: entry.id, metadata: metadata) }
        if value != nil { return }
        // Older native archives may contain raw variable-endpoint keys. Preserve
        // them as UNBOUND values; never infer a binding from restored public URLs.
        // A mismatched protected record contains the native envelope newline and
        // fails native raw-key validation, so its binding cannot be stripped.
        guard isVariable(entry.id) else { throw CloudError.invalidCredential }
        do { try entry.withValue { _ = try AICredentialBinding.validated($0, multiple: multiple(entry.id)) } }
        catch { throw CloudError.invalidCredential }
    }

    static func destinationLabel(_ id: CloudCredentialID, metadata: [String: ClientSettingValue]) throws -> String? {
        if id == CloudCloudflareMetadata.credential {
            return "https://api.cloudflare.com/client/v4/accounts/" + (try CloudCloudflareMetadata.account(in: metadata)) + "/ai/run · Workers AI"
        }
        guard let destination = try destination(id, metadata: metadata) else { return nil }
        return "\(destination.scheme)://\(destination.host):\(destination.port)\(destination.path) · \(destination.wireProtocol.rawValue)"
    }

    private static func isVariable(_ id: CloudCredentialID) -> Bool {
        switch id {
        case .assistant, .llm(preset: .custom), .translation(.openAIAudio): return true
        default: return false
        }
    }

    private static func multiple(_ id: CloudCredentialID) -> Bool {
        if case .llm = id { return true }
        return false
    }

    private static func destination(_ id: CloudCredentialID, metadata: [String: ClientSettingValue]) throws -> AICredentialDestination? {
        try id.validate()
        let url: String
        let wireProtocol: AIWireProtocol
        switch id {
        case let .assistant(serviceId):
            let services = try CloudArchivePolicy.services(metadata["ai.services"])
            guard let service = services.first(where: { $0.id == serviceId }) ?? (serviceId == AIService.default.id ? AIService.default : nil) else {
                throw CloudError.invalidCredential
            }
            url = service.url
            wireProtocol = service.wireProtocol
        case .llm(preset: .custom):
            guard case let .string(value)? = metadata["ai.llmApiUrl"], !value.isEmpty else { return nil }
            url = value
            wireProtocol = .openAI
        case .translation(.openAIAudio):
            guard case let .string(value)? = metadata["ai.transcribeProviderOpenAiApiBase"], !value.isEmpty else { return nil }
            url = value
            wireProtocol = .openAI
        default: return nil // Fixed provider destinations are defined by native AI code.
        }
        return try AICredentialDestination(settingKey: id.settingKey, baseURL: url, wireProtocol: wireProtocol)
    }
}
