import Display
import ExteralessCore
import Foundation

/// The application root owns this binding. Its constructor applies the cached
/// preference before the first layout; subsequent changes retain that root/stack.
@MainActor
final class ExteralessAppearanceLayoutModeBinding {
    private weak var root: NavigationController?
    private let settings: ClientSettings
    private var observation: ClientSettingsObservation?

    init(root: NavigationController, settings: ClientSettings = .shared) {
        self.root = root
        self.settings = settings
        self.observation = settings.observe { [weak self] keys in
            guard keys.contains(AppearanceLayoutModePolicy.settingKey) else { return }
            Task { @MainActor [weak self] in self?.apply() }
        }
        self.apply()
    }

    private func apply() {
        self.root?.updateContentLayoutMode(self.settings.integer(AppearanceLayoutModePolicy.settingKey, default: 0))
    }

    deinit { self.observation?.cancel() }
}
