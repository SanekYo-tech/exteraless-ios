import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramPresentationData
import TelegramUI
import UIKit

@MainActor
private final class ClientHarnessSeekLog {
    var values: [(PlayerLyricsTrack, Double)] = []
}

@MainActor
final class ClientHarnessPlayerFixture {
    var input: ExteralessPlayerVisualInput
    let surface: ExteralessPlayerVisualSurface
    private let seeks: ClientHarnessSeekLog
    var seekCount: Int { self.seeks.values.count }

    func renderedSeconds() throws -> Int {
        var labels: [UILabel] = []
        func visit(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text,
               text.range(of: "^[0-9]+:[0-9]{2}$", options: .regularExpression) != nil { labels.append(label) }
            for child in view.subviews { visit(child) }
        }
        visit(self.surface.view)
        guard labels.count == 1, let text = labels[0].text else { throw ClientHarnessFailure(description: "native elapsed label missing/ambiguous") }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else {
            throw ClientHarnessFailure(description: "native elapsed label is not a timestamp")
        }
        return minutes * 60 + seconds
    }

    init(context: AccountContext, synced: Bool = false) throws {
        let log = ClientHarnessSeekLog()
        self.seeks = log
        let document = try Self.document(synced: synced)
        let track = PlayerLyricsTrack(account: context.account.id.int64, resource: "ui-harness-local-lyrics",
            duration: 120, query: .init(artist: "Fixture artist", title: "Paused fixture track", duration: 120))
        self.input = ExteralessPlayerVisualInput(title: "Paused fixture track", artist: "Fixture artist",
            style: .current, palette: Self.palette(context), dark: false, track: track, lyrics: document,
            position: 13, duration: 120, advancing: false)
        // Default real monotonic clock and animated following: the recording must
        // traverse the shipping render + same-position tick sequence (FU-04).
        self.surface = ExteralessPlayerVisualSurface(input: self.input, animateFollowing: true,
            seek: { track, time in log.values.append((track, time)) })
    }

    static func document(synced: Bool) throws -> PlayerLyricsDocument {
        let text = (0 ..< 30).map { index -> String in
            let line = "Fixture lyric line \(index) · local text"
            return synced ? String(format: "[%02d:%02d]", index * 3 / 60, index * 3 % 60) + line : line
        }.joined(separator: "\n")
        guard let result = try PlayerLyricsDocument.parse(text, source: .file, provider: "Local acceptance fixture") else {
            throw ClientHarnessFailure(description: "local lyric fixture did not parse")
        }
        return result
    }

    static func palette(_ context: AccountContext) -> ExteralessPlayerPalette {
        let theme = context.sharedContext.currentPresentationData.with { $0 }.theme
        return ExteralessPlayerPalette(surface: theme.list.blocksBackgroundColor,
            elevated: theme.list.itemBlocksBackgroundColor, primary: theme.list.itemAccentColor,
            text: theme.list.itemPrimaryTextColor, secondary: theme.list.itemSecondaryTextColor)
    }

    func appearance(context: AccountContext) {
        self.input.palette = Self.palette(context)
        self.input.dark = context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance
        self.surface.update(self.input)
        self.surface.tick()
    }

    func stop() { self.surface.stop(); self.surface.view.removeFromSuperview() }
}

/// Scene container only; the entire player view is the owner's production factory.
@MainActor
private final class ClientHarnessPlayerContainer: UIViewController {
    let fixture: ClientHarnessPlayerFixture
    init(_ fixture: ClientHarnessPlayerFixture) { self.fixture = fixture; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); self.view.addSubview(self.fixture.surface.view) }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.fixture.surface.view.frame = self.view.bounds
        self.fixture.surface.setInsets(.zero) // Display parent already supplies safe/navigation insets.
    }
}

@MainActor
final class ClientHarnessMiniFixture {
    let mini: ExteralessMiniPlayerVisualSurface
    private let window: UIWindow
    private let accountId: Int64
    private var observation: UUID?
    private(set) var rects: [CGRect] = []
    private var input: ExteralessPlayerVisualInput

