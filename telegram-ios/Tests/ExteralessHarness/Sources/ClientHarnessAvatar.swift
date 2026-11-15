import AccountContext
import AsyncDisplayKit
import AvatarNode
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Positions real AvatarNode/complete-image outputs and labels only. No contour,
/// letters compositor, transition overlay or expected-output raster is drawn here.
@MainActor
private final class ClientHarnessAvatarBoard: UIViewController {
    let avatar = AvatarNode(font: UIFont.systemFont(ofSize: 18), appearanceSettings: .shared)
    let stage = UILabel()
    private var previews: [(UILabel, UIImageView)] = []
    private(set) var side: CGFloat = 60
    private var textColor = UIColor.label

    override func viewDidLoad() {
        super.viewDidLoad()
        self.stage.numberOfLines = 2
        self.stage.font = .systemFont(ofSize: 15, weight: .semibold)
        self.view.addSubview(self.stage)
        self.view.addSubview(self.avatar.view)
        self.avatar.view.accessibilityIdentifier = "client-harness.avatar.actual"
    }
    func appearance(_ data: PresentationData) {
        self.view.backgroundColor = data.theme.list.blocksBackgroundColor
        self.textColor = data.theme.list.itemPrimaryTextColor
        self.stage.textColor = self.textColor
        self.previews.forEach { $0.0.textColor = self.textColor }
    }
    func resize(_ side: CGFloat) { self.side = side; self.view.setNeedsLayout(); self.view.layoutIfNeeded() }
    func images(_ images: [(String, UIImage)]) {
        self.previews.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview() }
        self.previews = images.map { title, image in
            let label = UILabel(); label.text = title; label.textColor = self.textColor
            label.font = .systemFont(ofSize: 11); label.numberOfLines = 2; label.textAlignment = .center
            let view = UIImageView(image: image); view.contentMode = .center
            self.view.addSubview(label); self.view.addSubview(view)
            return (label, view)
        }
        self.view.setNeedsLayout(); self.view.layoutIfNeeded()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.stage.frame = CGRect(x: 16, y: 8, width: self.view.bounds.width - 32, height: 44)
        self.avatar.frame = CGRect(x: (self.view.bounds.width - self.side) / 2, y: 65 + (100 - self.side) / 2,
            width: self.side, height: self.side)
        let column = (self.view.bounds.width - 24) / 4
        for (index, item) in self.previews.enumerated() {
            let x = 12 + CGFloat(index % 4) * column
            let y = 195 + CGFloat(index / 4) * 112
            item.1.frame = CGRect(x: x, y: y, width: column, height: 64)
            item.0.frame = CGRect(x: x, y: y + 66, width: column, height: 40)
        }
    }
    func stop() {
        self.avatar.setCustomLetters([" "])
        self.avatar.imageNode.clearContents()
        self.avatar.view.removeFromSuperview()
        self.images([])
    }
}

