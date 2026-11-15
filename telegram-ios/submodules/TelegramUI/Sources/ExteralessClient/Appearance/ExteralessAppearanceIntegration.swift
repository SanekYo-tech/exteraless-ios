import AccountContext
import Display
import ExteralessCore
import Foundation
import SettingsUI
import SwiftSignalKit
import TabBarUI
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences

/// Application-owned composition. Native preferences remain authoritative when
/// opened from Telegram's own settings, and client edits use the same transaction
/// APIs. All persistence is scheduled off the main thread.
@MainActor
public final class ExteralessAppearanceIntegration {
    private var context: AccountContext?
    private var observation: ClientSettingsObservation?
    private var presentationDisposable: Disposable?
    private var nativeSettingsDisposable: Disposable?
    private var accountPeerDisposable: Disposable?
    private let nativeWriteDisposable = MetaDisposable()
    private let settingsQueue = DispatchQueue(label: "Exteraless.Appearance.Settings", qos: .utility)
    private let nativeMirrorGeneration = Atomic<UInt64>(value: 0)
    private var nativeCallsVisible: Bool?
    private var pendingCallsVisible: Bool?
    private let rootApplication = AppearanceRootApplication<AnyObject> { value in
        MainActor.assumeIsolated {
            guard let context = value as? AccountContext else { return }
            exteralessApplyRootTabAppearance(context: context)
        }
    }

