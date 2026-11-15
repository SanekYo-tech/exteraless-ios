import Foundation

/// The existing settings controller subscribes with its trusted plugin id (see
/// the exact insertion hunk in docs/wave-2/plugin-ui.md). Notifications trigger
/// the real host settings read, not a cached JSON view refresh.
public enum PluginUISettingsRefresh {
    private static let notification = Notification.Name("ExteralessPluginSettingsReloadRequested")

    @MainActor public static func invalidate(pluginId: String) {
        NotificationCenter.default.post(name: self.notification, object: nil, userInfo: ["pluginId": pluginId])
    }

    @MainActor public static func observe(pluginId: String, refresh: @escaping @MainActor () -> Void) -> PluginUISettingsObservation {
        let token = NotificationCenter.default.addObserver(forName: self.notification, object: nil, queue: .main) { notification in
            guard notification.userInfo?["pluginId"] as? String == pluginId else { return }
            MainActor.assumeIsolated { refresh() }
        }
        return PluginUISettingsObservation(token: token)
    }
}

public final class PluginUISettingsObservation {
    private let token: NSObjectProtocol

    fileprivate init(token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(self.token) }
}
