import Foundation

enum ClientHarnessScenario {
    static let baseline = ["core-light", "core-dark", "sdk-ui"]
    static let domains = ["feed-render", "player-render", "pill-render"]
    static let finalVisuals = ["avatar-render", "composer-render"]
    static let resetSupplement = SettingsResetNavigationChecks.Scenario.allCases.map(\.rawValue)
    static let trustSupplement = ["trust-secondary-permissions"]
    static let mapSupplement = ["map-attribution"]
    static func isDomain(_ value: String) -> Bool { domains.contains(value) }
    static func isFinalVisual(_ value: String) -> Bool { finalVisuals.contains(value) }
    static func isReset(_ value: String) -> Bool { resetSupplement.contains(value) }
    static func isTrustSupplement(_ value: String) -> Bool { trustSupplement.contains(value) }
    static func isMapSupplement(_ value: String) -> Bool { mapSupplement.contains(value) }
    static func needsSourceEvidence(_ value: String) -> Bool { isDomain(value) || isFinalVisual(value) || isReset(value) || isTrustSupplement(value) || isMapSupplement(value) }
    static func contains(_ value: String) -> Bool { baseline.contains(value) || needsSourceEvidence(value) }
}
