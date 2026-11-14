import Foundation

/// `peerId` is the native packed peer ID, including its namespace. Never use abs(id).
public struct PrivacyPeerKey: Hashable, Codable, Sendable {
    public let accountId: Int64
    public let peerId: Int64

    public init(accountId: Int64, peerId: Int64) {
        self.accountId = accountId
        self.peerId = peerId
    }

    public var settingKey: String { "\(accountId):\(peerId)" }
}

public struct PrivacyPolicy: Equatable, Sendable {
    public enum ReadIntent: Sendable { case automatic, explicit, afterSend }

    public let sendReadMessagePackets: Bool
    public let sendReadStoriesPackets: Bool
    public let sendOnlinePackets: Bool
    public let sendUploadProgress: Bool
    public let sendOfflinePacketAfterOnline: Bool
    public let markReadAfterSend: Bool
    public let hidePhone: Bool
    public let contentCapture: Bool
    public let saveLocalLastSeen: Bool
    public let saveReadDate: Bool
    public let showNotificationPreviewWhenLocked: Bool
    public let botPrivacyEnabled: Bool
    public let botPrivacyAlwaysAsk: Bool
    public let botPrivacyUserId: Int64
    public let proxyDisableConditions: ProxyDisableConditions
    private let values: [String: ClientSettingValue]

    public init(values: [String: ClientSettingValue] = [:]) {
        self.values = values
        func flag(_ field: String, _ fallback: Bool) -> Bool {
            if case let .bool(value)? = values["privacy." + field] { return value }
            return fallback
        }
        sendReadMessagePackets = flag("sendReadMessagePackets", true)
        sendReadStoriesPackets = flag("sendReadStoriesPackets", true)
        sendOnlinePackets = flag("sendOnlinePackets", true)
        sendUploadProgress = flag("sendUploadProgress", true)
        sendOfflinePacketAfterOnline = flag("sendOfflinePacketAfterOnline", false)
        markReadAfterSend = flag("markReadAfterSend", true)
        hidePhone = flag("hidePhone", true)
        contentCapture = flag("contentCapture", false)
        saveLocalLastSeen = flag("saveLocalLastSeen", false)
        saveReadDate = flag("saveReadDate", false)
        showNotificationPreviewWhenLocked = flag("showNotificationPreviewWhenLocked", false)
        botPrivacyEnabled = flag("botPrivacyEnabled", false)
        botPrivacyAlwaysAsk = flag("botPrivacyAlwaysAsk", false)
        if case let .integer(value)? = values["privacy.botPrivacyUserId"] { botPrivacyUserId = value } else { botPrivacyUserId = 0 }
        if case let .integer(value)? = values["privacy.proxyDisableConditions"] {
            proxyDisableConditions = ProxyDisableConditions(rawValue: Int(truncatingIfNeeded: value) & 7)
        } else {
            proxyDisableConditions = []
        }
    }

    public static var current: PrivacyPolicy { PrivacyPolicy(values: ClientSettings.shared.snapshot()) }

    public func readExcluded(_ peer: PrivacyPeerKey) -> Bool { excluded("ghostModeReadExclusions", peer) }
    public func typingExcluded(_ peer: PrivacyPeerKey) -> Bool { excluded("ghostModeTypingExclusions", peer) }

    private func excluded(_ field: String, _ peer: PrivacyPeerKey) -> Bool {
        guard case let .object(entries)? = values["privacy." + field], case .bool(true)? = entries[peer.settingKey] else { return false }
        return true
    }

    public func allowsMessageRead(_ peer: PrivacyPeerKey, intent: ReadIntent = .automatic) -> Bool {
        switch intent {
        case .explicit: return true
        case .afterSend: return sendReadMessagePackets || readExcluded(peer) || markReadAfterSend
        case .automatic: return sendReadMessagePackets || readExcluded(peer)
        }
    }

    public func allowsStoryRead(_ peer: PrivacyPeerKey, ghostSession: Bool = false) -> Bool {
        !ghostSession && (sendReadStoriesPackets || readExcluded(peer))
    }

