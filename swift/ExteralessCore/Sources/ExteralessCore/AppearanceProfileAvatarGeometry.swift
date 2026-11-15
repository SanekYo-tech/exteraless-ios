import Foundation

/// Geometry of PeerInfo's expanded-photo parent chain: a zero-size parent at
/// centerY, a (-width/2, -width/2) child, a scale, and an outer clipping translation.
/// Disabling elasticity pins the entire header viewport, not just the photo scale.
public struct AppearanceProfileAvatarGeometry: Equatable, Sendable {
    public let contentOffset: Double
    public let centerY: Double
    public let scale: Double
    public let clippingOffsetY: Double
    public let clippingFrameY: Double
    public let clippingContentOffsetY: Double
    public let clippingHeight: Double
    public let headerHeight: Double
    public let photoMinY: Double
    public let photoMaxY: Double

    public static func contentOffset(_ value: Double, elastic: Bool) -> Double {
        let value = value.isFinite ? value : 0
        return elastic ? value : max(0, value)
    }

    public init(width: Double, height: Double, contentOffset: Double, navigationHeight: Double, elastic: Bool) {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let offset = Self.contentOffset(contentOffset, elastic: elastic)
        let pull = max(0, -offset)
        let side = min(width, height)
        self.contentOffset = offset
        self.scale = side > 0 ? 1 + pull / side : 1
        self.centerY = width * 0.5 - offset * 0.5
        // For portrait this is the native (width-height)*(scale-1). Use the
        // actual bottom edge formula so landscape also covers the whole viewport.
        self.clippingOffsetY = pull > 0 ? height + pull - (self.centerY + (height - width * 0.5) * self.scale) : 0
        self.headerHeight = max(max(0, navigationHeight.isFinite ? navigationHeight : 0), height - offset)
        // A positive translation belongs inside the clip. Moving the clip itself
        // downward would cut off the photo's top in wide/short (landscape) layouts.
        self.clippingFrameY = min(0, self.clippingOffsetY)
        self.clippingContentOffsetY = self.clippingOffsetY - self.clippingFrameY
        self.clippingHeight = max(1000, self.headerHeight - self.clippingFrameY)
        self.photoMinY = self.clippingFrameY + self.clippingContentOffsetY + self.centerY - width * 0.5 * self.scale
        self.photoMaxY = self.photoMinY + height * self.scale
    }
}
