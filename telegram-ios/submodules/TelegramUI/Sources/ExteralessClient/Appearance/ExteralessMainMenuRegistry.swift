import AccountContext
import BrowserUI
import DeviceAccess
import Display
import ExteralessCore
import Foundation
import PeerInfoScreen
import QrCodeUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

public struct ExteralessMainMenuRoute: Sendable {
    public let id: Int
    public let title: String
    public let isAvailable: @MainActor @Sendable (AccountContext) -> Bool
    public let action: @MainActor @Sendable (AccountContext, ViewController) -> Void

    public init(id: Int, title: String, isAvailable: @escaping @MainActor @Sendable (AccountContext) -> Bool = { _ in true }, action: @escaping @MainActor @Sendable (AccountContext, ViewController) -> Void) {
        self.id = id
        self.title = title
        self.isAvailable = isAvailable
        self.action = action
    }
}

/// Domain-owned routes can appear after application composition or capability
/// initialization. Their stored menu positions survive temporary unavailability.
@MainActor
public enum ExteralessMainMenuRegistry {
    public enum RegistrationError: Error { case invalidRoute(Int) }
    private static var routes: [Int: ExteralessMainMenuRoute] = [:]
    private static var actionObserver: NSObjectProtocol?

    public static func register(_ additions: [ExteralessMainMenuRoute]) throws {
        for route in additions {
            guard route.id > 0, route.id <= Int(Int32.max), route.id != 111, !route.title.isEmpty else { throw RegistrationError.invalidRoute(route.id) }
        }
        for route in additions { routes[route.id] = route }
        NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil)
    }

    public static func unregister(ids: Set<Int>) {
        for id in ids { routes.removeValue(forKey: id) }
        NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil)
    }

    public static func route(id: Int) -> ExteralessMainMenuRoute? { routes[id] }
    public static func availableIds(context: AccountContext) -> [Int] {
        routes.values.filter { $0.isAvailable(context) }.map(\.id).sorted()
    }
    public static var registeredIds: [Int] { routes.keys.sorted() }

    static func registerNativeRoutes() {
        let native: [ExteralessMainMenuRoute] = [
            ExteralessMainMenuRoute(id: 105, title: "Bots and Mini Apps", action: { context, parent in
                exteralessOpenMenuSearch(context: context, parent: parent, filter: .apps)
            }),
            ExteralessMainMenuRoute(id: 18, title: "My Profile", action: { context, parent in
                parent.push(exteralessOwnProfileController(context: context, settings: false))
            }),
            ExteralessMainMenuRoute(id: 101, title: "Browser", action: { context, parent in
                // Real browser/address UI without opening an unsolicited external site.
                parent.push(BrowserScreen(context: context, subject: .webPage(url: "about:blank")))
            }),
            ExteralessMainMenuRoute(id: 17, title: "Scan QR Code", action: { context, parent in
                exteralessOpenMenuQRScanner(context: context, parent: parent)
            }),
            ExteralessMainMenuRoute(id: 108, title: "Recent Chats", action: { context, parent in
                exteralessOpenMenuSearch(context: context, parent: parent, filter: .chats)
            }),
            ExteralessMainMenuRoute(id: 109, title: "Wallet", isAvailable: { $0.walletContext != nil }, action: { context, parent in
                guard context.walletContext != nil else { exteralessUnavailableRoute(parent: parent); return }
                parent.push(context.sharedContext.makeWalletScreen(context: context, opensCollectibles: false))
            })
        ]
        do { try register(native.filter { routes[$0.id] == nil }) }
        catch { assertionFailure("Invalid built-in appearance route") }
    }

    /// Bind an existing native domain screen without importing its private
    /// controller type. Both availability and execution re-read the action registry.
    public static func registerSettingsAction(id: Int, title: String, actionId: String) throws {
        if actionObserver == nil {
            actionObserver = NotificationCenter.default.addObserver(forName: ExteralessSettingsUI.actionsDidChange, object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil)
            }
        }
        try register([ExteralessMainMenuRoute(id: id, title: title, isAvailable: { _ in
            ExteralessSettingsUI.registeredActions.contains { $0.id == actionId }
        }, action: { context, parent in
            if let action = ExteralessSettingsUI.registeredActions.first(where: { $0.id == actionId }) {
                action.action(context, parent)
            } else { exteralessUnavailableRoute(parent: parent) }
        })])
    }
}

