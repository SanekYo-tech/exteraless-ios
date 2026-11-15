import Foundation

/// ConfigItemKeyLinked stores all four logical preferences in DefaultDeleteMenu.
/// Keeping that single value avoids contradictory independent native switches.
public struct ChatDeleteMenuDefaults: Equatable, Sendable {
    public enum Flag: Int, CaseIterable, Sendable {
        case commonGroups = 0, deleteAll = 1, reportSpam = 2, banUsers = 3
        public var field: String {
            switch self {
            case .banUsers: return "defaultDeleteMenuBanUsers"
            case .reportSpam: return "defaultDeleteMenReportSpam"
            case .deleteAll: return "defaultDeleteMenuDeleteAll"
            case .commonGroups: return "defaultDeleteMenuDoActionsInCommonGroups"
            }
        }
        public var title: String {
            switch self {
            case .banUsers: return "Ban users"
            case .reportSpam: return "Report spam"
            case .deleteAll: return "Delete all messages and reactions"
            case .commonGroups: return "Also apply in common groups"
            }
        }
    }
    public static let key = "chats.defaultDeleteMenu"
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public func contains(_ flag: Flag) -> Bool { rawValue & (Int64(1) << flag.rawValue) != 0 }
    public func setting(_ flag: Flag, enabled: Bool) -> Self {
        let bit = Int64(1) << flag.rawValue
        return Self(rawValue: enabled ? rawValue | bit : rawValue & ~bit)
    }
    public static func current(in settings: ClientSettings = .shared) -> Self {
        if case let .integer(value)? = settings.value(key) { return Self(rawValue: value) }
        return Self(rawValue: 0)
    }
    public static func set(_ flag: Flag, enabled: Bool, in settings: ClientSettings = .shared) throws {
        let snapshot = settings.readSnapshot()
        guard case let .integer(value)? = snapshot.values[key] else { throw ClientSettingsError.unregisteredKey(key) }
        let updated = Self(rawValue: value).setting(flag, enabled: enabled)
        try settings.applyPublic([key: .integer(updated.rawValue)], expected: snapshot)
    }
}

public enum ChatCommonGroupModerationPolicy {
    public struct Actions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let ban = Self(rawValue: 1)
        public static let restrict = Self(rawValue: 2)
        public static let clearHistory = Self(rawValue: 4)
    }
    public static func allowed(ban: Bool, restrict: Bool, clearHistory: Bool, cloudChannel: Bool, canBan: Bool, canDelete: Bool) -> Actions {
        var actions: Actions = []
        if canBan {
            if restrict && cloudChannel { actions.insert(.restrict) }
            else if ban { actions.insert(.ban) }
        }
        if clearHistory && cloudChannel && canDelete { actions.insert(.clearHistory) }
        return actions
    }
}