    public init() {
        ExteralessMainMenuRegistry.registerNativeRoutes()
        do {
            try ExteralessMainMenuRegistry.registerSettingsAction(id: 106, title: "Channel Feed", actionId: "chats.feed")
            try ExteralessMainMenuRegistry.registerSettingsAction(id: 107, title: "Ghost Mode", actionId: "privacy.ghost")
        } catch { assertionFailure("Invalid native menu action route") }
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "appearance.nativeThemes", title: "Themes, Colors, Wallpaper and Text Size", section: "Appearance · Native Settings", action: { context, controller in
                controller.push(themeSettingsController(context: context))
            }),
            ExteralessSettingsAction(id: "appearance.autoNight", title: "Automatic Night Mode", section: "Appearance · Native Settings", action: { context, controller in
                controller.push(themeAutoNightSettingsController(context: context))
            }),
            ExteralessSettingsAction(id: "appearance.appIcons", title: "App Icon", section: "Appearance · Native Settings", action: { context, controller in
                controller.push(ExteralessAppIconsController(context: context))
            }),
            ExteralessSettingsAction(id: "appearance.mainMenu", title: "Main Menu", section: "Appearance · Navigation", action: { context, controller in
                exteralessPresentMainMenu(context: context, from: controller)
            }),
            ExteralessSettingsAction(id: "appearance.customizeMenu", title: "Customize Main Menu", section: "Appearance · Navigation", action: { context, controller in
                controller.push(ExteralessMenuLayoutController(context: context))
            }),
            ExteralessSettingsAction(id: "appearance.iconPacks", title: "Icon Packs", section: "Appearance · Icons", action: { context, controller in
                controller.push(ExteralessIconPacksController(context: context, mode: .list))
            }),
            ExteralessSettingsAction(id: "appearance.editIconPack", title: "Edit Selected Icon Pack", section: "Appearance · Icons", action: { context, controller in
                controller.push(ExteralessIconPacksController(context: context, mode: .editor))
            })
        ])
        ExteralessSettingsUI.registerActions(exteralessMonetSettingsActions())
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            var keys = keys
            // ClientSettings delivers on the mutating thread. A native preference
            // mirror is not another user command to write back to native storage.
            if Thread.current.threadDictionary["Exteraless.Appearance.NativeMirror"] as? Bool == true {
                keys.remove("appearance.mainTabsHideCallsSettings")
            }
            guard keys.contains(where: { $0.hasPrefix("appearance.") }) else { return }
            Task { @MainActor [weak self, keys] in
                self?.settingsChanged(keys)
            }
        }
    }

    public func update(context: AccountContext) {
        if self.context === context { return }
        self.clearContext()
        self.context = context
        ExteralessMonetThemeActions.shared.attach(context: context)
        self.rootApplication.attach(context)
        ExteralessAppearanceEntry.setMainMenu(context: context) { context, controller in
            exteralessPresentMainMenu(context: context, from: controller)
        }
        ExteralessIconPacks.shared.start()
        self.accountPeerDisposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, self.context === context else { return }
            if case let .user(user) = peer {
                let firstName = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = firstName?.isEmpty == false ? firstName : user.lastName
                exteralessUpdateHeaderIdentity(accountId: context.account.id.int64, username: peer?.addressName, displayName: name)
            }
        })
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] _ in
            // Native theme and date-format changes already travel through the
            // presentation pipeline. Keep composition scoped to the current account.
            guard let self, self.context === context else { return }
            self.applyPendingNativeSettings()
            self.rootApplication.applyIfCurrent(context)
        })
        self.nativeSettingsDisposable = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings])
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self, self.context === context else { return }
            let settings = data.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? .defaultSettings
            _ = self.nativeMirrorGeneration.modify { $0 &+ 1 }
            self.nativeCallsVisible = settings.showTab
            if let pending = self.pendingCallsVisible, pending != settings.showTab { return }
            self.pendingCallsVisible = nil
            self.mirrorNativeCallsVisibility(settings.showTab)
            Queue.mainQueue().async { [weak self] in
                guard self?.context === context else { return }
                self?.rootApplication.applyIfCurrent(context)
            }
        })
        NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil)
    }

    /// AppDelegate has now mounted this account's ready root. Initial native
    /// callbacks may all have run against the previous root; this explicit apply
    /// must not be swallowed by update(context:)'s same-context fast path.
    public func rootDidBecomeReady(context: AccountContext) {
        self.rootApplication.applyIfCurrent(context)
    }

    public func clearContext() {
        ExteralessMonetThemeActions.shared.detach()
        self.rootApplication.clear()
        ExteralessAppearanceEntry.setMainMenu(context: nil, handler: nil)
        if let context, let root = context.sharedContext.mainWindow?.viewController as? TelegramRootController,
           root.chatListController?.context === context {
            (root.rootTabController as? TabBarControllerImpl)?.updateExteralessTabBarHidden(false, transition: .immediate)
        }
        _ = self.nativeMirrorGeneration.modify { $0 &+ 1 }
        ExteralessIconPacks.shared.stop()
        if let context { exteralessClearHeaderIdentity(accountId: context.account.id.int64) }
        self.accountPeerDisposable?.dispose()
        self.accountPeerDisposable = nil
        self.presentationDisposable?.dispose()
        self.presentationDisposable = nil
        self.nativeSettingsDisposable?.dispose()
        self.nativeSettingsDisposable = nil
        self.nativeWriteDisposable.set(nil)
        self.context = nil
        self.nativeCallsVisible = nil
        self.pendingCallsVisible = nil
    }

    private func settingsChanged(_ keys: Set<String>) {
        if !keys.isDisjoint(with: ["appearance.mainTabsHideContacts", "appearance.mainTabsHideProfile", "appearance.hideBottomNavigationBar"]), let context { self.rootApplication.applyIfCurrent(context) }
        if !keys.isDisjoint(with: ["appearance.enabled", "appearance.activePacks", "appearance.iconReplacements"]) {
            ExteralessIconPacks.shared.reload()
        }
        if keys.contains("appearance.mainTabsHideCallsSettings") {
            let visible = !ClientSettings.shared.bool("appearance.mainTabsHideCallsSettings")
            guard visible != self.nativeCallsVisible else { return }
            self.pendingCallsVisible = visible
            self.applyPendingNativeSettings()
        }
    }

    private func applyPendingNativeSettings() {
        guard let context, let visible = self.pendingCallsVisible else { return }
        self.nativeWriteDisposable.set(updateCallListSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
            if current.showTab == visible { return current }
            return current.withUpdatedShowTab(visible)
        }).start())
    }

    private func mirrorNativeCallsVisibility(_ visible: Bool) {
        let key = "appearance.mainTabsHideCallsSettings"
        let settings = ClientSettings.shared
        let expected = settings.value(key)
        let generation = self.nativeMirrorGeneration
        let expectedGeneration = generation.with { $0 }
        guard settings.bool(key) != !visible else { return }
        self.settingsQueue.async {
            // A client edit that raced the native read takes precedence.
            guard generation.with({ $0 }) == expectedGeneration, settings.value(key) == expected else { return }
            Thread.current.threadDictionary["Exteraless.Appearance.NativeMirror"] = true
            defer { Thread.current.threadDictionary.removeObject(forKey: "Exteraless.Appearance.NativeMirror") }
            do {
                try settings.set(.bool(!visible), for: key)
            } catch {
                // Native settings still hold the real value; the next native update
                // retries the mirror. Do not change the Calls tab after a write error.
                NSLog("Exteraless appearance: could not mirror native Calls preference")
            }
        }
    }

    deinit {
        self.observation?.cancel()
        self.presentationDisposable?.dispose()
        self.nativeSettingsDisposable?.dispose()
        self.accountPeerDisposable?.dispose()
        self.nativeWriteDisposable.dispose()
    }
}
