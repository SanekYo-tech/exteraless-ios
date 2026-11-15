import AccountContext
import ExteralessCore
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences

/// ApplicationContext's badge source. The stock counter remains authoritative
/// when no local filters apply. Zero on an incomplete filtered view clears only
/// the OS number; no unread state or message is marked read.
func exteralessPrivacyExtrasApplicationBadge(context: AccountContext) -> Signal<Int32, NoError> {
    let identity = exteralessPrivacyExtrasIdentity(context.account)
    return combineLatest(renderedTotalUnreadCount(accountManager: context.sharedContext.accountManager, engine: context.engine), context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]), ExteralessFilteringRuntime.shared.changes, ExteralessHiddenAccounts.shared.changes)
    |> mapToSignal { raw, shared, _, _ -> Signal<Int32, NoError> in
        guard ExteralessHiddenAccounts.shared.shouldNotify(identity) else { return .single(0) }
        let policy = ExteralessFilteringRuntime.shared.policy(identity)
        guard policy.hasSenderFilters || policy.configuration.regexFiltersEnabled else { return .single(raw.0) }
        let settings = shared.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? .defaultSettings
        return exteralessFilteredAccountBadge(account: context.account, countChats: settings.totalUnreadCountDisplayCategory == .chats, includeTags: settings.totalUnreadCountIncludeTags)
        |> map { $0 ?? 0 }
    }
    |> distinctUntilChanged
}
