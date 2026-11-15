import Foundation

public enum ClientAPIEnvironment: String, Codable, CaseIterable, Sendable {
    case production, test

    public var settingPrefix: String { self == .production ? "clientAPI." : "clientAPI.test." }
}

/// The original selector uses 0 (built in) and 3 (custom), not a boolean.
public enum ClientAPIMode: Int, Codable, Sendable {
    case builtIn = 0
    case custom = 3
}

public enum ClientAPIFeatures {
    /// These fields are edited together by the native Client API screen.
    public static func requiresNativeEditor(_ key: String) -> Bool { key.hasPrefix("clientAPI.") }

    public static let definitions: [ClientSettingDefinition] = ClientAPIEnvironment.allCases.flatMap { environment in
        let prefix = environment.settingPrefix
        let section = environment == .production ? "Client API" : "Client API · test server"
        let policy = "Applies to new authorization flows after restarting the app. Existing accounts and an already-started login retain their API identity. Disabling keeps the saved draft."
        return [
            ClientSettingDefinition(key: prefix + "customApi", title: "API identity", section: section,
                defaultValue: .integer(0), options: [
                    .init(value: .integer(0), title: "Built-in API"),
                    .init(value: .integer(3), title: "Custom API")
                ], explanation: policy, androidSymbols: ["NekoXConfig.customApi"]),
            ClientSettingDefinition(key: prefix + "customAppId", title: "App ID", section: section,
                defaultValue: .integer(0), minimum: 0, maximum: Double(Int32.max), step: 1,
                explanation: "Use the Client API editor to save the ID and hash together. " + policy,
                androidSymbols: ["NekoXConfig.customAppId"]),
            ClientSettingDefinition(key: prefix + "customAppHash", title: "App hash", section: section,
                defaultValue: .string(""), isSecret: true,
                explanation: "Stored in native Keychain. Never included in settings/cloud exports. " + policy,
                androidSymbols: ["NekoXConfig.customAppHash"])
        ]
    }
}
