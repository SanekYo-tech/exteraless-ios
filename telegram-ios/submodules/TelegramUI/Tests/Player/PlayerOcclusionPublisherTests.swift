import AccountContext
import Foundation
import UIKit
import XCTest
@testable import TelegramUI

final class PlayerOcclusionPublisherTests: XCTestCase {
    @MainActor func testRenderedWindowCoordinatesFollow64And52PointFramesAndWindowReplacement() {
        let registry = ExteralessContentOcclusions()
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let second = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        first.isHidden = false
        second.isHidden = false
        let container = UIView(frame: CGRect(x: 20, y: 30, width: 350, height: 700))
        let view = UIView(frame: CGRect(x: 10, y: 570, width: 320, height: 64))
        view.backgroundColor = .blue
        first.addSubview(container)
        container.addSubview(view)
        let publisher = ExteralessPlayerOcclusionPublisher(accountId: 1, view: view, registry: registry)
        var firstRects: [CGRect] = [], secondRects: [CGRect] = [], otherAccountRects: [CGRect] = []
        let a = registry.subscribe(accountId: 1, window: first) { firstRects = $0.rects }
        let b = registry.subscribe(accountId: 1, window: second) { secondRects = $0.rects }
        let c = registry.subscribe(accountId: 2, window: first) { otherAccountRects = $0.rects }
        defer {
            publisher.retire(); registry.unsubscribe(a); registry.unsubscribe(b); registry.unsubscribe(c)
            first.isHidden = true; second.isHidden = true
        }
        publisher.update(visible: true)
        XCTAssertEqual(firstRects, [CGRect(x: 30, y: 600, width: 320, height: 64)])
        XCTAssertTrue(otherAccountRects.isEmpty)
        view.frame = CGRect(x: 10, y: 40, width: 320, height: 52)
        publisher.update(visible: true)
        XCTAssertTrue(firstRects.contains(CGRect(x: 30, y: 70, width: 320, height: 52)))
        publisher.update(visible: false) // The controller's keyboard/visibility gate.
        XCTAssertTrue(firstRects.isEmpty)
        view.removeFromSuperview()
        publisher.update(visible: true)
        second.addSubview(view)
        view.frame = CGRect(x: 80, y: 240, width: 520, height: 52)
        publisher.update(visible: true)
        XCTAssertTrue(firstRects.isEmpty)
        XCTAssertEqual(secondRects, [CGRect(x: 80, y: 240, width: 520, height: 52)])
    }

    @MainActor func testOwnerRetirementClearsOnceAndLateLayoutsCannotEraseAnotherOwner() {
        let registry = ExteralessContentOcclusions()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let view = UIView(frame: CGRect(x: 12, y: 700, width: 366, height: 64))
        view.backgroundColor = .blue
        window.addSubview(view)
        let publisher = ExteralessPlayerOcclusionPublisher(accountId: 1, view: view, registry: registry)
        let other = UUID()
        let otherRect = CGRect(x: 0, y: 0, width: 390, height: 20)
        var rects: [CGRect] = []
        var deliveries = 0
        let token = registry.subscribe(accountId: 1, window: window) { rects = $0.rects; deliveries += 1 }
        defer { registry.unsubscribe(token); registry.clear(owner: other); window.isHidden = true }
        registry.publish(owner: other, accountId: 1, window: window, rects: [otherRect])
        publisher.update(visible: true)
        publisher.retire()
        let afterRetirement = deliveries
        XCTAssertEqual(rects, [otherRect])
        publisher.retire()
        view.frame.origin.y = 100
        publisher.update(visible: true, animationDuration: 0.2)
        XCTAssertEqual(deliveries, afterRetirement)
        XCTAssertEqual(rects, [otherRect])
    }

    @MainActor func testActualMiniViewPublishesOnAttachLayoutHideAndDetach() {
        let registry = ExteralessContentOcclusions()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let mini = ExteralessMiniPlayerView(frame: CGRect(x: 12, y: 700, width: 366, height: 64))
        mini.backgroundColor = .blue
        let publisher = ExteralessPlayerOcclusionPublisher(accountId: 1, view: mini, registry: registry)
        mini.geometryChanged = { [weak mini, weak publisher] in publisher?.update(visible: mini?.isHidden == false) }
        var rects: [CGRect] = []
        let token = registry.subscribe(accountId: 1, window: window) { rects = $0.rects }
        defer { publisher.retire(); registry.unsubscribe(token); window.isHidden = true }
        window.addSubview(mini)
        mini.layoutIfNeeded()
        XCTAssertTrue(rects.contains(CGRect(x: 12, y: 700, width: 366, height: 64)))
        mini.frame = CGRect(x: 24, y: 120, width: 342, height: 52)
        mini.setNeedsLayout()
        mini.layoutIfNeeded()
        XCTAssertTrue(rects.contains(CGRect(x: 24, y: 120, width: 342, height: 52)))
        mini.isHidden = true
        XCTAssertTrue(rects.isEmpty)
        mini.isHidden = false
        mini.removeFromSuperview()
        XCTAssertTrue(rects.isEmpty)
    }
}
