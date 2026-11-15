import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramUIPreferences

@MainActor
public final class ExteralessChatIntegration {
    private typealias PresentationScope = ChatContextPresentationScope<ObjectIdentifier, ExteralessChatTableController>
    private var context: AccountContext?
    private let presentationScope = PresentationScope(invalidate: { screen in
        MainActor.assumeIsolated { screen.invalidateAccount() }
    })
    private var observation: ClientSettingsObservation?
    private let playerUpdate = MetaDisposable()
    private let rulesQueue = DispatchQueue(label: "Exteraless.Chats.LinkRules", qos: .utility)

    public init() {
        ExteralessGalleryChatActions.install()
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            Task { @MainActor [weak self] in
                if keys.contains("chats.musicPlaybackSpeed") { self?.updatePlayingMusicRate() }
                if keys.contains("chats.stripTrackingOnOpen") || keys.contains("chats.stripTrackingOnPaste") { self?.preloadLinkRules() }
            }
        }
    }

    private func registerActions(lease: PresentationScope.Lease) {
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "chats.feed", title: "Channel Feed", section: "Chats · Feed", action: { [weak self] context, parent in
                self?.open(context: context, parent: parent, lease: lease, factory: { ExteralessFeedController(context: context) })
            }),
            ExteralessSettingsAction(id: "chats.player", title: "Now Playing and Playback Controls", section: "Chats · Playback", action: { [weak self] context, parent in
                self?.open(context: context, parent: parent, lease: lease, factory: { ExteralessPlayerController(context: context) })
            }),
            ExteralessSettingsAction(id: "chats.bookmarks", title: "Message Bookmarks", section: "Chats · Actions", action: { [weak self] context, parent in
                self?.open(context: context, parent: parent, lease: lease, factory: { ExteralessBookmarksController(context: context) })
            }),
            ExteralessSettingsAction(id: "chats.deleteDefaults", title: "Deletion Defaults", section: "Chats · Actions", action: { [weak self] context, parent in
                self?.open(context: context, parent: parent, lease: lease, factory: { ExteralessDeleteDefaultsController(context: context) })
            }),
            ExteralessSettingsAction(id: "chats.trackingFilter", title: "URL-tracking Filter", section: "Chats · Links", action: { [weak self] context, parent in
                self?.open(context: context, parent: parent, lease: lease, factory: { ExteralessLinkRulesController(context: context) })
            })
        ])
    }

    public func update(context: AccountContext) {
        if self.context === context { return }
        self.clearContext()
        self.context = context
        let lease = self.presentationScope.activate(ObjectIdentifier(context))
        self.registerActions(lease: lease)
        self.preloadLinkRules()
    }

    public func clearContext() {
        self.playerUpdate.set(nil)
        ChatLinkConfirmationLedger.shared.clear()
        self.context = nil
        self.presentationScope.clear()
    }

    private func open(context: AccountContext, parent: ViewController, lease: PresentationScope.Lease, factory: @MainActor () -> ExteralessChatTableController) {
        guard self.context === context else { return }
        self.presentationScope.open(identity: ObjectIdentifier(context), lease: lease, factory: {
            MainActor.assumeIsolated { factory() }
        }, present: { screen in
            MainActor.assumeIsolated { parent.push(screen) }
        })
    }

    private func updatePlayingMusicRate() {
        guard let context = self.context else { return }
        self.playerUpdate.set((context.sharedContext.mediaManager.musicMediaPlayerState
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self, let context, self.context === context,
                  let (account, _, _) = value, account.id == context.account.id else { return }
            let rate = AudioPlaybackRate(ChatPlaybackPolicy.musicSpeed(ClientSettings.shared.double("chats.musicPlaybackSpeed", default: 1.0)))
            context.sharedContext.mediaManager.playlistControl(.setBaseRate(rate), type: .music)
        }))
    }

    private func preloadLinkRules() {
        guard let context = self.context,
              ClientSettings.shared.bool("chats.stripTrackingOnOpen", default: true) || ClientSettings.shared.bool("chats.stripTrackingOnPaste", default: true) else { return }
        let overrideURL = exteralessTrackingFilterURL(context: context)
        let bundledURL = exteralessBundledTrackingFilterURL()
        self.rulesQueue.async {
            // A bad override retains the last known-good cached rules. The filter screen surfaces
            // the read failure and allows Reset; startup does not modify the user's file.
            try? ChatTrackingRulesStore.shared.configure(overrideURL: overrideURL, bundledURL: bundledURL)
        }
    }
}
