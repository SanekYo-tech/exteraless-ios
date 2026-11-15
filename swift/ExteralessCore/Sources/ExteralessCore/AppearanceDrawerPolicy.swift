import Foundation

public enum AppearanceDrawerPolicy {
    public static func width(available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        return max(0, min(420, min(max(260, available * 0.85), available - min(40, available * 0.15))))
    }

    public static func progress(translation: Double, width: Double) -> Double {
        guard translation.isFinite, width.isFinite, width > 0 else { return 0 }
        return min(1, max(0, translation / width))
    }

    public static func shouldDismiss(progress: Double, velocity: Double, cancelled: Bool) -> Bool {
        return !cancelled && (progress >= 0.28 || velocity >= 600)
    }

    public static func backdropScale(progress: Double, immersive: Bool) -> Double {
        return immersive ? 0.96 + 0.04 * min(1, max(0, progress)) : 1
    }
}