    init(input: ExteralessPlayerVisualInput, window: UIWindow) {
        self.input = input
        self.window = window
        self.accountId = input.track.account
        self.mini = ExteralessMiniPlayerVisualSurface(input: input, registry: .shared)
        self.observation = ExteralessContentOcclusions.shared.subscribe(accountId: self.accountId, window: window) { [weak self] value in
            self?.rects = value.rects
        }
    }

    func dock(in parent: UIView, top: Bool, compact: Bool, animated: Bool) {
        var values = ClientSettings.shared.snapshot()
        values["appearance.playerMiniTop"] = .bool(top)
        values["appearance.playerMiniCompact"] = .bool(compact)
        self.input.style = PlayerStylePolicy(values: values)
        if self.mini.view.superview !== parent { parent.addSubview(self.mini.view) }
        self.mini.update(self.input, visible: true)
        let height = self.mini.preferredHeight
        let y = top ? max(0, self.window.safeAreaInsets.top) + 54
            : self.window.bounds.height - max(24, self.window.safeAreaInsets.bottom) - height - 8
        let windowFrame = CGRect(x: 12, y: y, width: self.window.bounds.width - 24, height: height)
        let frame = parent.convert(windowFrame, from: self.window)
        if animated {
            self.mini.beginGeometryTransition(duration: 0.3)
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
                self.mini.view.frame = frame
                self.mini.view.layoutIfNeeded()
            })
        } else { self.mini.view.frame = frame; self.mini.view.layoutIfNeeded() }
        self.mini.update(self.input, visible: true)
    }

    func assertPublication(height: CGFloat) throws {
        let frame = self.mini.view.convert(self.mini.view.bounds, to: self.window)
        try clientHarnessRequire(abs(frame.height - height) < 0.5, "native mini preferred height did not reach fixture layout")
        try clientHarnessRequire(self.rects.contains(where: { abs($0.minY - frame.minY) < 1 && abs($0.height - frame.height) < 1 }),
            "actual Player publisher did not publish its rendered window rectangle")
    }

    func stop() { self.mini.stop(); self.mini.view.removeFromSuperview() }
    func finishObservation() { if let observation = self.observation { ExteralessContentOcclusions.shared.unsubscribe(observation) }; self.observation = nil }
    var snapshot: [String: Any] {
        let frame = self.mini.view.convert(self.mini.view.bounds, to: self.window)
        return ["renderer": NSStringFromClass(type(of: self.mini.view)), "height": self.mini.preferredHeight,
            "frame": [frame.minX, frame.minY, frame.width, frame.height],
            "published": self.rects.map { [$0.minX, $0.minY, $0.width, $0.height] }, "account": self.accountId,
            "placement": "harness-owned docking; shipping mini view and occlusion publisher"]
    }
}

