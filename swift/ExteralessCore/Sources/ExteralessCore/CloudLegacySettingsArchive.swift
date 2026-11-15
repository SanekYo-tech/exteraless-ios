import Foundation

public enum CloudLegacySettingsArchive {
    public static func inspect(_ remote: CloudLegacyRemoteSnapshot, snapshot: ClientSettingsSnapshot,
                               includeApiKeys: Bool, date: Date = Date()) throws -> CloudLegacyRestorePlan {
        guard snapshot.lastError == nil else { throw CloudError.localStorage }
        let root = try CloudLegacyJSON.decode(remote.data)
        guard !Set(root.keys).isDisjoint(with: ["nkmrcfg", "mainconfig", "userconfing", "aiConfig"]), root.count <= 32 else { throw CloudError.malformedRemote }
        var sections: [String: [String: ClientSettingValue]] = [:]
        var count = 0
        for (name, value) in root {
            guard name.utf8.count <= 128, case let .object(fields) = value else { throw CloudError.malformedRemote }
            count += fields.count
            guard count <= 4_096, fields.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else { throw CloudError.sizeLimit }
            sections[name] = fields
        }
        let originalChatPreferences = sections["nkmrcfg"] ?? [:]
        if sections["nkmrcfg"] != nil {
            sections["nkmrcfg"] = ChatLegacyPreferenceMigration.apply(to: originalChatPreferences)
        }
        let definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.key, $0) })
        var patch: [String: ClientSettingValue] = [:]
        var reports: [CloudLegacyFieldReport] = []
        var credentials: [CloudCredentialEntry] = []
        var pendingKeys: [(String, String, String, ClientSettingValue, CloudCredentialID)] = []
        var conflicting = Set<String>()
        let neko = sections["nkmrcfg"] ?? [:]
        let ai = sections["aiConfig"] ?? [:]

        func report(_ section: String, _ key: String, _ ids: [String], _ disposition: CloudLegacyDisposition,
                    native: [String] = [], reason: CloudLegacySkipReason? = nil, detail: String? = nil) {
            reports.append(CloudLegacyFieldReport(sourcePreference: section + "." + key, originalIDs: ids,
                nativeKeys: native, disposition: disposition, reason: reason, detail: detail))
        }
        func assign(_ value: ClientSettingValue, key: String) throws {
            guard !conflicting.contains(key) else { throw CloudLegacySkipReason.conflictingFields }
            if let existing = patch[key], existing != value {
                conflicting.insert(key)
                patch.removeValue(forKey: key)
                throw CloudLegacySkipReason.conflictingFields
            }
            patch[key] = value
        }

        for section in sections.keys.sorted() {
            for (key, value) in (sections[section] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let ids = CloudLegacyCatalog.ids(section: section, key: key)
                guard section == "nkmrcfg" || section == "aiConfig" else {
                    report(section, key, ids, .skipped, reason: excludedSection(section, key: key))
                    continue
                }
                if section == "aiConfig", ["services", "selectedServiceId", "selectedService"].contains(key) { continue }
                if section == "nkmrcfg", key == "TranslatorModeWithOriginalMigrated" { continue }
                if section == "nkmrcfg", ["DisableChannelMuteButton", "HideReactions", "MessageColoredBackground"].contains(key) { continue }
                guard ids.count == 1, let id = ids.first else {
                    report(section, key, ids, .skipped, reason: ToolsBackupPolicy.isSensitiveKey(key) ? .excludedCredential : .unsupportedSetting)
                    continue
                }
                if let credential = CloudLegacyAIImport.credentialAliases[id] {
                    pendingKeys.append((section, key, id, value, credential))
                    continue
                }
                if id == "nagram.transcribeProviderCfAccountID", !includeApiKeys {
                    report(section, key, ids, .skipped, reason: .credentialsDisabled)
                    continue
                }
                guard let rule = CloudLegacyRules.rules[id] else {
                    report(section, key, ids, .skipped, reason: excludedField(id))
                    continue
                }
                guard let definition = definitions[rule.key], !definition.isSecret, !snapshot.secretKeys.contains(rule.key) else {
                    report(section, key, ids, .skipped, reason: .nativeUnavailable)
                    continue
                }
                if id == "nagram.translatorMode", definitions["ai.translatorModeWithOriginalMigrated"] == nil {
                    report(section, key, ids, .skipped, reason: .nativeUnavailable)
                    continue
                }
                do {
                    let suffix = ["_long", "_float"].first(where: { key.hasSuffix($0) })
                    let converted = try CloudLegacyRules.convert(value, rule: rule, suffix: suffix, nkmrcfg: neko, definition: definition)
                    try assign(converted, key: rule.key)
                    let detail: String
                    if id == "nagram.transcribeProviderCfAccountID" { detail = "Service account metadata (key inclusion explicitly enabled)." }
                    else if let option = definition.options.first(where: { $0.value == converted }) { detail = "Native option: " + option.title }
                    else {
                        switch converted {
                        case let .bool(value): detail = value ? "Native value: On" : "Native value: Off"
                        case let .integer(value): detail = "Native value: \(value)"
                        case let .number(value): detail = "Native value: \(value)"
                        case let .string(value): detail = "Native value: " + String(value.prefix(160))
                        default: detail = "Validated native value."
                        }
                    }
                    if id == "nagram.defaultHlsVideoQuality", originalChatPreferences["DefaultHlsVideoQuality"] == .integer(1) {
                        report(section, key, ids, .mapped, native: [rule.key, "chats.preferOriginalQuality"],
                            detail: "Legacy value 1 enables Prefer highest video quality; the streaming selector becomes Auto.")
                    } else {
                        report(section, key, ids, .mapped, native: [rule.key], detail: detail)
                    }
                } catch {
                    report(section, key, ids, .skipped, reason: (error as? CloudLegacySkipReason) ?? .invalidValue)
                }
            }
        }
        if patch["ai.translatorMode"] != nil, let definition = definitions["ai.translatorModeWithOriginalMigrated"], !definition.isSecret {
            patch[definition.key] = try definition.validatedValue(.bool(true))
            if neko["TranslatorModeWithOriginalMigrated"] != nil {
                report("nkmrcfg", "TranslatorModeWithOriginalMigrated", ["nagram.translatorModeWithOriginalMigrated"], .mapped,
                    native: [definition.key], detail: "Recorded after applying the source version's mode conversion.")
            }
        } else if neko["TranslatorModeWithOriginalMigrated"] != nil {
            report("nkmrcfg", "TranslatorModeWithOriginalMigrated", ["nagram.translatorModeWithOriginalMigrated"], .skipped, reason: .deviceOrAccountState)
        }

        let chatAliases: [(String, Bool, [String])] = [
            ("DisableChannelMuteButton", true, ["chats.bottomButton"]),
            ("HideReactions", true, ["chats.hideReactionsInChannels", "chats.hideReactionsInGroups", "chats.hideReactionsInPrivate"]),
            ("MessageColoredBackground", false, ["chats.replyBackground"])
        ]
        for (source, activeValue, targets) in chatAliases {
            guard let value = originalChatPreferences[source] else { continue }
            guard case let .bool(enabled) = value else {
                report("nkmrcfg", source, CloudLegacyCatalog.ids(section: "nkmrcfg", key: source), .skipped, reason: .incompatibleType)
                continue
            }
            let native = enabled == activeValue ? targets.filter { patch[$0] != nil } : []
            report("nkmrcfg", source, CloudLegacyCatalog.ids(section: "nkmrcfg", key: source), native.isEmpty ? .skipped : .mapped,
                native: native, reason: native.isEmpty ? .unsupportedSetting : nil,
                detail: native.isEmpty ? "Inactive or unavailable legacy alias; no native override was synthesized." : "Source-defined ChatsConfig migration; canonical controls receive the imported value.")
        }

        if let value = ai["services"] {
            do {
                guard let definition = definitions["ai.services"], !definition.isSecret, !snapshot.secretKeys.contains("ai.services") else { throw CloudLegacySkipReason.nativeUnavailable }
                let records = try CloudLegacyAIImport.services(value)
                let metadata = try JSONDecoder().decode(ClientSettingValue.self, from: CloudProtocol.encode(records.map(\.service)))
                try AIFeatures.servicesDefinition.validate(metadata)
                patch["ai.services"] = try definition.validatedValue(metadata)
                report("aiConfig", "services", ["ai.services"], .mapped, native: ["ai.services"], detail: "\(records.count) closed service records; inline keys are separate.")
                if let selectedDefinition = definitions["ai.selectedServiceId"], !selectedDefinition.isSecret, !snapshot.secretKeys.contains(selectedDefinition.key) {
                    let selected = try CloudLegacyAIImport.selected(records, preferences: ai)
                    patch[selectedDefinition.key] = try selectedDefinition.validatedValue(.string(selected))
                    for key in ["selectedServiceId", "selectedService"] where ai[key] != nil {
                        report("aiConfig", key, CloudLegacyCatalog.ids(section: "aiConfig", key: key), .mapped,
                            native: [selectedDefinition.key], detail: "Stable ID first, then original Java hash, then first service.")
                    }
                } else {
                    for key in ["selectedServiceId", "selectedService"] where ai[key] != nil {
                        report("aiConfig", key, CloudLegacyCatalog.ids(section: "aiConfig", key: key), .skipped, reason: .nativeUnavailable)
                    }
                }
                for (index, record) in records.enumerated() {
                    if let key = record.incomingKey, !key.isEmpty {
                        pendingKeys.append(("aiConfig", "services[\(index)].key", "ai.services", .string(key), .assistant(serviceId: record.service.id)))
                    }
                }
            } catch {
                patch.removeValue(forKey: "ai.services")
                patch.removeValue(forKey: "ai.selectedServiceId")
                reports.removeAll { ["aiConfig.services", "aiConfig.selectedServiceId", "aiConfig.selectedService"].contains($0.sourcePreference) }
                report("aiConfig", "services", ["ai.services"], .skipped, reason: (error as? CloudLegacySkipReason) ?? .malformedServices)
                for key in ["selectedServiceId", "selectedService"] where ai[key] != nil {
                    report("aiConfig", key, CloudLegacyCatalog.ids(section: "aiConfig", key: key), .skipped, reason: .missingServiceMetadata)
                }
            }
        } else {
            for key in ["selectedServiceId", "selectedService"] where ai[key] != nil {
                report("aiConfig", key, CloudLegacyCatalog.ids(section: "aiConfig", key: key), .skipped, reason: .missingServiceMetadata)
            }
        }
        for (section, key, id, value, credential) in pendingKeys {
            guard includeApiKeys else { report(section, key, [id], .skipped, reason: .credentialsDisabled); continue }
            do {
                guard case let .string(raw) = value, !raw.isEmpty else { throw CloudLegacySkipReason.invalidValue }
                if case .assistant = credential {} else {
                    guard snapshot.secretKeys.contains(credential.settingKey) else { throw CloudLegacySkipReason.nativeUnavailable }
                }
                let entry = try CloudAICredentialBridge.importedAndroid(raw, id: credential, metadata: patch)
                credentials.append(entry)
                let destination = try CloudAICredentialBridge.destinationLabel(credential, metadata: patch)
                report(section, key, [id], .credential, native: [credential.settingKey],
                    detail: destination ?? "Native fixed-provider destination; existing keys are retained.")
            } catch {
                report(section, key, [id], .skipped, reason: (error as? CloudLegacySkipReason) ?? .missingEndpoint)
            }
        }
        if !conflicting.isEmpty {
            reports = reports.map { item in
                guard !Set(item.nativeKeys).isDisjoint(with: conflicting) else { return item }
                return CloudLegacyFieldReport(sourcePreference: item.sourcePreference, originalIDs: item.originalIDs,
                    nativeKeys: [], disposition: .skipped, reason: .conflictingFields, detail: nil)
            }
        }
        if originalChatPreferences["DefaultHlsVideoQuality"] == .integer(1) {
            reports = reports.map { item in
                guard item.disposition == .mapped, item.originalIDs.contains("nagram.defaultHlsVideoQuality") else { return item }
                let keys = ["chats.defaultHlsVideoQuality", "chats.preferOriginalQuality"].filter { patch[$0] != nil }
                return CloudLegacyFieldReport(sourcePreference: item.sourcePreference, originalIDs: item.originalIDs,
                    nativeKeys: keys, disposition: .mapped, reason: nil, detail: item.detail)
            }
        }
        let payload = ToolsBackupPayload(createdAt: ISO8601DateFormatter().string(from: date), appVersion: "Android cloud import",
            clientSettings: patch, clientStoredKeys: Set(patch.keys))
        let originalInspection = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload), definitions: snapshot.definitions, secretKeys: snapshot.secretKeys)
        let credentialMetadata = try CloudCloudflareMetadata.sourceMetadata(entries: credentials, metadata: patch)
        let candidate = try CloudCloudflareMetadata.publicInspection(originalInspection, entries: credentials, metadata: credentialMetadata, expected: snapshot)
        let inspection = try CloudPublicRestoreProjection.make(candidate, expected: snapshot)
        if patch[CloudCloudflareMetadata.accountKey] != nil, inspection.settings[CloudCloudflareMetadata.accountKey] == nil {
            reports = reports.map { item in
                guard item.nativeKeys.contains(CloudCloudflareMetadata.accountKey) else { return item }
                return CloudLegacyFieldReport(sourcePreference: item.sourcePreference, originalIDs: item.originalIDs,
                    nativeKeys: [], disposition: .skipped, reason: snapshot.storedKeys.contains(CloudCloudflareMetadata.tokenKey) ? .existingCredential : .missingServiceMetadata, detail: nil)
            }
        }
        return CloudLegacyRestorePlan(owner: remote.owner, remoteFingerprint: remote.fingerprint,
            reportedUpdatedAtMilliseconds: remote.reportedUpdatedAtMilliseconds, fields: reports,
            includedApiKeys: includeApiKeys, publicInspection: inspection, expectedSettings: snapshot, credentials: credentials, credentialMetadata: credentialMetadata)
    }

    public static func apply(_ plan: CloudLegacyRestorePlan, settings: ClientSettings,
                             includeApiKeys: Bool, credentials: any CloudCredentialStorage) throws -> CloudRestoreResult {
        try Task.checkCancellation()
        try plan.verifyCredentialTarget(includeApiKeys: includeApiKeys, storage: credentials)
        try settings.applyPublic(plan.publicInspection.settings, expected: plan.expectedSettings)
        return try restoreMissingCredentials(plan, settings: settings, includeApiKeys: includeApiKeys, credentials: credentials)
    }

    public static func restoreMissingCredentials(_ plan: CloudLegacyRestorePlan, settings: ClientSettings,
        includeApiKeys: Bool, credentials: any CloudCredentialStorage, permitKeys: @Sendable () -> Bool = { true }) throws -> CloudRestoreResult {
        let entries = includeApiKeys && plan.includedApiKeys ? plan.credentials : []
        var added = 0, retained = 0
        do {
            try CloudCredentials.validate(entries, publicValues: plan.credentialMetadata)
            if !entries.isEmpty { try CloudCredentials.register(entries, settings: settings) }
            for entry in entries {
                guard permitKeys() else { throw CloudError.restorePartiallyApplied }
                switch try credentials.insertIfAbsent(entry) {
                case .inserted: added += 1
                case .alreadyPresent: retained += 1
                }
            }
            if !entries.isEmpty { try settings.reload() }
        } catch { throw CloudError.restorePartiallyApplied }
        return CloudRestoreResult(settings: plan.settingCount, addedCredentials: added, retainedCredentials: retained)
    }

    private static func excludedSection(_ section: String, key: String) -> CloudLegacySkipReason {
        if section == "nekox_config" || ToolsBackupPolicy.isSensitiveKey(key) { return .excludedCredential }
        if section == "userconfing", ["passcodeHash", "passcodeType", "autoLockIn", "useFingerprint"].contains(key) { return .excludedCredential }
        if section == "nekocloud" { return .deviceOrAccountState }
        if section == "userconfing" || section == "mainconfig" || section == "themeconfig" { return .stockTelegramPreference }
        return .unsupportedSetting
    }

    private static func excludedField(_ id: String) -> CloudLegacySkipReason {
        if id.hasPrefix("glyph.") || id == "icons.useSystemIconShape" || id.contains("pushService") || ["neko.disableSystemAccount", "neko.cachePath", "neko.customSavePath", "neko.typeface", "nagram.notificationIcon"].contains(id) { return .androidSystem }
        if id.hasPrefix("icons.") { return .requiresNativeResources }
        if ["ai.roles", "ai.history"].contains(id) || id.contains("Prompt") || id.hasSuffix("Data") || id.hasPrefix("localnamehelper.") { return .privateContent }
        if id == "dialog.customForumTabsEnable" { return .deviceOrAccountState }
        if id.contains("Cache") || id.contains("Migrated") || id.contains("lastActive") || id == "translator.inputTranslateLangForChat" { return .deviceOrAccountState }
        if ToolsBackupPolicy.isSensitiveKey(id) { return .excludedCredential }
        return .unsupportedSetting
    }
}
