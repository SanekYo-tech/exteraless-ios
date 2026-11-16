import Display
import Foundation

/// AccountContext-level seam: PeerInfo can open the client settings without
/// importing TelegramUI or creating an AccountContext/TelegramUI dependency cycle.
public enum ExteralessSettingsEntry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var factory: (@MainActor (AccountContext) -> ViewController?)?
    }

    private static let storage = Storage()

    /// Install at application composition, after configuring/registering settings.
    public static func setControllerFactory(_ factory: @escaping @MainActor (AccountContext) -> ViewController?) {
        self.storage.lock.lock()
        self.storage.factory = factory
        self.storage.lock.unlock()
    }

    public static var isAvailable: Bool {
        self.storage.lock.lock()
        defer { self.storage.lock.unlock() }
        return self.storage.factory != nil
    }

    /// Matches existing AccountContext factories used from legacy main-thread
    /// callbacks. The registered factory itself is main-actor isolated.
    public static func makeController(context: AccountContext) -> ViewController? {
        precondition(Thread.isMainThread)
        self.storage.lock.lock()
        let factory = self.storage.factory
        self.storage.lock.unlock()
        return MainActor.assumeIsolated { factory?(context) }
    }
}

public enum ExteralessSettingsLocalization {
    public static func text(_ key: String, fallback: String) -> String {
        return NSLocalizedString("Exteraless.ClientSettings." + key, tableName: "Exteraless", bundle: .main, value: fallback, comment: "")
    }
}
