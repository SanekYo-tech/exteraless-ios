import AppBundle
import Display
import ExteralessCore
import Foundation
import TelegramPresentationData
import UIKit

/// Native floating compose action. The controller owns its frame; this view only
/// lays out the glyph and shape, keeping a 56pt tap target in either style.
final class ExteralessComposeButton: HighlightTrackingButton {
    private let icon = UIImageView()
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.icon.isUserInteractionEnabled = false
        self.addSubview(self.icon)
        self.layer.cornerCurve = .continuous
        self.layer.shadowOpacity = 0.16
        self.layer.shadowRadius = 6
        self.layer.shadowOffset = CGSize(width: 0, height: 2)
        self.accessibilityTraits = .button
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.highligthedChanged = { [weak self] value in self?.alpha = value ? 0.72 : 1.0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(theme: PresentationTheme, title: String) {
        self.backgroundColor = theme.list.itemAccentColor
        self.icon.image = generateTintedImage(image: UIImage(bundleImageName: "Chat List/ComposeIcon"), color: theme.list.itemCheckColors.foregroundColor)
        self.accessibilityLabel = title
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = CGFloat(AppearancePresentationPolicy.composeRadius(side: Double(min(bounds.width, bounds.height)), square: ClientSettings.shared.bool("appearance.squareFab", default: true)))
        self.layer.cornerRadius = radius
        self.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        if let image = self.icon.image {
            let factor = min(1, 28 / max(1, max(image.size.width, image.size.height)))
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            self.icon.frame = CGRect(x: (bounds.width - size.width) * 0.5, y: (bounds.height - size.height) * 0.5, width: size.width, height: size.height)
        }
    }

    @objc private func pressed() { self.action?() }
}
