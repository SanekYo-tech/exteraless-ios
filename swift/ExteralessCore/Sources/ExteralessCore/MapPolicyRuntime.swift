import Foundation

/// Shared policy epoch only; no selected-account singleton. Actual resource keys
/// remain account/view scoped. All consumers see cancellation before new work.
public final class MapPolicyRuntime: @unchecked Sendable {
    public static let shared = MapPolicyRuntime()
    public static let didChange = Notification.Name("ExteralessMapPolicyDidChange")
    private let lock = NSLock()
    private var value: UInt64 = 1
    private var observation: ClientSettingsObservation?
    private init() {
        observation = ClientSettings.shared.observe { [weak self] keys in
            if keys.isEmpty || !keys.isDisjoint(with: MapFeatures.keys) { self?.invalidate() }
        }
    }
    public var epoch: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    public func invalidate() {
        lock.lock(); value &+= 1; lock.unlock()
        MapResourceCache.shared.clear()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
