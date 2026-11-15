import Display
import ExteralessCore
import UIKit

/// Fills NavigationBarNode's real action-safe title lane; the parent owns its
/// frame. This controls appearance pages without guessing other controllers' roles.
final class ExteralessAppearanceTitleView: UIView, NavigationBarTitleView {
    var requestUpdate: ((ContainedViewLayoutTransition) -> Void)?
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.label.numberOfLines = 1
        self.label.lineBreakMode = .byTruncatingTail
        self.label.accessibilityTraits = .header
        self.addSubview(self.label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, color: UIColor) {
        self.label.text = title
        self.label.textColor = color
        self.label.font = Font.semibold(17)
        let leading: NSTextAlignment = self.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        self.label.textAlignment = AppearanceControlPolicy.centersHeader(enabled: ClientSettings.shared.bool("appearance.centerActionBarTitle"), scope: ClientSettings.shared.integer("appearance.centerActionBarTitleType", default: 1), isSettings: true) ? .center : leading
        self.setNeedsLayout()
        self.requestUpdate?(.immediate)
    }

    func animateLayoutTransition() { self.setNeedsLayout() }

    func updateLayout(availableSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let size = CGSize(width: max(0, availableSize.width), height: max(0, availableSize.height))
        transition.updateFrame(view: self.label, frame: CGRect(origin: .zero, size: size))
        return size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.label.frame = self.bounds
    }
}
