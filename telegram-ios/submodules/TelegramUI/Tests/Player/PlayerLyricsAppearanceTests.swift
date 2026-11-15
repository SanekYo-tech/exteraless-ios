import ExteralessCore
import Foundation
import UIKit
import XCTest
@testable import TelegramUI

/// FPP-08: actual UIKit visible-cell fixtures, with local Core lyrics only.
/// No AccountContext/Network/player instance is constructed or controlled.
final class PlayerLyricsAppearanceTests: XCTestCase, @unchecked Sendable {
    @MainActor func testPausedPlainLyricsRecolorExistingCellsWithoutMovingScrollOrSeeking() async throws {
        let fixture = PlayerLyricsViewFixture()
        defer { fixture.close() }
        let document = try XCTUnwrap(PlayerLyricsDocument.parse((0..<24).map { "Fixture line \($0)" }.joined(separator: "\n")))
        let track = PlayerLyricsTrack(account: 1, resource: "fixture", duration: 120, query: .init(artist: "Fixture", title: "Fixture", duration: 120))
        let result = try await PlayerLyricsClient().lookup(track: track, onlineAllowed: false, embedded: document)
        var seeks = 0
        var tappedTrack: PlayerLyricsTrack?
        fixture.lyrics.lineTapped = { _, _, _, track in seeks += 1; tappedTrack = track }
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.light, position: 20, duration: 120)
        fixture.layout()
        let table = try XCTUnwrap(fixture.lyrics.subviews.compactMap { $0 as? UITableView }.first)
        table.setContentOffset(CGPoint(x: 0, y: 140), animated: false)
        fixture.layout()
        let path = try XCTUnwrap(table.indexPathsForVisibleRows?.first)
        let cell = try XCTUnwrap(table.cellForRow(at: path))
        let offset = table.contentOffset
        let first = try XCTUnwrap(cell.textLabel?.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        XCTAssertTrue(first.isEqual(fixture.light.secondary))
        for palette in [fixture.dark, fixture.light] {
            fixture.lyrics.update(state: .result(result), track: track, palette: palette, position: 20, duration: 120)
            fixture.layout()
            XCTAssertTrue(table.cellForRow(at: path) === cell)
            XCTAssertEqual(table.contentOffset, offset)
            let color = try XCTUnwrap(cell.textLabel?.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
            XCTAssertTrue(color.isEqual(palette.secondary))
        }
        XCTAssertEqual(seeks, 0)
        fixture.lyrics.tableView(table, didSelectRowAt: path)
        XCTAssertEqual(tappedTrack, track)
    }

    @MainActor func testPausedInlineActiveAndAdjacentCellsUseNewPaletteAtSameCue() async throws {
        let fixture = PlayerLyricsViewFixture()
        defer { fixture.close() }
        let document = try XCTUnwrap(PlayerLyricsDocument.parse("[00:01]First\n[00:05]Current\n[00:09]Next"))
        let track = PlayerLyricsTrack(account: 1, resource: "fixture-synced", duration: 20, query: .init(artist: "Fixture", title: "Fixture", duration: 20))
        let result = try await PlayerLyricsClient().lookup(track: track, onlineAllowed: false, embedded: document)
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.light, position: 6, duration: 20)
        fixture.layout()
        let table = try XCTUnwrap(fixture.lyrics.subviews.compactMap { $0 as? UITableView }.first)
        let current = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 1, section: 0)))
        let previous = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        var tappedTime: Double?
        fixture.lyrics.lineTapped = { index, lyrics, offset, receivedTrack in
            XCTAssertEqual(receivedTrack, track)
            tappedTime = lyrics.seekTime(line: index, userOffset: offset, duration: 20)
        }
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.dark, position: 6, duration: 20)
        fixture.layout()
        XCTAssertTrue(table.cellForRow(at: IndexPath(row: 1, section: 0)) === current)
        XCTAssertTrue((current.textLabel?.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?.isEqual(fixture.dark.text) == true)
        XCTAssertTrue((previous.textLabel?.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?.isEqual(fixture.dark.secondary) == true)
        XCTAssertNil(tappedTime)
        fixture.lyrics.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(tappedTime, 5)
    }

    @MainActor func testFontTraitChangeReconfiguresExistingDocumentWithoutSeek() async throws {
        let fixture = PlayerLyricsViewFixture()
        defer { fixture.close() }
        let document = try XCTUnwrap(PlayerLyricsDocument.parse("One\nTwo\nThree"))
        let track = PlayerLyricsTrack(account: 1, resource: "fixture-font", duration: 20, query: .init(artist: "Fixture", title: "Fixture", duration: 20))
        let result = try await PlayerLyricsClient().lookup(track: track, onlineAllowed: false, embedded: document)
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.light, position: 3, duration: 20)
        fixture.layout()
        let table = try XCTUnwrap(fixture.lyrics.subviews.compactMap { $0 as? UITableView }.first)
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        let oldFont = try XCTUnwrap(cell.textLabel?.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        var seeks = 0
        fixture.lyrics.lineTapped = { _, _, _, _ in seeks += 1 }
        fixture.root.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), forChild: fixture.child)
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.light, position: 3, duration: 20)
        fixture.layout()
        let updatedCell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        let newFont = try XCTUnwrap(updatedCell.textLabel?.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(newFont.pointSize, oldFont.pointSize)
        XCTAssertEqual(updatedCell.textLabel?.text, "One")
        XCTAssertEqual(seeks, 0)
    }

    @MainActor func testPausedKaraokeRecolorsPastAndFutureCellsAsWellAsActiveFill() async throws {
        let fixture = PlayerLyricsViewFixture()
        defer { fixture.close() }
        let document = try XCTUnwrap(PlayerLyricsDocument.parse("[00:01]Past\n[00:05]Current\n[00:09]Future"))
        let track = PlayerLyricsTrack(account: 1, resource: "fixture-karaoke", duration: 20, query: .init(artist: "Fixture", title: "Fixture", duration: 20))
        let result = try await PlayerLyricsClient().lookup(track: track, onlineAllowed: false, embedded: document)
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.light, position: 6, duration: 20)
        let mode = try XCTUnwrap(fixture.lyrics.subviews.compactMap { $0 as? UISegmentedControl }.first)
        mode.selectedSegmentIndex = 1
        mode.sendActions(for: .valueChanged)
        fixture.layout()
        let table = try XCTUnwrap(fixture.lyrics.subviews.compactMap { $0 as? UITableView }.first)
        let future = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 2, section: 0)))
        let offset = table.contentOffset
        var seeks = 0
        fixture.lyrics.lineTapped = { _, _, _, _ in seeks += 1 }
        fixture.child.view.backgroundColor = fixture.dark.surface
        fixture.lyrics.update(state: .result(result), track: track, palette: fixture.dark, position: 6, duration: 20)
        fixture.layout()
        XCTAssertTrue(table.cellForRow(at: IndexPath(row: 2, section: 0)) === future)
        for row in [0, 2] {
            let color = table.cellForRow(at: IndexPath(row: row, section: 0))?.textLabel?.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
            XCTAssertTrue(color?.isEqual(fixture.dark.secondary) == true)
        }
        let fill = table.cellForRow(at: IndexPath(row: 1, section: 0))?.textLabel?.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertTrue(fill?.isEqual(fixture.dark.primary) == true)
        XCTAssertEqual(table.contentOffset, offset)
        XCTAssertEqual(seeks, 0)
    }
}

@MainActor
private final class PlayerLyricsViewFixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    let child = UIViewController()
    let lyrics = ExteralessPlayerLyricsView(frame: CGRect(x: 12, y: 100, width: 366, height: 430))
    let light = ExteralessPlayerPalette(surface: .white, elevated: .white, primary: .blue, text: .black, secondary: .darkGray)
    let dark = ExteralessPlayerPalette(surface: .black, elevated: .black, primary: .cyan, text: .white, secondary: .lightGray)

    init() {
        window.rootViewController = root
        root.addChild(child)
        root.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .large), forChild: child)
        child.view.frame = window.bounds
        child.view.backgroundColor = .white
        root.view.addSubview(child.view)
        child.didMove(toParent: root)
        child.view.addSubview(lyrics)
        window.isHidden = false
    }
    func layout() { window.layoutIfNeeded(); lyrics.setNeedsLayout(); lyrics.layoutIfNeeded(); lyrics.subviews.forEach { $0.layoutIfNeeded() } }
    func close() { window.isHidden = true; lyrics.removeFromSuperview(); window.rootViewController = nil }
}
