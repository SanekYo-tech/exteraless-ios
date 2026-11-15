import AccountContext
import ExteralessCore
import Foundation
import UIKit

/// Local, explicitly supplied presentation data for the shipping UIKit player.
/// This path has no AccountContext, media manager, HTTP client or playback engine.
public struct ExteralessPlayerVisualInput {
    public var title: String
    public var artist: String
    public var style: PlayerStylePolicy
    public var palette: ExteralessPlayerPalette
    public var dark: Bool
    public var artwork: UIImage?
    public var track: PlayerLyricsTrack
    public var lyrics: PlayerLyricsDocument
    public var offset: Double
    public var position: Double
    public var duration: Double
    public var advancing: Bool

    public init(title: String, artist: String, style: PlayerStylePolicy = PlayerStylePolicy(), palette: ExteralessPlayerPalette, dark: Bool, artwork: UIImage? = nil, track: PlayerLyricsTrack, lyrics: PlayerLyricsDocument, offset: Double = 0, position: Double, duration: Double, advancing: Bool = false) {
        self.title = title; self.artist = artist; self.style = style
        self.palette = palette; self.dark = dark; self.artwork = artwork
        self.track = track; self.lyrics = lyrics; self.offset = PlayerLyricsDocument.clampedOffset(offset)
        self.position = position; self.duration = duration; self.advancing = advancing
    }
}

/// Harness/control seam around the actual Surface and its actual LyricsView.
/// Hosts own the clock/scenario; the handle never starts audio or a remote lookup.
@MainActor
public final class ExteralessPlayerVisualSurface {
    private let surface: ExteralessPlayerSurface
    public var view: UIView { surface }
    public var lyricsContentOffset: CGPoint { surface.visualLyricsContentOffset }
    public var activeLyricsIndex: Int? { surface.visualActiveLyricsIndex }

    public init(input: ExteralessPlayerVisualInput, now: @escaping () -> TimeInterval = { CACurrentMediaTime() }, animateFollowing: Bool = true, seek: @escaping (PlayerLyricsTrack, Double) -> Void = { _, _ in }) {
        surface = ExteralessPlayerSurface(visualInput: input, now: now, animateFollowing: animateFollowing, seek: seek)
    }

    /// Runs the same complete render -> lyric presentation -> tick sequence.
    public func update(_ input: ExteralessPlayerVisualInput) { surface.updateVisualInput(input) }
    /// Runs the shipping playback tick with the last supplied input sample.
    public func tick() { surface.visualPlaybackTick() }
    public func setKaraoke(_ value: Bool) { surface.visualSetKaraoke(value) }
    public func setLyricsVisible(_ value: Bool) { surface.visualSetLyricsVisible(value) }
    /// Uses the same manual-follow suspension callback as a real table gesture.
    public func scrollLyrics(to offset: CGPoint) { surface.visualScrollLyrics(to: offset) }
    public func setInsets(_ insets: UIEdgeInsets) { surface.layoutInsets = insets }
    public func stop() { surface.setActive(false) }
}

/// The shipping mini view plus the shipping window/account/UUID publisher.
/// The host places `view` and owns scenario timing; engine-only controls are disabled.
@MainActor
public final class ExteralessMiniPlayerVisualSurface {
    private let mini: ExteralessMiniPlayerView
    private let publisher: ExteralessPlayerOcclusionPublisher
    private let accountId: Int64
    private var visible = true
    private var retired = false
    public var view: UIView { mini }
    public var preferredHeight: CGFloat { mini.preferredHeight }

    public init(input: ExteralessPlayerVisualInput, registry: ExteralessContentOcclusions? = nil, open: (() -> Void)? = nil) {
        let registry = registry ?? ExteralessContentOcclusions.shared
        let mini = ExteralessMiniPlayerView(frame: .zero)
        self.mini = mini
        self.accountId = input.track.account
        self.publisher = ExteralessPlayerOcclusionPublisher(accountId: input.track.account, view: mini, registry: registry)
        mini.openAction = open
        mini.geometryChanged = { [weak self] in
            guard let self else { return }
            self.publisher.update(visible: self.visible && !self.retired)
        }
        mini.updateVisual(input)
    }

    public func update(_ input: ExteralessPlayerVisualInput, visible: Bool = true) {
        guard !retired else { return }
        guard input.track.account == accountId else { stop(); return }
        self.visible = visible
        mini.isHidden = !visible
        mini.updateVisual(input)
        publisher.update(visible: visible)
    }

    /// Call before an animated frame change. Layout/attachment also publish directly.
    public func beginGeometryTransition(duration: Double) { if !retired { publisher.update(visible: visible, animationDuration: duration) } }
    public func stop() {
        guard !retired else { return }
        retired = true
        visible = false
        mini.isHidden = true
        publisher.retire()
        mini.stop()
    }
}
