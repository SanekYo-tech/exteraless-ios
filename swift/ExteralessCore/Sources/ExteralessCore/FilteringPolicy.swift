import Foundation

public struct FilteringRule: Codable, Equatable, Sendable {
    public var id: String
    public var regex: String
    public var caseInsensitive: Bool
    public var enabled: Bool
    public var reversed: Bool

    public init(id: String = UUID().uuidString, regex: String, caseInsensitive: Bool = false, enabled: Bool = true, reversed: Bool = false) {
        self.id = id; self.regex = regex; self.caseInsensitive = caseInsensitive
        self.enabled = enabled; self.reversed = reversed
    }

    private enum CodingKeys: String, CodingKey { case id, regex, caseInsensitive, enabled, reversed }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regex = try container.decode(String.self, forKey: .regex)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? regex
        caseInsensitive = try container.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        reversed = try container.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
    }
}

public enum FilteringConfigurationError: Error, Sendable {
    case invalidCollection, tooManyRules, tooManyPeers, invalidPeer, duplicateRule
}

public struct FilteringConfiguration: Equatable, Sendable {
    public static let maximumRules = 64
    public static let maximumPeers = 4_096
    public var ignoreBlocked = false
    public var regexFiltersEnabled = false
    public var regexFiltersEnableInChats = false
    public var blockedChannels = Set<Int64>()
    public var customFilteredUsers = Set<Int64>()
    public var excludedDialogs = Set<Int64>()
    public var sharedRules: [FilteringRule] = []
    public var chatRules: [Int64: [FilteringRule]] = [:]

    public init() {}

    public init(account: PrivacyExtrasAccountIdentity, values: [String: ClientSettingValue]) throws {
        self.init()
        ignoreBlocked = values["privacy.ignoreBlocked"] == .bool(true)
        regexFiltersEnabled = values["privacy.regexFiltersEnabled"] == .bool(true)
        regexFiltersEnableInChats = values["privacy.regexFiltersEnableInChats"] == .bool(true)
        blockedChannels = try Self.peers(Self.scoped("blockedChannelsData", account: account, values: values))
        customFilteredUsers = try Self.peers(Self.scoped("customFilteredUsersData", account: account, values: values))
        excludedDialogs = try Self.peers(Self.scoped("regexFiltersExcludedDialogs", account: account, values: values))
        sharedRules = try Self.rules(Self.scoped("regexFiltersData", account: account, values: values))
        if let value = Self.scoped("regexChatFiltersData", account: account, values: values) {
            guard case let .object(chats) = value, chats.count <= Self.maximumPeers else { throw FilteringConfigurationError.invalidCollection }
            for (key, value) in chats {
                guard let peer = Int64(key) else { throw FilteringConfigurationError.invalidPeer }
                chatRules[peer] = try Self.rules(value)
            }
        }
        guard sharedRules.count + chatRules.values.reduce(0, { $0 + $1.count }) <= Self.maximumRules else { throw FilteringConfigurationError.tooManyRules }
    }

    public static func scoped(_ field: String, account: PrivacyExtrasAccountIdentity, values: [String: ClientSettingValue]) -> ClientSettingValue? {
        guard case let .object(accounts)? = values["privacy." + field] else { return nil }
        return accounts[account.storageKey]
    }

    public static func peers(_ value: ClientSettingValue?) throws -> Set<Int64> {
        guard let value else { return [] }
        guard case let .array(items) = value else { throw FilteringConfigurationError.invalidCollection }
        guard items.count <= maximumPeers else { throw FilteringConfigurationError.tooManyPeers }
        var result = Set<Int64>()
        for item in items {
            // A decimal packed native peer ID survives JSON's double limitations.
            guard case let .string(text) = item, let id = Int64(text) else { throw FilteringConfigurationError.invalidPeer }
            result.insert(id)
        }
        return result
    }

    public static func rules(_ value: ClientSettingValue?) throws -> [FilteringRule] {
        guard let value else { return [] }
        guard case let .array(items) = value else { throw FilteringConfigurationError.invalidCollection }
        guard items.count <= maximumRules else { throw FilteringConfigurationError.tooManyRules }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64 * 1_024 else { throw FilteringConfigurationError.tooManyRules }
        let rules = try JSONDecoder().decode([FilteringRule].self, from: data)
        guard Set(rules.map(\.id)).count == rules.count else { throw FilteringConfigurationError.duplicateRule }
        return rules
    }

