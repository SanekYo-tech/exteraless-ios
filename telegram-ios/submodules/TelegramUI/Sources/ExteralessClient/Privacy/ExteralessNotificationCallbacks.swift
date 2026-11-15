import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import UserNotifications

func exteralessNotificationAuthorization(_ value: UNAuthorizationStatus) -> PrivacyNotificationAuthorization {
    switch value {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .authorized: return .authorized
    case .provisional: return .provisional
    case .ephemeral: return .ephemeral
    @unknown default: return .unknown
    }
}

/// Preserves provisional/ephemeral authorization; requests permission only at a user
/// authorized entry point. Every branch, including denied/unknown, calls completion.
func exteralessRegisterForNotifications(center: UNUserNotificationCenter, authorize: Bool, prepareCategories: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
    let once = PrivacyCompletion<Bool>(completion)
    let register: () -> Void = {
        Queue.mainQueue().async {
            prepareCategories()
            UIApplication.shared.registerForRemoteNotifications()
            once.finish(true)
        }
    }
    center.getNotificationSettings { settings in
        PrivacyNotificationDiagnostics.shared.recordAuthorization(exteralessNotificationAuthorization(settings.authorizationStatus))
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            register()
        case .notDetermined where authorize:
            center.requestAuthorization(options: [.badge, .sound, .alert, .carPlay, .providesAppNotificationSettings]) { granted, _ in
                center.getNotificationSettings { current in
                    PrivacyNotificationDiagnostics.shared.recordAuthorization(exteralessNotificationAuthorization(current.authorizationStatus))
                }
                if granted { register() }
                else { Queue.mainQueue().async { once.finish(false) } }
            }
        default:
            Queue.mainQueue().async { once.finish(false) }
        }
    }
}

/// Stock wakeup processing retains its bounded getDifference work. This watchdog only
/// terminates the OS callback if account initialization never emits; it never polls.
func exteralessBackgroundNotificationCompletion(_ callback: @escaping (UIBackgroundFetchResult) -> Void) -> (UIBackgroundFetchResult) -> Void {
    let once = PrivacyCompletion<UIBackgroundFetchResult> { result in
        Queue.mainQueue().async { callback(result) }
    }
    Queue.mainQueue().after(25.0) { once.finish(.noData) }
    return { result in once.finish(result) }
}

func exteralessForegroundNotificationCompletion(_ callback: @escaping (UNNotificationPresentationOptions) -> Void) -> (UNNotificationPresentationOptions) -> Void {
    let once = PrivacyCompletion<UNNotificationPresentationOptions> { result in
        Queue.mainQueue().async { callback(result) }
    }
    Queue.mainQueue().after(2.0) { once.finish([]) }
    return { result in once.finish(result) }
}

func exteralessForegroundNotificationOptions(context: AccountContext, accountId: AccountRecordId?, notification: UNNotification) -> Signal<UNNotificationPresentationOptions, NoError> {
    return context.sharedContext.appLockContext.isPasscodeLocked
    |> take(1)
    |> map { locked -> UNNotificationPresentationOptions in
        // willPresent cannot rewrite delivered content. Suppress a stale unredacted
        // banner if the app locked after the service extension prepared it.
        if locked && !PrivacyPolicy.current.showNotificationPreviewWhenLocked { return [] }
        if let accountId, context.account.id != accountId || notification.request.content.userInfo["url"] != nil { return [.banner, .list] }
        return []
    }
}
