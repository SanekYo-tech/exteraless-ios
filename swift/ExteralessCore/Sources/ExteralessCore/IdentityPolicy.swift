import Foundation

public enum IdentityError: Error, Equatable, LocalizedError, Sendable {
    case invalidData
    case unsupportedVersion
    case differentAccount
    case quotaExceeded
    case invalidAlias
    case staleEdit
    case inactiveAccount

    public var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid local identity data."
        case .unsupportedVersion: return "This identity archive uses a newer format."
        case .differentAccount: return "This identity archive belongs to another account."
        case .quotaExceeded: return "The local identity data limit has been reached."
        case .invalidAlias: return "Use a single-line name of at most 128 characters and 512 UTF-8 bytes."
        case .staleEdit: return "This value changed while it was being edited. Reopen the editor."
        case .inactiveAccount: return "This account is no longer active."
        }
    }
}

public struct IdentityAccountId: Hashable, Sendable {
    public let recordId: Int64
    public let userId: Int64
    public let testingEnvironment: Bool

    public init(recordId: Int64, userId: Int64, testingEnvironment: Bool) {
        self.recordId = recordId
        self.userId = userId
        self.testingEnvironment = testingEnvironment
    }
}

public enum IdentityPeerKind: String, Codable, Hashable, Sendable {
    case user, group, channel, community
}

public struct IdentityPeerKey: Hashable, Codable, Sendable {
    public static let maximumId: Int64 = 0x00ffffffffffffff
    public let kind: IdentityPeerKind
    public let id: Int64

    public init(kind: IdentityPeerKind, id: Int64) {
        self.kind = kind
        self.id = id
    }

    public var storageKey: String { kind.rawValue + ":" + String(id) }

    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = IdentityPeerKind(rawValue: String(parts[0])),
              let id = Int64(parts[1]), (1...Self.maximumId).contains(id), String(id) == parts[1] else { return nil }
        self.init(kind: kind, id: id)
    }
}

public enum IdentityNameOrder: Int, Codable, Equatable, Sendable {
    case lastFirst = 0
    case firstLast = 1
}

public struct IdentityEmojiStatus: Codable, Equatable, Sendable {
    public let documentId: Int64
    public let until: Int32?

    public init(documentId: Int64, until: Int32? = nil) {
        self.documentId = documentId
        self.until = until == 0 ? nil : until
    }

    public func isActive(at timestamp: Int64) -> Bool {
        documentId != 0 && (until == nil || until == 0 || Int64(until!) > timestamp)
    }

    public func validate() throws {
        guard documentId != 0, until == nil || until! >= 0 else { throw IdentityError.invalidData }
    }
}

/// Matches the original Kotlin four-field record. Nil means use the native
/// value; zero emoji / -1 profile color from Android are normalized to nil.
public struct IdentityPeerColors: Codable, Equatable, Sendable {
    public var colorId: Int32?
    public var emojiId: Int64?
    public var profileColorId: Int32?
    public var profileEmojiId: Int64?

    public init(colorId: Int32? = nil, emojiId: Int64? = nil, profileColorId: Int32? = nil, profileEmojiId: Int64? = nil) {
        self.colorId = colorId
        self.emojiId = emojiId == 0 ? nil : emojiId
        self.profileColorId = profileColorId == -1 ? nil : profileColorId
        self.profileEmojiId = profileEmojiId == 0 ? nil : profileEmojiId
    }

    public func validate() throws {
        for color in [colorId, profileColorId].compactMap({ $0 }) {
            guard color >= 0 else { throw IdentityError.invalidData }
        }
        guard emojiId != 0, profileEmojiId != 0 else { throw IdentityError.invalidData }
    }
}

/// Only explicitly chosen local data is retained. There is no contact dump or
/// saved copy of a server name to become stale when the alias is removed.
public struct IdentityAccountState: Codable, Equatable, Sendable {
    public static let maximumAliases = 2048
    public static let maximumEncodedBytes = 1024 * 1024
    public let version: Int
    public let ownerUserId: Int64
    public let testingEnvironment: Bool
    public private(set) var aliases: [String: String]
    public var nameOrder: IdentityNameOrder
    public var localPremium: Bool
    public var emojiStatus: IdentityEmojiStatus?
    public var colors: IdentityPeerColors?

    public init(ownerUserId: Int64, testingEnvironment: Bool) {
        self.version = 1
        self.ownerUserId = ownerUserId
        self.testingEnvironment = testingEnvironment
        self.aliases = [:]
        self.nameOrder = .firstLast
        self.localPremium = false
        self.emojiStatus = nil
        self.colors = nil
    }

    public func alias(for peer: IdentityPeerKey) -> String? { aliases[peer.storageKey] }