    public static func value(for rules: [FilteringRule]) throws -> ClientSettingValue {
        guard rules.count <= maximumRules else { throw FilteringConfigurationError.tooManyRules }
        guard Set(rules.map(\.id)).count == rules.count else { throw FilteringConfigurationError.duplicateRule }
        for rule in rules { _ = try FilteringRegex(rule.regex, caseInsensitive: rule.caseInsensitive) }
        return try JSONDecoder().decode(ClientSettingValue.self, from: JSONEncoder().encode(rules))
    }

    public static func value(for peers: Set<Int64>) -> ClientSettingValue {
        .array(peers.sorted().map { .string(String($0)) })
    }
}

public enum FilteringSurface: Equatable, Sendable { case history, preview, notification, automaticDownload }

public struct FilteringMessage: Sendable {
    public let account: PrivacyExtrasAccountIdentity
    public let peerId: Int64
    public let senderId: Int64?
    public let replySenderId: Int64?
    public let isMegagroup: Bool
    public let isPrivateChat: Bool
    public let isOutgoing: Bool
    /// Already combines eligible original text, keyboard labels and link targets.
    public let text: String
    public let isOAuthNotification: Bool

    public init(account: PrivacyExtrasAccountIdentity, peerId: Int64, senderId: Int64?, replySenderId: Int64? = nil, isMegagroup: Bool, isPrivateChat: Bool, isOutgoing: Bool, text: String, isOAuthNotification: Bool = false) {
        self.account = account; self.peerId = peerId; self.senderId = senderId; self.replySenderId = replySenderId
        self.isMegagroup = isMegagroup; self.isPrivateChat = isPrivateChat; self.isOutgoing = isOutgoing
        self.text = text; self.isOAuthNotification = isOAuthNotification
    }
}

public struct FilteringDecision: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case sender, replySender, regex(String) }
    public let hiddenReason: Reason?
    public let incomplete: Bool
    public var isHidden: Bool { hiddenReason != nil }
    public static let visible = FilteringDecision(hiddenReason: nil, incomplete: false)
}

public struct FilteringPolicy: Sendable {
    private struct Compiled: Sendable {
        let rule: FilteringRule
        let expression: FilteringRegex?
    }
    public let account: PrivacyExtrasAccountIdentity
    public let configuration: FilteringConfiguration
    public let blockedPeers: Set<Int64>
    public let invalidRuleIds: Set<String>
    private let shared: [Compiled]
    private let chats: [Int64: [Compiled]]

    public init(account: PrivacyExtrasAccountIdentity, configuration: FilteringConfiguration, blockedPeers: Set<Int64> = []) {
        self.account = account; self.configuration = configuration; self.blockedPeers = blockedPeers
        var invalid = Set<String>()
        func compile(_ rules: [FilteringRule]) -> [Compiled] {
            rules.prefix(FilteringConfiguration.maximumRules).map { rule in
                let expression = try? FilteringRegex(rule.regex, caseInsensitive: rule.caseInsensitive)
                if expression == nil { invalid.insert(rule.id) }
                return Compiled(rule: rule, expression: expression)
            }
        }
        shared = compile(configuration.sharedRules)
        chats = configuration.chatRules.mapValues(compile)
        invalidRuleIds = invalid
    }

    public var hasSenderFilters: Bool {
        configuration.ignoreBlocked || !configuration.blockedChannels.isEmpty || !configuration.customFilteredUsers.isEmpty
    }

    public func hidesSender(_ id: Int64?) -> Bool {
        guard let id else { return false }
        return (configuration.ignoreBlocked && blockedPeers.contains(id)) || configuration.blockedChannels.contains(id) || configuration.customFilteredUsers.contains(id)
    }

