import ExteralessCore
import Foundation
import UIKit

public func exteralessAvatarOnlineMarkerOffset(radius: CGFloat) -> CGFloat {
    let policy = AppearanceAvatarPolicy(corners: ClientSettings.shared.integer("appearance.avatarCorners", default: 28))
    return CGFloat(policy.onlineDotOffset(base: 0, radius: Double(radius)))
}

extension AvatarNodeClipStyle {
    /// Carry the resolved shape in the cache key and async draw parameters. Reading
    /// a global preference only inside draw() leaves cached photos at the old shape.
    public func withExteralessShape(size: CGSize) -> AvatarNodeClipStyle {
        let settings = ClientSettings.shared
        let policy = AppearanceAvatarPolicy(corners: settings.integer("appearance.avatarCorners", default: 28), singleRadius: settings.bool("appearance.singleCornerRadius"))
        return self.withExteralessShape(size: size, policy: policy)
    }

    /// Resolve once at the image's display dimensions. Final video/morph/ring
    /// consumers use the resulting fraction, not a second rounded radius.
    public func withExteralessShape(size: CGSize, policy: AppearanceAvatarPolicy) -> AvatarNodeClipStyle {
        guard !policy.preservesNativeShape, min(size.width, size.height) > 0 else { return self }
        let kind: AppearanceAvatarPolicy.Kind
        switch self {
        case .round: kind = .regular
        case .roundedRect: kind = .forum
        case .none, .bubble, .exteralessRoundedRect: return self
        }
        if policy.corners == 28 && policy.singleRadius { return .round }
        let side = min(size.width, size.height)
        return .exteralessRoundedRect(fraction: CGFloat(policy.radius(size: Double(side), kind: kind)) / side)
    }

    var exteralessCornerFraction: CGFloat? {
        if case let .exteralessRoundedRect(fraction) = self { return fraction }
        return nil
    }

    public var exteralessResolvedCornerFraction: CGFloat? {
        switch self {
        case .round: return 0.5
        case .roundedRect: return 0.25
        case let .exteralessRoundedRect(fraction): return min(0.5, max(0, fraction))
        case .none, .bubble: return nil
        }
    }

    /// Explicit final-consumer clipping. Calling code selects the image's already
    /// resolved style; this never globally changes the meaning of .none.
    public func applyExteralessFinalClip(to layer: CALayer, size: CGSize) {
        layer.cornerRadius = min(size.width, size.height) * (self.exteralessResolvedCornerFraction ?? 0)
        switch self {
        case .none:
            layer.mask = nil
            layer.masksToBounds = false
        case .bubble:
            let mask: CALayer
            if let current = layer.mask, current.name == "appearance.avatar.bubbleClip" {
                mask = current
            } else {
                mask = CALayer()
                mask.name = "appearance.avatar.bubbleClip"
                mask.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            }
            if mask.bounds.size != size || mask.contents == nil {
                mask.frame = CGRect(origin: .zero, size: size)
                mask.contents = AvatarNode.avatarBubbleMask(size: size)?.cgImage
            }
            layer.mask = mask
            layer.masksToBounds = true
        case .round, .roundedRect, .exteralessRoundedRect:
            layer.mask = nil
            layer.masksToBounds = true
        }
    }
}