@MainActor
extension ClientHarnessSession {
    func runAvatarScenario() async throws {
        try await ClientHarnessLocalImages.install(context: self.context)
        let cache = ClientHarnessAvatarCache(context: self.context)
        let red = try await cache.warm(ClientHarnessLocalImages.redId, size: Int(60 * self.window.screen.scale))
        let green = try await cache.warm(ClientHarnessLocalImages.greenId, size: Int(60 * self.window.screen.scale))
        let redPeer = clientHarnessAvatarPeer(ClientHarnessLocalImages.redId)
        let board = ClientHarnessAvatarBoard()
        let host = ClientHarnessDomainHost(context: self.context, title: "Native Avatar fixture", child: board)
        self.navigation.pushViewController(host)
        defer { board.stop() }
        try await self.driver.settle()
        let avatar = board.avatar
        let instance = self.viewIdentities.id(avatar.view)
        var deliveries: [ClientHarnessAvatarDelivery] = []

        for dark in [false, true] {
            let palette = dark ? "dark" : "light"
            let prefix = "avatar-" + palette + "-"
            self.setDark(dark)
            let data = self.context.shared.currentPresentationData.with { $0 }
            board.appearance(data); board.images([]); board.resize(60)
            avatar.font = .systemFont(ofSize: 18)
            try ClientSettings.shared.set(.integer(0), for: "appearance.avatarCorners")
            board.stage.text = "\(palette) · legacy letters / square"
            avatar.setPeer(context: self.context, theme: data.theme, peer: redPeer, overrideLetters: ["A"],
                overrideImage: AvatarNodeImageOverride.none, synchronousLoad: true)
            avatar.recursivelyEnsureDisplaySynchronously(true)
            try await self.driver.settle(0.25)
            let legacyPixels = try ClientHarnessImagePixels(clientHarnessViewImage(avatar.view))
            try clientHarnessRequire(avatar.contentNode.contents != nil && (legacyPixels.alpha.first ?? 0) > 240, "legacy Avatar never drew its square raster")
            try self.visualProbe(prefix + "legacy", view: board.view, extra: self.avatarEvidence(avatar))

            let child = ClientHarnessAvatarDelivery(), pending = ClientHarnessAvatarDelivery(), current = ClientHarnessAvatarDelivery()
            deliveries += [child, pending, current]
            avatar.imageNode.setSignal(child.signal())
            try child.enqueue(green)
            avatar.contentNode.setNeedsDisplay()
            cache.delayed = true; cache.delivery = pending
            avatar.setPeerV2(imageCache: cache, peer: redPeer)
            board.stage.text = "\(palette) · V2 pending / old raster retired"
            try await self.driver.settle(0.15)
            try clientHarnessRequire(avatar.contentNode.contents == nil && avatar.imageNode.contents == nil && avatar.contentNode.displaySuspended,
                "AF01 pending V2 retained an old parent/child raster")
            try self.visualProbe(prefix + "v2-pending", view: board.view, extra: self.avatarEvidence(avatar))
            try ClientSettings.shared.reset("appearance.avatarCorners")
            cache.delivery = current
            avatar.setPeerV2(imageCache: cache, peer: redPeer)
            try pending.enqueue(green); try current.enqueue(red)
            avatar.font = .systemFont(ofSize: 31)
            avatar.recursivelyEnsureDisplaySynchronously(true)
            try await self.driver.settle(0.25)
            try self.requireAvatarImage(avatar, equals: red)
            try clientHarnessRequire(avatar.contentNode.contents == nil && avatar.imageNode.cornerRadius == 30, "AF01 round reset restored legacy drawing")
            board.stage.text = "\(palette) · V2 red / round"
            try self.visualProbe(prefix + "v2", view: board.view, extra: self.avatarEvidence(avatar))

            cache.delayed = false; cache.delivery = nil
            avatar.setPeerV2(imageCache: cache, peer: redPeer, clipStyle: .bubble)
            let mask = avatar.imageNode.layer.mask
            for side in [CGFloat(60), 38, 100] {
                board.resize(side)
                board.stage.text = "\(palette) · native bubble \(Int(side))pt"
                try await self.driver.settle(0.2)
                try clientHarnessRequire(mask != nil && avatar.imageNode.layer.mask === mask
                    && mask?.name == "appearance.avatar.bubbleClip" && mask?.frame == avatar.imageNode.bounds
                    && avatar.imageNode.cornerRadius == 0, "AF02 bubble retained old radius or lost its resized mask")
                try self.visualProbe(prefix + "bubble-\(Int(side))", view: board.view, extra: self.avatarEvidence(avatar))
            }

            board.resize(60)
            let tail = ClientHarnessAvatarDelivery(), childTail = ClientHarnessAvatarDelivery()
            deliveries += [tail, childTail]
            cache.delivery = tail
            avatar.setPeerV2(imageCache: cache, peer: redPeer, storeUnrounded: true)
            avatar.imageNode.setSignal(childTail.signal())
            try tail.enqueue(red); try childTail.enqueue(red)
            avatar.setCustomLetters(["B"])
            avatar.recursivelyEnsureDisplaySynchronously(true)
            board.stage.text = "\(palette) · custom B / image subscriptions cancelled"
            try await self.driver.settle(0.25)
            try clientHarnessRequire(avatar.imageNode.contents == nil && avatar.unroundedImage == nil
                && avatar.imageNode.layer.mask == nil && avatar.imageNode.cornerRadius == 0, "AF04 left an actual image behind custom letters")
            try self.visualProbe(prefix + "letters", view: board.view, extra: self.avatarEvidence(avatar))
            avatar.setCustomLetters([" "]); avatar.recursivelyEnsureDisplaySynchronously(true)
            board.stage.text = "\(palette) · blank custom letters / no photo"
            try await self.driver.settle(0.2)
            try self.visualProbe(prefix + "blank", view: board.view, extra: self.avatarEvidence(avatar))
            avatar.setPeer(context: self.context, theme: data.theme, peer: redPeer, overrideLetters: ["Q"],
                overrideImage: AvatarNodeImageOverride.none, synchronousLoad: true)
            board.stage.text = "\(palette) · actual overrideLetters Q"
            try await self.driver.settle(0.2)
            try self.visualProbe(prefix + "override", view: board.view, extra: self.avatarEvidence(avatar))

            board.stage.text = "\(palette) · active photo fade → Q at frame 2"
            cache.delivery = nil
            avatar.setPeerV2(imageCache: cache, peer: redPeer)
            // Keep the real V2 round clip; arrange the ImageNode exactly as the
            // native ASC01 fixture (no previous child bitmap before the two puts).
            avatar.imageNode.clearContents()
            let crossfade = ClientHarnessAvatarCrossfade(avatar: avatar)
            let fade = try await crossfade.record(red: red, green: green)
            let beforePath = try self.saveVisualImage(fade.before, name: prefix + "fade-before", kind: "presentation-layer-before-active-reset")
            let afterPath = try self.saveVisualImage(fade.after, name: prefix + "fade-after", kind: "presentation-layer-after-active-reset")
            try await self.driver.settle(0.25)
            try self.visualProbe(prefix + "active-fade-reset", view: board.view,
                extra: ["avatar": self.avatarEvidence(avatar), "events": fade.events,
                    "beforeImage": beforePath, "afterImage": afterPath, "resetAfterDisplayFrames": 2])
            cache.delivery = nil
            avatar.setPeerV2(imageCache: cache, peer: clientHarnessAvatarPeer(ClientHarnessLocalImages.greenId))
            // Same late old completion as the ASC01 fixture, now after the new V2
            // bitmap is installed and with the preceding real-time frames retained.
            fade.completion?.animationDidStop?(fade.animation, finished: true)
            try tail.enqueue(red); try childTail.enqueue(red)
            board.stage.text = "\(palette) · new V2 green / retired completion ignored"
            try await self.driver.settle(0.25)
            try self.requireAvatarImage(avatar, equals: green)
            try clientHarnessRequire(avatar.contentNode.contents == nil, "new V2 retained letters raster")
            try self.visualProbe(prefix + "v2-return", view: board.view, extra: self.avatarEvidence(avatar))

            for corners in [0, 14, 28] {
                for single in [false, true] {
                    try ClientSettings.shared.set(.integer(Int64(corners)), for: "appearance.avatarCorners")
                    try ClientSettings.shared.set(.bool(single), for: "appearance.singleCornerRadius")
                    let comparison = try self.avatarComparisonImages()
                    board.images(comparison.images)
                    board.stage.text = "\(palette) · corners \(corners) / singleRadius \(single)"
                    try await self.driver.settle(0.2)
                    try self.visualProbe(prefix + "forum-\(corners)-" + (single ? "unified" : "native"), view: board.view,
                        extra: ["corners": corners, "singleRadius": single, "comparisons": comparison.facts])
                }
            }
        }
        board.stop()
        try self.driver.back(); try await self.driver.settle()
        try clientHarnessRequire(deliveries.allSatisfy { $0.counts == ["starts": 1, "cancellations": 1] }, "Avatar pending image subscription leaked")
        try clientHarnessRequire(self.navigation.viewControllers.count == 1 && avatar.view.window == nil, "Avatar view survived cleanup")
        self.report.facts["visualFamily"] = ["name": "avatar-render", "realNativeRenderer": true, "cleanup": true,
            "avatarInstance": instance, "cache": "DirectMediaImageCache", "cacheRequests": cache.requests,
            "deliveries": deliveries.map(\.counts), "activeFadeResets": 2]
        try self.probe("avatar-cleanup", extra: ["attached": avatar.view.window != nil, "subscriptions": deliveries.map(\.counts)])
    }

