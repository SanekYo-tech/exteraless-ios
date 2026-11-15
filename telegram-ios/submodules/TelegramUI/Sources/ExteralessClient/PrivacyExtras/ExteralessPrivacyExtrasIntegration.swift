import AccountContext
import Display
import ExteralessCore
import Foundation
import PasscodeCore
import PasscodeUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
public final class ExteralessPrivacyExtrasIntegration {
    private var context: AccountContext?
    private var leases: [PrivacyExtrasAccountIdentity: ExteralessFilteringAccountLease] = [:]
    private let environmentDisposable = MetaDisposable()
    private let hiddenDisposable = MetaDisposable()
    private let switchDisposable = MetaDisposable()
    private var hiddenActionRegistered = false
    private var foreground = false
    private var knownIdentities: [PrivacyExtrasAccountIdentity] = []
    private var pendingUnlockCompletion: ((Bool) -> Void)?

    public init() {
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "privacy.localFilters", title: "Local filters for this account", section: "Local filters", action: { context, parent in
                parent.push(ExteralessLocalFiltersController(context: context))
            })
        ])
        hiddenDisposable.set((ExteralessHiddenAccounts.shared.changes |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self else { return }
            self.updateHiddenAction()
            for identity in self.knownIdentities where ExteralessHiddenAccounts.shared.isHidden(identity) { ExteralessNotificationClearing.clearAll(accountId: identity.recordId) }
            ExteralessBotAccountRouter.shared.invalidate()
        }))
    }

    public func update(context: AccountContext) {
        if self.context === context { return }
        environmentDisposable.set(nil)
        self.context = context
        let shared = context.sharedContext
        // Main/extension configure is a bootstrap hunk: no Keychain/filesystem
        // setup is hidden inside this main-thread context callback.
        ExteralessHiddenAccountUnlock.install(accountManager: shared.accountManager, panicDidAdmit: { identity in
            ExteralessNotificationClearing.clearAll(accountId: identity.recordId)
        }, switchAccount: { [weak self, weak shared] plan, completed in
            guard let self, let shared, case let .unlock(identity, _) = plan else { completed(false); return }
            self.pendingUnlockCompletion?(false)
            self.switchDisposable.set(nil)
            var finished = false
            let finish: (Bool) -> Void = { [weak self] value in
                guard !finished else { return }; finished = true
                self?.pendingUnlockCompletion = nil
                completed(value)
            }
            self.pendingUnlockCompletion = finish
            self.switchDisposable.set(exteralessAwaitHiddenAccountPresentation(
                identity: identity,
                primary: shared.activeAccountContexts |> map { $0.primary.map { exteralessPrivacyExtrasIdentity($0.account) } },
                foreground: shared.applicationBindings.applicationInForeground,
                rootReady: ExteralessClientRuntime.shared.accountPresentationReady(for: identity)
            ).start(next: { success in
                guard success, ExteralessHiddenAccounts.shared.canSelect(identity) else { finish(false); return }
                // PasscodeUI rechecks its own presentation/lifecycle generation
                // before unlocking. Switching an account never uncovers a window.
                finish(true)
            }))
            shared.switchToAccount(id: AccountRecordId(rawValue: identity.recordId), fromSettingsController: nil, withChatListController: nil)
        })
        environmentDisposable.set((combineLatest(shared.activeAccountContexts, shared.applicationBindings.applicationInForeground, shared.appLockContext.isPasscodeLocked)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] value, foreground, locked in
            guard let self, let context, self.context === context else { return }
            let accounts = value.accounts.map { $0.1.account }
            let identities = Set(accounts.map(exteralessPrivacyExtrasIdentity))
            self.knownIdentities = Array(identities)
            self.leases = self.leases.filter { identities.contains($0.key) }
            for account in accounts {
                let identity = exteralessPrivacyExtrasIdentity(account)
                if self.leases[identity]?.isForAccount(account) != true { self.leases[identity] = ExteralessFilteringAccountLease(account: account) }
                if ExteralessHiddenAccounts.shared.isHidden(identity) { ExteralessNotificationClearing.clearAll(accountId: identity.recordId) }
            }
            ExteralessHiddenAccounts.shared.update(accounts: accounts, current: value.primary?.account, foreground: foreground, locked: locked)
            if foreground && !self.foreground { for lease in self.leases.values { lease.refresh() } }
            self.foreground = foreground
            self.updateHiddenAction()
        }))
    }

    private func updateHiddenAction() {
        let visible = !ExteralessHiddenAccounts.shared.settingsHidden
        guard visible != hiddenActionRegistered else { return }
        hiddenActionRegistered = visible
        if visible {
            ExteralessSettingsUI.registerActions([
                ExteralessSettingsAction(id: "privacy.hiddenAccounts", title: "Hidden accounts and panic code", section: "Local privacy", action: { context, parent in
                    exteralessOpenHiddenAccountSettings(context: context, parent: parent)
                })
            ])
        } else { ExteralessSettingsUI.unregisterActions(ids: ["privacy.hiddenAccounts"]) }
    }

    public func clearContext() {
        pendingUnlockCompletion?(false); pendingUnlockCompletion = nil
        environmentDisposable.set(nil); switchDisposable.set(nil)
        leases = [:]; context = nil; foreground = false; knownIdentities = []
        ExteralessHiddenAccountUnlock.clear()
        ExteralessHiddenAccounts.shared.clearContext()
    }
    deinit { environmentDisposable.dispose(); hiddenDisposable.dispose(); switchDisposable.dispose() }
}

@MainActor
func exteralessOpenHiddenAccountSettings(context: AccountContext, parent: ViewController) {
    let owner = exteralessPrivacyExtrasIdentity(context.account)
    guard (try? PasscodeCredentialStore.shared.protectionSettings().passcode) != nil else {
        parent.present(textAlertController(context: context, title: "App passcode required", text: "Enable Telegram's passcode in Settings → Privacy and Security → Passcode, then reopen Hidden accounts.", actions: [TextAlertAction(type: .defaultAction, title: context.sharedContext.currentPresentationData.with { $0.strings.Common_OK }, action: {})]), in: .window(.root))
        return
    }
    if let controller = settingsPasscodeSessionController(context: context, completion: { [weak parent, weak context] result in
        guard let parent, let context else { if case let .success(session) = result { session.invalidate() }; return }
        guard case let .success(session) = result else { return }
        guard exteralessPrivacyExtrasIdentity(context.account) == owner else { session.invalidate(); return }
        let controller = ExteralessHiddenAccountsController(context: context, session: session)
        if let navigation = parent.navigationController as? NavigationController { navigation.replaceTopController(controller, animated: true) }
        else { session.invalidate() }
    })) {
        parent.push(controller)
    }
}

/// Handle before URL resolution/network navigation. The capability reveals only
/// the management entry; it still requires the real, ordinary native Settings PIN.
@MainActor
public func exteralessPrivacyExtrasOpenRecoveryURL(context: AccountContext, url: URL, parent: ViewController) -> Bool {
    guard ExteralessHiddenAccounts.shared.acceptsRecoveryURL(url) else { return false }
    exteralessOpenHiddenAccountSettings(context: context, parent: parent)
    return true
}

/// Display-only adapters for account menus, bot routing, Share and shortcut lists.
public func exteralessPrivacyExtrasVisibleAccounts(_ accounts: [AccountWithInfo]) -> [AccountWithInfo] {
    accounts.filter { !ExteralessHiddenAccounts.shared.isHidden(exteralessPrivacyExtrasIdentity($0.account)) }
}
