import Foundation

public enum DialogOrderingPolicy {
    /// ChatsHelper.isUnreadSortPriority, not the legacy Neko sort_by_unread.
    /// A manual "mark unread" without a positive count is deliberately not enough.
    public static func isUnreadPriority(unreadCount: Int, counterMuted: Bool, hasMentions: Bool, hasReactions: Bool, isMonoforum: Bool = false) -> Bool {
        (!isMonoforum && hasMentions) || hasReactions || (unreadCount > 0 && !counterMuted)
    }

    /// Stable promotion within each already-native-ordered account/group/filter.
    /// Pins and structural rows retain their slots; ties keep native draft/date
    /// order. Scope is supplied by the caller rather than guessed from peer IDs.
    public static func promoteUnread<Element, Scope: Hashable>(
        _ nativeOrder: [Element], enabled: Bool,
        scope: (Element) -> Scope, isFixed: (Element) -> Bool, isPriority: (Element) -> Bool
    ) -> [Element] {
        guard enabled else { return nativeOrder }
        var slots: [Scope: [Int]] = [:]
        var priority: [Scope: [Element]] = [:]
        var ordinary: [Scope: [Element]] = [:]
        for (index, item) in nativeOrder.enumerated() where !isFixed(item) {
            let key = scope(item)
            slots[key, default: []].append(index)
            if isPriority(item) { priority[key, default: []].append(item) }
            else { ordinary[key, default: []].append(item) }
        }
        var result = nativeOrder
        for (key, indices) in slots {
            let ordered = (priority[key] ?? []) + (ordinary[key] ?? [])
            for (index, item) in zip(indices, ordered) { result[index] = item }
        }
        return result
    }

    /// Window in TOP-FIRST display order. The anchor is a native identity's
    /// position in that order, never an invented timestamp or message ID.
    public static func window(totalCount: Int, count: Int, anchorIndex: Int?) -> Range<Int> {
        let total = max(0, totalCount)
        let size = min(total, max(1, count))
        guard let anchorIndex else { return 0 ..< size }
        let anchor = min(max(0, anchorIndex), max(0, total - 1))
        let lower = min(max(0, anchor - size / 2), total - size)
        return lower ..< lower + size
    }
}

public enum DialogPinPolicy {
    /// Android also uses the archive limit rather than infinite server capacity.
    public static func localRootLimit(enabled: Bool, serverRootLimit: Int, archiveLimit: Int) -> Int {
        enabled ? max(serverRootLimit, archiveLimit) : serverRootLimit
    }

    /// Keep missing local pins at their previous slots after a server refresh.
    /// The native sync algorithm remains responsible for explicit local removals.
    public static func preservingLocalPins<ID: Hashable>(nativeResult: [ID], currentLocal: [ID], enabled: Bool) -> [ID] {
        guard enabled else { return nativeResult }
        var result = nativeResult
        var present = Set(result)
        for (index, id) in currentLocal.enumerated() where present.insert(id).inserted {
            result.insert(id, at: min(index, result.count))
        }
        return result
    }

    public static func serverOrder<ID>(_ nativeOrder: [ID], serverLimit: Int) -> [ID] {
        Array(nativeOrder.prefix(max(0, serverLimit)))
    }
}
