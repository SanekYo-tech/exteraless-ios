import Foundation

public enum AppearanceControlPolicy {
    public static func hidesAllChatsChip(enabled: Bool, selectedIsAll: Bool, isReordering: Bool, isTransitioning: Bool, hasCustomFolders: Bool) -> Bool {
        enabled && hasCustomFolders && !selectedIsAll && !isReordering && !isTransitioning
    }

    public static func centersHeader(enabled: Bool, scope: Int, isSettings: Bool) -> Bool {
        guard enabled else { return false }
        switch scope {
        case 0: return false
        case 2: return isSettings
        case 3: return !isSettings
        default: return true
        }
    }

    public static func usesMaterialSlider(style: Int, explicitGeometry: Bool, lowerBound: Double, startValue: Double, minimumValue: Double?) -> Bool {
        style == 2 && !explicitGeometry && lowerBound.isFinite && startValue == lowerBound && (minimumValue == nil || minimumValue == lowerBound)
    }

    public struct SwitchMetrics: Equatable, Sendable {
        public let width: Double
        public let trackHeight: Double
        public let centerX: Double
        public let thumbWidth: Double
        public let thumbHeight: Double
        public let outlineWidth: Double
    }

    public static func switchMetrics(style: Int, progress: Double, pressed: Bool) -> SwitchMetrics {
        let p = min(1, max(0, progress.isFinite ? progress : 0))
        if style == 3 {
            let diameter = pressed ? 28 : 16 + 8 * p
            return SwitchMetrics(width: 52, trackHeight: 32, centerX: 16 + 20 * p,
                                 thumbWidth: diameter, thumbHeight: diameter, outlineWidth: 2 * (1 - p))
        }
        let radius = 7 + 4 * p - 2 * p * p
        let stretch = 3 * (1 - abs(2 * p - 1))
        return SwitchMetrics(width: 40, trackHeight: 26, centerX: 12 + 16 * p,
                             thumbWidth: 2 * (radius + stretch), thumbHeight: 2 * radius, outlineWidth: 0)
    }
}
