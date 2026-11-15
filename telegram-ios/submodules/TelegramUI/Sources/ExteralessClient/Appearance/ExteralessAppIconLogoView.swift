import ExteralessCore
import UIKit

final class ExteralessAppIconLogoView: UIView {
    private let imageView = UIImageView()
    var toggleShape: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.clipsToBounds = true
        self.addSubview(self.imageView)
        self.isAccessibilityElement = true
        self.accessibilityLabel = "App Icon preview"
        self.accessibilityHint = "Long press to change the in-app logo shape"
        self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Toggle logo shape", target: self, selector: #selector(self.toggleForAccessibility))]
        self.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: UIImage?) {
        self.imageView.image = image ?? UIImage(systemName: "app.fill")
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = min(60, max(0, self.bounds.width - 32))
        self.imageView.frame = CGRect(x: (self.bounds.width - side) * 0.5, y: (self.bounds.height - side) * 0.5, width: side, height: side)
        let rounded = ClientSettings.shared.bool("appearance.useSystemIconShape")
        self.imageView.layer.cornerCurve = rounded ? .continuous : .circular
        self.imageView.layer.cornerRadius = side * (rounded ? 0.22 : 0.5)
        self.accessibilityValue = rounded ? "Rounded square" : "Circle"
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { self.toggleShape?() }
    }

    @objc private func toggleForAccessibility() -> Bool {
        self.toggleShape?()
        return self.toggleShape != nil
    }
}
