import AccountContext
import Display
import ExteralessCore
import Foundation
import SettingsUI
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
public final class ExteralessPrivacyIntegration {
    private final class ScreenReference {
        weak var screen: ExteralessPrivacyListController?
        init(_ screen: ExteralessPrivacyListController) { self.screen = screen }
    }
    private var context: AccountContext?
    private var screens: [ScreenReference] = []
    private let accountsDisposable = MetaDisposable()
    private let approvalDisposable = MetaDisposable()
    private let notificationPrivacyDisposable = MetaDisposable()
    private let observationMaintenanceDisposable = MetaDisposable()
    private var observation: ClientSettingsObservation?

    public init() {
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "privacy.ghost", title: "Ghost mode and local activity", section: "Ghost mode", action: { [weak self] context, parent in
                self?.open(ExteralessPrivacyOverviewController(context: context), parent: parent)
            }),
            ExteralessSettingsAction(id: "privacy.chat", title: "Privacy for a chat", section: "Ghost exceptions", action: { [weak self] context, parent in
                let selector = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: "Privacy for a chat"))
                selector.peerSelected = { [weak self, weak selector, weak parent] peer, _ in
                    selector?.dismiss()
                    guard let self, let parent, self.context?.account === context.account else { return }
                    self.open(ExteralessPrivacyPeerController(context: context, peerId: peer.id), parent: parent)
                }
                parent.push(selector)
            }),
            ExteralessSettingsAction(id: "privacy.botAccount", title: "Select bot account", section: "Bot privacy", action: { [weak self] context, parent in
                self?.open(ExteralessBotAccountSettingsController(context: context), parent: parent)
            }),
            ExteralessSettingsAction(id: "privacy.proxies", title: "Manage proxies", section: "Proxy", action: { context, parent in parent.push(proxySettingsController(context: context)) }),
            ExteralessSettingsAction(id: "privacy.notifications", title: "Notification diagnostics", section: "Notifications", action: { [weak self] context, parent in
                self?.open(ExteralessNotificationDiagnosticsController(context: context), parent: parent)
            })
        ])
        observation = ClientSettings.shared.observe { keys in
            if keys.isEmpty || keys.contains(where: { $0.hasPrefix("privacy.botPrivacy") }) {
                Task { @MainActor in ExteralessBotAccountRouter.shared.invalidate() }
            }
        }
    }

    public func update(context: AccountContext) {
        if self.context === context { return }
        clearContext()
        self.context = context
        accountsDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self, let context, self.context === context else { return }
            ExteralessBotAccountRouter.shared.update(context: context, accounts: value.accounts.map { $0.1 })
        }))
        approvalDisposable.set(ExteralessBotSendAuthorization.shared.install { account, peerId in
            return ExteralessBotAccountRouter.shared.guardSend(account: account, peerId: peerId)
        })
        notificationPrivacyDisposable.set((combineLatest(context.sharedContext.appLockContext.isPasscodeLocked, exteralessPrivacySettingsChanges())
        |> map { locked, _ in locked && !PrivacyPolicy.current.showNotificationPreviewWhenLocked }
        |> distinctUntilChanged
        |> filter { $0 }
        |> deliverOnMainQueue).start(next: { _ in ExteralessNotificationClearing.hideMessagePreviews() }))
        observationMaintenanceDisposable.set((exteralessPrivacySettingsChanges()
        |> mapToSignal { [weak context] _ -> Signal<Void, NoError> in
            guard let context else { return .complete() }
            return exteralessMaintainPrivacyObservations(engine: context.engine)
        }).start())
    }

    deinit {
        accountsDisposable.dispose()
        approvalDisposable.dispose()
        notificationPrivacyDisposable.dispose()
        observationMaintenanceDisposable.dispose()
        observation?.cancel()
    }

    public func clearContext() {
        accountsDisposable.set(nil)
        approvalDisposable.set(nil)
        notificationPrivacyDisposable.set(nil)
        observationMaintenanceDisposable.set(nil)
        if let context { ExteralessStoryPrivacySessions.shared.clear(accountId: context.account.id.int64) }
        ExteralessBotAccountRouter.shared.clearContext()
        for reference in screens { reference.screen?.invalidateAccount() }
        screens.removeAll()
        context = nil
    }

    private func open(_ screen: ExteralessPrivacyListController, parent: ViewController) {
        guard context?.account === screen.context.account else { return }
        screens.removeAll { $0.screen == nil }
        screens.append(ScreenReference(screen))
        parent.push(screen)
    }
}