    private func requireAvatarImage(_ avatar: AvatarNode, equals expected: UIImage) throws {
        guard let actual = avatar.imageNode.image else { throw ClientHarnessFailure(description: "actual Avatar ImageNode has no bitmap") }
        try clientHarnessRequire(try ClientHarnessImagePixels(actual).rgba == ClientHarnessImagePixels(expected).rgba,
            "retired Avatar image replaced the current cached bitmap")
    }

    private func avatarEvidence(_ avatar: AvatarNode) -> [String: Any] {
        let frame = avatar.view.convert(avatar.view.bounds, to: self.window)
        return ["instance": self.viewIdentities.id(avatar.view), "renderer": NSStringFromClass(type(of: avatar)),
            "parentRaster": avatar.contentNode.contents != nil, "childRaster": avatar.imageNode.contents != nil,
            "unroundedImage": avatar.unroundedImage != nil, "displaySuspended": avatar.contentNode.displaySuspended,
            "size": [avatar.bounds.width, avatar.bounds.height], "cornerRadius": avatar.imageNode.cornerRadius,
            "windowFrame": [frame.minX, frame.minY, frame.width, frame.height],
            "mask": avatar.imageNode.layer.mask?.name ?? "", "clip": String(describing: avatar.resolvedClipStyle),
            "crossfades": avatar.imageNode.layer.sublayers?.filter { $0.name == "ImageNode.Crossfade" }.count ?? 0]
    }

