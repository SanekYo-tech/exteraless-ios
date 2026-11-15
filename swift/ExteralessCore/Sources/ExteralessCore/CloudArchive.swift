import Foundation

/// The shared Tools archive owns its format and validation. Cloud selects portable
/// public preferences and adds a SEPARATE, typed opt-in service-key envelope.
public enum CloudArchivePolicy {
    private static let domains: Set<String> = ["appearance", "chats", "privacy", "ai", "tools", "player", "feed", "pills", "retention", "identity", "stickers", "dialogs", "network"]
    private static let excluded: Set<String> = [
        "privacy.botPrivacyUserId", "ai.translatorModeWithOriginalMigrated", "ai.translatorModeMigrationTarget",
        "ai.transcribeProviderCfAccountID", "tools.subtitleFolder", "tools.downloadFolder"
    ]

    public static func isPortable(_ definition: ClientSettingDefinition) -> Bool {
        let parts = definition.key.split(separator: ".")
        guard parts.count == 2, domains.contains(String(parts[0])), !definition.isSecret,
              !excluded.contains(definition.key), !ToolsBackupPolicy.isSensitiveKey(definition.key),
              !definition.key.hasPrefix("ai.translateInputLang_"), !definition.androidSymbols.isEmpty else { return false }
        switch definition.defaultValue {
        case .object, .array: return definition.key == "ai.services"
        default: return true
        }
    }

    public static func snapshot(_ snapshot: ClientSettingsSnapshot) throws -> ClientSettingsSnapshot {
        if snapshot.lastError != nil { throw CloudError.localStorage }
        let definitions = snapshot.definitions.filter { isPortable($0) && !snapshot.secretKeys.contains($0.key) }
        let keys = Set(definitions.map(\.key))
        var values = snapshot.values.filter { keys.contains($0.key) }
        if let value = values["ai.services"] {
            values["ai.services"] = try JSONDecoder().decode(ClientSettingValue.self, from: CloudProtocol.encode(services(value)))
        }
        return ClientSettingsSnapshot(definitions: definitions, values: values,
            storedKeys: snapshot.storedKeys.intersection(keys), secretKeys: snapshot.secretKeys)
    }

    static func services(_ value: ClientSettingValue?) throws -> [AIService] {
        guard let value else { return [] }
        do { try AIFeatures.servicesDefinition.validate(value) } catch { throw CloudError.malformedRemote }
        guard let services = try? JSONDecoder().decode([AIService].self, from: CloudProtocol.encode(value)), services.count <= 100,
              Set(services.map(\.id)).count == services.count else { throw CloudError.malformedRemote }
        for service in services {
            try CloudCredentialID.assistant(serviceId: service.id).validate()
            guard service.name.utf8.count <= 256, service.model.utf8.count <= 256,
                  (0...3).contains(service.reasoningEffort) else { throw CloudError.sizeLimit }
            do {
                _ = try AIRequestBuilder.normalizedBaseURL(service.url)
                try AIRequestBuilder.validateModel(service.model)
            } catch { throw CloudError.malformedRemote }
        }
        return services
    }
}

public struct CloudBackupEnvelope: Codable, Sendable, CustomStringConvertible, CustomReflectable {
    public let format: String
    public let version: Int
    public let owner: CloudRemoteOwner
    public let archive: Data
    public let includesApiKeys: Bool
    public let credentials: [CloudCredentialEntry]
    // Records the real source protection. No un-restorable device-only encryption
    // key or falsely labelled E2E scheme is introduced over the original protocol.
    public let protection: String

    public var description: String { "CloudBackupEnvelope(version: \(version), credentials: redacted)" }
    public var customMirror: Mirror { Mirror(self, children: ["version": version as Any, "credentials": "redacted" as Any]) }
}

public struct CloudPreparedBackup: Sendable {
    public let data: Data
    public let contentDigest: String
    public let settingCount: Int
    public let credentialCount: Int
}

public struct CloudRestorePlan: Sendable, CustomStringConvertible, CustomReflectable {
    public let revision: CloudRevision
    public let expectedHeads: Set<UUID>
    public let settingCount: Int
    public let credentialCount: Int
    public let ignoredCount: Int
    let envelope: CloudBackupEnvelope
    let inspection: ToolsBackupInspection
    let expectedSettings: ClientSettingsSnapshot

    /// The public-only shared archive inspection; credentials stay in this plan's
    /// separate typed envelope and never enter the Tools filesystem journal.
    public var publicInspection: ToolsBackupInspection { inspection }

    /// Use in ToolsBackupRestorer.beforeSettingsCommit. This is a no-change CAS
    /// against the preview. Tools then performs its own journalled forward CAS;
    /// a native edit between those two guards also makes the forward write fail.
    public func verifyLocalPreview(settings: ClientSettings) throws {
        let keys = Set(inspection.settings.keys).union(inspection.resetting)
        let stored = keys.intersection(expectedSettings.storedKeys)
        let values = expectedSettings.values.filter { stored.contains($0.key) }
        do { try settings.applyPublic(values, resetting: keys.subtracting(stored), expected: expectedSettings) }
        catch let error as ClientSettingsError {
            if error == .concurrentModification { throw CloudError.settingsChanged }
            throw error
        }
    }

    public var description: String { "CloudRestorePlan(settings: \(settingCount), credentials: \(credentialCount))" }
    public var customMirror: Mirror { Mirror(self, children: ["settings": settingCount, "credentials": credentialCount]) }
}

public struct CloudRestoreResult: Sendable, Equatable {
    public let settings: Int
    public let addedCredentials: Int
    public let retainedCredentials: Int
}

