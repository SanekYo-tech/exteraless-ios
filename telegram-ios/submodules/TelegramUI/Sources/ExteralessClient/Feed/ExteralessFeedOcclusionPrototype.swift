#if DEBUG
import AccountContext
import ExteralessCore
import Foundation
import SwiftUI
import UIKit

/// Geometry-only window prototype: private registry, synthetic rectangles, no Account/Engine.
/// Useful for recording overlap transitions; it is not a substitute for real feed/player frames.
@MainActor
public struct ExteralessFeedOcclusionPrototype: UIViewControllerRepresentable {
    public init() {}
    public func makeUIViewController(context: Context) -> UIViewController { FeedOcclusionPrototypeController() }
    public func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private final class FeedOcclusionPrototypeController: UIViewController, UIScrollViewDelegate {
    private let registry = ExteralessContentOcclusions()
    private let owner = UUID()
    private let keyboardOwner = UUID()
    private let scroll = UIScrollView()
    private let mode = UISegmentedControl(items: ["Hidden", "Top", "Bottom"])
    private let compact = UISwitch()
    private let keyboardButton = UIButton(type: .system)
    private let summary = UILabel()
    private let bar = UILabel()
    private let keyboard = UILabel()
    private var keyboardVisible = false
    private var posts: [UILabel] = []
    private var subscription: UUID?
    private var rects: [CGRect] = []
    private var updating = false
    private var expired = false
    private var expiry: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.mode.selectedSegmentIndex = 2
        self.mode.addTarget(self, action: #selector(self.controlsChanged), for: .valueChanged)
        self.compact.addTarget(self, action: #selector(self.controlsChanged), for: .valueChanged)
        self.compact.accessibilityLabel = "52 point compact bar"
        self.keyboardButton.setTitle("Keyboard", for: .normal)
        self.keyboardButton.addTarget(self, action: #selector(self.keyboardChanged), for: .touchUpInside)
        self.summary.font = .systemFont(ofSize: 12)
        self.summary.numberOfLines = 2
        self.scroll.delegate = self
        self.bar.backgroundColor = .systemIndigo
        self.bar.textColor = .white
        self.bar.textAlignment = .center
        self.keyboard.text = "Synthetic keyboard"
        self.keyboard.textAlignment = .center
        self.keyboard.backgroundColor = .systemGray3
        for view in [self.mode, self.compact, self.keyboardButton, self.summary, self.scroll, self.bar, self.keyboard] { self.view.addSubview(view) }
        for title in ["Small post", "Tall album", "Last small post"] {
            let label = UILabel()
            label.text = title
            label.textAlignment = .center
            label.layer.borderWidth = 2
            label.layer.cornerRadius = 8
            self.posts.append(label)
            self.scroll.addSubview(label)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let window = self.view.window else { return }
        self.subscription = self.registry.subscribe(accountId: 1, window: window, updated: { [weak self] value in
            self?.rects = value.rects
            self?.updateGeometry()
        })
        let expiry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expired = true
            self.registry.clear(owner: self.owner)
            self.registry.clear(owner: self.keyboardOwner)
            if let token = self.subscription { self.registry.unsubscribe(token) }
            self.subscription = nil
            self.bar.isHidden = true
            self.keyboard.isHidden = true
            self.mode.isEnabled = false
            self.compact.isEnabled = false
            self.keyboardButton.isEnabled = false
            self.scroll.isScrollEnabled = false
            self.summary.text = "30 second geometry fixture completed. No account activity."
        }
        self.expiry?.cancel()
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
        self.view.setNeedsLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.expiry?.cancel()
        self.registry.clear(owner: self.owner)
        self.registry.clear(owner: self.keyboardOwner)
        if let subscription = self.subscription { self.registry.unsubscribe(subscription) }
        self.subscription = nil
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !self.expired else { return }
        let inset = self.view.safeAreaInsets
        let width = self.view.bounds.width - inset.left - inset.right
        self.mode.frame = CGRect(x: inset.left + 8, y: inset.top, width: max(100, width - 160), height: 36)
        self.compact.frame = CGRect(x: self.mode.frame.maxX + 8, y: inset.top, width: 51, height: 36)
        self.keyboardButton.frame = CGRect(x: self.compact.frame.maxX + 4, y: inset.top, width: 88, height: 36)
        self.summary.frame = CGRect(x: inset.left + 8, y: inset.top + 38, width: width - 16, height: 36)
        self.scroll.frame = CGRect(x: inset.left, y: self.summary.frame.maxY, width: width, height: max(0, self.view.bounds.height - self.summary.frame.maxY - inset.bottom))
        let frames = [CGRect(x: 8, y: 12, width: width - 16, height: 88), CGRect(x: 8, y: 112, width: width - 16, height: 750), CGRect(x: 8, y: 874, width: width - 16, height: 64)]
        for (post, frame) in zip(self.posts, frames) { post.frame = frame }
        self.scroll.contentSize = CGSize(width: width, height: 950)
        let height: CGFloat = self.compact.isOn ? 52 : 64
        self.bar.frame = CGRect(x: inset.left + 12, y: self.mode.selectedSegmentIndex == 1 ? self.scroll.frame.minY + 6 : self.scroll.frame.maxY - height - 16, width: width - 24, height: height)
        self.bar.text = "Native window rect · \(Int(height)) pt"
        self.bar.isHidden = self.mode.selectedSegmentIndex == 0
        self.keyboard.frame = CGRect(x: inset.left, y: self.scroll.frame.maxY - 240, width: width, height: 240)
        self.keyboard.isHidden = !self.keyboardVisible
        if let window = self.view.window {
            self.registry.publish(owner: self.owner, accountId: 1, window: window, rects: self.bar.isHidden ? [] : [self.bar.convert(self.bar.bounds, to: window)])
            self.registry.publish(owner: self.keyboardOwner, accountId: 1, window: window, rects: self.keyboard.isHidden ? [] : [self.keyboard.convert(self.keyboard.bounds, to: window)])
        }
        self.updateGeometry()
    }

    @objc private func controlsChanged() { self.view.setNeedsLayout() }
    @objc private func keyboardChanged() { self.keyboardVisible.toggle(); self.view.setNeedsLayout() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { self.updateGeometry() }

    private func updateGeometry() {
        guard !self.updating, !self.expired, let window = self.view.window else { return }
        self.updating = true
        defer { self.updating = false }
        func rect(_ value: CGRect) -> FeedContentGeometry.Rect { .init(x: Double(value.minX), y: Double(value.minY), width: Double(value.width), height: Double(value.height)) }
        let occlusions = self.rects.map { rect(self.scroll.convert($0, from: window)) }
        let screen = self.scroll.bounds
        let extra = FeedContentGeometry.additionalInsets(viewport: rect(screen), occlusions: occlusions)
        self.scroll.contentInset = UIEdgeInsets(top: CGFloat(extra.top), left: 0, bottom: CGFloat(extra.bottom), right: 0)
        let viewport = CGRect(x: screen.minX, y: screen.minY + CGFloat(extra.top), width: screen.width, height: max(0, screen.height - CGFloat(extra.top + extra.bottom)))
        var admitted = 0
        for post in self.posts {
            let eligible = FeedContentGeometry.admitsReceipt(post: rect(post.frame), viewport: rect(viewport), onScreen: rect(screen), occlusions: occlusions, active: true, positioned: true)
            post.backgroundColor = eligible ? .systemGreen.withAlphaComponent(0.2) : .systemRed.withAlphaComponent(0.15)
            post.layer.borderColor = (eligible ? UIColor.systemGreen : UIColor.systemRed).cgColor
            if eligible { admitted += 1 }
        }
        self.summary.text = "Geometry only · \(admitted) eligible · top \(Int(extra.top)) / bottom \(Int(extra.bottom))\nPrivate fixture registry; no account, networking or receipts."
    }

    deinit { self.expiry?.cancel() }
}
#endif