@MainActor
extension ClientHarnessSession {
    func runPlayerScenario() async throws {
        let fixture = try ClientHarnessPlayerFixture(context: self.context)
        let host = ClientHarnessDomainHost(context: self.context, title: "Native Player fixture", child: ClientHarnessPlayerContainer(fixture))
        self.navigation.pushViewController(host)
        defer { fixture.stop() }
        fixture.surface.setLyricsVisible(true)
        try await self.driver.settle()
        let table = try self.nativeTable("exteraless.player.lyrics.lines", in: fixture.surface.view)
        fixture.surface.scrollLyrics(to: CGPoint(x: 0, y: 140))
        try await self.driver.settle(0.25)
        let plainOffset = fixture.surface.lyricsContentOffset
        let plainCells = table.visibleCells.map { self.viewIdentities.id($0) }
        let initialPosition = try fixture.renderedSeconds()
        let lightColors = self.lyricColors(table)
        let light = self.tableEvidence(table)
        try self.probe("player-plain-light", extra: light)
        self.setDark(true)
        fixture.appearance(context: self.context)
        try await self.driver.settle(0.3)
        try clientHarnessRequire(abs(fixture.surface.lyricsContentOffset.y - plainOffset.y) < 1, "plain paused lyrics moved on theme change")
        try clientHarnessRequire(table.visibleCells.map { self.viewIdentities.id($0) } == plainCells, "plain theme update replaced native cells")
        let dark = self.tableEvidence(table)
        let darkColors = self.lyricColors(table)
        try clientHarnessRequire(!lightColors.isEmpty && lightColors.count == darkColors.count
            && zip(lightColors, darkColors).allSatisfy { $0 != $1 }, "plain lyric cells did not all receive the new colors")
        try self.probe("player-plain-dark", extra: dark)

        self.setDark(false)
        fixture.input.lyrics = try ClientHarnessPlayerFixture.document(synced: true)
        fixture.appearance(context: self.context)
        fixture.surface.setKaraoke(true)
        try await self.driver.settle()
        try self.probe("player-karaoke-light", extra: self.tableEvidence(table))
        fixture.surface.scrollLyrics(to: CGPoint(x: 0, y: 650))
        try await self.driver.settle(0.25)
        let scrolled = fixture.surface.lyricsContentOffset
        let cells = table.visibleCells.map { self.viewIdentities.id($0) }
        let karaokeColors = self.lyricColors(table)
        try clientHarnessRequire(scrolled.y > 300, "manual scroll did not move away from active cue")
        // Real time, not a fake clock: reproduce FU-04 after the five-second
        // suspension expires, including the full render and the extra tick.
        try await self.driver.settle(5.15)
        try self.probe("player-paused-scrolled", extra: self.tableEvidence(table))
        self.setDark(true)
        fixture.appearance(context: self.context)
        fixture.surface.tick()
        try await self.driver.settle(0.4)
        try clientHarnessRequire(abs(fixture.surface.lyricsContentOffset.y - scrolled.y) < 1, "same-position paused Surface tick resumed following")
        try clientHarnessRequire(table.visibleCells.map { self.viewIdentities.id($0) } == cells, "karaoke restyling replaced native cells")
        try clientHarnessRequire(fixture.seekCount == 0, "styling/scrolling emitted a native seek intent")
        let karaokeDarkColors = self.lyricColors(table)
        try clientHarnessRequire(!karaokeColors.isEmpty && karaokeColors.count == karaokeDarkColors.count
            && zip(karaokeColors, karaokeDarkColors).allSatisfy { $0 != $1 }, "paused karaoke cells retained light colors")
        let finalPosition = try fixture.renderedSeconds()
        try clientHarnessRequire(initialPosition == 13 && finalPosition == initialPosition, "rendered paused timestamp changed")
        try self.probe("player-paused-dark", extra: self.tableEvidence(table))

        let mini = ClientHarnessMiniFixture(input: fixture.input, window: self.window)
        defer { mini.stop(); mini.finishObservation() }
        mini.dock(in: self.display.hostView.containerView, top: false, compact: false, animated: false)
        try await self.driver.settle(0.35)
        try mini.assertPublication(height: 64)
        try self.probe("player-mini-64", extra: mini.snapshot)
        mini.dock(in: self.display.hostView.containerView, top: true, compact: true, animated: true)
        try await self.driver.settle(0.55)
        try mini.assertPublication(height: 52)
        try self.probe("player-mini-52-top", extra: mini.snapshot)
        mini.stop()
        fixture.stop()
        try await self.driver.settle(0.15)
        try clientHarnessRequire(mini.rects.isEmpty && fixture.surface.view.window == nil, "Player surfaces/publisher survived cleanup")
        try self.driver.back(); try await self.driver.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 1, "Player fixture left a navigation controller")
        self.report.facts["domain"] = ["name": "player-render", "realNativeRenderer": true, "cleanup": true,
            "seekCount": fixture.seekCount, "pausedPosition": initialPosition, "finalPosition": finalPosition,
            "samePositionTickPreservedOffset": true, "surfacesStopped": true,
            "backend": "production visual-input seam; no media engine, HTTP or audio playback"]
        try self.probe("player-cleanup", extra: ["seekCount": fixture.seekCount, "published": mini.rects.count])
    }

    private func lyricColors(_ table: UITableView) -> [[CGFloat]] {
        table.visibleCells.compactMap { cell in
            guard let label = cell.textLabel, let text = label.attributedText, text.length > 0,
                  let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor else { return nil }
            return clientHarnessRGBA(color, traits: label.traitCollection)
        }
    }
}