    public mutating func setAlias(_ alias: String?, for peer: IdentityPeerKey) throws {
        guard (1...IdentityPeerKey.maximumId).contains(peer.id) else { throw IdentityError.invalidData }
        let value = try IdentityNamePolicy.normalizedAlias(alias)
        if value != nil && aliases[peer.storageKey] == nil && aliases.count >= Self.maximumAliases {
            throw IdentityError.quotaExceeded
        }
        aliases[peer.storageKey] = value
    }

    public mutating func clearAliases() { aliases.removeAll() }

    public mutating func resetPremium() {
        localPremium = false
        emojiStatus = nil
        colors = nil
    }

    public func validate(owner: IdentityAccountId? = nil) throws {
        guard version == 1 else { throw IdentityError.unsupportedVersion }
        guard ownerUserId > 0 else { throw IdentityError.invalidData }
        if let owner, owner.userId != ownerUserId || owner.testingEnvironment != testingEnvironment {
            throw IdentityError.differentAccount
        }
        guard aliases.count <= Self.maximumAliases else { throw IdentityError.quotaExceeded }
        for (key, value) in aliases {
            guard IdentityPeerKey(storageKey: key) != nil,
                  try IdentityNamePolicy.normalizedAlias(value) == value else { throw IdentityError.invalidData }
        }
        try emojiStatus?.validate()
        try colors?.validate()
    }
}

public enum IdentityNamePolicy {
    public static func normalizedAlias(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return nil }
        guard result.count <= 128, result.utf8.count <= 512,
              !result.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029 }) else {
            throw IdentityError.invalidAlias
        }
        return result
    }

    /// Compact callers use the chosen first component; an alias is one display
    /// name and is not split. Empty native names retain the caller's localization.
    public static func userName(first: String?, last: String?, alias: String?, order: IdentityNameOrder, compact: Bool = false) -> String? {
        if let alias, !alias.isEmpty { return alias }
        let first = first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = (order == .firstLast ? [first, last] : [last, first]).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return compact ? parts[0] : parts.joined(separator: " ")
    }

    public static func initials(_ name: String) -> [String] {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        if words.count > 1, let first = words.first?.first, let last = words.last?.first {
            return [String(first).uppercased(), String(last).uppercased()]
        }
        return name.first.map { [String($0).uppercased()] } ?? []
    }
}

public enum IdentityActivityBand: Equatable, Sendable {
    case online, within15Minutes, within30Minutes, withinHour
}

public enum IdentityMetadataPolicy {
    public static func displayedId(peer: IdentityPeerKey, type: Int) -> String? {
        guard type != 0, peer.id > 0 else { return nil }
        if type == 2 {
            switch peer.kind {
            case .group: return String(-peer.id)
            case .channel:
                let (result, overflow) = Int64(-1_000_000_000_000).subtractingReportingOverflow(peer.id)
                return overflow ? nil : String(result)
            case .user, .community: break
            }
        }
        return String(peer.id)
    }

    public static func activityBand(enabled: Bool, isSelf: Bool, isBot: Bool, visibleUntil: Int32?, locallyOnline: Bool, now: Int64) -> IdentityActivityBand? {
        guard enabled, !isSelf, !isBot else { return nil }
        if locallyOnline { return .online }
        // Approximate / privacy-hidden presence is not an observed timestamp.
        guard let until = visibleUntil, until > 0 else { return nil }
        if Int64(until) > now { return .online }
        let (elapsed, overflow) = now.subtractingReportingOverflow(Int64(until))
        if overflow { return nil }
        if elapsed < 900 { return .within15Minutes }
        if elapsed < 1800 { return .within30Minutes }
        if elapsed < 3600 { return .withinHour }
        return nil
    }

    /// The original preference replaces the gifts default, not an explicit tab
    /// choice, stories, media or a tab that does not exist.
    public static func preferCommonGroups(enabled: Bool, defaultIsGifts: Bool, hasCommonGroups: Bool, explicitSelection: Bool) -> Bool {
        enabled && defaultIsGifts && hasCommonGroups && !explicitSelection
    }
}

public struct IdentityPremiumCapabilities: Equatable, Sendable {
    public let rendersLocalIdentity: Bool
    public let rendersPremiumBadge: Bool
    public let canSubmitPremiumIdentity: Bool

    public init(actualPremium: Bool, isOwningUser: Bool, localPremium: Bool) {
        self.rendersLocalIdentity = isOwningUser && localPremium
        self.rendersPremiumBadge = actualPremium || self.rendersLocalIdentity
        self.canSubmitPremiumIdentity = actualPremium && isOwningUser
    }

    /// UserObject.java prefers an active server status, then the account-local
    /// fallback. Expiration is evaluated on every read, never cached as a Bool.
    public func emojiStatus(server: IdentityEmojiStatus?, local: IdentityEmojiStatus?, now: Int64) -> IdentityEmojiStatus? {
        if let server, server.isActive(at: now) { return server }
        if rendersLocalIdentity, let local, local.isActive(at: now) { return local }
        return nil
    }
}
