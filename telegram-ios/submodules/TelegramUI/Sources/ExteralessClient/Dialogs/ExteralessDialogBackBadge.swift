import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences

func exteralessDialogInitialBackBadge(context _: AccountContext, nativeBadge _: String, entryPointAllowsBadge: Bool) -> String? {
    // ContentData's cached scalar has already subtracted a peer, without carrying
    // its tag/mute provenance. It cannot be corrected from the string. Defer to
    // the checked live adapter instead of flashing that unqualified number.
    return exteralessDialogBackBadgeText(total: nil, peerUnreadCount: nil, peerIsIncluded: nil, peerIsMarkedUnread: false, countChats: false, entryPointAllowsBadge: entryPointAllowsBadge)
}

/// The native Back badge calculation, observing its actual native notification
/// preferences. Privacy Extras supplies filtered counts; an unknown projection
/// hides the number rather than fabricating a count or marking anything read.
func exteralessDialogBackBadge(context: AccountContext, peerId: EnginePeer.Id, entryPointAllowsBadge: Bool) -> Signal<String?, NoError> {
    guard entryPointAllowsBadge else { return .single(nil) }
    let identity = exteralessPrivacyExtrasIdentity(context.account)
    return combineLatest(
        context.engine.data.subscribe(
            TelegramEngine.EngineData.Item.Messages.PeerUnreadCount(id: peerId),
            TelegramEngine.EngineData.Item.Messages.TotalReadCounters(),
            TelegramEngine.EngineData.Item.Peer.NotificationSettings(id: peerId),
            TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
            TelegramEngine.EngineData.Item.Peer.IsContact(id: peerId),
            TelegramEngine.EngineData.Item.NotificationSettings.Global()
        ),
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]),
        exteralessDialogPolicyUpdates(),
        ExteralessFilteringRuntime.shared.changes,
        ExteralessHiddenAccounts.shared.changes
    )
    |> mapToSignal { input, sharedData, policy, _, _ -> Signal<String?, NoError> in
        guard policy.unreadBadgeOnBackButton, ExteralessHiddenAccounts.shared.shouldNotify(identity) else { return .single(nil) }
        let (peerUnreadCount, totalReadCounters, _, _, _, _) = input
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? .defaultSettings
        let filtering = ExteralessFilteringRuntime.shared.policy(identity)
        let useProjection = filtering.hasSenderFilters || filtering.configuration.regexFiltersEnabled
        let countChats = settings.totalUnreadCountDisplayCategory == .chats
        // The stock total is root-only; the existing Privacy Extras projection
        // explicitly includes root + archive. Match whichever total is used.
        return exteralessDialogBadgePeerState(account: context.account, peerId: peerId, includeTags: settings.totalUnreadCountIncludeTags, includeArchived: useProjection)
        |> mapToSignal { peer -> Signal<String?, NoError> in
            guard peer.isIncluded != nil else { return .single(nil) }
            if useProjection {
                let total = exteralessFilteredAccountBadge(account: context.account, countChats: countChats, includeTags: settings.totalUnreadCountIncludeTags)
                if peer.isIncluded == false {
                    return total |> map { exteralessDialogBackBadgeText(total: $0, peerUnreadCount: nil, peerIsIncluded: false, peerIsMarkedUnread: peer.isMarkedUnread, countChats: countChats, entryPointAllowsBadge: entryPointAllowsBadge) }
                }
                return combineLatest(total, exteralessFilteredChatSummary(account: context.account, peerId: peerId))
                |> map { total, summary in
                    exteralessDialogBackBadgeText(total: total, peerUnreadCount: summary.unreadCount, peerIsIncluded: peer.isIncluded, peerIsMarkedUnread: peer.isMarkedUnread, countChats: countChats, entryPointAllowsBadge: entryPointAllowsBadge)
                }
            }
            let total = renderedTotalUnreadCount(inAppSettings: settings, totalUnreadState: totalReadCounters._asCounters()).0
            return .single(exteralessDialogBackBadgeText(total: total, peerUnreadCount: peerUnreadCount, peerIsIncluded: peer.isIncluded, peerIsMarkedUnread: peer.isMarkedUnread, countChats: countChats, entryPointAllowsBadge: entryPointAllowsBadge))
        }
    }
    |> distinctUntilChanged
}
