import Display
import ExteralessCore
import UIKit

/// Component-local vector switch. Native UISwitch remains the style-0 backend;
/// this UIControl owns its public touch/accessibility behavior, not UIKit internals.
final class AppearanceSwitchControl: UIControl {
    private let track = UIView()
    private let thumb = UIView()
    private(set) var isOn = false
    private var style = 2
    private var accent: UIColor = .systemGreen
    private var progress: CGFloat = 0
    private var initialTouchX: CGFloat = 0
    private var initialProgress: CGFloat = 0
    private var dragged = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        self.disablesInteractiveTransitionGestureRecognizer = true
        for view in [track, thumb] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: Bool, style: Int, tint: UIColor?, animated: Bool) {
        let changedStyle = self.style != style
        self.style = style
        self.accent = tint ?? .systemGreen
        self.isOn = value
        if !self.isTracking { self.setProgress(value ? 1 : 0, animated: animated && !changedStyle) }
        self.accessibilityValue = value ? "On" : "Off"
        self.accessibilityTraits = value ? [.button, .selected] : .button
    }

    override var intrinsicContentSize: CGSize { CGSize(width: style == 3 ? 52 : 44, height: 44) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil { self.setProgress(self.isOn ? 1 : 0, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.drawState(pressed: self.isTracking)
    }

    private func drawState(pressed: Bool) {
        let metrics = AppearanceControlPolicy.switchMetrics(style: style, progress: Double(progress), pressed: pressed)
        let x = (bounds.width - CGFloat(metrics.width)) * 0.5
        track.frame = CGRect(x: x, y: (bounds.height - CGFloat(metrics.trackHeight)) * 0.5, width: CGFloat(metrics.width), height: CGFloat(metrics.trackHeight))
        track.layer.cornerRadius = CGFloat(metrics.trackHeight) * 0.5
        track.backgroundColor = UIColor.secondarySystemFill.resolvedColor(with: traitCollection).mixedWith(accent.resolvedColor(with: traitCollection), alpha: progress)
        track.layer.borderWidth = CGFloat(metrics.outlineWidth)
        track.layer.borderColor = UIColor.secondaryLabel.cgColor
        let center = effectiveUserInterfaceLayoutDirection == .rightToLeft ? CGFloat(metrics.width - metrics.centerX) : CGFloat(metrics.centerX)
        thumb.frame = CGRect(x: x + center - CGFloat(metrics.thumbWidth) * 0.5, y: (bounds.height - CGFloat(metrics.thumbHeight)) * 0.5, width: CGFloat(metrics.thumbWidth), height: CGFloat(metrics.thumbHeight))
        thumb.layer.cornerRadius = CGFloat(metrics.thumbHeight) * 0.5
        thumb.backgroundColor = style == 2 ? .white : UIColor.secondaryLabel.resolvedColor(with: traitCollection).mixedWith(.white, alpha: progress)
    }

    private func displayedProgress() -> CGFloat {
        guard let presentation = thumb.layer.presentation(), !thumb.bounds.isEmpty else { return progress }
        let metrics = AppearanceControlPolicy.switchMetrics(style: style, progress: 0, pressed: false)
        let x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - presentation.position.x : presentation.position.x
        return min(1, max(0, (x - (bounds.width - CGFloat(metrics.width)) * 0.5 - CGFloat(metrics.centerX)) / (style == 3 ? 20 : 16)))
    }

    private func setProgress(_ value: CGFloat, animated: Bool) {
        let from = displayedProgress()
        progress = value
        guard animated, !UIAccessibility.isReduceMotionEnabled, window != nil else {
            track.layer.removeAllAnimations()
            thumb.layer.removeAllAnimations()
            drawState(pressed: false)
            return
        }
        UIView.animateKeyframes(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            for step in 1...4 {
                UIView.addKeyframe(withRelativeStartTime: Double(step - 1) / 4, relativeDuration: 0.25) {
                    self.progress = from + (value - from) * CGFloat(step) / 4
                    self.drawState(pressed: false)
                }
            }
        }, completion: nil)
        progress = value
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        initialTouchX = touch.location(in: self).x
        progress = displayedProgress()
        initialProgress = progress
        dragged = false
        track.layer.removeAllAnimations()
        thumb.layer.removeAllAnimations()
        drawState(pressed: true)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        if abs(point.x - initialTouchX) > 3 { dragged = true }
        if dragged {
            let travel: CGFloat = style == 3 ? 20 : 16
            let direction: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
            progress = min(1, max(0, initialProgress + direction * (point.x - initialTouchX) / travel))
            drawState(pressed: true)
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch, !dragged, !bounds.contains(touch.location(in: self)) {
            cancelTracking(with: event)
            return
        }
        let value = dragged ? progress >= 0.5 : !isOn
        self.commit(value)
    }

    override func cancelTracking(with event: UIEvent?) {
        setProgress(isOn ? 1 : 0, animated: true)
    }

    private func commit(_ value: Bool) {
        guard isEnabled else { return }
        let changed = value != isOn
        isOn = value
        self.accessibilityValue = value ? "On" : "Off"
        self.accessibilityTraits = value ? [.button, .selected] : .button
        setProgress(value ? 1 : 0, animated: true)
        if changed { sendActions(for: .valueChanged) }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        commit(!isOn)
        return true
    }
}
