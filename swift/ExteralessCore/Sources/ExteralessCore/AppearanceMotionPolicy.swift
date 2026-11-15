import Foundation

public enum AppearanceMotionPolicy {
    public struct Spring: Equatable, Sendable {
        public let response: Double
        public let dampingRatio: Double
    }

    /// Original IDs: 0 Classic, 1 Spring, 2 Predictive, 3 Slide. Native interactive
    /// tracking stays native; these are release/tap curves in the shared timeline.
    public static func spring(style: Int, stockResponse: Double, stockDampingRatio: Double) -> Spring {
        switch style {
        case 0: return Spring(response: 0.22, dampingRatio: 1)
        case 2: return Spring(response: 0.34, dampingRatio: 1)
        case 3: return Spring(response: 0.30, dampingRatio: 1)
        default: return Spring(response: stockResponse, dampingRatio: stockDampingRatio)
        }
    }

    public static func headerContentAlpha(disappearance: Double, crossfade: Bool) -> Double {
        let value = min(1, max(0, disappearance.isFinite ? disappearance : 0))
        return crossfade ? 1 - value : (value < 0.5 ? 1 : 0)
    }
}
