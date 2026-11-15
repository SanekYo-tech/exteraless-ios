import Foundation

/// The Tools boundary receives the exact public write set admitted by Cloud's
/// preview. Original archive metadata needed by credentials stays in the plan.
public enum CloudPublicRestoreProjection {
    static func make(_ inspection: ToolsBackupInspection, expected: ClientSettingsSnapshot) throws -> ToolsBackupInspection {
        let settingKeys = Set(inspection.settings.keys)
        guard settingKeys.isDisjoint(with: inspection.resetting), inspection.payload.pluginSettings.isEmpty else { throw CloudError.malformedRemote }
        let admitted = settingKeys.union(inspection.resetting)
        let definitions = Dictionary(uniqueKeysWithValues: expected.definitions.map { ($0.key, $0) })
        var values = inspection.settings
        for key in admitted {
            guard let definition = definitions[key], !definition.isSecret, !expected.secretKeys.contains(key) else { throw CloudError.malformedRemote }
            if inspection.resetting.contains(key) { values[key] = definition.defaultValue }
            guard let value = values[key] else { throw CloudError.malformedRemote }
            try definition.validate(value)
        }
        let payload = ToolsBackupPayload(createdAt: inspection.payload.createdAt, appVersion: inspection.payload.appVersion,
            clientSettings: values, clientStoredKeys: settingKeys)
        return ToolsBackupInspection(origin: inspection.origin, payload: payload, settings: inspection.settings,
            resetting: inspection.resetting, ignoredKeys: inspection.ignoredKeys)
    }

    /// A runtime check at the native host boundary also protects future callers.
    public static func validate(_ inspection: ToolsBackupInspection) throws {
        let settingKeys = Set(inspection.settings.keys)
        guard settingKeys.isDisjoint(with: inspection.resetting), inspection.payload.pluginSettings.isEmpty,
              Set(inspection.payload.clientSettings.keys) == settingKeys.union(inspection.resetting),
              inspection.payload.clientStoredKeys == settingKeys else { throw CloudError.malformedRemote }
        for (key, value) in inspection.settings {
            guard inspection.payload.clientSettings[key] == value else { throw CloudError.malformedRemote }
        }
    }
}