public enum CloudSettingsArchive {
    public static func prepare(snapshot: ClientSettingsSnapshot, owner: CloudRemoteOwner, appVersion: String,
                               includeApiKeys: Bool, credentials: any CloudCredentialStorage, date: Date = Date()) throws -> CloudPreparedBackup {
        let portable = try CloudArchivePolicy.snapshot(snapshot)
        let exported = try CloudCredentials.export(snapshot: snapshot, includeApiKeys: includeApiKeys, storage: credentials)
        let archive = try ToolsBackupArchive.export(snapshot: portable, appVersion: appVersion, plugins: nil, date: date)
        let envelope = CloudBackupEnvelope(format: "exteraless.cloud-settings", version: 1, owner: owner, archive: archive,
            includesApiKeys: includeApiKeys, credentials: exported, protection: "telegram-mtproto-transport")
        let data = try CloudProtocol.encode(envelope)
        guard data.count <= CloudProtocol.maximumPayloadBytes else { throw CloudError.sizeLimit }
        struct Fingerprint: Encodable {
            let settings: [String: ClientSettingValue]
            let storedKeys: [String]
            let credentials: [CloudCredentialEntry]
            let includeApiKeys: Bool
        }
        let content = try CloudProtocol.encode(Fingerprint(settings: portable.values, storedKeys: portable.storedKeys.sorted(),
                                                          credentials: exported, includeApiKeys: includeApiKeys))
        return CloudPreparedBackup(data: data, contentDigest: ToolsSHA256.hex(content),
                                   settingCount: portable.values.count, credentialCount: exported.count)
    }

    public static func inspect(_ data: Data, revision: CloudRevision, heads: Set<UUID>, owner: CloudRemoteOwner,
                               snapshot: ClientSettingsSnapshot) throws -> CloudRestorePlan {
        let envelope = try CloudProtocol.decode(CloudBackupEnvelope.self, data, limit: CloudProtocol.maximumPayloadBytes)
        guard envelope.format == "exteraless.cloud-settings", envelope.version == 1,
              envelope.protection == "telegram-mtproto-transport" else { throw CloudError.unsupportedVersion }
        guard envelope.owner == owner, revision.owner == owner else { throw CloudError.wrongAccount }
        guard envelope.includesApiKeys || envelope.credentials.isEmpty else { throw CloudError.malformedRemote }
        let portable = try CloudArchivePolicy.snapshot(snapshot)
        let inspection = try ToolsBackupArchive.inspect(envelope.archive, definitions: portable.definitions, secretKeys: snapshot.secretKeys)
        guard inspection.payload.pluginSettings.isEmpty else { throw CloudError.malformedRemote }
        // Never let an imported archive smuggle an API identity/history key through
        // an ignored/unknown field. Only already-registered portable values apply.
        guard !inspection.payload.clientSettings.keys.contains(where: { $0.hasPrefix("clientAPI.") || $0.hasPrefix("cloud.") || $0.hasPrefix("ai.history.") }) else {
            throw CloudError.malformedRemote
        }
        if let services = inspection.payload.clientSettings["ai.services"] { _ = try CloudArchivePolicy.services(services) }
        try CloudCredentials.validate(envelope.credentials, publicValues: inspection.payload.clientSettings)
        return CloudRestorePlan(revision: revision, expectedHeads: heads, settingCount: inspection.settingCount,
            credentialCount: envelope.credentials.count, ignoredCount: inspection.ignoredKeys.count,
            envelope: envelope, inspection: inspection, expectedSettings: snapshot)
    }

    /// One public file CAS, then add-only Keychain restoration. This deliberately
    /// does NOT promise a transaction across Keychain and the settings file.
    /// A late secure-store failure reports partial application, never success.
    public static func apply(_ plan: CloudRestorePlan, settings: ClientSettings, includeApiKeys: Bool,
                             credentials: any CloudCredentialStorage) throws -> CloudRestoreResult {
        try Task.checkCancellation()
        let entries = includeApiKeys ? plan.envelope.credentials : []
        if !entries.isEmpty { try CloudCredentials.register(entries, settings: settings) }
        do {
            try settings.applyPublic(plan.inspection.settings, resetting: plan.inspection.resetting, expected: plan.expectedSettings)
        } catch let error as ClientSettingsError {
            if error == .concurrentModification { throw CloudError.settingsChanged }
            throw CloudError.localStorage
        }
        return try restoreMissingCredentials(plan, settings: settings, includeApiKeys: includeApiKeys, credentials: credentials)
    }

    /// Call after the shared Tools public-settings transaction has committed.
    /// Existing Keychain values (including concurrent native edits) are retained.
    public static func restoreMissingCredentials(_ plan: CloudRestorePlan, settings: ClientSettings,
                                                 includeApiKeys: Bool, credentials: any CloudCredentialStorage,
                                                 permitKeys: @Sendable () -> Bool = { true }) throws -> CloudRestoreResult {
        let entries = includeApiKeys ? plan.envelope.credentials : []
        var inserted = 0
        var retained = 0
        do {
            if !entries.isEmpty { try CloudCredentials.register(entries, settings: settings) }
            // The commit phase finishes even if its screen is closed. Never undo a
            // credential that another native writer changed during this operation.
            for entry in entries {
                guard permitKeys() else { throw CloudError.restorePartiallyApplied }
                try CloudAICredentialBridge.validate(entry, metadata: plan.inspection.payload.clientSettings)
                switch try credentials.insertIfAbsent(entry) {
                case .inserted: inserted += 1
                case .alreadyPresent: retained += 1
                }
            }
            if !entries.isEmpty { try settings.reload() }
        } catch { throw CloudError.restorePartiallyApplied }
        return CloudRestoreResult(settings: plan.settingCount, addedCredentials: inserted, retainedCredentials: retained)
    }
}
