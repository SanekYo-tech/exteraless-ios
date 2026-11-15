import Foundation

/// Destination metadata is carried by the opted-in credential, never made a
/// blanket portable public preference. An existing local token keeps its account.
enum CloudCloudflareMetadata {
    static let accountKey = "ai.transcribeProviderCfAccountID"
    static let tokenKey = "ai.transcribeProviderCfApiToken"
    static let credential = CloudCredentialID.translation(.cloudflareAudio)

    static func validated(_ value: String) throws -> String {
        guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw CloudError.invalidCredential
        }
        return value
    }

    static func account(in metadata: [String: ClientSettingValue]) throws -> String {
        guard case let .string(value)? = metadata[accountKey] else { throw CloudError.invalidCredential }
        return try validated(value)
    }

    static func sourceMetadata(entries: [CloudCredentialEntry], metadata: [String: ClientSettingValue]) throws -> [String: ClientSettingValue] {
        var result = metadata
        for entry in entries where entry.id == credential {
            let source = try entry.cloudflareAccountID.map(validated) ?? account(in: metadata)
            if let value = metadata[accountKey], value != .string(source) { throw CloudError.invalidCredential }
            result[accountKey] = .string(source)
        }
        return result
    }

    static func publicInspection(_ inspection: ToolsBackupInspection, entries: [CloudCredentialEntry],
                                 metadata: [String: ClientSettingValue], expected: ClientSettingsSnapshot) throws -> ToolsBackupInspection {
        var values = inspection.settings
        var resetting = inspection.resetting
        var ignored = inspection.ignoredKeys
        values.removeValue(forKey: accountKey)
        resetting.remove(accountKey)
        if entries.contains(where: { $0.id == credential }), !expected.storedKeys.contains(tokenKey) {
            let source = try account(in: metadata)
            guard let definition = expected.definitions.first(where: { $0.key == accountKey }), !definition.isSecret,
                  !expected.secretKeys.contains(accountKey) else { throw CloudError.invalidCredential }
            guard case let .string(current)? = expected.values[accountKey], current.isEmpty || current == source else {
                throw CloudError.credentialDestinationConflict
            }
            values[accountKey] = try definition.validatedValue(.string(source))
            ignored.removeAll { $0 == accountKey }
        } else if inspection.payload.clientSettings[accountKey] != nil || entries.contains(where: { $0.id == credential }) {
            if !ignored.contains(accountKey) { ignored.append(accountKey) }
        }
        return ToolsBackupInspection(origin: inspection.origin, payload: inspection.payload, settings: values,
            resetting: resetting, ignoredKeys: ignored.sorted())
    }

    /// Recheck real secure presence before public commit, not just the preview's
    /// cached presence. A token installed since preview requires a new review.
    static func verifyTarget(inspection: ToolsBackupInspection, includeApiKeys: Bool,
                             storage: any CloudCredentialStorage) throws {
        guard inspection.settings[accountKey] != nil else { return }
        guard includeApiKeys, try storage.read(credential) == nil else { throw CloudError.settingsChanged }
    }
}
