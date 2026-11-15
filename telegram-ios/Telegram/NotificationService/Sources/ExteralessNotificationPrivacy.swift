import AppLockState
import ExteralessCore
import Foundation
import NotificationsPresentationData
import PasscodeCore
import TelegramCore
import UserNotifications

private func exteralessNotificationContainer() -> URL? {
    guard let identifier = Bundle.main.bundleIdentifier, let dot = identifier.lastIndex(of: ".") else { return nil }
    let appId = String(identifier[..<dot])
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + appId)
}

func exteralessNotificationRoot() -> URL? {
    return exteralessNotificationContainer()?.appendingPathComponent("telegram-data", isDirectory: true)
}

/// The same app-group file used by the app composition root; it carries settings only.
/// Any failed read falls back to the original, preview-redacting defaults.
func exteralessNotificationPrivacySettings(root: URL) -> PrivacyPolicy {
    do {
        guard let container = exteralessNotificationContainer() else { throw ClientSettingsError.invalidStorageURL }
        try ClientSettings.shared.configure(storageURL: root.appendingPathComponent("exteraless/client-settings.json"), durabilityRootURL: container)
        try ClientSettings.shared.register(PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions)
        return PrivacyPolicy.current
    } catch {
        return PrivacyPolicy()
    }
}

/// Re-read both stores at the extension's actual delivery boundary. Failure cannot
/// reuse a previously allowed filter decision or an old private-account snapshot.
func exteralessReloadNotificationPrivacyExtras() -> Bool {
    guard let root = exteralessNotificationRoot(), let container = exteralessNotificationContainer() else { return false }
    do {
        try ClientSettings.shared.configure(storageURL: root.appendingPathComponent("exteraless/client-settings.json"), durabilityRootURL: container)
        try ClientSettings.shared.register(PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions)
        try ExteralessHiddenAccounts.shared.configure(basePath: root.path,
            accessGroup: PasscodeEnvironment.shared.sharedAccessGroup(), isMainApp: false,
            keychainScope: PasscodeEnvironment.shared.keychainScope, durabilityRootURL: container)
        try ExteralessHiddenAccounts.shared.reload()
        return true
    } catch {
        return false
    }
}

func exteralessRedactedNotificationContent(_ source: UNNotificationContent, message: String) -> UNNotificationContent {
    let content = UNMutableNotificationContent()
    // Creating a new object also drops attributedBody, intent avatars and attachments.
    if !source.title.isEmpty || !source.subtitle.isEmpty || !source.body.isEmpty { content.body = message }
    content.badge = source.badge
    content.sound = source.sound
    content.threadIdentifier = source.threadIdentifier
    content.userInfo = source.userInfo
    content.categoryIdentifier = "unknown"
    return content
}

func exteralessNotificationPrivacyFallback(_ content: UNNotificationContent) -> (UNNotificationContent, Bool) {
    guard let root = exteralessNotificationRoot() else {
        return (exteralessRedactedNotificationContent(content, message: "You have a new message"), true)
    }
    let policy = exteralessNotificationPrivacySettings(root: root)
    let locked: Bool
    if let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: root.path))), let state = try? JSONDecoder().decode(LockState.self, from: data) {
        locked = isAppLocked(state: state)
    } else {
        // Includes protected data before the first unlock. Unknown is not unlocked.
        locked = true
    }
    guard NotificationPrivacyContext(appLocked: locked).decision(policy: policy) == .redact else { return (content, false) }
    let message: String
    if let data = try? Data(contentsOf: URL(fileURLWithPath: notificationsPresentationDataPath(rootPath: root.path))), let presentation = try? JSONDecoder().decode(NotificationsPresentationData.self, from: data) {
        message = presentation.applicationLockedMessageString
    } else { message = "You have a new message" }
    return (exteralessRedactedNotificationContent(content, message: message), true)
}
