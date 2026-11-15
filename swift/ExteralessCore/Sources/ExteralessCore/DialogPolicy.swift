import Foundation

public enum DialogHashtagPage: Int, CaseIterable, Sendable {
    case thisChat = 0
    case myMessages = 1
    case publicPosts = 2
}

public enum DialogForumLayout: Int, CaseIterable, Codable, Sendable {
    case inherit = 0
    case tabs = 1
    case list = 2

    public func usesTabs(nativeDefault: Bool) -> Bool {
        switch self {
        case .inherit: return nativeDefault
        case .tabs: return true
        case .list: return false
        }
    }
}

/// One coherent settings generation. Reading a policy has no I/O or read-receipt
/// side effect. The native adapters retain native account, peer and thread IDs.
public struct DialogPolicy: Equatable, Sendable {
    public let sortByUnread: Bool
    public let disableGlobalSearch: Bool
    public let disableStories: Bool
    public let hideArchive: Bool
    public let openArchiveOnPull: Bool
    public let doNotUnarchiveBySwipe: Bool
    public let searchHashtagDefaultPageChat: DialogHashtagPage
    public let searchHashtagDefaultPageChannel: DialogHashtagPage
    public let disableSwipeToNext: Bool
    public let disableSwipeToNextTopic: Bool
    public let rememberAllBackMessages: Bool
    public let unreadBadgeOnBackButton: Bool
    public let unlimitedPinnedDialogs: Bool

    public init(values: [String: ClientSettingValue] = [:]) {
        func flag(_ key: String) -> Bool { values[key] == .bool(true) }
        func page(_ field: String) -> DialogHashtagPage {
            guard case let .integer(value) = values["chats." + field], let raw = Int(exactly: value) else { return .thisChat }
            return DialogHashtagPage(rawValue: raw) ?? .thisChat
        }
        sortByUnread = flag("chats.sortByUnread")
        disableGlobalSearch = flag("chats.disableGlobalSearch")
        disableStories = flag("chats.disableStories")
        hideArchive = flag("appearance.hideArchive")
        openArchiveOnPull = flag("chats.openArchiveOnPull")
        doNotUnarchiveBySwipe = flag("chats.doNotUnarchiveBySwipe")
        searchHashtagDefaultPageChat = page("searchHashtagDefaultPageChat")
        searchHashtagDefaultPageChannel = page("searchHashtagDefaultPageChannel")
        disableSwipeToNext = flag("chats.disableSwipeToNext")
        disableSwipeToNextTopic = flag("chats.disableSwipeToNextTopic")
        rememberAllBackMessages = flag("chats.rememberAllBackMessages")
        unreadBadgeOnBackButton = flag("chats.unreadBadgeOnBackButton")
        unlimitedPinnedDialogs = flag("chats.unlimitedPinnedDialogs")
    }

    public static var current: DialogPolicy { DialogPolicy(values: ClientSettings.shared.snapshot()) }

    public func allowsSwipeToNext(isTopic: Bool) -> Bool {
        !(isTopic ? disableSwipeToNextTopic : disableSwipeToNext)
    }

    public func allowsArchiveRowSwipe(isArchive: Bool, isPeer: Bool) -> Bool {
        !(isArchive && isPeer && doNotUnarchiveBySwipe)
    }

    public func opensArchiveAfterPull(isRootList: Bool, nativeHiddenRow: Bool, editing: Bool, searching: Bool) -> Bool {
        openArchiveOnPull && !hideArchive && isRootList && nativeHiddenRow && !editing && !searching
    }

    public func initialHashtagPage(isPublicBroadcast: Bool, hasCurrentChat: Bool, explicit: DialogHashtagPage? = nil) -> DialogHashtagPage {
        let page = explicit ?? (isPublicBroadcast ? searchHashtagDefaultPageChannel : searchHashtagDefaultPageChat)
        return page == .thisChat && !hasCurrentChat ? .myMessages : page
    }

    public func backBadge(_ nativeBadge: String?, entryPointAllowsBadge: Bool) -> String? {
        unreadBadgeOnBackButton && entryPointAllowsBadge ? nativeBadge : nil
    }
}
