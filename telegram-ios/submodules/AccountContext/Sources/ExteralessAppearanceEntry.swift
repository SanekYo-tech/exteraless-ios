import Display
import Foundation

/// The application supplies presentation. ChatListUI depends only on this seam,
/// never on TelegramUI, and never captures a global AccountContext.
public enum ExteralessAppearanceEntry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        weak var context: AccountContext?
        var menu: (@MainActor (AccountContext, ViewController) -> Void)?
    }
    private static let storage = Storage()

    public static let contextDidChange = Notification.Name("Exteraless.Appearance.EntryContextChanged")

    public static func setMainMenu(context: AccountContext?, handler: (@MainActor (AccountContext, ViewController) -> Void)?) {
        precondition(Thread.isMainThread)
        storage.lock.lock()
        storage.context = context
        storage.menu = handler
        storage.lock.unlock()
        NotificationCenter.default.post(name: contextDidChange, object: nil)
    }

    public static var isMainMenuAvailable: Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.context != nil && storage.menu != nil
    }

    public static func isMainMenuAvailable(context: AccountContext) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.context === context && storage.menu != nil
    }

    @discardableResult
    public static func openMainMenu(context: AccountContext, from controller: ViewController) -> Bool {
        precondition(Thread.isMainThread)
        storage.lock.lock()
        let handler = storage.context === context ? storage.menu : nil
        storage.lock.unlock()
        guard let handler else { return false }
        MainActor.assumeIsolated { handler(context, controller) }
        return true
    }
}
