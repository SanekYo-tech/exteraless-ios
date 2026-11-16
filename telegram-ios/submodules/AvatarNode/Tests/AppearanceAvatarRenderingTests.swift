import AvatarNode
import AvatarStoryIndicatorComponent
import AsyncDisplayKit
import ComponentFlow
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import XCTest

final class AppearanceAvatarRenderingTests: XCTestCase {
    private func store() throws -> ClientSettings {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-avatar-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"))
        try store.register(AppearanceFeatures.definitions)
        return store
    }

    private func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { allLayers($0) }
    }

    @MainActor
    func testResolvedFractionIsSharedByFinalPhotoVideoAndMorphClips() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let originalBytes = image.pngData()
        let photo = UIImageView(image: image)
        let video = CALayer()
        let sourceSize = CGSize(width: 60, height: 60)
        for corners in [28, 14, 0, 28] {
            for single in [false, true] {
                for native in [AvatarNodeClipStyle.round, .roundedRect] {
                    let shape = native.withExteralessShape(size: sourceSize, policy: AppearanceAvatarPolicy(corners: corners, singleRadius: single))
                    let fraction = try XCTUnwrap(shape.exteralessResolvedCornerFraction)
                    for side in [CGFloat(38), 60, 100, 200] {
                        let size = CGSize(width: side, height: side)
                        shape.applyExteralessFinalClip(to: photo.layer, size: size)
                        shape.applyExteralessFinalClip(to: video, size: size)
                        XCTAssertEqual(photo.layer.cornerRadius, side * fraction, accuracy: 0.000001)
                        XCTAssertEqual(video.cornerRadius, photo.layer.cornerRadius, accuracy: 0.000001)
                        XCTAssertEqual(photo.layer.cornerRadius / side, fraction, accuracy: 0.000001, "expansion loan fraction")
                        XCTAssertTrue(photo.image === image, "gallery source stays unrounded")
                    }
                }
            }
        }
        XCTAssertEqual(image.pngData(), originalBytes)
        let squarePolicy = AppearanceAvatarPolicy(corners: 0)
        XCTAssertEqual(AvatarNodeClipStyle.none.withExteralessShape(size: sourceSize, policy: squarePolicy), .none)
        AvatarNodeClipStyle.none.applyExteralessFinalClip(to: video, size: sourceSize)
        XCTAssertFalse(video.masksToBounds)
        XCTAssertNil(video.mask)
        let fraction = try XCTUnwrap(AvatarNodeClipStyle.round.withExteralessShape(size: sourceSize, policy: AppearanceAvatarPolicy(corners: 14)).exteralessResolvedCornerFraction)
        XCTAssertEqual(38 * fraction, 9.5, accuracy: 0.000001, "do not ceil again at 38pt")
    }

    @MainActor
    func testSameLettersStatsAndFrameStillInvalidateTheVisibleStoryRing() throws {
        let settings = try store()
        let avatar = AvatarNode(font: UIFont.systemFont(ofSize: 20), appearanceSettings: settings)
        avatar.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        _ = avatar.view
        avatar.setCustomLetters(["A"])
        let colors = AvatarNode.Colors(unseenColors: [.red, .red], unseenCloseFriendsColors: [.green, .green], seenColors: [.gray, .gray])
        let stats = AvatarNode.StoryStats(totalCount: 1, unseenCount: 1, hasUnseenCloseFriendsItems: false, hasLiveItems: false, progress: nil)
        avatar.setStoryStats(storyStats: stats, presentationParams: .init(colors: colors, lineWidth: 2, inactiveLineWidth: 1), transition: .init(animation: .none))
        let ring = try XCTUnwrap(avatar.view.subviews.compactMap { $0 as? AvatarStoryIndicatorComponent.View }.first)
        func image() throws -> UIImage {
            try XCTUnwrap(ring.subviews.compactMap { ($0 as? UIImageView)?.image }.first)
        }
        let round = try image()
        try settings.set(.integer(0), for: "appearance.avatarCorners")
        avatar.setCustomLetters(["A"])
        XCTAssertEqual(avatar.resolvedClipStyle.exteralessResolvedCornerFraction, 0)
        XCTAssertEqual(avatar.resolvedStoryCornerFraction, 0)
        XCTAssertFalse(try image() === round, "same stats/frame must not keep the old ring bitmap")

        try settings.reset("appearance.avatarCorners")
        avatar.setCustomLetters(["A"])
        avatar.setStoryStats(storyStats: stats, presentationParams: .init(colors: colors, lineWidth: 2, inactiveLineWidth: 1, forceRoundedRect: true), transition: .init(animation: .none))
        XCTAssertEqual(avatar.resolvedStoryCornerFraction, 0.25)
        let forum = try image()
        try settings.set(.bool(true), for: "appearance.singleCornerRadius")
        avatar.setCustomLetters(["A"])
        XCTAssertEqual(avatar.resolvedStoryCornerFraction, 0.5)
        XCTAssertFalse(try image() === forum)
        try settings.reset("appearance.singleCornerRadius")
        avatar.setCustomLetters(["A"])
        XCTAssertEqual(avatar.resolvedStoryCornerFraction, 0.25)
    }

    @MainActor
    func testNormalAndBothProgressModesUseTheSameFixedContour() throws {
        let host = ComponentView<Empty>()
        let colors = AvatarStoryIndicatorComponent.Colors(unseenColors: [.red, .red], unseenCloseFriendsColors: [.green, .green], seenColors: [.gray, .gray])
        let available = CGSize(width: 52, height: 52)
        for fraction in [CGFloat(0), 0.25, 0.5, 0] {
            for progress in [AvatarStoryIndicatorComponent.Progress.indefinite, .definite(0.6)] {
                let component = AvatarStoryIndicatorComponent(hasUnseen: true, hasUnseenCloseFriendsItems: false, hasLiveItems: false, colors: colors, activeLineWidth: 2, inactiveLineWidth: 1, counters: .init(totalCount: 1, unseenCount: 1), progress: progress, isRoundedRect: false, customCornerFraction: fraction)
                XCTAssertEqual(component.isRoundedRect, fraction < 0.5, "an explicit fraction selects its path")
                _ = host.update(transition: .init(animation: .none), component: AnyComponent(component), environment: {}, containerSize: available)
                let view = try XCTUnwrap(host.view)
                let name: String
                if case .indefinite = progress { name = "appearance.story.loadingContour" }
                else { name = "appearance.story.uploadContour" }
                let layer = try XCTUnwrap(allLayers(view.layer).first { $0.name == name } as? CAShapeLayer)
                let path = try XCTUnwrap(layer.path)
                let normalPath = AvatarStoryIndicatorComponent.contourPath(size: CGSize(width: 60, height: 60), diameter: 60, lineWidth: 2, isRoundedRect: component.isRoundedRect, customCornerFraction: fraction)
                XCTAssertTrue(path == normalPath)
                XCTAssertEqual(path.contains(CGPoint(x: 2, y: 2)), fraction == 0)
                if component.isRoundedRect {
                    XCTAssertNil(layer.animation(forKey: "rotation"))
                    if case .indefinite = progress {
                        XCTAssertNotNil(layer.animation(forKey: "contourDash"))
                        XCTAssertNotNil(layer.lineDashPattern)
                    }
                }
            }
        }
        _ = host.update(transition: .init(animation: .none), component: AnyComponent(AvatarStoryIndicatorComponent(hasUnseen: true, hasUnseenCloseFriendsItems: false, hasLiveItems: false, colors: colors, activeLineWidth: 2, inactiveLineWidth: 1, counters: nil, progress: nil, isRoundedRect: true, customCornerFraction: 0)), environment: {}, containerSize: available)
        let view = try XCTUnwrap(host.view)
        XCTAssertFalse(view.layer.sublayers?.contains { $0.mask != nil && $0.opacity > 0 } ?? false, "cancelled loading restores the normal indicator")
    }

    @MainActor
    func testLegacyRasterAndQueuedImageCannotSurviveV2Reset() throws {
        let settings = try store()
        try settings.set(.integer(0), for: "appearance.avatarCorners")
        let avatar = AvatarNode(font: UIFont.systemFont(ofSize: 17), appearanceSettings: settings)
        avatar.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        _ = avatar.view
        avatar.setCustomLetters(["A"])
        avatar.recursivelyEnsureDisplaySynchronously(true)
        XCTAssertNotNil(avatar.contentNode.contents, "must start with a genuinely drawn legacy raster")
        XCTAssertGreaterThan(try alpha(render(avatar.view)).first ?? 0, 240, "square placeholder covers its corners")

        // Exercise the real child ImageNode's pending-signal lifetime as well as
        // the pending parent ASDisplayLayer draw; neither is a standalone layer.
        let legacyDelivery = AvatarFixtureDelivery()
        avatar.imageNode.setSignal(legacyDelivery.signal())
        let cache = try AvatarFixtureImageCache()
        cache.showsImmediateImage = false
        let firstPhotoDelivery = AvatarFixtureDelivery()
        cache.delivery = firstPhotoDelivery
        XCTAssertEqual(legacyDelivery.enqueue(cache.greenImage), .success)
        avatar.contentNode.setNeedsDisplay()
        avatar.contentNode.recursivelyEnsureDisplaySynchronously(false)
        let peer = avatarFixturePeer(id: 101, forum: false, hasPhoto: true)
        avatar.setPeerV2(imageCache: cache, peer: peer, displayDimensions: CGSize(width: 60, height: 60))
        XCTAssertEqual(legacyDelivery.disposals, 1)
        XCTAssertTrue(avatar.contentNode.displaySuspended)
        XCTAssertNil(avatar.contentNode.contents)
        XCTAssertNil(avatar.imageNode.contents, "delayed V2 starts image-only, without a leftover placeholder")
        let asyncLayer = try XCTUnwrap(avatar.contentNode.layer as? _ASDisplayLayer)
        XCTAssertTrue(avatar.contentNode.drawParameters(forAsyncLayer: asyncLayer).isMember(of: NSObject.self), "V2 drops the old draw parameters")

        try settings.reset("appearance.avatarCorners")
        let currentPhotoDelivery = AvatarFixtureDelivery()
        cache.delivery = currentPhotoDelivery
        avatar.setPeerV2(imageCache: cache, peer: peer, displayDimensions: CGSize(width: 60, height: 60))
        XCTAssertEqual(firstPhotoDelivery.disposals, 1)
        XCTAssertEqual(firstPhotoDelivery.enqueue(cache.greenImage), .success)
        XCTAssertEqual(currentPhotoDelivery.enqueue(cache.redImage), .success)
        avatar.font = UIFont.systemFont(ofSize: 31)
        avatar.recursivelyEnsureDisplaySynchronously(true)
        drainMainQueue()
        XCTAssertNil(avatar.contentNode.contents, "font/layout and the cancelled draw cannot restore the parent raster")
        XCTAssertEqual(avatar.imageNode.cornerRadius, 30)
        XCTAssertEqual(try pixels(try XCTUnwrap(avatar.imageNode.image)), try pixels(cache.redImage))
        XCTAssertEqual(try alpha(render(avatar.view)).first, 0, "round reset must not reveal old square corners")
        XCTAssertEqual(cache.requests.count, 2, "same peer/resource must still reconfigure a changed contour")
        XCTAssertTrue(cache.requests.allSatisfy { $0.resource == peer.smallProfileImage?.resource.id.stringRepresentation })
    }

    @MainActor
    func testV2BubbleReplacesCornerBackendAndResizesWithVideoContour() throws {
        let settings = try store()
        let cache = try AvatarFixtureImageCache()
        let peer = avatarFixturePeer(id: 102, forum: false, hasPhoto: true)
        let avatar = AvatarNode(font: UIFont.systemFont(ofSize: 17), appearanceSettings: settings)
        avatar.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        _ = avatar.view
        // A decoded video-frame plane uses the same final-clip call as native
        // video consumers. Only the photo side is the actual cached AvatarNode;
        // this fixture does not claim AVPlayer/video-decoder execution.
        let videoFrame = UIImageView(image: cache.redImage)
        videoFrame.contentMode = .scaleToFill
        for previous in [AvatarNodeClipStyle.round, .roundedRect] {
            avatar.setPeerV2(imageCache: cache, peer: peer, clipStyle: previous)
            XCTAssertGreaterThan(avatar.imageNode.cornerRadius, 0)
            avatar.setPeerV2(imageCache: cache, peer: peer, clipStyle: .bubble)
            let firstMask = try XCTUnwrap(avatar.imageNode.layer.mask)
            for side in [CGFloat(60), 38, 100] {
                let size = CGSize(width: side, height: side)
                avatar.frame = CGRect(origin: .zero, size: size)
                videoFrame.frame = avatar.bounds
                avatar.resolvedClipStyle.applyExteralessFinalClip(to: videoFrame.layer, size: size)
                XCTAssertEqual(avatar.resolvedClipStyle, .bubble)
                XCTAssertEqual(avatar.imageNode.cornerRadius, 0, "no circle may remain behind the bubble mask")
                XCTAssertTrue(avatar.imageNode.clipsToBounds)
                let mask = try XCTUnwrap(avatar.imageNode.layer.mask)
                XCTAssertTrue(mask === firstMask)
                XCTAssertEqual(mask.name, "appearance.avatar.bubbleClip")
                XCTAssertEqual(mask.frame, avatar.imageNode.bounds)
                XCTAssertEqual(try alpha(render(avatar.imageNode.view)), try alpha(render(videoFrame)), "cached photo and decoded video plane have one contour at \(side)pt")
            }
            avatar.setPeerV2(imageCache: cache, peer: peer, clipStyle: .round)
            XCTAssertNil(avatar.imageNode.layer.mask)
            XCTAssertEqual(avatar.imageNode.cornerRadius, avatar.bounds.width / 2)
            avatar.setPeerV2(imageCache: cache, peer: peer, clipStyle: .none)
            XCTAssertNil(avatar.imageNode.layer.mask)
            XCTAssertFalse(avatar.imageNode.clipsToBounds)
            XCTAssertEqual(avatar.imageNode.cornerRadius, 0)
        }
    }

    @MainActor
    func testCompleteImageKeepsForumContourFontAndUnroundedChoice() throws {
        let settings = try store()
        let cache = try AvatarFixtureImageCache()
        let size = CGSize(width: 28, height: 28)
        for corners in [0, 14, 28] {
            try settings.set(.integer(Int64(corners)), for: "appearance.avatarCorners")
            for single in [false, true] {
                try settings.set(.bool(single), for: "appearance.singleCornerRadius")
                var masks: [[UInt8]] = []
                for forum in [false, true] {
                    let photoPeer = avatarFixturePeer(id: 103, forum: forum, hasPhoto: true)
                    let emptyPeer = avatarFixturePeer(id: 103, forum: forum, hasPhoto: false)
                    let photo = try completeImage(peer: photoPeer, size: size, settings: settings, cache: cache, letters: false)
                    let fallback = try completeImage(peer: emptyPeer, size: size, settings: settings, cache: cache, letters: false)
                    let photoMask = try alpha(photo)
                    XCTAssertEqual(photoMask, try alpha(fallback), "cached PNG vs no-photo: forum=\(forum), corners=\(corners), single=\(single)")
                    masks.append(photoMask)
                    for peer in [photoPeer, emptyPeer] {
                        let unrounded = try completeImage(peer: peer, size: size, settings: settings, cache: cache, round: false, letters: false)
                        XCTAssertTrue(try alpha(unrounded).allSatisfy { $0 == 255 }, ".none stays unrounded for photos and fallback")
                    }
                    let lookups = cache.dataRequests
                    let forcedFallback = try completeImage(peer: photoPeer, size: size, settings: settings, cache: cache, letters: false, forceEmpty: true)
                    XCTAssertEqual(try alpha(forcedFallback), photoMask)
                    XCTAssertEqual(cache.dataRequests, lookups, "explicit missing representation cannot start an image fetch")
                }
                if corners == 0 || single {
                    XCTAssertEqual(masks[0], masks[1])
                } else {
                    XCTAssertNotEqual(masks[0], masks[1], "forum geometry must survive photo removal")
                }
            }
        }
        let peer = avatarFixturePeer(id: 104, forum: true, hasPhoto: false)
        let fontCanvas = CGSize(width: 60, height: 60)
        let small = try completeImage(peer: peer, size: fontCanvas, settings: settings, cache: cache, font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular))
        let large = try completeImage(peer: peer, size: fontCanvas, settings: settings, cache: cache, font: UIFont.monospacedSystemFont(ofSize: 20, weight: .bold))
        let noLetters = try completeImage(peer: peer, size: fontCanvas, settings: settings, cache: cache, letters: false)
        XCTAssertNotEqual(try pixels(small), try pixels(large), "the supplied font must reach the actual fallback compositor")
        XCTAssertNotEqual(try pixels(small), try pixels(noLetters))
        XCTAssertEqual(try alpha(small), try alpha(large), "glyphs remain inside the resolved contour")
        try settings.reset("appearance.avatarCorners")
        try settings.reset("appearance.singleCornerRadius")
        let restored = try completeImage(peer: peer, size: size, settings: settings, cache: cache, letters: false)
        let restoredPhoto = try completeImage(peer: avatarFixturePeer(id: 104, forum: true, hasPhoto: true), size: size, settings: settings, cache: cache, letters: false)
        XCTAssertEqual(try alpha(restored), try alpha(restoredPhoto))
    }

    @MainActor
    func testV2ToLettersDisposesBothImageSourcesAndRejectsLateCompletions() throws {
        let settings = try store()
        let cache = try AvatarFixtureImageCache()
        let avatar = AvatarNode(font: UIFont.systemFont(ofSize: 19), appearanceSettings: settings)
        avatar.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        _ = avatar.view
        for letters in [["B"], [" "]] {
            let cacheDelivery = AvatarFixtureDelivery()
            cache.delivery = cacheDelivery
            cache.useGreen = false
            avatar.setPeerV2(imageCache: cache, peer: avatarFixturePeer(id: 105, forum: false, hasPhoto: true), storeUnrounded: true)
            XCTAssertNotNil(avatar.unroundedImage)
            avatar.imageNode.setSignal(.single(nil))
            XCTAssertNotNil(avatar.imageNode.contents, "enableEmpty=false: nil emission is intentionally not a clear")
            let imageNodeDelivery = AvatarFixtureDelivery()
            avatar.imageNode.setSignal(imageNodeDelivery.signal())
            XCTAssertEqual(cacheDelivery.enqueue(cache.redImage), .success)
            XCTAssertEqual(imageNodeDelivery.enqueue(cache.redImage), .success)

            avatar.setCustomLetters(letters)
            XCTAssertEqual(cacheDelivery.disposals, 1)
            XCTAssertEqual(imageNodeDelivery.disposals, 1, "must invoke ImageNode.clearContents, not assign only its layer contents")
            XCTAssertNil(avatar.imageNode.contents)
            XCTAssertNil(avatar.unroundedImage)
            XCTAssertNil(avatar.imageNode.layer.mask)
            XCTAssertEqual(avatar.imageNode.cornerRadius, 0)
            XCTAssertFalse(avatar.contentNode.displaySuspended)
            avatar.recursivelyEnsureDisplaySynchronously(true)
            XCTAssertNotNil(avatar.contentNode.contents)
            drainMainQueue()
            XCTAssertNil(avatar.imageNode.contents, "already queued cache and child-signal results cannot cover the letters")

            cache.delivery = nil
            cache.useGreen = true
            avatar.setPeerV2(imageCache: cache, peer: avatarFixturePeer(id: 106, forum: false, hasPhoto: true))
            XCTAssertEqual(cacheDelivery.enqueue(cache.redImage), .success)
            drainMainQueue()
            XCTAssertNil(avatar.contentNode.contents)
            XCTAssertEqual(try pixels(try XCTUnwrap(avatar.imageNode.image)), try pixels(cache.greenImage), "late previous-peer completion cannot overwrite a cached new peer")
        }
    }

    @MainActor
    private func drainMainQueue() {
        let drained = expectation(description: "queued avatar deliveries")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    @MainActor
    private func render(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            return true
        }
        XCTAssertTrue(drawn)
        return data
    }

    private func alpha(_ image: UIImage) throws -> [UInt8] {
        let values = try pixels(image)
        return stride(from: 3, to: values.count, by: 4).map { values[$0] }
    }

    private func completeImage(peer: EnginePeer, size: CGSize, settings: ClientSettings, cache: AvatarFixtureImageCache, round: Bool = true, font: UIFont = UIFont.systemFont(ofSize: 13), letters: Bool = true, forceEmpty: Bool = false) throws -> UIImage {
        var result: UIImage?
        let disposable = peerAvatarCompleteImage(peer: peer, forceProvidedRepresentation: forceEmpty, representation: nil, size: size, round: round, font: font, drawLetters: letters, fullSize: true, appearanceSettings: settings, imageDataProvider: { representation, synchronous in
            cache.imageData(representation: representation, synchronous: synchronous)
        }).start(next: { result = $0 })
        defer { disposable.dispose() }
        return try XCTUnwrap(result, "fully cached PNG/no-image fixture must finish synchronously")
    }
}