    public func allowsTyping(_ peer: PrivacyPeerKey) -> Bool { sendUploadProgress || typingExcluded(peer) }
    public func reportOnline(requested: Bool) -> Bool { requested && sendOnlinePackets }
    public func goOfflineAfterSend(to peer: PrivacyPeerKey?) -> Bool {
        sendOfflinePacketAfterOnline && !(peer.map(typingExcluded) ?? false)
    }

    /// Final transport guard also covers raw native/plugin TL requests. Unknown peers
    /// cannot borrow another chat's exception. Typed client adapters supply local results
    /// before reaching this guard; raw requests receive a terminal privacy error.
    public func permitsRequest(method: String, peer: PrivacyPeerKey?, incrementViews: Bool?, requestsOnline: Bool?, ghostStorySession: Bool = false) -> Bool {
        let readAllowed = sendReadMessagePackets || (peer.map(readExcluded) ?? false)
        switch method {
        case "messages.readHistory", "messages.readEncryptedHistory", "messages.readDiscussion", "messages.readMessageContents", "channels.readHistory", "channels.readMessageContents", "messages.readSavedHistory":
            return readAllowed
        case "messages.getMessagesViews":
            return incrementViews == false || readAllowed
        case "stories.readStories", "stories.incrementStoryViews":
            return !ghostStorySession && (sendReadStoriesPackets || (peer.map(readExcluded) ?? false))
        case "messages.setTyping", "messages.setEncryptedTyping":
            return sendUploadProgress || (peer.map(typingExcluded) ?? false)
        case "account.updateStatus":
            return sendOnlinePackets || requestsOnline == false
        default: return true
        }
    }

    /// A vector contents-read can address several peers. Every resolved peer must
    /// permit it; any unresolved ID additionally requires the global policy.
    public func permitsRequest(method: String, peers: [PrivacyPeerKey], allPeersResolved: Bool, incrementViews: Bool?, requestsOnline: Bool?, ghostStorySession: Bool = false) -> Bool {
        if peers.isEmpty || !allPeersResolved {
            guard permitsRequest(method: method, peer: nil, incrementViews: incrementViews, requestsOnline: requestsOnline, ghostStorySession: ghostStorySession) else { return false }
        }
        return peers.allSatisfy { permitsRequest(method: method, peer: $0, incrementViews: incrementViews, requestsOnline: requestsOnline, ghostStorySession: ghostStorySession) }
    }

    public var ghostModeActive: Bool {
        for field in PrivacyFeatures.ghostFields where !locked(field) {
            let target = field == "sendOfflinePacketAfterOnline"
            if fieldValue(field) != target { return false }
        }
        return true
    }

    public func ghostModeChanges(enabled: Bool) -> [String: ClientSettingValue] {
        var changes: [String: ClientSettingValue] = [:]
        for field in PrivacyFeatures.ghostFields where !locked(field) {
            changes["privacy." + field] = .bool((field == "sendOfflinePacketAfterOnline") == enabled)
        }
        return changes
    }

    private func locked(_ field: String) -> Bool { values["privacy." + field + "Locked"] == .bool(true) }
    private func fieldValue(_ field: String) -> Bool {
        if case let .bool(value)? = values["privacy." + field] { return value }
        return field != "sendOfflinePacketAfterOnline"
    }
}

public struct ProxyDisableConditions: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let vpn = ProxyDisableConditions(rawValue: 1)
    public static let mobileData = ProxyDisableConditions(rawValue: 2)
    public static let wifi = ProxyDisableConditions(rawValue: 4)

    /// Unknown VPN state is not inferred from an interface's name or from a proxy.
    public func matches(mobileData: Bool, wifi: Bool, vpn: Bool? = nil) -> Bool {
        (contains(.mobileData) && mobileData) || (contains(.wifi) && wifi) || (contains(.vpn) && vpn == true)
    }
}

public enum NotificationPrivacyDecision: Equatable, Sendable { case show, redact, suppress }

