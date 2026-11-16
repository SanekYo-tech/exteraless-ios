import TelegramPresentationData
import UIKit

/// A table slot for the shipping PluginUIWidgetView/Container renderer. No Python
/// or factory invocation occurs here, including sizing and resource failures.
@MainActor final class PluginUIManagerCustomCell: UITableViewCell, UIGestureRecognizerDelegate {
    private var container: PluginUIWidgetContainer?
    var rootLongAction: (() -> Void)?
    private lazy var rootLongPress: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:)))
        gesture.delegate = self
        self.addGestureRecognizer(gesture)
        return gesture
    }()

    func configure(model: PluginUIWidget, data: PresentationData, enabled: Bool, values: [String: PluginUIJSON],
        change: @escaping (PluginUIWidget, PluginUIJSON) -> Bool,
        select: @escaping (PluginUIWidget, UIView) -> Void,
        activated: @escaping (PluginUIWidget, Bool) -> Void,
        layoutChanged: @escaping () -> Void) throws {
        self.container?.removeFromSuperview()
        _ = self.rootLongPress
        let widget = try PluginUIWidgetView(model: model, data: data, values: values,
            change: change, select: select, activated: activated, layoutChanged: layoutChanged)
        let container = PluginUIWidgetContainer(widget: widget)
        self.container = container
        container.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -6)
        ])
        self.contentView.isUserInteractionEnabled = enabled
        self.contentView.alpha = enabled ? 1 : 0.55
        self.backgroundColor = data.theme.list.itemBlocksBackgroundColor
        self.selectionStyle = .none
        self.accessibilityIdentifier = "plugin-custom:" + model.id
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.container?.constrain(to: max(1, self.contentView.layoutMarginsGuide.layoutFrame.width), height: nil)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                         verticalFittingPriority: UILayoutPriority) -> CGSize {
        let width = max(1, targetSize.width - self.contentView.layoutMargins.left - self.contentView.layoutMargins.right)
        self.container?.constrain(to: width, height: nil)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.container?.removeFromSuperview()
        self.container = nil
        self.rootLongAction = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard self.rootLongAction != nil else { return false }
        var view = touch.view
        while let current = view, current !== self {
            if let widget = current as? PluginUIWidgetView, widget.model.longCallback != nil { return false }
            view = current.superview
        }
        return true
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, self.contentView.isUserInteractionEnabled { self.rootLongAction?() }
    }
}
