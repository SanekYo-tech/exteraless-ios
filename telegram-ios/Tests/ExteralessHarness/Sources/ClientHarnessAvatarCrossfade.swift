import AvatarNode
import Foundation
import SwiftSignalKit
import UIKit

/// ASC01 is timed by display callbacks, never a 0.2s settle that would miss it.
/// Images stay in memory until after reset; file I/O cannot delay the reset frame.
@MainActor
final class ClientHarnessAvatarCrossfade: NSObject {
    struct Evidence {
        let before: UIImage
        let after: UIImage
        let events: [[String: Any]]
        let animation: CAAnimation
        let completion: CAAnimationDelegate?
    }
    private let avatar: AvatarNode
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Evidence, Error>?
    private var oldLayer: CALayer?
    private var animation: CAAnimation?
    private var completion: CAAnimationDelegate?
    private let foreign = CALayer()
    private var pipe: ValuePipe<UIImage?>?
    private var started: CFTimeInterval = 0
    private var ticks = 0
    private var before: UIImage?
    private var events: [[String: Any]] = []

    init(avatar: AvatarNode) { self.avatar = avatar }

    func record(red: UIImage, green: UIImage) async throws -> Evidence {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.foreign.name = "ClientHarness.ForeignAvatarOverlay"
            self.avatar.imageNode.layer.addSublayer(self.foreign)
            self.avatar.imageNode.enableAnimatedTransition = true
            self.avatar.imageNode.animateFirstTransition = false
            let pipe = ValuePipe<UIImage?>()
            self.pipe = pipe
            self.avatar.imageNode.setSignal(pipe.signal())
            // Both puts occur AFTER setSignal returned, so wasSynchronous=false.
            pipe.putNext(red)
            pipe.putNext(green)
            self.started = CACurrentMediaTime()
            guard let layer = self.avatar.imageNode.layer.sublayers?.last(where: { $0.name == "ImageNode.Crossfade" }),
                  let key = layer.animationKeys()?.first, let animation = layer.animation(forKey: key), layer.contents != nil else {
                self.finish(.failure(ClientHarnessFailure(description: "ASC01 never installed an active bitmap crossfade")))
                return
            }
            self.oldLayer = layer
            self.animation = animation
            self.completion = animation.delegate
            self.events.append(["name": "fade-installed", "wallTime": Date().timeIntervalSince1970, "mediaTime": self.started,
                "duration": animation.duration, "emissionsAfterSetSignalReturn": 2])
            let link = CADisplayLink(target: self, selector: #selector(self.frame(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard link.timestamp >= self.started else { return }
        self.ticks += 1
        do {
            guard let oldLayer = self.oldLayer, let animation = self.animation else {
                throw ClientHarnessFailure(description: "ASC01 lost its actual crossfade layer")
            }
            if self.ticks <= 2 {
                let opacity = oldLayer.presentation()?.opacity
                try clientHarnessRequire(link.timestamp - self.started < 0.2 && oldLayer.superlayer === self.avatar.imageNode.layer
                    && oldLayer.contents != nil && !(oldLayer.animationKeys()?.isEmpty ?? true), "ASC01 reset would happen after fade completion")
                self.events.append(["name": "active-frame-\(self.ticks)", "wallTime": Date().timeIntervalSince1970,
                    "displayTimestamp": link.timestamp, "targetTimestamp": link.targetTimestamp,
                    "presentationOpacity": opacity as Any? ?? NSNull()])
                if self.ticks == 1 {
                    try clientHarnessRequire(opacity != nil && opacity! > 0, "ASC01 has no presented old bitmap before reset")
                    self.before = try clientHarnessViewImage(self.avatar.view, presentation: true)
                } else {
                    self.avatar.setCustomLetters(["Q"])
                    self.avatar.recursivelyEnsureDisplaySynchronously(true)
                    try clientHarnessRequire(oldLayer.superlayer == nil && oldLayer.contents == nil
                        && (oldLayer.animationKeys()?.isEmpty ?? true), "ASC01 left a retired bitmap/animation attached")
                    try clientHarnessRequire(self.foreign.superlayer === self.avatar.imageNode.layer,
                        "ASC01 reset removed a foreign-owned overlay")
                    self.events.append(["name": "reset-to-letters", "wallTime": Date().timeIntervalSince1970,
                        "mediaTime": CACurrentMediaTime(), "afterDisplayFrames": self.ticks,
                        "oldBitmapReleased": oldLayer.contents == nil, "oldLayerDetached": oldLayer.superlayer == nil])
                }
            } else if self.ticks == 4 {
                try clientHarnessRequire(self.avatar.imageNode.contents == nil && self.avatar.contentNode.contents != nil,
                    "ASC01 old photo covered the new letters")
                let after = try clientHarnessViewImage(self.avatar.view, presentation: true)
                self.events.append(["name": "letters-presented", "wallTime": Date().timeIntervalSince1970,
                    "displayTimestamp": link.timestamp, "targetTimestamp": link.targetTimestamp])
                guard let before = self.before else { throw ClientHarnessFailure(description: "ASC01 before frame missing") }
                self.finish(.success(Evidence(before: before, after: after, events: self.events,
                    animation: animation, completion: self.completion)))
            }
        } catch { self.finish(.failure(error)) }
    }

    private func finish(_ result: Result<Evidence, Error>) {
        self.link?.invalidate(); self.link = nil
        self.foreign.removeFromSuperlayer()
        self.pipe = nil
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
}
