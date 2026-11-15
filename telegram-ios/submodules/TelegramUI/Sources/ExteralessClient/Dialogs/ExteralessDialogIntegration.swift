import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences

@MainActor
public final class ExteralessDialogIntegration {
    private final class ScreenReference {
        weak var screen: ExteralessDialogForumController?
        init(_ screen: ExteralessDialogForumController) { self.screen = screen }
    }

    private weak var context: AccountContext?
    private let settingsDisposable = MetaDisposable()
    private let archiveDisposable = MetaDisposable()
    private let pinsDisposable = MetaDisposable()
    private var screens: [ScreenReference] = []

    public init() {
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "dialogs.forumLayout", title: "Forum layout for a chat", section: "Chats · Navigation", action: { [weak self] context, parent in
                guard let self, self.context === context else { return }
                let selector = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyGroups, .excludeRecent, .excludeSecretChats, .doNotSearchMessages], hasContactSelector: false, title: "Choose a forum"))
                selector.peerSelected = { [weak self, weak selector, weak parent] peer, _ in
                    selector?.dismiss()
                    guard let self, let parent, self.context === context else { return }
                    let screen = ExteralessDialogForumController(context: context, peerId: peer.id)
                    self.screens.removeAll { $0.screen == nil }
                    self.screens.append(ScreenReference(screen))
                    parent.push(screen)
                }
                parent.push(selector)
            })
        ])
    }

    public func update(context: AccountContext) {
        guard self.context !== context else { return }
        clearContext()
        self.context = context
        settingsDisposable.set((exteralessDialogPolicyUpdates() |> deliverOnMainQueue).start(next: { [weak self, weak context] policy in
            guard let self, let context, self.context === context else { return }
            self.archiveDisposable.set(updateChatArchiveSettings(engine: context.engine, { settings in
                settings.withExteralessArchivePull(policy.openArchiveOnPull)
            }).start())
        }))
        pinsDisposable.set((exteralessDialogPolicyUpdates()
        |> map { $0.unlimitedPinnedDialogs }
        |> distinctUntilChanged
        |> deliverOnMainQueue
        |> mapToSignal { [weak self, weak context] _ -> Signal<Bool, NoError> in
            guard let self, let context, self.context === context else { return .complete() }
            return exteralessUpdateDialogPinPolicy(account: context.account)
        }).start())
    }

    public func clearContext() {
        settingsDisposable.set(nil)
        archiveDisposable.set(nil)
        pinsDisposable.set(nil)
        for reference in screens { reference.screen?.invalidateAccount() }
        screens.removeAll()
        context = nil
    }

    deinit {
        settingsDisposable.dispose()
        archiveDisposable.dispose()
        pinsDisposable.dispose()
    }
}