private func avatarFixturePeer(id: Int64, forum: Bool, hasPhoto: Bool) -> EnginePeer {
    let photo = hasPhoto ? [TelegramMediaImageRepresentation(dimensions: .init(width: 8, height: 8), resource: LocalFileMediaResource(fileId: id), progressiveSizes: [], immediateThumbnailData: nil)] : []
    if forum {
        return .channel(TelegramChannel(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(id)), accessHash: .personal(1), title: "AB", username: nil, photo: photo, creationDate: 0, version: 0, participationStatus: .member, info: .group(TelegramChannelGroupInfo(flags: [])), flags: [.isForum], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil))
    }
    return .user(TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)), accessHash: .personal(1), firstName: "A", lastName: "B", username: nil, phone: nil, photo: photo, botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
}

/// Two owned 8x8 RGB PNGs, 74 bytes each. No file/account/network resource loader
/// is involved; the real UIKit decoder and PeerAvatar compositor consume them.
private final class AvatarFixtureImageCache: AvatarNodeImageCache {
    private static let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGN4p2CCFTEMLQkAoxlQgUcPF4kAAAAASUVORK5CYII=")!
    private static let greenPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGOQvBSAFTEMLQkAt8pOwaU/RqkAAAAASUVORK5CYII=")!
    let redImage: UIImage
    let greenImage: UIImage
    var useGreen = false
    var showsImmediateImage = true
    var delivery: AvatarFixtureDelivery?
    private(set) var requests: [(resource: String, size: Int)] = []
    private(set) var dataRequests = 0