@MainActor
func exteralessOpenMenuSearch(context: AccountContext, parent: ViewController, filter: ChatListSearchFilter) {
    guard ExteralessAppearanceEntry.isMainMenuAvailable(context: context) else { return }
    if let root = context.sharedContext.mainWindow?.viewController as? TelegramRootController, root.chatListController?.context === context {
        root.openChatsController(activateSearch: true, filter: filter)
    } else {
        let controller = context.sharedContext.makeChatListController(context: context, location: .chatList(groupId: .root), controlsHistoryPreload: false, hideNetworkActivityStatus: false, previewing: false, enableDebugActions: false)
        parent.push(controller)
        controller.activateSearch(filter: filter, query: nil)
    }
}

@MainActor
private func exteralessUnavailableRoute(parent: ViewController) {
    let alert = UIAlertController(title: "Not Available", message: "This menu provider is no longer available for the current account.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
    parent.present(alert, animated: true)
}

func exteralessOwnProfileController(context: AccountContext, settings: Bool) -> ViewController {
    let controller = PeerInfoScreenImpl(context: context, updatedPresentationData: nil, peerId: context.account.peerId, avatarInitiallyExpanded: false, isOpenedFromChat: false, reactionSourceMessageId: nil, callMessages: [], isSettings: settings)
    controller.parentController = context.sharedContext.mainWindow?.viewController as? TelegramRootController
    return controller
}

/// Used by the coordinator's openSettings fallback when the Settings tab is hidden.
public func exteralessOpenSettingsFallback(context: AccountContext, navigationController: NavigationController, edit: Bool) {
    let controller = PeerInfoScreenImpl(context: context, updatedPresentationData: nil, peerId: context.account.peerId, avatarInitiallyExpanded: false, isOpenedFromChat: false, reactionSourceMessageId: nil, callMessages: [], isSettings: true)
    controller.parentController = navigationController as? TelegramRootController
    navigationController.pushViewController(controller)
    if edit { controller.activateEdit() }
}

@MainActor
private func exteralessOpenMenuQRScanner(context: AccountContext, parent: ViewController) {
    let data = context.sharedContext.currentPresentationData.with { $0 }
    DeviceAccess.authorizeAccess(to: .camera(.qrCode), presentationData: data, present: { controller, arguments in
        controller.presentationArguments = arguments
        parent.present(controller, in: .window(.root))
    }, openSettings: { context.sharedContext.applicationBindings.openSettings() }, { [weak parent] allowed in
        guard allowed, let parent, ExteralessAppearanceEntry.isMainMenuAvailable(context: context) else { return }
        let scanner = QrCodeScanScreen(context: context, subject: .customValidated(info: "Scan a QR code to inspect its contents.", validate: { !$0.isEmpty && $0.utf8.count <= 16384 }))
        scanner.completion = { [weak scanner, weak parent] value in
            guard let value, let scanner, let parent else { return }
            scanner.dismiss(completion: {
                guard ExteralessAppearanceEntry.isMainMenuAvailable(context: context) else { return }
                let alert = UIAlertController(title: "QR Code", message: value, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: data.strings.Conversation_ContextMenuCopy, style: .default, handler: { _ in UIPasteboard.general.string = value }))
                if let url = URL(string: value), ["http", "https", "tg", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                    alert.addAction(UIAlertAction(title: "Open", style: .default, handler: { _ in context.sharedContext.applicationBindings.openUrl(value) }))
                }
                alert.addAction(UIAlertAction(title: data.strings.Common_Close, style: .cancel))
                parent.present(alert, animated: true)
            })
        }
        parent.push(scanner)
    })
}
