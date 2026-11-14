import Display
import Foundation

/// Connects the settings module to the app's plugin UI without importing TelegramUI.
public enum ExteralessPluginEntry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var factory: ((AccountContext) -> ViewController)?
    }

    private static let storage = Storage()

    /// Register during application bootstrap, before the account settings are displayed.
    /// The factory is invoked on the main thread, outside the storage lock.
    public static func setControllerFactory(_ factory: @escaping (AccountContext) -> ViewController) {
        self.storage.lock.lock()
        self.storage.factory = factory
        self.storage.lock.unlock()
    }

    /// Availability describes the entry point, including a runtime that failed to start.
    public static var isAvailable: Bool {
        self.storage.lock.lock()
        defer { self.storage.lock.unlock() }
        return self.storage.factory != nil
    }

    /// UI callers must be on the main thread, as with other AccountContext factories.
    public static func makeController(context: AccountContext) -> ViewController? {
        precondition(Thread.isMainThread)
        self.storage.lock.lock()
        let factory = self.storage.factory
        self.storage.lock.unlock()
        return factory?(context)
    }
}

/// One localization seam for the plugin entry and screens. Until an Exteraless
/// strings table is shipped, all new UI text has an explicit English fallback.
public enum ExteralessPluginLocalization {
    public static func text(_ key: String, fallback: String) -> String {
        return NSLocalizedString("Exteraless." + key, tableName: "Exteraless", bundle: .main, value: fallback, comment: "")
    }
}
