import Foundation

/// Independent from PrivacyFeatures (ghost mode). Collection values are scoped by
/// account record, Telegram user and environment, never by an Android account slot.
public enum PrivacyExtrasFeatures {
    public static let definitions: [ClientSettingDefinition] = [
        flag("ignoreBlocked", "Hide blocked senders locally", false, owner: "NekoConfig"),
        flag("regexFiltersEnabled", "Filter messages by text", false),
        flag("regexFiltersEnableInChats", "Use shared text rules in private chats", false),
        flag("zalgoFilter", "Filter excessive combining marks in displayed text", false),
        flag("forwardProtectedAsCopy", "Offer protected content as a new copy", false),
        ClientSettingDefinition(key: "privacy.ignoreContentRestrictions", title: "Ignore local content restriction notices", section: "Local filters", defaultValue: .bool(true), explanation: "Only changes presentation of content Telegram has supplied. Does not remove a server ban, fetch missing content, or change sensitive-content consent.", androidSymbols: ["NekoConfig.ignoreContentRestrictions"]),
        collection("blockedChannelsData", "Locally filtered channels"),
        collection("customFilteredUsersData", "Locally filtered users"),
        collection("regexFiltersData", "Shared text rules"),
        collection("regexChatFiltersData", "Chat-specific text rules"),
        collection("regexFiltersExcludedDialogs", "Chats excluded from text filtering")
    ]

    /// Register ONLY in the native private store, not in the generic settings/UI
    /// or plugin bridge. Mutations require a native settings PasscodeSession.
    public static let privateDefinitions: [ClientSettingDefinition] = [
        privateValue("accountHidden", .object([:]), "Per-account hidden flag; absent is false."),
        privateValue("accountAllowPanic", .object([:]), "Per-account panic eligibility; absent is true."),
        privateValue("settingsHidden", .bool(false), "Hide the hidden-account settings entry."),
        privateValue("settingsKey", .string(""), "Generated recovery-route capability."),
        privateValue("passcodeHash", .object([:]), "Salted account-code verifiers, with their input kind."),
        privateValue("panicPasscode", .object([:]), "Explicitly configured panic-code verifier.")
    ]

    public static let filteringKeys = Set(definitions.map(\.key))

    private static func flag(_ field: String, _ title: String, _ value: Bool, owner: String = "NaConfig") -> ClientSettingDefinition {
        ClientSettingDefinition(key: "privacy." + field, title: title, section: "Local filters", defaultValue: .bool(value), androidSymbols: [owner + "." + field])
    }

    private static func collection(_ field: String, _ title: String) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "privacy." + field, title: title, section: "Local filters", defaultValue: .object([:]), explanation: "Managed by Local filters for this account. iOS uses account-scoped native peer identities instead of Android's global JSON array.", androidSymbols: ["NaConfig." + field])
    }

    private static func privateValue(_ field: String, _ value: ClientSettingValue, _ explanation: String) -> ClientSettingDefinition {
        ClientSettingDefinition(key: "privacy." + field, title: field, section: "Hidden accounts", defaultValue: value, isSecret: true, explanation: explanation, androidSymbols: ["PasscodeHelper." + field])
    }
}

public struct PrivacyExtrasAccountIdentity: Hashable, Codable, Sendable {
    public let recordId: Int64
    public let userId: Int64
    public let testingEnvironment: Bool

    public init(recordId: Int64, userId: Int64, testingEnvironment: Bool) {
        self.recordId = recordId
        self.userId = userId
        self.testingEnvironment = testingEnvironment
    }

    public var storageKey: String {
        "\(testingEnvironment ? "test" : "production"):\(recordId):\(userId)"
    }
}
