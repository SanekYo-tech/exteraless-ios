import UIKit

/// Observes the real settings/share/chat controller without subclassing a final
/// native controller. This child has no rendered content and owns no callbacks;
/// the presentation lease owns it along with the actual native screen.
final class PluginUIAppearanceObserver: UIViewController {
    private let appeared: (Bool) -> Void
    private let disappeared: () -> Void

    init(appeared: @escaping (Bool) -> Void, disappeared: @escaping () -> Void) {
        self.appeared = appeared
        self.disappeared = disappeared
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(to controller: UIViewController) {
        controller.addChild(self)
        self.view.isUserInteractionEnabled = false
        self.view.isAccessibilityElement = false
        self.view.accessibilityElementsHidden = true
        self.view.frame = .zero
        controller.view.addSubview(self.view)
        self.didMove(toParent: controller)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.appeared(self.parent?.viewIfLoaded?.window != nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.appeared(false)
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.disappeared()
    }
}
