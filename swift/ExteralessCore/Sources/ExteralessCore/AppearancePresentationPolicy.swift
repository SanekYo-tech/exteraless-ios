import Foundation

public enum AppearancePresentationPolicy {
    public struct TitleLane: Equatable, Sendable {
        public let origin: Double
        public let width: Double
    }

    /// Titles never steal the touch band occupied by navigation actions.
    public static func titleLane(width: Double, leftButtons: Double, rightButtons: Double) -> TitleLane {
        let width = width.isFinite ? max(0, width) : 0
        let left = min(width, max(0, leftButtons.isFinite ? leftButtons : 0) + 6)
        let right = min(width, max(0, rightButtons.isFinite ? rightButtons : 0) + 6)
        return TitleLane(origin: left, width: max(0, width - left - right))
    }

    public static func composeRadius(side: Double, square: Bool) -> Double {
        guard side.isFinite, side > 0 else { return 0 }
        return square ? min(side / 2, ceil(side * 16 / 56)) : side / 2
    }

    /// Latch once per native transition. Applying this to push and pop preserves
    /// continuity when a back swipe catches an in-flight push.
    public static func navigationParallax(percent: Int) -> Double {
        return 0.3 * Double(min(200, max(0, percent))) / 100
    }

    public static func elasticAvatarScale(stock: Double, enabled: Bool) -> Double {
        guard stock.isFinite else { return 1 }
        return enabled ? max(0, stock) : max(0, min(1, stock))
    }

    public static func showsSenderAvatar(enabled: Bool, hasName: Bool, hasMessage: Bool, isSelf: Bool, isDraft: Bool) -> Bool {
        return enabled && hasName && hasMessage && !isSelf && !isDraft
    }

    public enum ActivityBackend: Equatable, Sendable { case system, legacyCustom, material }
    public static func activityBackend(material: Bool, forceCustom: Bool) -> ActivityBackend {
        return material ? .material : (forceCustom ? .legacyCustom : .system)
    }

    public enum NavigationVariant: Int, Equatable, Sendable { case floating, wide, material }
    public static func navigationVariant(material: Bool, wide: Bool) -> NavigationVariant {
        material ? .material : (wide ? .wide : .floating)
    }

    public struct Rect: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    /// MainTabsUiHelper.setMainTabSelectedIndicatorBounds: at most 56x32,
    /// 6pt from the top with titles, vertically centered without them.
    public static func materialTabIndicator(width: Double, height: Double, showsTitle: Bool) -> Rect {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let w = min(56, max(0, width - 8))
        let h = min(32, height)
        return Rect(x: (width - w) / 2, y: showsTitle ? min(6, max(0, height - h)) : (height - h) / 2, width: w, height: h)
    }
}

/// Keep transient native requests (search/keyboard) independent from the user's
/// persistent preference, so resetting one never clears the other.
public struct AppearanceTabVisibilityPolicy: Equatable, Sendable {
    public var nativeRequest = false
    public var persistentRequest = false
    public init() {}
    public var isHidden: Bool { nativeRequest || persistentRequest }
}
