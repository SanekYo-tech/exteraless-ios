import Foundation
import ExteralessCore
import SwiftSignalKit
import UIKit

/// Uses CameraProtocol's active AVFoundation device, not model-name lens guesses.
/// Both controls call rampZoom and receive KVO feedback from the same capture device.
public final class ExteralessCameraZoomControl: UIView {
    private weak var camera: CameraProtocol?
    private var disposable: Disposable?
    private var zoomState: Camera.ZoomState?
    private let lenses = UISegmentedControl(items: [])
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private var pendingZoom: CGFloat?
    private var displayLink: CADisplayLink?
    public var visibilityAllowed = true { didSet { updateVisibility() } }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        background.isUserInteractionEnabled = false
        background.translatesAutoresizingMaskIntoConstraints = false
        background.clipsToBounds = true
        background.layer.cornerRadius = 18
        addSubview(background)
        lenses.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
        lenses.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        lenses.setTitleTextAttributes([.foregroundColor: UIColor.systemYellow], for: .selected)
        lenses.addTarget(self, action: #selector(lensSelected), for: .valueChanged)
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .systemYellow
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.3)
        slider.accessibilityLabel = "Camera zoom"
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderFinished), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        valueLabel.textColor = .white
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        let bottom = UIStackView(arrangedSubviews: [slider, valueLabel])
        bottom.spacing = 8
        let stack = UIStackView(arrangedSubviews: [lenses, bottom])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            lenses.heightAnchor.constraint(equalToConstant: 40), bottom.heightAnchor.constraint(equalToConstant: 40)
        ])
        isHidden = true
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { disposable?.dispose(); displayLink?.invalidate() }

    public func bind(_ camera: CameraProtocol) {
        disposable?.dispose()
        displayLink?.invalidate()
        displayLink = nil
        pendingZoom = nil
        self.camera = camera
        disposable = (camera.zoomState |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else { return }
            let previous = self.zoomState
            self.zoomState = state
            if previous?.deviceId != state?.deviceId {
                self.pendingZoom = nil
                self.displayLink?.invalidate()
                self.displayLink = nil
            }
            if previous?.stops != state?.stops || previous?.neutral != state?.neutral {
                self.lenses.removeAllSegments()
                for (index, stop) in (state?.stops ?? []).enumerated() {
                    self.lenses.insertSegment(withTitle: self.label(stop), at: index, animated: false)
                }
            }
            if !self.slider.isTracking { self.updateValue() }
            self.updateVisibility()
        })
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayLink?.invalidate(); displayLink = nil; pendingZoom = nil }
    }

    private func updateVisibility() {
        isHidden = !visibilityAllowed || zoomState == nil || (zoomState.map { $0.maximum <= $0.minimum } ?? true)
    }

    public func resetZoom(startWide: Bool) {
        guard let state = zoomState else { return }
        pendingZoom = nil
        camera?.rampZoom(startWide ? state.minimum : state.neutral, rate: 8)
    }

    private func label(_ rawValue: CGFloat) -> String {
        let neutral = zoomState?.neutral ?? 1
        return String(format: "%.1f×", rawValue / max(0.01, neutral))
    }

    private func updateValue() {
        guard let state = zoomState else { return }
        let range = log(Double(state.maximum / state.minimum))
        slider.value = range > 0 ? Float(log(Double(state.value / state.minimum)) / range) : 0
        valueLabel.text = label(state.value)
        slider.accessibilityValue = valueLabel.text
        lenses.selectedSegmentIndex = state.stops.firstIndex(where: { abs($0 - state.value) < 0.03 }) ?? UISegmentedControl.noSegment
    }

    @objc private func lensSelected() {
        guard let state = zoomState, state.stops.indices.contains(lenses.selectedSegmentIndex) else { return }
        pendingZoom = nil
        camera?.rampZoom(state.stops[lenses.selectedSegmentIndex], rate: 8)
        if !ClientSettings.shared.bool("appearance.disableVibration") { UISelectionFeedbackGenerator().selectionChanged() }
    }

    @objc private func sliderChanged() {
        guard let state = zoomState else { return }
        let value = state.minimum * CGFloat(exp(Double(slider.value) * log(Double(state.maximum / state.minimum))))
        pendingZoom = min(state.maximum, max(state.minimum, value))
        valueLabel.text = label(value)
        slider.accessibilityValue = valueLabel.text
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(flushZoom))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func sliderFinished() {
        flushZoom()
        updateValue()
    }

    @objc private func flushZoom() {
        displayLink?.invalidate()
        displayLink = nil
        if let value = pendingZoom { camera?.rampZoom(value, rate: 100) }
        pendingZoom = nil
    }
}
