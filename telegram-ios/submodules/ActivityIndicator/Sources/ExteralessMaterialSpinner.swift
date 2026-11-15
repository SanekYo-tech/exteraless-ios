import Foundation
import UIKit

/// A bounded, vector-only indeterminate Material-style indicator. Core Animation
/// owns the cadence; no display-link, timer, allocations or I/O per frame.
final class ExteralessMaterialSpinner: UIView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var lineWidth: CGFloat = 2
    private var duration: Double = 1.6
    private var wantsAnimation = false
    private var applicationActive = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.applicationActive = UIApplication.shared.applicationState == .active
        for layer in [track, arc] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.motionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationInactive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(color: UIColor, lineWidth: CGFloat, slow: Bool, animating: Bool) {
        self.lineWidth = max(1, lineWidth)
        self.duration = slow ? 2.2 : 1.6
        self.wantsAnimation = animating
        self.track.strokeColor = color.withAlphaComponent(0.16).cgColor
        self.arc.strokeColor = color.cgColor
        self.setNeedsLayout()
        self.updateAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = max(0, min(self.bounds.width, self.bounds.height))
        let width = min(self.lineWidth, max(1, diameter / 4))
        let rect = CGRect(x: (self.bounds.width - diameter) * 0.5 + width * 0.5, y: (self.bounds.height - diameter) * 0.5 + width * 0.5, width: max(0, diameter - width), height: max(0, diameter - width))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, arc] {
            layer.frame = self.bounds
            layer.path = UIBezierPath(ovalIn: rect).cgPath
            layer.lineWidth = width
        }
        self.arc.strokeStart = 0.0
        self.arc.strokeEnd = 0.72
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updateAnimation()
    }

    @objc private func motionChanged() { self.updateAnimation() }
    @objc private func applicationInactive() { self.applicationActive = false; self.updateAnimation() }
    @objc private func applicationBecameActive() { self.applicationActive = true; self.updateAnimation() }

    private func updateAnimation() {
        guard wantsAnimation, window != nil, applicationActive, !isHidden, !UIAccessibility.isReduceMotionEnabled else {
            arc.removeAllAnimations()
            return
        }
        guard arc.animation(forKey: "material.rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -Double.pi / 2
        rotation.toValue = 3 * Double.pi / 2
        rotation.duration = duration
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        let length = CAKeyframeAnimation(keyPath: "strokeEnd")
        length.values = [0.12, 0.78, 0.12]
        length.keyTimes = [0, 0.5, 1]
        length.duration = duration
        length.repeatCount = .infinity
        length.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        arc.add(rotation, forKey: "material.rotation")
        arc.add(length, forKey: "material.length")
    }
}
