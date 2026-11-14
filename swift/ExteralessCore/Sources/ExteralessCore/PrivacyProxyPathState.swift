import Foundation

/// Android ProxyUtil changes its decision only in onAvailable, not onLost. Keep
/// the last usable route through airplane mode; replace it on the next usable
/// route. User intent and the selected proxy are not part of this transient state.
public struct PrivacyProxyPathState: Equatable, Sendable {
    public private(set) var lastAvailableConditions: ProxyDisableConditions = []
    public private(set) var isAvailable = false
    public init() {}

    public mutating func update(isAvailable: Bool, mobileData: Bool, wifi: Bool) {
        self.isAvailable = isAvailable
        guard isAvailable else { return }
        var conditions: ProxyDisableConditions = []
        if mobileData { conditions.insert(.mobileData) }
        if wifi { conditions.insert(.wifi) }
        self.lastAvailableConditions = conditions
    }

    public func suppressesProxy(conditions: ProxyDisableConditions) -> Bool {
        !conditions.intersection(lastAvailableConditions).isEmpty
    }
}
