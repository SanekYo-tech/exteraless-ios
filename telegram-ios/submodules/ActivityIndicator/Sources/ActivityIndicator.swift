import Foundation
import ExteralessCore
import UIKit
import AsyncDisplayKit
import Display

private func generateIndefiniteActivityIndicatorImage(color: UIColor, diameter: CGFloat = 22.0, lineWidth: CGFloat = 2.0) -> UIImage? {
    return generateImage(CGSize(width: diameter, height: diameter), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        let cutoutAngle: CGFloat = CGFloat.pi * 30.0 / 180.0
        context.addArc(center: CGPoint(x: size.width / 2.0, y: size.height / 2.0), radius: size.width / 2.0 - lineWidth / 2.0, startAngle: 0.0, endAngle: CGFloat.pi * 2.0 - cutoutAngle, clockwise: false)
        context.strokePath()
    })
}

private func convertIndicatorColor(_ color: UIColor) -> UIColor {
    if color.isEqual(UIColor(rgb: 0x007aff)) || color.isEqual(UIColor(rgb: 0x0088ff)) {
        return .gray
    } else if color.isEqual(UIColor(rgb: 0x2ea6ff)) {
        return .white
    } else if color.isEqual(UIColor(rgb: 0x000000)) || color.isEqual(UIColor.black) {
        return .gray
    } else {
        return color
    }
}

public enum ActivityIndicatorType: Equatable {
    case navigationAccent(UIColor)
    case custom(UIColor, CGFloat, CGFloat, Bool)
    
    public static func ==(lhs: ActivityIndicatorType, rhs: ActivityIndicatorType) -> Bool {
        switch lhs {
        case let .navigationAccent(lhsColor):
            if case let .navigationAccent(rhsColor) = rhs, lhsColor.isEqual(rhsColor) {
                return true
            } else {
                return false
            }
        case let .custom(lhsColor, lhsDiameter, lhsWidth, lhsForceCustom):
            if case let .custom(rhsColor, rhsDiameter, rhsWidth, rhsForceCustom) = rhs, lhsColor.isEqual(rhsColor), lhsDiameter == rhsDiameter, lhsWidth == rhsWidth, lhsForceCustom == rhsForceCustom {
                return true
            } else {
                return false
            }
        }
    }
}

public enum ActivityIndicatorSpeed {
    case regular
    case slow
}

public final class ActivityIndicator: ASDisplayNode {
    public var type: ActivityIndicatorType {
        didSet {
            self.refreshAppearance()
        }
    }
    
    private var currentInHierarchy = false
    
    override public var isHidden: Bool {
        didSet {
            self.updateAnimation()
        }
    }
    
    private let speed: ActivityIndicatorSpeed
    
    private let indicatorNode: ASImageNode
    private var indicatorView: UIActivityIndicatorView?
    private var materialView: ExteralessMaterialSpinner?
    private var settingsObservation: ClientSettingsObservation?
    private var backend: AppearancePresentationPolicy.ActivityBackend = .system
    private var isAnimating = false
    
