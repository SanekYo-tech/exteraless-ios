import Foundation

/// SharedConfig.ChatSwipeAction / SwipeGestureSettingsView persisted values.
public enum ChatSwipePolicy {
    public static let settingKey = "chats.chatSwipeAction"

    public enum Action: Int, CaseIterable, Hashable, Sendable {
        case automatic = -1
        case pin = 0
        case read = 1
        case archive = 2
        case mute = 3
        case delete = 4
        case folders = 5
    }

    public enum GestureOwner: Equatable, Sendable {
        case native
        case rowReveal
        case folderPager
        case horizontalContent
    }

    public static func current(in settings: ClientSettings = .shared) -> Int {
        settings.integer(settingKey, default: Action.automatic.rawValue)
    }

    public static func resolvedAction(rawValue: Int, hasFilters: Bool) -> Action {
        switch Action(rawValue: rawValue) ?? .automatic {
        case .automatic: return hasFilters ? .folders : .archive
        case .folders: return hasFilters ? .folders : .archive
        case let action: return action
        }
    }

    /// Eligibility belongs to the native row. Never manufacture an action which
    /// its peer/privacy/editing/forum policy omitted. Nil preserves an unfamiliar
    /// native fallback (such as Hide PSA or Close topic) without reinterpreting it.
    public static func primaryAction(rawValue: Int, hasFilters: Bool, allowed: Set<Action>, nativeFallback: Action?) -> Action? {
        let action = resolvedAction(rawValue: rawValue, hasFilters: hasFilters)
        if action == .folders { return nil }
        if allowed.contains(action) { return action }
        if let nativeFallback, allowed.contains(nativeFallback) { return nativeFallback }
        return nil
    }

    /// Matches the native folder pager's widthMultiplier(1/6, min:22, max:80).
    public static func isActionEdge(x: Double, width: Double) -> Bool {
        guard x.isFinite, width.isFinite, width > 0 else { return true }
        let edge = min(80, max(22, width / 6))
        return x < edge || x > width - edge
    }

    public static func gestureOwner(rawValue: Int, hasFilters: Bool, rowHasActions: Bool,
                                    isActionEdge: Bool, revealIsOpen: Bool, horizontalContent: Bool) -> GestureOwner {
        if horizontalContent { return .horizontalContent }
        if revealIsOpen { return .rowReveal }
        guard rowHasActions, hasFilters, !isActionEdge else { return .native }
        return resolvedAction(rawValue: rawValue, hasFilters: hasFilters) == .folders ? .folderPager : .rowReveal
    }
}
