import AccountContext
import Foundation
import UIKit

@MainActor
private final class PlayerOcclusionDisplayLinkTarget: NSObject {
    var update: (() -> Void)?
    @objc func tick() { update?() }
}

/// Geometry-only lease: no playback/messages/network operations. The immutable
/// account and owner cannot be revived by a late layout after retirement.
@MainActor
final class ExteralessPlayerOcclusionPublisher {
    let owner = UUID()
    private let accountId: Int64
    private let registry: ExteralessContentOcclusions
    private weak var view: UIView?
    private weak var publishedWindow: UIWindow?
    private var published = false
    private var retired = false
    private var visible = false
    private var previousRect: CGRect?
    private var animationRects: [CGRect] = []
    private var animationUntil: CFTimeInterval = 0
    private let target = PlayerOcclusionDisplayLinkTarget()
    private var displayLink: CADisplayLink?
    private var windowObservers: [NSObjectProtocol] = []

    init(accountId: Int64, view: UIView, registry: ExteralessContentOcclusions? = nil) {
        self.accountId = accountId
        self.view = view
        self.registry = registry ?? .shared
        target.update = { [weak self] in self?.publishCurrentGeometry() }
        for name in [UIWindow.didBecomeHiddenNotification, UIWindow.didBecomeVisibleNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.retired, let window = notification.object as? UIWindow,
                          window === self.view?.window || window === self.publishedWindow else { return }
                    self.publishCurrentGeometry()
                }
            })
        }
    }

    func update(visible: Bool, animationDuration: Double = 0) {
        guard !retired else { return }
        self.visible = visible
        if animationDuration.isFinite, animationDuration > 0, let view, let window = view.window {
            animationUntil = CACurrentMediaTime() + min(2, animationDuration) + 0.1
            animationRects = publishedWindow === window ? previousRect.map { [$0] } ?? [] : []
            animationRects.append(view.convert(view.bounds, to: window))
        }
        publishCurrentGeometry()
    }

    func retire() {
        guard !retired else { return }
        retired = true
        visible = false
        clearPublication()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
    }

    private func publishCurrentGeometry() {
        guard !retired, visible, let view, let window = view.window, Self.isRendered(view, in: window) else {
            clearPublication()
            return
        }
        let modelRect = view.convert(view.bounds, to: window)
        var rects = [modelRect]
        let now = CACurrentMediaTime()
        // Presentation layers share the window's presentation tree. During an
        // unsettled transition also retain old/new rectangles, as the registry
        // contract requires when a presentation tree isn't available yet.
        if let presented = view.layer.presentation(), let windowLayer = window.layer.presentation(), Self.belongs(presented, to: windowLayer) {
            let rect = presented.convert(presented.bounds, to: windowLayer)
            if abs(rect.minX - modelRect.minX) > 0.1 || abs(rect.minY - modelRect.minY) > 0.1 || abs(rect.width - modelRect.width) > 0.1 || abs(rect.height - modelRect.height) > 0.1 {
                rects.append(rect)
                if animationUntil <= now { animationUntil = now + 0.25 }
            }
        }
        if now < animationUntil {
            if publishedWindow === window { rects.append(contentsOf: animationRects) }
            if displayLink == nil {
                let link = CADisplayLink(target: target, selector: #selector(PlayerOcclusionDisplayLinkTarget.tick))
                link.preferredFramesPerSecond = 30
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            animationUntil = 0
            animationRects = []
            displayLink?.invalidate()
            displayLink = nil
        }
        rects = rects.compactMap { rect in
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
            let rect = rect.intersection(window.bounds)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
        guard !rects.isEmpty else { clearPublication(); return }
        published = true
        publishedWindow = window
        previousRect = modelRect
        registry.publish(owner: owner, accountId: accountId, window: window, rects: rects)
    }

    private func clearPublication() {
        displayLink?.invalidate()
        displayLink = nil
        previousRect = nil
        animationRects = []
        animationUntil = 0
        publishedWindow = nil
        guard published else { return }
        published = false
        registry.clear(owner: owner)
    }

    private static func isRendered(_ view: UIView, in window: UIWindow) -> Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha <= 0.01 { return false }
            if node === window { return true }
            current = node.superview
        }
        return false
    }

    private static func belongs(_ layer: CALayer, to windowLayer: CALayer) -> Bool {
        var current: CALayer? = layer
        while let value = current {
            if value === windowLayer { return true }
            current = value.superlayer
        }
        return false
    }

    deinit {
        displayLink?.invalidate()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        // Normal hide/detachment/stop clears synchronously. This is an owner-only
        // backstop if a caller releases the publisher without its explicit stop.
        if published {
            let owner = owner, registry = registry
            Task { @MainActor in registry.clear(owner: owner) }
        }
    }
}
