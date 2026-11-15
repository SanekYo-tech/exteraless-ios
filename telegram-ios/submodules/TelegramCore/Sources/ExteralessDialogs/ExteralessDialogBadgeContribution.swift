import Foundation
import Postbox
import SwiftSignalKit

/// Read-only membership in the same native tag/mute/group set as the total.
/// Reuses Postbox's Telegram seed classifier (including secret-chat contacts),
/// rather than maintaining a second user/group/channel classification in UI.
func exteralessDialogBadgePeerState(transaction: Transaction, peerId: EnginePeer.Id, includeTags: EnginePeerSummaryCounterTags, includeArchived: Bool) -> (isIncluded: Bool?, isMarkedUnread: Bool) {
    guard let peer = transaction.getPeer(peerId) else { return (nil, false) }
    let marked = transaction.getCombinedPeerReadState(peerId)?.markedUnread ?? false
    let identity = peer.associatedPeerOverridesIdentity ? (peer.associatedPeerId ?? peerId) : peerId
    let tag = telegramPostboxSeedConfiguration.peerSummaryCounterTags(peer, transaction.isPeerContact(peerId: identity))
    guard !includeTags.intersection(tag).isEmpty else { return (false, marked) }
    guard let (group, _) = transaction.getPeerChatListIndex(peerId), group == .root || (includeArchived && group == Namespaces.PeerGroup.archive) else { return (false, marked) }
    let global = transaction.getPreferencesEntry(key: PreferencesKeys.globalNotifications)?.get(GlobalNotificationSettings.self) ?? .defaultSettings
    let excluded = resolvedIsRemovedFromTotalUnreadCount(globalSettings: global.postboxAccessor, peer: peer, peerSettings: transaction.getPeerNotificationSettings(id: identity))
    return (!excluded, marked)
}

public func exteralessDialogBadgePeerState(account: Account, peerId: EnginePeer.Id, includeTags: EnginePeerSummaryCounterTags, includeArchived: Bool) -> Signal<(isIncluded: Bool?, isMarkedUnread: Bool), NoError> {
    account.postbox.transaction { transaction in
        exteralessDialogBadgePeerState(transaction: transaction, peerId: peerId, includeTags: includeTags, includeArchived: includeArchived)
    }
}

/// Shared by the actual UI adapter and native transaction fixtures. Unknown
/// included contributions hide the number; excluded peers contribute exactly 0,
/// even when their own filtered unread count is unavailable.
public func exteralessDialogBackBadgeText(total: Int32?, peerUnreadCount: Int?, peerIsIncluded: Bool?, peerIsMarkedUnread: Bool, countChats: Bool, entryPointAllowsBadge: Bool) -> String? {
    guard entryPointAllowsBadge, let total, total >= 0 else { return nil }
    if peerIsIncluded == false { return total > 0 ? String(total) : nil }
    guard peerIsIncluded == true, let peerUnreadCount, peerUnreadCount >= 0 else { return nil }
    let count = max(peerUnreadCount, peerIsMarkedUnread ? 1 : 0)
    let contribution = countChats ? (count > 0 ? 1 : 0) : count
    let remaining = max(0, Int64(total) - Int64(clamping: contribution))
    return remaining > 0 ? String(remaining) : nil
}