    public func decision(_ message: FilteringMessage, surface: FilteringSurface, budget: inout FilteringWorkBudget) -> FilteringDecision {
        guard message.account == account else { return .visible }
        let filterSender: Bool
        switch surface {
        case .history, .preview: filterSender = message.isMegagroup
        case .notification: filterSender = true
        case .automaticDownload: filterSender = false
        }
        if filterSender {
            if hidesSender(message.senderId) { return FilteringDecision(hiddenReason: .sender, incomplete: false) }
            if message.isMegagroup, surface != .notification, hidesSender(message.replySenderId) {
                return FilteringDecision(hiddenReason: .replySender, incomplete: false)
            }
        }
        guard configuration.regexFiltersEnabled, !message.isOutgoing, !message.text.isEmpty,
              !configuration.excludedDialogs.contains(message.peerId),
              !(surface == .notification && message.isOAuthNotification) else { return .visible }
        let candidates = (chats[message.peerId] ?? []) + ((!message.isPrivateChat || configuration.regexFiltersEnableInChats) ? shared : [])
        var incomplete = false
        for candidate in candidates where candidate.rule.enabled {
            guard let expression = candidate.expression else { incomplete = true; continue }
            switch expression.find(in: message.text, budget: &budget) {
            case .matched:
                if !candidate.rule.reversed { return FilteringDecision(hiddenReason: .regex(candidate.rule.id), incomplete: incomplete) }
            case .notMatched:
                if candidate.rule.reversed { return FilteringDecision(hiddenReason: .regex(candidate.rule.id), incomplete: incomplete) }
            case .inputLimit, .workLimit: incomplete = true
            }
        }
        return FilteringDecision(hiddenReason: nil, incomplete: incomplete)
    }

    /// Unknown/anonymous reactions are retained. A recent-peer sample is not the
    /// entire reaction list; only identifiable hidden peers may reduce a count.
    public func reactionProjection(_ counts: [FilteringReactionCount], recent: [FilteringRecentReaction], isMegagroup: Bool) -> FilteringReactionProjection {
        guard isMegagroup, hasSenderFilters else { return FilteringReactionProjection(counts: counts, recent: recent) }
        let hidden = recent.filter { !$0.isOwn && hidesSender($0.peerId) }
        // The same peer can arrive twice with different unread flags after edits.
        let deductions = Dictionary(grouping: hidden, by: \.value).mapValues { Set($0.map(\.peerId)).count }
        let visible = counts.compactMap { count -> FilteringReactionCount? in
            let value = max(count.isChosen ? 1 : 0, count.count - (deductions[count.value] ?? 0))
            return value > 0 || count.isChosen ? FilteringReactionCount(value: count.value, count: value, isChosen: count.isChosen) : nil
        }
        return FilteringReactionProjection(counts: visible, recent: recent.filter { $0.isOwn || !hidesSender($0.peerId) })
    }
}

public struct FilteringReactionCount: Equatable, Sendable {
    public let value: String
    public let count: Int
    public let isChosen: Bool
    public init(value: String, count: Int, isChosen: Bool) { self.value = value; self.count = max(0, count); self.isChosen = isChosen }
}
public struct FilteringRecentReaction: Hashable, Sendable {
    public let value: String
    public let peerId: Int64
    public let unread: Bool
    public let isOwn: Bool
    public init(value: String, peerId: Int64, unread: Bool, isOwn: Bool = false) { self.value = value; self.peerId = peerId; self.unread = unread; self.isOwn = isOwn }
}
public struct FilteringReactionProjection: Equatable, Sendable {
    public let counts: [FilteringReactionCount]
    public let recent: [FilteringRecentReaction]
    public var hasUnread: Bool { recent.contains(where: \.unread) }
}

/// Ephemeral per-view result. No read marker, PTS or secret-chat sequence changes.
public struct FilteringUnreadProjection: Equatable, Sendable {
    public let visibleCount: Int?
    public let knownHiddenCount: Int
    public init(totalUnread: Int, inspectedUnread: Int, hiddenUnreadIds: Set<String>, hasHoles: Bool, evaluationIncomplete: Bool) {
        knownHiddenCount = min(max(0, totalUnread), hiddenUnreadIds.count)
        visibleCount = !hasHoles && !evaluationIncomplete && inspectedUnread >= totalUnread
            ? max(0, totalUnread - knownHiddenCount) : nil
    }
}
