import Display
import Foundation
import SwiftSignalKit

/// TelegramUI supplies these factories. ChatListUI consumes only AccountContext.
public enum ExteralessFeedEntry {
    public static let presentationChanged = Notification.Name("Exteraless.FeedPresentationChanged")
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var factory: (@MainActor (AccountContext) -> ViewController?)?
        var badge: (@MainActor (AccountContext) -> Signal<(count: Int, isPartial: Bool), NoError>)?
        var tabVisible: (@MainActor () -> Bool)?
    }
    private static let storage = Storage()

    public static func install(factory: @escaping @MainActor (AccountContext) -> ViewController?, unreadBadge: @escaping @MainActor (AccountContext) -> Signal<(count: Int, isPartial: Bool), NoError>, isTabVisible: @escaping @MainActor () -> Bool) {
        storage.lock.lock()
        storage.factory = factory
        storage.badge = unreadBadge
        storage.tabVisible = isTabVisible
        storage.lock.unlock()
    }

    public static var isAvailable: Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.factory != nil
    }

    public static var isTabVisible: Bool {
        precondition(Thread.isMainThread)
        storage.lock.lock()
        let handler = storage.tabVisible
        storage.lock.unlock()
        return MainActor.assumeIsolated { handler?() ?? false }
    }

    public static func makeController(context: AccountContext) -> ViewController? {
        precondition(Thread.isMainThread)
        storage.lock.lock()
        let factory = storage.factory
        storage.lock.unlock()
        return MainActor.assumeIsolated { factory?(context) }
    }

    public static func unreadBadge(context: AccountContext) -> Signal<(count: Int, isPartial: Bool), NoError> {
        precondition(Thread.isMainThread)
        storage.lock.lock()
        let handler = storage.badge
        storage.lock.unlock()
        return MainActor.assumeIsolated { handler?(context) ?? .single((0, true)) }
    }
}
