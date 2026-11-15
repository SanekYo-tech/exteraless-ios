import Foundation

/// Point-space geometry, independent of UIKit and of any account/message side effect.
public enum FeedContentGeometry {
    public struct Rect: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var maxX: Double { self.x + self.width }
        public var maxY: Double { self.y + self.height }
        public var area: Double { self.valid ? self.width * self.height : 0 }
        public var valid: Bool { self.x.isFinite && self.y.isFinite && self.width.isFinite && self.height.isFinite && self.maxX.isFinite && self.maxY.isFinite && self.width > 0 && self.height > 0 }
        public func intersection(_ other: Rect) -> Rect? {
            guard self.valid, other.valid else { return nil }
            let x = max(self.x, other.x), y = max(self.y, other.y)
            let width = min(self.maxX, other.maxX) - x, height = min(self.maxY, other.maxY) - y
            return width > 0 && height > 0 ? Rect(x: x, y: y, width: width, height: height) : nil
        }
    }

    public struct EdgeInsets: Equatable, Sendable {
        public let top: Double
        public let bottom: Double
    }

    /// Reserve the entire band occupied by an edge-adjoining overlay, including its small
    /// edge padding. Heights come from actual rectangles, not hardcoded mini-player sizes.
    public static func additionalInsets(viewport: Rect, occlusions: [Rect], edgePadding: Double = 24) -> EdgeInsets {
        guard viewport.valid else { return EdgeInsets(top: 0, bottom: 0) }
        var top = 0.0, bottom = 0.0
        for rect in occlusions {
            guard let clipped = rect.intersection(viewport) else { continue }
            if clipped.y - viewport.y <= edgePadding { top = max(top, clipped.maxY - viewport.y) }
            if viewport.maxY - clipped.maxY <= edgePadding { bottom = max(bottom, viewport.maxY - clipped.y) }
        }
        return EdgeInsets(top: min(top, viewport.height), bottom: min(bottom, max(0, viewport.height - top)))
    }

    public static func subtract(_ occlusions: [Rect], from rect: Rect) -> [Rect] {
        guard rect.valid else { return [] }
        var result = [rect]
        for occlusion in occlusions where occlusion.valid {
            var next: [Rect] = []
            for piece in result {
                guard let cut = piece.intersection(occlusion) else { next.append(piece); continue }
                let candidates = [
                    Rect(x: piece.x, y: piece.y, width: piece.width, height: cut.y - piece.y),
                    Rect(x: piece.x, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    Rect(x: piece.x, y: cut.y, width: cut.x - piece.x, height: cut.height),
                    Rect(x: cut.maxX, y: cut.y, width: piece.maxX - cut.maxX, height: cut.height)
                ]
                next.append(contentsOf: candidates.filter(\.valid))
            }
            result = next
            if result.isEmpty { break }
        }
        return result
    }

    public static func visibleArea(post: Rect, viewport: Rect, occlusions: [Rect]) -> Double {
        guard let visible = post.intersection(viewport) else { return 0 }
        return self.subtract(occlusions, from: visible).reduce(0) { $0 + $1.area }
    }

    /// A smaller effective viewport must not make a tall obscured post pass. Any actual
    /// overlay intersection with the on-screen bubble/album rejects the whole receipt.
    public static func admitsReceipt(post: Rect, viewport: Rect, onScreen: Rect, occlusions: [Rect], active: Bool, positioned: Bool) -> Bool {
        guard active, positioned, post.valid, viewport.valid,
              let visible = post.intersection(viewport), let screenPart = post.intersection(onScreen) else { return false }
        guard !occlusions.contains(where: { $0.intersection(screenPart) != nil }) else { return false }
        guard visible.width >= post.width - 1 else { return false }
        return visible.height >= min(post.height, viewport.height) - 1
    }
}
