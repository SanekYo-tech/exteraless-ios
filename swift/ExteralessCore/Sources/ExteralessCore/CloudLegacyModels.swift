import Foundation

public enum CloudLegacyDisposition: String, Sendable { case mapped, skipped, credential }

public enum CloudLegacySkipReason: String, Sendable {
    case unsupportedSetting, nativeUnavailable, incompatibleType, invalidValue, unsupportedOption
    case androidSystem, deviceOrAccountState, excludedCredential, privateContent, credentialsDisabled
    case missingEndpoint, malformedServices, conflictingFields, missingServiceMetadata, stockTelegramPreference, requiresNativeResources

    public var explanation: String {
        switch self {
        case .unsupportedSetting: return "No audited native conversion for this preference."
        case .nativeUnavailable: return "The native setting is not registered in this installation."
        case .incompatibleType: return "The source type/suffix or native type does not match the audited conversion."
        case .invalidValue: return "The value does not satisfy the native schema or source bounds."
        case .unsupportedOption: return "This Android option has no reviewed native equivalent."
        case .androidSystem: return "Android-specific system, hardware, push or file-provider preference."
        case .deviceOrAccountState: return "Device/account state cannot be reassigned to this account."
        case .excludedCredential: return "Authorization, session, passcode and Telegram App credentials are excluded."
        case .privateContent: return "Private history, prompts and personal records are not imported by this settings action."
        case .credentialsDisabled: return "Service-key inclusion is off; no credential is imported."
        case .missingEndpoint: return "No matching validated endpoint was included in this selected backup."
        case .malformedServices: return "Service metadata is not the supported closed Android service schema."
        case .conflictingFields: return "Multiple source fields disagree about this native setting."
        case .missingServiceMetadata: return "Selection requires service metadata from the same backup."
        case .stockTelegramPreference: return "Requires a native Telegram preferences adapter; it is not part of the ClientSettings CAS archive."
        case .requiresNativeResources: return "The settings backup does not include compatible native assets or model packages."
        }
    }
}

public struct CloudLegacyFieldReport: Sendable {
    public let sourcePreference: String
    public let originalIDs: [String]
    public let nativeKeys: [String]
    public let disposition: CloudLegacyDisposition
    public let reason: CloudLegacySkipReason?
    public let detail: String?
}

public struct CloudLegacyRemoteSnapshot: Sendable, CustomStringConvertible, CustomReflectable {
    public let owner: CloudRemoteOwner
    public let fingerprint: String
    public let reportedUpdatedAtMilliseconds: Int64?
    let data: Data

    public var description: String { "CloudLegacyRemoteSnapshot(payload: redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["payload": "redacted"]) }
}

public struct CloudLegacyRestorePlan: Sendable, CustomStringConvertible, CustomReflectable {
    public let owner: CloudRemoteOwner
    public let remoteFingerprint: String
    public let reportedUpdatedAtMilliseconds: Int64?
    public let fields: [CloudLegacyFieldReport]
    public let includedApiKeys: Bool
    public let publicInspection: ToolsBackupInspection
    let expectedSettings: ClientSettingsSnapshot
    let credentials: [CloudCredentialEntry]

    public var mapped: [CloudLegacyFieldReport] { fields.filter { $0.disposition == .mapped } }
    public var skipped: [CloudLegacyFieldReport] { fields.filter { $0.disposition == .skipped } }
    public var credentialGroups: [CloudLegacyFieldReport] { fields.filter { $0.disposition == .credential } }
    public var settingCount: Int { publicInspection.settingCount }
    public var credentialCount: Int { credentials.count }

    public func verifyLocalPreview(settings: ClientSettings) throws {
        let keys = Set(publicInspection.settings.keys)
        let stored = keys.intersection(expectedSettings.storedKeys)
        try settings.applyPublic(expectedSettings.values.filter { stored.contains($0.key) },
            resetting: keys.subtracting(stored), expected: expectedSettings)
    }

    public var description: String { "CloudLegacyRestorePlan(mapped: \(mapped.count), skipped: \(skipped.count), keys: \(credentialCount))" }
    public var customMirror: Mirror { Mirror(self, children: ["mapped": mapped.count, "skipped": skipped.count, "credentials": credentialCount]) }
}

enum CloudLegacyJSON {
    /// Original Gson/SharedPreferences output has unique object keys. Reject a
    /// duplicate before a dictionary decoder can silently choose an endpoint/key.
    static func decode(_ data: Data) throws -> [String: ClientSettingValue] {
        guard case let .object(value) = try decodeValue(data) else { throw CloudError.malformedRemote }
        return value
    }

    static func decodeValue(_ data: Data) throws -> ClientSettingValue {
        try ToolsFileSafety.checkJSON(data, maximumBytes: CloudProtocol.maximumPayloadBytes)
        struct Frame { let object: Bool; var expectsKey: Bool; var keys: Set<String> = [] }
        var stack: [Frame] = []
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: stack.append(Frame(object: true, expectsKey: true))
            case 91: stack.append(Frame(object: false, expectsKey: false))
            case 125, 93:
                guard !stack.isEmpty else { throw CloudError.malformedRemote }
                stack.removeLast()
            case 44:
                if !stack.isEmpty, stack[stack.count - 1].object { stack[stack.count - 1].expectsKey = true }
            case 34:
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    if escaped { escaped = false }
                    else if bytes[index] == 92 { escaped = true }
                    else if bytes[index] == 34 { break }
                    index += 1
                }
                guard index < bytes.count else { throw CloudError.malformedRemote }
                if !stack.isEmpty, stack[stack.count - 1].object, stack[stack.count - 1].expectsKey {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard stack[stack.count - 1].keys.insert(key).inserted else { throw CloudError.malformedRemote }
                    stack[stack.count - 1].expectsKey = false
                }
            default: break
            }
            index += 1
        }
        return try JSONDecoder().decode(ClientSettingValue.self, from: data)
    }
}
