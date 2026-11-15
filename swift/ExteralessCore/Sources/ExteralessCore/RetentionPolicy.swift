import Foundation

public struct RetentionPeerFacts: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case privateChat, group(isPublic: Bool), channel(isPublic: Bool), unknown
    }

    public let kind: Kind
    public let isArchived: Bool
    public let chatIsBot: Bool
    /// nil is an unresolved/non-user sender. Ayu checks this before its bot-dialog fallback.
    public let senderIsBot: Bool?

    public init(kind: Kind, isArchived: Bool = false, chatIsBot: Bool = false, senderIsBot: Bool? = nil) {
        self.kind = kind
        self.isArchived = isArchived
        self.chatIsBot = chatIsBot
        self.senderIsBot = senderIsBot
    }
}

public struct RetentionPeerExceptions: Codable, Equatable, Sendable {
    public var deleted: Bool
    public var edited: Bool

    public init(deleted: Bool = false, edited: Bool = false) {
        self.deleted = deleted
        self.edited = edited
    }

    public init(from decoder: Decoder) throws {
        try retentionRejectUnknownKeys(decoder, allowed: ["deleted", "edited"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deleted = try container.decode(Bool.self, forKey: .deleted)
        self.edited = try container.decode(Bool.self, forKey: .edited)
    }
}

public struct RetentionPolicy: Equatable, Sendable {
    public static var current: RetentionPolicy { RetentionPolicy(values: ClientSettings.shared.snapshot()) }

    public static let maximumVersions = 32
    public static let maximumMetadataBytes = 32 * 1024 * 1024
    public static let maximumVersionBytes = 512 * 1024
    public static let maximumResourcesPerVersion = 64
    public static let maximumResourceBytes: Int64 = 128 * 1024 * 1024
    public static let maximumResourceCount = 4096
    public static let maximumExceptions = 20000
    public static let pageSize = 100

    /// Reserve encrypted chunks plus the native full-file copy, rounded to 4 KiB blocks.
    /// Native derived thumbnails remain subject to Telegram's ordinary cache budget.
    public static func mediaReservationCost(bytes: Int64) -> Int64 {
        guard bytes > 0, bytes <= maximumResourceBytes else { return Int64.max }
        let chunks = (bytes + 262143) / 262144
        let encrypted = bytes + 16 + chunks * 32
        return ((bytes + 4095) / 4096 + (encrypted + 4095) / 4096) * 4096
    }

    public let saveDeleted: Bool
    public let saveEdits: Bool
    public let deletedOnlyMarked: Bool
    public let editedOnlyMarked: Bool
    public let savePrivate: Bool
    public let saveGroups: Bool
    public let saveChannels: Bool
    public let saveArchived: Bool
    public let saveBotDialogs: Bool
    public let saveBotSenders: Bool
    public let saveMedia: Bool
    public let mediaPrivate: Bool
    public let mediaPublicChannels: Bool
    public let mediaPrivateChannels: Bool
    public let mediaPublicGroups: Bool
    public let mediaPrivateGroups: Bool
    public let translucent: Bool
    public let useDeletedIcon: Bool
    public let useEditedIcon: Bool
    public let editedMark: String
    public let replyToDeletedAsQuote: Bool
    public let showMessageHide: Bool
    public let showViewHistory: Bool
    public let deletedMark: String
    public let deletedColorARGB: UInt32?
    public let menuViewDeleted: Bool
    public let menuClearDeleted: Bool
    public let days: Int
    public let messageLimit: Int
    public let mediaByteLimit: Int64

    public init(values: [String: ClientSettingValue] = [:]) {
        func flag(_ field: String, _ fallback: Bool, prefix: String = "privacy") -> Bool {
            if case let .bool(value)? = values["\(prefix).\(field)"] { return value }
            return fallback
        }
        func integer(_ field: String, _ fallback: Int64) -> Int64 {
            if case let .integer(value)? = values["privacy.\(field)"] { return value }
            return fallback
        }
        self.saveDeleted = flag("enableSaveDeletedMessages", false)
        self.saveEdits = flag("enableSaveEditsHistory", false)
        self.deletedOnlyMarked = integer("saveDeletedExceptionsMode", 0) == 1
        self.editedOnlyMarked = integer("saveEditedExceptionsMode", 0) == 1
        self.savePrivate = flag("saveDeletedInPrivateChats", true)
        self.saveGroups = flag("saveDeletedInGroups", true)
        self.saveChannels = flag("saveDeletedInChannels", true)
        self.saveArchived = flag("saveInArchivedChats", true)
        self.saveBotDialogs = flag("saveDeletedMessageForBot", false)
        self.saveBotSenders = flag("saveDeletedMessageForBotUser", false)
        self.saveMedia = flag("messageSavingSaveMedia", true)
        self.mediaPrivate = flag("saveMediaInPrivateChats", true)
        self.mediaPublicChannels = flag("saveMediaInPublicChannels", true)
        self.mediaPrivateChannels = flag("saveMediaInPrivateChannels", true)
        self.mediaPublicGroups = flag("saveMediaInPublicGroups", true)
        self.mediaPrivateGroups = flag("saveMediaInPrivateGroups", true)
        self.translucent = flag("translucentDeletedMessages", true, prefix: "chats")
        self.useDeletedIcon = flag("useDeletedIcon", true, prefix: "chats")
        self.useEditedIcon = flag("useEditedIcon", true, prefix: "chats")
        self.replyToDeletedAsQuote = flag("replyToDeletedAsQuote", true, prefix: "chats")
        self.showMessageHide = flag("showMessageHide", false, prefix: "chats")
        self.showViewHistory = flag("showViewHistory", false, prefix: "chats")
        if case let .string(value)? = values["chats.customEditedMessage"] {
            self.editedMark = String(value.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(64))
        } else { self.editedMark = "" }
        self.menuViewDeleted = flag("chatMenuItemViewDeleted", true, prefix: "chats")
        self.menuClearDeleted = flag("chatMenuItemClearDeleted", true, prefix: "chats")
        if case let .string(value)? = values["chats.customDeletedMark"] {
            // A label must remain a single, bounded line even for imported settings.
            self.deletedMark = String(value.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(64))
        } else {
            self.deletedMark = ""
        }
        if case let .integer(value)? = values["chats.deletedMarkColor"], value != 0,
           value >= Int64(Int32.min), value <= Int64(UInt32.max) {
            self.deletedColorARGB = UInt32(truncatingIfNeeded: value)
        } else {
            self.deletedColorARGB = nil
        }
        self.days = Int(max(1, min(365, integer("retentionDays", 30))))
        self.messageLimit = Int(max(100, min(20000, integer("retentionMessageLimit", 5000))))
        self.mediaByteLimit = max(16, min(2048, integer("retentionMediaMegabytes", 512))) * 1024 * 1024
    }

    public func keepsDeleted(in peer: RetentionPeerFacts, chat: RetentionPeerExceptions = .init(), sender: RetentionPeerExceptions = .init()) -> Bool {
        guard self.saveDeleted, self.deletedOnlyMarked == (chat.deleted || sender.deleted),
              self.saveArchived || !peer.isArchived else { return false }
        switch peer.kind {
        case .privateChat: if !self.savePrivate { return false }
        case .group: if !self.saveGroups { return false }
        case .channel: if !self.saveChannels { return false }
        case .unknown: break // Matches Ayu's unknown-chat fallback, not a guessed channel classification.
        }
        if let senderIsBot = peer.senderIsBot { return !senderIsBot || self.saveBotSenders }
        return !peer.chatIsBot || self.saveBotDialogs
    }

    public func keepsEdits(in peer: RetentionPeerFacts, chat: RetentionPeerExceptions = .init(), sender: RetentionPeerExceptions = .init()) -> Bool {
        // Ayu does NOT apply deleted-message chat-kind/bot controls to edits.
        self.saveEdits && self.editedOnlyMarked == (chat.edited || sender.edited) && (self.saveArchived || !peer.isArchived)
    }

    public func keepsMedia(in peer: RetentionPeerFacts) -> Bool {
        guard self.saveMedia else { return false }
        switch peer.kind {
        case .privateChat: return self.mediaPrivate
        case let .group(isPublic): return isPublic ? self.mediaPublicGroups : self.mediaPrivateGroups
        case let .channel(isPublic): return isPublic ? self.mediaPublicChannels : self.mediaPrivateChannels
        case .unknown: return true
        }
    }

    public func cutoff(now: Int64) -> Int64 { max(0, now - Int64(self.days) * 86400) }
}

struct RetentionCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func retentionRejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: RetentionCodingKey.self)
    if container.allKeys.contains(where: { !allowed.contains($0.stringValue) }) {
        throw RetentionArchiveError.invalidData
    }
}
