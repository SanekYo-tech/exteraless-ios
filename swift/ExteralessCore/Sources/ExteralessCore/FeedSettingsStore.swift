import Foundation

/// The original FeedConfig fields remain one set of account-keyed public definitions.
/// A membership edit commits all read dependencies in one applyPublic CAS operation.
public final class FeedSettingsStore: Sendable {
    public static let keys: Set<String> = ["chats.includeArchived", "chats.addNewChannels", "chats.excludedChannels", "chats.knownChannels"]
    public let settings: ClientSettings

    public init(settings: ClientSettings) { self.settings = settings }

    public func read(account: String) -> ChatFeedConfiguration {
        Self.configuration(account: account, snapshot: self.settings.readSnapshot())
    }

    public static func configuration(account: String, snapshot: ClientSettingsSnapshot) -> ChatFeedConfiguration {
        func value(_ field: String) -> ClientSettingValue? {
            guard case let .object(accounts)? = snapshot.values["chats." + field] else { return nil }
            return accounts[account]
        }
        func flag(_ field: String, fallback: Bool) -> Bool {
            if case let .bool(result)? = value(field) { return result }
            return fallback
        }
        func ids(_ field: String) -> Set<Int64> {
            guard case let .array(values)? = value(field) else { return [] }
            return Set(values.compactMap { value in
                if case let .string(id) = value { return Int64(id) }
                if case let .integer(id) = value { return id }
                return nil
            })
        }
        return ChatFeedConfiguration(includeArchived: flag("includeArchived", fallback: false), addNewChannels: flag("addNewChannels", fallback: true), excludedChannels: ids("excludedChannels"), knownChannels: ids("knownChannels"))
    }

    public func write(_ configuration: ChatFeedConfiguration, account: String, expected: ClientSettingsSnapshot) throws {
        let values: [String: ClientSettingValue] = [
            "chats.includeArchived": .bool(configuration.includeArchived),
            "chats.addNewChannels": .bool(configuration.addNewChannels),
            "chats.excludedChannels": .array(configuration.excludedChannels.sorted().map { .string(String($0)) }),
            "chats.knownChannels": .array(configuration.knownChannels.sorted().map { .string(String($0)) })
        ]
        var patch: [String: ClientSettingValue] = [:]
        for (key, value) in values {
            var accounts: [String: ClientSettingValue] = [:]
            if case let .object(current)? = expected.values[key] { accounts = current }
            accounts[account] = value
            patch[key] = .object(accounts)
        }
        // Includes all four keys even when only one value changes. Concurrent edits to the
        // same account or another account's entry in these maps cannot be overwritten.
        try self.settings.applyPublic(patch, expected: expected)
    }
}
