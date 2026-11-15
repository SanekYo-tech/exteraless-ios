import Foundation
import ExteralessCore
import UIKit
import TelegramPresentationData
import DeviceAccess

enum ApplicationShortcutItemType: String {
    case search
    case compose
    case camera
    case savedMessages
    case account
    case appIcon
    case toolsGhostMode = "app.exteraless.action.TOGGLE_GHOST_MODE"
    case toolsSafeMode = "app.exteraless.action.TOGGLE_SAFE_MODE"
}

struct ApplicationShortcutItem: Equatable {
    let type: ApplicationShortcutItemType
    let title: String
    let subtitle: String?
}

@available(iOS 9.1, *)
extension ApplicationShortcutItem {
    func shortcutItem() -> UIApplicationShortcutItem {
        let icon: UIApplicationShortcutIcon
        switch self.type {
            case .search:
                icon = UIApplicationShortcutIcon(type: .search)
            case .compose:
                icon = UIApplicationShortcutIcon(type: .compose)
            case .camera:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/Camera")
            case .savedMessages:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/SavedMessages")
            case .account:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/Account")
            case .appIcon:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/AppIcon")
            case .toolsGhostMode:
                icon = UIApplicationShortcutIcon(systemImageName: "eye.slash")
            case .toolsSafeMode:
                icon = UIApplicationShortcutIcon(systemImageName: "shield")
        }
        return UIApplicationShortcutItem(type: self.type.rawValue, localizedTitle: self.title, localizedSubtitle: self.subtitle, icon: icon, userInfo: nil)
    }
}

func applicationShortcutItems(strings: PresentationStrings, otherAccountName: String?) -> [ApplicationShortcutItem] {
    if ClientSettings.shared.bool("tools.quickToggles") {
        return [
            ApplicationShortcutItem(type: .toolsGhostMode, title: "Toggle Ghost mode", subtitle: nil),
            ApplicationShortcutItem(type: .toolsSafeMode, title: "Toggle Plugin safe mode", subtitle: nil),
            ApplicationShortcutItem(type: .search, title: strings.Common_Search, subtitle: nil),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil)
        ]
    }
    if let otherAccountName = otherAccountName {
        return [
            ApplicationShortcutItem(type: .search, title: strings.Common_Search, subtitle: nil),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil),
            ApplicationShortcutItem(type: .savedMessages, title: strings.Conversation_SavedMessages, subtitle: nil),
            ApplicationShortcutItem(type: .account, title: strings.Shortcut_SwitchAccount, subtitle: otherAccountName)
        ]
    } else {
        return [
            ApplicationShortcutItem(type: .search, title: strings.Common_Search, subtitle: nil),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil),
            ApplicationShortcutItem(type: .savedMessages, title: strings.Conversation_SavedMessages, subtitle: nil),
            ApplicationShortcutItem(type: .appIcon, title: strings.Shortcut_AppIcon, subtitle: nil)
        ]
    }
}
