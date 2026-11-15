import AppBundle
import ExteralessCore
import Foundation
import SwiftSignalKit

private struct ExteralessHeaderIdentity: Equatable {
    let username: String?
    let displayName: String?
}

// Values only, keyed by account record ID. No singleton AccountContext, no disk
// persistence and no cross-account fallback for personal names.
private let exteralessHeaderIdentities = Atomic<[Int64: ExteralessHeaderIdentity]>(value: [:])

public func exteralessUpdateHeaderIdentity(accountId: Int64, username: String?, displayName: String?) {
    let identity = ExteralessHeaderIdentity(username: username, displayName: displayName)
    var changed = false
    _ = exteralessHeaderIdentities.modify { current in
        var current = current
        changed = current[accountId] != identity
        current[accountId] = identity
        return current
    }
    if changed { NotificationCenter.default.post(name: AppearanceFeatures.resourcesChangedNotification, object: nil) }
}

public func exteralessClearHeaderIdentity(accountId: Int64) {
    _ = exteralessHeaderIdentities.modify { current in
        var current = current
        current.removeValue(forKey: accountId)
        return current
    }
}

public func exteralessChatListTitle(accountId: Int64, chatsTitle: String) -> String {
    let identity = exteralessHeaderIdentities.with { $0[accountId] }
    let settings = ClientSettings.shared
    let appName = getAppBundle().object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "exteraless"
    return AppearanceHeaderPolicy.title(mode: settings.integer("appearance.titleText"), custom: settings.string("appearance.customTitle", default: "exteraless"), appName: appName, chatsTitle: chatsTitle, username: identity?.username, displayName: identity?.displayName)
}

public func exteralessHideHeaderStatus() -> Bool {
    return ClientSettings.shared.bool("appearance.hideActionBarStatus")
}
