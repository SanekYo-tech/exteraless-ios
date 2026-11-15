import Foundation
import UIKit

/// A native accessible UISlider handles gestures. Only its track is drawn as a
/// wave; cancellation and track ownership are handled by ChatPlaybackSeekLease.
final class ExteralessPlayerProgressView: UIView {
    private let slider = UISlider()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private(set) var scrubbing = false
    var began: (() -> Void)?
    var ended: ((Double) -> Void)?
    var cancelled: (() -> Void)?
    var wavy = true
    var phase: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(track)
        layer.addSublayer(progress)
        for layer in [track, progress] { layer.fillColor = UIColor.clear.cgColor; layer.lineWidth = 3; layer.lineCap = .round }
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.accessibilityLabel = "Playback position"
        slider.accessibilityIdentifier = "exteraless.player.position"
        slider.addTarget(self, action: #selector(begin), for: .touchDown)
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        slider.addTarget(self, action: #selector(end), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(self, action: #selector(cancel), for: .touchCancel)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(fraction: Double, enabled: Bool, wavy: Bool, phase: Double, color: UIColor, secondary: UIColor) {
        if !scrubbing { slider.value = Float(min(1, max(0, fraction.isFinite ? fraction : 0))) }
        if !enabled, scrubbing { cancel() }
        slider.isEnabled = enabled
        self.wavy = wavy
        self.phase = phase
        track.strokeColor = secondary.withAlphaComponent(0.25).cgColor
        progress.strokeColor = color.cgColor
        slider.thumbTintColor = color
        drawTrack()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        slider.frame = bounds
        drawTrack()
    }

    private func drawTrack() {
        let rect = slider.trackRect(forBounds: slider.bounds).insetBy(dx: 2, dy: 0)
        let width = max(0, rect.width)
        let y = bounds.midY
        let end = width * CGFloat(slider.value)
        let baseline = UIBezierPath()
        baseline.move(to: CGPoint(x: rect.minX, y: y))
        baseline.addLine(to: CGPoint(x: rect.minX + width, y: y))
        let wave = UIBezierPath()
        let points = max(1, min(256, Int(width / 2)))
        for step in 0...points {
            let x = end * CGFloat(step) / CGFloat(points)
            let taper = min(1, min(x / 10, max(0, (end - x) / 10)))
            let offset = wavy ? sin(Double(x) / 18 * .pi * 2 - phase) * 3 * Double(taper) : 0
            let point = CGPoint(x: rect.minX + x, y: y + CGFloat(offset))
            if step == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = baseline.cgPath
        progress.path = wave.cgPath
        CATransaction.commit()
    }

    @objc private func begin() { scrubbing = true; began?() }
    @objc private func changed() {
        // VoiceOver changes a slider without touchDown/touchUp events.
        if !scrubbing { began?(); ended?(Double(slider.value)) }
        drawTrack()
    }
    @objc private func end() { scrubbing = false; ended?(Double(slider.value)) }
    @objc private func cancel() { scrubbing = false; cancelled?() }
}