    init() throws {
        self.redImage = try XCTUnwrap(UIImage(data: Self.redPNG))
        self.greenImage = try XCTUnwrap(UIImage(data: Self.greenPNG))
    }

    func avatarImage(peer: PeerReference, resource: MediaResourceReference, immediateThumbnail: Data?, size: Int, synchronous: Bool) -> (image: UIImage?, loadSignal: Signal<UIImage?, NoError>?)? {
        self.requests.append((resource.resource.id.stringRepresentation, size))
        return (self.showsImmediateImage ? (self.useGreen ? self.greenImage : self.redImage) : nil, self.delivery?.signal())
    }

    func imageData(representation: TelegramMediaImageRepresentation, synchronous: Bool) -> Signal<(Data, PeerAvatarImageType)?, NoError>? {
        self.dataRequests += 1
        XCTAssertTrue(representation.resource is LocalFileMediaResource)
        XCTAssertTrue(synchronous)
        return .single((self.useGreen ? Self.greenPNG : Self.redPNG, .complete))
    }
}

private final class AvatarFixtureDelivery {
    private var subscriber: Subscriber<UIImage?, NoError>?
    private(set) var disposals = 0

    func signal() -> Signal<UIImage?, NoError> {
        return Signal { subscriber in
            self.subscriber = subscriber
            return ActionDisposable { self.disposals += 1 }
        }
    }

    /// Put the old result on deliverOnMainQueue before the caller changes the
    /// renderer. The background handoff is bounded; there are no sleeps/timers.
    func enqueue(_ image: UIImage) -> DispatchTimeoutResult {
        let subscriber = self.subscriber
        let queued = DispatchSemaphore(value: 0)
        Queue.concurrentDefaultQueue().async {
            subscriber?.putNext(image)
            queued.signal()
        }
        return queued.wait(timeout: .now() + 1)
    }
}
