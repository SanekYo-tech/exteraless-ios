import Foundation

/// The stock main-list accessory yields only after its account's replacement is
/// actually mounted. This prevents a missing composition root from hiding audio
/// controls and lets lower-level UI avoid depending on TelegramUI.
public enum PlayerMiniPresentation {
    public static let changed = Notification.Name("Exteraless.Player.MiniPresentationChanged")
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var account: Int64?
    }
    private static let state = State()

    public static func isMounted(account: Int64) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.account == account
    }

    public static func setMounted(account: Int64?) {
        state.lock.lock()
        let changed = state.account != account
        state.account = account
        state.lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}
