import ExteralessCore
import Foundation
import UIKit

/// Passive decoration, with at most 32 Core Animation layers. It has no touch,
/// scroll, accessibility, display-link or per-frame application work.
public final class ExteralessSnowView: UIView {
    private let settingKey: String
    private var observation: ClientSettingsObservation?
    private var color: UIColor = .white
    private var maximumParticles = 32
    private var paused = false
    private var applicationActive = true
    private var installedSize = CGSize.zero
    private var installedParticles: [AppearanceSnowPolicy.Particle] = []
    private var particles: [CAShapeLayer] = []

    public init(settingKey: String) {
        self.settingKey = settingKey
        super.init(frame: .zero)
        self.applicationActive = UIApplication.shared.applicationState == .active
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.accessibilityElementsHidden = true
        self.clipsToBounds = true
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.contains(settingKey) else { return }
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.environmentChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.environmentChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.enteredBackground), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.enteredForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observation?.cancel(); NotificationCenter.default.removeObserver(self) }

    public func update(color: UIColor, maximumParticles: Int = 32, paused: Bool = false) {
        self.color = color
        self.maximumParticles = maximumParticles
        self.paused = paused
        for particle in particles { particle.fillColor = color.cgColor }
        self.refresh()
    }

    override public func layoutSubviews() { super.layoutSubviews(); self.refresh() }
    override public func didMoveToWindow() { super.didMoveToWindow(); self.refresh() }
    override public var isHidden: Bool { didSet { self.refresh() } }

    @objc private func enteredBackground() { applicationActive = false; self.refresh() }
    @objc private func enteredForeground() { applicationActive = true; self.refresh() }
    @objc private func environmentChanged() { self.refresh() }

    private func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let enabled = window != nil && !isHidden && !paused && applicationActive && ClientSettings.shared.integer(settingKey) == 1
        let values = enabled ? AppearanceSnowPolicy.particles(width: Double(bounds.width), height: Double(bounds.height), maximum: maximumParticles, reducedMotion: UIAccessibility.isReduceMotionEnabled, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) : []
        guard installedSize != bounds.size || installedParticles != values else { return }
        installedSize = bounds.size
        installedParticles = values
        for particle in particles { particle.removeAllAnimations(); particle.removeFromSuperlayer() }
        particles.removeAll(keepingCapacity: true)
        for value in values {
            let particle = CAShapeLayer()
            let radius = CGFloat(value.radius)
            particle.bounds = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            particle.path = UIBezierPath(ovalIn: particle.bounds).cgPath
            particle.fillColor = color.cgColor
            let x = CGFloat(value.xFraction) * bounds.width
            let motion = CAKeyframeAnimation(keyPath: "position")
            motion.values = [NSValue(cgPoint: CGPoint(x: x, y: -4)), NSValue(cgPoint: CGPoint(x: x + CGFloat(value.sway), y: bounds.height * 0.5)), NSValue(cgPoint: CGPoint(x: x, y: bounds.height + 4))]
            motion.keyTimes = [0, 0.5, 1]
            motion.duration = value.duration
            motion.timeOffset = value.phase * value.duration
            motion.repeatCount = .infinity
            motion.calculationMode = .linear
            layer.addSublayer(particle)
            particle.add(motion, forKey: "snow.fall")
            particles.append(particle)
        }
    }
}
