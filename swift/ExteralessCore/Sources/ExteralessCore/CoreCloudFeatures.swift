import Foundation

public enum NewCloudFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        .init(key: "cloud.autoSync", title: "Automatically sync settings", section: "Cloud settings",
              defaultValue: .bool(false),
              explanation: "Sync changed configuration for the active account while the app is in the foreground. Conflicting remote revisions require review.",
              androidSymbols: ["CloudSettingsHelper.autoSync", "nekocloud.auto_sync"]),
        .init(key: "cloud.includeApiKeys", title: "Include service API keys", section: "Cloud settings",
              defaultValue: .bool(false),
              explanation: "Explicitly includes supported AI/translation service keys. The original Telegram bot cloud storage is transport-encrypted, not end-to-end encrypted. Telegram App hashes, account authorization keys and history are never included.",
              androidSymbols: ["CloudSettingsHelper.includeApiKeys", "nekocloud.include_api_keys"])
    ]

    /// Explicit import of aliases already in the selected native settings file.
    /// Android's global updated_at cannot be assigned to an arbitrary iOS account.
    public static func migrateAndroidAliases(in settings: ClientSettings) throws {
        try settings.register(definitions)
        try settings.migrateKey(from: "auto_sync", to: "cloud.autoSync")
        try settings.migrateKey(from: "include_api_keys", to: "cloud.includeApiKeys")
    }
}

public typealias CloudFeatures = NewCloudFeatures

public struct CloudSyncPolicy: Equatable, Sendable {
    public let autoSync: Bool
    public let includeApiKeys: Bool

    public init(autoSync: Bool, includeApiKeys: Bool) {
        self.autoSync = autoSync
        self.includeApiKeys = includeApiKeys
    }

    public init(snapshot: ClientSettingsSnapshot) {
        self.autoSync = snapshot.values["cloud.autoSync"] == .bool(true)
        self.includeApiKeys = snapshot.values["cloud.includeApiKeys"] == .bool(true)
    }
}
