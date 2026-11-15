import AvatarNode
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import UIKit
import XCTest

final class AvatarImageTransitionResetTests: XCTestCase {
    @MainActor
    func testActiveCrossfadeIsRetiredByAvatarResetWithoutTouchingLaterContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let settings = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"))
        try settings.register(AppearanceFeatures.definitions)
        let avatar = AvatarNode(font: UIFont.systemFont(ofSize: 18), appearanceSettings: settings)
        avatar.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        _ = avatar.view
        let imageNode = avatar.imageNode
        imageNode.enableAnimatedTransition = true
        imageNode.animateFirstTransition = false
        let foreignLayer = CALayer()
        foreignLayer.name = "UnrelatedAvatarOverlay"
        imageNode.layer.addSublayer(foreignLayer)
        let images = ValuePipe<UIImage?>()
        imageNode.setSignal(images.signal())
        let red = image(.red)
        let green = image(.green)
        images.putNext(red)
        images.putNext(green)
        let previous = try XCTUnwrap(imageNode.layer.sublayers?.first { $0.name == "ImageNode.Crossfade" })
        let animationKey = try XCTUnwrap(previous.animationKeys()?.first)
        let animation = try XCTUnwrap(previous.animation(forKey: animationKey))
        let completion = animation.delegate
        XCTAssertNotNil(previous.contents, "The old bitmap must already be in a running compositor layer")

        avatar.setCustomLetters(["Q"])
        XCTAssertNil(previous.contents)
        XCTAssertTrue(previous.animationKeys()?.isEmpty ?? true)
        XCTAssertNil(previous.superlayer)
        XCTAssertFalse(imageNode.layer.sublayers?.contains { $0.name == "ImageNode.Crossfade" } ?? false)
        XCTAssertTrue(foreignLayer.superlayer === imageNode.layer)
        XCTAssertNil(imageNode.contents)

        let laterImages = ValuePipe<UIImage?>()
        imageNode.setSignal(laterImages.signal())
        laterImages.putNext(red)
        laterImages.putNext(green)
        let current = try XCTUnwrap(imageNode.layer.sublayers?.first { $0.name == "ImageNode.Crossfade" })
        XCTAssertFalse(current === previous)
        completion?.animationDidStop?(animation, finished: true)
        XCTAssertTrue(current.superlayer === imageNode.layer)
        XCTAssertNotNil(current.contents)
        XCTAssertNotNil(imageNode.contents)
        imageNode.clearContents()
        XCTAssertNil(current.contents)
        XCTAssertNil(current.superlayer)
        XCTAssertTrue(foreignLayer.superlayer === imageNode.layer)
    }

    @MainActor
    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}
