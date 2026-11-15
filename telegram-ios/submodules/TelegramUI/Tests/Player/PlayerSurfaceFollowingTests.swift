import ExteralessCore
import Foundation
import UIKit
import XCTest
@testable import TelegramUI

/// FU-04 traverses the real Surface.render -> lyrics update -> trailing tick.
/// No AccountContext, Core lyrics client, media manager or audio/network is used.
final class PlayerSurfaceFollowingTests: XCTestCase {
    @MainActor func testPausedAppearanceAndRepeatedTickKeepManualOffsetAndSeekLease() throws {
        let fixture = try PlayerSurfaceFollowingFixture()
        defer { fixture.close() }
        fixture.scene.setKaraoke(false)
        fixture.scene.setKaraoke(true)
        fixture.layout()
        fixture.scene.scrollLyrics(to: CGPoint(x: 0, y: 650))
        fixture.layout()
        let offset = fixture.scene.lyricsContentOffset
        XCTAssertGreaterThan(offset.y, 400)
        let slider = try XCTUnwrap(fixture.find(UISlider.self))
        slider.sendActions(for: .touchDown)
        fixture.now = 106 // Manual resume deadline (100 + 5) has elapsed.
        fixture.input.dark = true
        fixture.input.palette = fixture.dark
        fixture.scene.update(fixture.input)
        fixture.scene.tick() // The second same-position tick must not undo render's gate.
        fixture.layout()
        XCTAssertEqual(fixture.scene.lyricsContentOffset, offset)
        XCTAssertTrue(fixture.seeks.isEmpty)
        XCTAssertEqual(fixture.scene.activeLyricsIndex, 3)
        fixture.input.palette = fixture.light
        fixture.input.dark = false
        fixture.scene.update(fixture.input)
        fixture.scene.tick()
        fixture.layout()
        XCTAssertEqual(fixture.scene.lyricsContentOffset, offset)
        XCTAssertTrue(fixture.seeks.isEmpty)
        slider.value = 0.25
        slider.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.seeks.count, 1)
        XCTAssertEqual(fixture.seeks.first?.0, fixture.input.track)
        XCTAssertEqual(fixture.seeks.first?.1, 30)
    }

    @MainActor func testPlayingFollowWaitsForManualDeadlineThenActuallyScrolls() throws {
        let fixture = try PlayerSurfaceFollowingFixture()
        defer { fixture.close() }
        fixture.scene.setKaraoke(true)
        fixture.layout()
        fixture.scene.scrollLyrics(to: CGPoint(x: 0, y: 650))
        let offset = fixture.scene.lyricsContentOffset
        fixture.input.advancing = true
        fixture.input.position = 13.1
        fixture.scene.update(fixture.input)
        fixture.scene.tick()
        XCTAssertEqual(fixture.scene.lyricsContentOffset, offset)
        fixture.now = 106
        fixture.input.position = 13.2
        fixture.scene.update(fixture.input)
        fixture.scene.tick()
        fixture.layout()
        XCTAssertLessThan(fixture.scene.lyricsContentOffset.y, offset.y - 200)
        XCTAssertEqual(fixture.scene.activeLyricsIndex, 3)
        XCTAssertTrue(fixture.seeks.isEmpty)
    }

    @MainActor func testPausedFontRestylingKeepsItsRestoredAnchorThroughSurfaceTick() throws {
        let fixture = try PlayerSurfaceFollowingFixture()
        defer { fixture.close() }
        fixture.scene.setKaraoke(true)
        fixture.layout()
        fixture.scene.scrollLyrics(to: CGPoint(x: 0, y: 650))
        fixture.now = 106
        fixture.root.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityLarge), forChild: fixture.child)
        fixture.layout()
        let restored = fixture.scene.lyricsContentOffset
        XCTAssertGreaterThan(restored.y, 400)
        fixture.scene.update(fixture.input)
        fixture.scene.tick()
        fixture.layout()
        XCTAssertEqual(fixture.scene.lyricsContentOffset, restored)
        XCTAssertTrue(fixture.seeks.isEmpty)
    }
}

@MainActor
private final class PlayerSurfaceFollowingFixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    let child = UIViewController()
    let light: ExteralessPlayerPalette
    let dark = ExteralessPlayerPalette(surface: .black, elevated: .darkGray, primary: .cyan, text: .white, secondary: .lightGray)
    var input: ExteralessPlayerVisualInput
    private(set) var scene: ExteralessPlayerVisualSurface!
    var now: TimeInterval = 100
    var seeks: [(PlayerLyricsTrack, Double)] = []

    init() throws {
        let light = ExteralessPlayerPalette(surface: .white, elevated: .lightGray, primary: .blue, text: .black, secondary: .darkGray)
        self.light = light
        let text = (0..<30).map { String(format: "[%02d:%02d]Fixture line %d", $0 * 4 / 60, $0 * 4 % 60, $0) }.joined(separator: "\n")
        XCTAssertLessThan(text.utf8.count, 1024)
        let document = try XCTUnwrap(PlayerLyricsDocument.parse(text))
        let track = PlayerLyricsTrack(account: 1, resource: "surface-following-fixture", duration: 120, query: .init(artist: "Fixture", title: "Fixture", duration: 120))
        input = ExteralessPlayerVisualInput(title: "Fixture", artist: "Fixture", palette: light, dark: false, track: track, lyrics: document, position: 13, duration: 120)
        scene = ExteralessPlayerVisualSurface(input: input, now: { [weak self] in self?.now ?? 0 }, animateFollowing: false, seek: { [weak self] track, time in self?.seeks.append((track, time)) })
        window.rootViewController = root
        root.addChild(child)
        root.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .large), forChild: child)
        child.view.frame = window.bounds
        root.view.addSubview(child.view)
        child.didMove(toParent: root)
        scene.view.frame = window.bounds
        child.view.addSubview(scene.view)
        window.isHidden = false
        layout()
    }

    func layout() {
        window.layoutIfNeeded()
        scene.view.setNeedsLayout()
        func visit(_ view: UIView) { view.layoutIfNeeded(); for child in view.subviews { visit(child) } }
        visit(scene.view)
    }
    func find<T: UIView>(_ type: T.Type) -> T? {
        func visit(_ view: UIView) -> T? {
            if let result = view as? T { return result }
            for child in view.subviews { if let result = visit(child) { return result } }
            return nil
        }
        return visit(scene.view)
    }
    func close() { scene.stop(); scene.view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
}