    public init(type: ActivityIndicatorType, speed: ActivityIndicatorSpeed = .regular) {
        self.type = type
        self.speed = speed
        
        self.indicatorNode = ASImageNode()
        self.indicatorNode.isLayerBacked = true
        self.indicatorNode.displaysAsynchronously = false
        
        super.init()
        
        self.addSubnode(self.indicatorNode)
        self.settingsObservation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.contains("appearance.newLoadingStyle") else { return }
            DispatchQueue.main.async { [weak self] in self?.refreshAppearance() }
        }
        self.refreshAppearance()
    }
    
    override public func didLoad() {
        super.didLoad()
        self.refreshAppearance()
    }

    deinit { self.settingsObservation?.cancel() }

    private var metrics: (color: UIColor, diameter: CGFloat, lineWidth: CGFloat, forceCustom: Bool) {
        switch self.type {
        case let .navigationAccent(color): return (color, 22, 2, false)
        case let .custom(color, diameter, width, force): return (color, diameter, width, force)
        }
    }

    private func refreshAppearance() {
        let metrics = self.metrics
        self.backend = AppearancePresentationPolicy.activityBackend(material: ClientSettings.shared.bool("appearance.newLoadingStyle", default: true), forceCustom: metrics.forceCustom)
        self.indicatorNode.image = self.backend == .legacyCustom ? generateIndefiniteActivityIndicatorImage(color: metrics.color, diameter: metrics.diameter, lineWidth: metrics.lineWidth) : nil
        self.indicatorNode.isHidden = self.backend != .legacyCustom
        guard self.isNodeLoaded else { return }
        if self.backend == .system && self.indicatorView == nil {
            let indicator = UIActivityIndicatorView(style: metrics.diameter < 15 ? .medium : .large)
            self.indicatorView = indicator
            self.view.addSubview(indicator)
        }
        if self.backend == .material && self.materialView == nil {
            let indicator = ExteralessMaterialSpinner(frame: .zero)
            self.materialView = indicator
            self.view.addSubview(indicator)
        }
        self.indicatorView?.isHidden = self.backend != .system
        self.materialView?.isHidden = self.backend != .material
        if let indicator = self.indicatorView {
            let style: UIActivityIndicatorView.Style = metrics.diameter < 15 ? .medium : .large
            if indicator.style != style {
                indicator.style = style
                indicator.sizeToFit()
            }
        }
        if case .navigationAccent = self.type { self.indicatorView?.color = metrics.color }
        else { self.indicatorView?.color = convertIndicatorColor(metrics.color) }
        self.layoutContents(size: self.bounds.size)
        self.updateAnimation()
    }
    
    private func updateAnimation() {
        self.isAnimating = !self.isHidden && self.currentInHierarchy
        if self.isAnimating && self.backend == .system { self.indicatorView?.startAnimating() }
        else { self.indicatorView?.stopAnimating() }
        let metrics = self.metrics
        self.materialView?.configure(color: metrics.color, lineWidth: metrics.lineWidth, slow: self.speed == .slow, animating: self.isAnimating && self.backend == .material)
        if self.isAnimating && self.backend == .legacyCustom {
            if self.indicatorNode.layer.animation(forKey: "progressRotation") == nil {
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0.0
                animation.toValue = Double.pi * 2
                animation.duration = self.speed == .slow ? 0.7 : 0.5
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                self.indicatorNode.layer.add(animation, forKey: "progressRotation")
            }
        } else { self.indicatorNode.layer.removeAnimation(forKey: "progressRotation") }
    }
    
    override public func willEnterHierarchy() {
        super.willEnterHierarchy()
        
        self.currentInHierarchy = true
        self.updateAnimation()
    }
    
    override public func didExitHierarchy() {
        super.didExitHierarchy()
        
        self.currentInHierarchy = false
        self.updateAnimation()
    }
    
    override public func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        switch self.type {
        case .navigationAccent:
            return CGSize(width: 22.0, height: 22.0)
        case let .custom(_, diameter, _, _):
            return CGSize(width: diameter, height: diameter)
        }
    }
    
    override public func layout() {
        super.layout()
        
        let size = self.bounds.size
        
        self.layoutContents(size: size)
    }
    
    private func layoutContents(size: CGSize) {
        let indicatorSize = CGSize(width: self.metrics.diameter, height: self.metrics.diameter)
        self.indicatorNode.frame = CGRect(origin: CGPoint(x: ((size.width - indicatorSize.width) / 2.0), y: ((size.height - indicatorSize.height) / 2.0)), size: indicatorSize)
        self.materialView?.frame = self.indicatorNode.frame
        if let indicatorView = self.indicatorView {
            let intrinsicSize = indicatorView.bounds.size
            let scale = min(1.0, indicatorSize.width / max(1.0, intrinsicSize.width))
            indicatorView.transform = CGAffineTransform(scaleX: scale, y: scale)
            indicatorView.center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        }
    }
}
