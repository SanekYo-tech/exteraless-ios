import Foundation

enum ClientHarnessScenario {
    static let baseline = ["core-light", "core-dark", "sdk-ui"]
    static let domains = ["feed-render", "player-render", "pill-render"]
    static let finalVisuals = ["avatar-render", "composer-render"]
    static func isDomain(_ value: String) -> Bool { domains.contains(value) }
    static func isFinalVisual(_ value: String) -> Bool { finalVisuals.contains(value) }
    static func needsSourceEvidence(_ value: String) -> Bool { isDomain(value) || isFinalVisual(value) }
    static func contains(_ value: String) -> Bool { baseline.contains(value) || needsSourceEvidence(value) }
}
