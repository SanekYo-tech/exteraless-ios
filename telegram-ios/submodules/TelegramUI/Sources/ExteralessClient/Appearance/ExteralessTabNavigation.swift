import AccountContext
import Display
import ExteralessCore
import Foundation
import TabBarUI

/// Apply after native Calls/News composition. Objects and selection are retained;
/// no controller is reconstructed merely because another tab was hidden.
public func exteralessIsSettingsRootTab(_ controllerType: ViewController.Type) -> Bool {
    return controllerType is PeerInfoScreen.Type
}

public func exteralessFilterRootTabs(_ controllers: [ViewController], contactsController: ViewController?) -> [ViewController] {
    let hideContacts = ClientSettings.shared.bool("appearance.mainTabsHideContacts")
    let hideSettings = ExteralessAppearanceEntry.isMainMenuAvailable && ClientSettings.shared.bool("appearance.mainTabsHideProfile")
    return controllers.filter { controller in
        if hideContacts, let contactsController, controller === contactsController { return false }
        if hideSettings && exteralessIsSettingsRootTab(type(of: controller)) { return false }
        return true
    }
}

public func exteralessRootTabsAreHidden() -> Bool {
    ExteralessAppearanceEntry.isMainMenuAvailable && ClientSettings.shared.bool("appearance.hideBottomNavigationBar")
}

func exteralessApplyRootTabAppearance(context: AccountContext) {
    guard let root = context.sharedContext.mainWindow?.viewController as? TelegramRootController,
          let tabs = root.rootTabController as? TabBarControllerImpl,
          let contacts = root.contactsController,
          let chats = root.chatListController,
          chats.context === context else { return }
    var controllers = tabs.controllers
    if ClientSettings.shared.bool("appearance.mainTabsHideContacts") {
        controllers.removeAll { $0 === contacts }
    } else if !controllers.contains(where: { $0 === contacts }) {
        controllers.insert(contacts, at: 0)
    }
    controllers = exteralessReplaceContactsWithFeed(controllers, contacts: contacts, feed: root.exteralessFeedTabController(), enabled: ExteralessFeedEntry.isTabVisible)
    if let settings = root.accountSettingsController {
        if ExteralessAppearanceEntry.isMainMenuAvailable && ClientSettings.shared.bool("appearance.mainTabsHideProfile") {
            controllers.removeAll { $0 === settings }
        } else if !controllers.contains(where: { $0 === settings }) {
            controllers.append(settings)
        }
    }
    let hideBar = exteralessRootTabsAreHidden()
    if controllers.map(ObjectIdentifier.init) != tabs.controllers.map(ObjectIdentifier.init) {
        let selected = AppearanceTabPolicy.selectedIndex(current: hideBar ? ObjectIdentifier(chats) : tabs.currentController.map(ObjectIdentifier.init), visible: controllers.map(ObjectIdentifier.init), fallback: ObjectIdentifier(chats))
        tabs.setControllers(controllers, selectedIndex: selected)
    } else if hideBar, tabs.currentController !== chats, let index = controllers.firstIndex(where: { $0 === chats }) {
        tabs.selectedIndex = index
    }
    tabs.updateExteralessTabBarHidden(hideBar, transition: .immediate)
}