    private func avatarComparisonImages() throws -> (images: [(String, UIImage)], facts: [[String: Any]]) {
        func image(forum: Bool, photo: Bool, rounded: Bool = true, letters: Bool = true, font: CGFloat = 16) throws -> UIImage {
            var result: UIImage?
            let disposable = peerAvatarCompleteImage(peer: clientHarnessAvatarPeer(ClientHarnessLocalImages.redId, forum: forum, photo: photo),
                size: CGSize(width: 60, height: 60), round: rounded, font: .monospacedSystemFont(ofSize: font, weight: .regular),
                drawLetters: letters, fullSize: true, appearanceSettings: .shared, imageDataProvider: { representation, synchronous in
                    guard let resource = representation.resource as? LocalFileMediaResource,
                          resource.fileId == ClientHarnessLocalImages.redId, synchronous else {
                        fatalError("client-ui-harness: complete Avatar image requested an unprovided resource")
                    }
                    return .single((ClientHarnessLocalImages.red, .complete))
                }).start(next: { if let image = $0 { result = image } })
            disposable.dispose()
            guard let result else { throw ClientHarnessFailure(description: "native complete Avatar compositor did not emit synchronously") }
            return result
        }
        var images: [(String, UIImage)] = [], facts: [[String: Any]] = []
        for forum in [false, true] {
            let photo = try image(forum: forum, photo: true)
            let empty = try image(forum: forum, photo: false, letters: false)
            let alpha = try ClientHarnessImagePixels(photo).alpha
            try clientHarnessRequire(try alpha == ClientHarnessImagePixels(empty).alpha, "AF03 photo/fallback contours diverged")
            images += [(forum ? "Forum PNG" : "Regular PNG", photo),
                (forum ? "Forum letters" : "Regular letters", try image(forum: forum, photo: false))]
            facts.append(["forum": forum, "photoAlpha": clientHarnessSHA256(alpha),
                "fallbackAlpha": try clientHarnessSHA256(ClientHarnessImagePixels(empty).alpha)])
        }
        let nonePhoto = try image(forum: true, photo: true, rounded: false)
        let noneLetters = try image(forum: true, photo: false, rounded: false)
        try clientHarnessRequire(try ClientHarnessImagePixels(nonePhoto).alpha.allSatisfy { $0 == 255 }
            && ClientHarnessImagePixels(noneLetters).alpha.allSatisfy { $0 == 255 }, "unrounded Avatar unexpectedly clipped")
        let small = try image(forum: true, photo: false, font: 9)
        let large = try image(forum: true, photo: false, font: 20)
        try clientHarnessRequire(try ClientHarnessImagePixels(small).rgba != ClientHarnessImagePixels(large).rgba,
            "complete Avatar compositor ignored its caller font")
        images += [("None PNG", nonePhoto), ("None letters", noneLetters), ("Forum font 9", small), ("Forum font 20", large)]
        return (images, facts)
    }
}