public struct NotificationPrivacyContext: Sendable {
    public let accountResolved: Bool
    public let accountEnabled: Bool
    public let appLocked: Bool
    public let chatPreviews: Bool

    public init(accountResolved: Bool = true, accountEnabled: Bool = true, appLocked: Bool, chatPreviews: Bool = true) {
        self.accountResolved = accountResolved
        self.accountEnabled = accountEnabled
        self.appLocked = appLocked
        self.chatPreviews = chatPreviews
    }

    public func decision(policy: PrivacyPolicy) -> NotificationPrivacyDecision {
        if !accountResolved || !accountEnabled { return .suppress }
        if !chatPreviews || (appLocked && !policy.showNotificationPreviewWhenLocked) { return .redact }
        return .show
    }
}

/// Captured callback state may finish or be cancelled only once, including a timeout race.
public final class PrivacyCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    public init(_ callback: @escaping (Value) -> Void) { self.callback = callback }

    @discardableResult public func finish(_ value: Value) -> Bool {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(value)
        return callback != nil
    }

    public func cancel() {
        lock.lock()
        callback = nil
        lock.unlock()
    }
}

public enum BotAccountDecision: Equatable, Sendable {
    case account(Int64)
    case choose([Int64])
    case unavailable
    case unknown
}

public enum BotAccountPolicy {
    public static func samePreferences(_ lhs: PrivacyPolicy, _ rhs: PrivacyPolicy) -> Bool {
        lhs.botPrivacyEnabled == rhs.botPrivacyEnabled && lhs.botPrivacyAlwaysAsk == rhs.botPrivacyAlwaysAsk && lhs.botPrivacyUserId == rhs.botPrivacyUserId
    }

    /// IDs are native account record IDs, resolved from the configured Telegram user ID.
    public static func choose(useSelectedAccount: Bool, alwaysAsk: Bool, requested: Int64, configured: Int64?, explicit: Bool, established: [Int64], available: [Int64], complete: Bool) -> BotAccountDecision {
        if !useSelectedAccount && !alwaysAsk { return .account(requested) }
        if explicit && established.contains(requested) { return .account(requested) }
        if !complete { return .unknown }
        let established = Array(Set(established)).sorted()
        if established.count == 1 { return .account(established[0]) }
        if established.count > 1 { return .choose(established) }
        if alwaysAsk { return available.isEmpty ? .unavailable : .choose(available) }
        guard let configured, available.contains(configured) else { return .unavailable }
        return .account(configured)
    }
}

public enum PrivacyScheduledSendPolicy {
    public static func scheduleDate(enabled: Bool, sendsOnline: Bool, now: Int32, hasExplicitSchedule: Bool, isSelf: Bool, isSecret: Bool, isBotOrUnknownUser: Bool, isSpecialFlow: Bool) -> Int32? {
        guard enabled, !sendsOnline, !hasExplicitSchedule, !isSelf, !isSecret, !isBotOrUnknownUser, !isSpecialFlow, now > 0 else { return nil }
        let value = Int64(now) + 12
        guard value < Int64(Int32.max) - 1 else { return nil }
        return Int32(value)
    }
}

/// Process-local, identity-scoped payload-link deduplication. Failed/cancelled starts retry.
public final class BotStartDeduplicator: @unchecked Sendable {
    private struct Key: Hashable { let accountId: Int64; let identity: Int64; let botId: Int64; let payload: String }
    private let lock = NSLock()
    private var starts = Set<Key>()

    public init() {}
    public func begin(accountId: Int64, identity: Int64, botId: Int64, payload: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return starts.insert(Key(accountId: accountId, identity: identity, botId: botId, payload: payload)).inserted
    }
    public func failed(accountId: Int64, identity: Int64, botId: Int64, payload: String) {
        lock.lock()
        starts.remove(Key(accountId: accountId, identity: identity, botId: botId, payload: payload))
        lock.unlock()
    }
    public func clear(accountId: Int64) {
        lock.lock()
        starts = starts.filter { $0.accountId != accountId }
        lock.unlock()
    }
}
