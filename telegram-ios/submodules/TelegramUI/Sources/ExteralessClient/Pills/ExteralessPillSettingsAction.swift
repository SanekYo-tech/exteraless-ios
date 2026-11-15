import Foundation

/// The Settings page may outlive its account. Check identity before evaluating a
/// controller factory; an entry action never changes the integration's context.
@MainActor enum ExteralessPillSettingsActionGate {
    @discardableResult static func open<Controller>(requested: AnyObject, current: AnyObject?, active: Bool,
                                                    make: () -> Controller, present: (Controller) -> Void) -> Bool {
        guard active, let current, current === requested else { return false }
        present(make())
        return true
    }
}
