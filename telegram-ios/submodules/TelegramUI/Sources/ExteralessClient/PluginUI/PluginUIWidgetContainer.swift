import UIKit

/// The parent stack owns this slot; requested dimensions/margins align the real
/// widget inside it. Fixed widths shrink at narrow viewport boundaries.
final class PluginUIWidgetContainer: UIView {
    let widget: PluginUIWidgetView
    private let widthConstraint: NSLayoutConstraint
    private var heightConstraint: NSLayoutConstraint?
    private var placementConstraint: NSLayoutConstraint?

    init(widget: PluginUIWidgetView) {
        self.widget = widget
        self.widthConstraint = widget.widthAnchor.constraint(equalToConstant: 1)
        super.init(frame: .zero)
        self.isHidden = widget.model.visibility == "gone"
        self.accessibilityElementsHidden = widget.model.visibility != "visible"
        widget.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(widget)
        let margins = widget.model.layout.margins
        let placement: NSLayoutConstraint
        switch widget.model.layout.alignment {
        case "start": placement = widget.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: CGFloat(margins.left))
        case "end": placement = widget.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -CGFloat(margins.right))
        default: placement = widget.centerXAnchor.constraint(equalTo: self.centerXAnchor, constant: CGFloat(margins.left - margins.right) * 0.5)
        }
        // Retain the actual constraints below; no widget writes its own frame.
        self.placementConstraint = placement
        let top = widget.topAnchor.constraint(equalTo: self.topAnchor, constant: CGFloat(margins.top))
        let bottom = widget.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -CGFloat(margins.bottom))
        NSLayoutConstraint.activate([placement, top, bottom])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func constrain(to width: CGFloat, height: CGFloat?) {
        let model = self.widget.model
        let margins = model.layout.margins.fitting(width: Double(width))
        let available = max(0, width - CGFloat(margins.left + margins.right))
        self.widthConstraint.isActive = false
        self.widget.constrain(to: available, height: height)
        let requested: CGFloat
        switch model.layout.width {
        case .fill: requested = available
        case .wrap: requested = self.widget.naturalWidth(maximum: available)
        case let .points(value): requested = value == 0 && model.layout.weight > 0 ? available : min(available, CGFloat(value))
        }
        self.widthConstraint.constant = requested
        self.widthConstraint.isActive = true
        if model.layout.alignment == "start" { self.placementConstraint?.constant = CGFloat(margins.left) }
        else if model.layout.alignment == "end" { self.placementConstraint?.constant = -CGFloat(margins.right) }
        else { self.placementConstraint?.constant = CGFloat(margins.left - margins.right) * 0.5 }
        self.heightConstraint?.isActive = false
        self.heightConstraint = nil
        let requestedHeight: CGFloat?
        switch model.layout.height {
        case .wrap: requestedHeight = nil
        case .fill: requestedHeight = height.map { max(0, $0 - CGFloat(margins.top + margins.bottom)) }
        case let .points(value): requestedHeight = value == 0 && model.layout.weight > 0 ? nil : CGFloat(value)
        }
        if let requestedHeight {
            let constraint = self.widget.heightAnchor.constraint(equalToConstant: requestedHeight)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            self.heightConstraint = constraint
        }
        self.widget.constrain(to: requested, height: requestedHeight ?? height)
    }
}
