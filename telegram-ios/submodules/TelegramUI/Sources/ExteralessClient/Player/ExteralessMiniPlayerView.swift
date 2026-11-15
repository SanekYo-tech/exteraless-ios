import AccountContext
import ExteralessCore
import Foundation
import TelegramCore
import UIKit

private final class ExteralessMiniClock: NSObject {
    var update: (() -> Void)?
    @objc func tick() { update?() }
}

final class ExteralessMiniPlayerView: UIView {
    private let artwork = ExteralessPlayerArtworkView(frame: .zero)
    private let title = UILabel()
    private let artist = UILabel()
    private let open = UIButton(type: .system)
    private let previous = UIButton(type: .system)
    private let play = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let close = UIButton(type: .system)
    private let progress = CAShapeLayer()
    private let track = CAShapeLayer()
    private var style = PlayerStylePolicy()
    private weak var session: ExteralessPlayerSession?
    private var visualInput: ExteralessPlayerVisualInput?
    private let clock = ExteralessMiniClock()
    private var displayLink: CADisplayLink?
    private var palette: ExteralessPlayerPalette?
    var openAction: (() -> Void)?
    var geometryChanged: (() -> Void)?

    var preferredHeight: CGFloat { style.miniCompact ? 52 : 64 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 3)
        title.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        artist.font = UIFont.systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        artist.lineBreakMode = .byTruncatingTail
        title.isAccessibilityElement = false
        artist.isAccessibilityElement = false
        addSubview(artwork)
        addSubview(title)
        addSubview(artist)
        addSubview(open)
        for (button, symbol, text, selector) in [
            (previous, "backward.end.fill", "Previous track", #selector(previousPressed)),
            (play, "play.fill", "Play", #selector(playPressed)),
            (nextButton, "forward.end.fill", "Next track", #selector(nextPressed)),
            (close, "xmark", "Close player", #selector(closePressed))
        ] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            button.accessibilityLabel = text
            button.addTarget(self, action: selector, for: .touchUpInside)
            addSubview(button)
        }
        open.addTarget(self, action: #selector(openPressed), for: .touchUpInside)
        open.accessibilityLabel = "Open music player"
        artwork.imageChanged = { [weak self] _ in self?.updateColors() }
        layer.addSublayer(track)
        layer.addSublayer(progress)
        for layer in [track, progress] { layer.fillColor = UIColor.clear.cgColor; layer.lineWidth = 2; layer.lineCap = .round }
        clock.update = { [weak self] in self?.updateProgress() }
        accessibilityIdentifier = "exteraless.player.mini"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate() }

    func update(session: ExteralessPlayerSession) {
        self.session = session
        self.visualInput = nil
        updatePresentation(style: session.style, title: session.titleAndArtist.0, artist: session.titleAndArtist.1, playing: session.isPlaying, canControl: session.state != nil && session.accountIsValid, previousAvailable: session.state?.previousItem != nil || session.position > 5, nextAvailable: session.state?.nextItem != nil)
        if isHidden { artwork.stopLoading() } else { artwork.update(context: session.context, state: session.state, style: miniArtStyle, playing: false, visible: true, surface: session.presentationData.theme.list.itemBlocksBackgroundColor) }
        updateColors()
        setNeedsLayout()
        updateClock()
        updateProgress()
    }

    func updateVisual(_ input: ExteralessPlayerVisualInput) {
        self.session = nil
        self.visualInput = input
        updatePresentation(style: input.style, title: input.title, artist: input.artist, playing: input.advancing, canControl: false, previousAvailable: false, nextAvailable: false)
        artwork.updateVisual(image: input.artwork, style: miniArtStyle, playing: false, visible: !isHidden, surface: input.palette.elevated)
        updateColors()
        setNeedsLayout()
        updateClock()
        updateProgress()
    }

    private var miniArtStyle: PlayerStylePolicy {
        PlayerStylePolicy(values: ["appearance.playerCoverStyle": .integer(0), "appearance.playerCoverRadius": .integer(style.miniCover == .circle ? 48 : 10), "appearance.playerDiscSpin": .bool(false)])
    }

    private func updatePresentation(style: PlayerStylePolicy, title: String, artist: String, playing: Bool, canControl: Bool, previousAvailable: Bool, nextAvailable: Bool) {
        self.style = style
        self.title.text = title
        self.artist.text = artist
        open.accessibilityValue = title + " — " + artist
        self.title.font = UIFont.systemFont(ofSize: style.miniCompact ? 13 : 15, weight: .semibold)
        self.artist.font = UIFont.systemFont(ofSize: style.miniCompact ? 11 : 12)
        self.artist.isHidden = !style.miniArtist
        previous.isHidden = !style.miniPrevious
        nextButton.isHidden = !style.miniNext
        close.isHidden = !style.miniClose
        artwork.isHidden = style.miniCover == .hidden
        previous.isEnabled = canControl && previousAvailable
        nextButton.isEnabled = canControl && nextAvailable
        play.isEnabled = canControl
        close.isEnabled = canControl
        open.isEnabled = canControl || openAction != nil
        play.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        play.accessibilityLabel = playing ? "Pause" : "Play"
    }

    func stop() { displayLink?.invalidate(); displayLink = nil; artwork.clear() }

    override func didMoveToWindow() { super.didMoveToWindow(); updateClock(); geometryChanged?() }

    override var isHidden: Bool { didSet { if oldValue != isHidden { geometryChanged?() } } }

    private func updateClock() {
        if window != nil && !isHidden && session?.isAdvancing == true {
            if displayLink == nil {
                let link = CADisplayLink(target: clock, selector: #selector(ExteralessMiniClock.tick))
                link.preferredFramesPerSecond = 15
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else { displayLink?.invalidate(); displayLink = nil }
    }

    private func updateColors() {
        let palette: ExteralessPlayerPalette
        if let session { palette = ExteralessPlayerPalette.make(theme: session.presentationData.theme, image: artwork.image, fromArtwork: !style.miniThemeColors) }
        else if let visualInput { palette = visualInput.palette }
        else { return }
        self.palette = palette
        backgroundColor = palette.elevated
        title.textColor = palette.text
        artist.textColor = palette.secondary
        for button in [previous, play, nextButton, close] { button.tintColor = palette.primary }
        progress.strokeColor = palette.primary.cgColor
        track.strokeColor = palette.secondary.withAlphaComponent(0.2).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius: CGFloat
        switch style.miniShape { case .rounded: radius = 20; case .pill: radius = bounds.height / 2; case .square: radius = 10 }
        layer.cornerRadius = radius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        let side: CGFloat = style.miniCompact ? 36 : 44
        artwork.frame = CGRect(x: 10, y: (bounds.height - side) / 2, width: side, height: side)
        var right = bounds.width - 4
        for button in [close, nextButton, play, previous] where !button.isHidden {
            button.frame = CGRect(x: right - 44, y: (bounds.height - 44) / 2, width: 44, height: 44)
            right -= 44
        }
        let left: CGFloat = artwork.isHidden ? 14 : artwork.frame.maxX + 10
        let textWidth = max(0, right - left - 4)
        title.frame = CGRect(x: left, y: style.miniArtist ? bounds.midY - 19 : bounds.midY - 10, width: textWidth, height: 22)
        artist.frame = CGRect(x: left, y: bounds.midY + 2, width: textWidth, height: 17)
        open.frame = CGRect(x: 0, y: 0, width: max(0, right - 2), height: bounds.height)
        let path: UIBezierPath
        switch style.miniProgress {
        case .ring:
            path = UIBezierPath(arcCenter: play.center, radius: 19, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        case .line:
            path = UIBezierPath()
            path.move(to: CGPoint(x: max(8, radius), y: bounds.height - 3))
            path.addLine(to: CGPoint(x: bounds.width - max(8, radius), y: bounds.height - 3))
        case .border: path = UIBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerRadius: max(0, radius - 2))
        case .hidden: path = UIBezierPath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = path.cgPath
        progress.path = path.cgPath
        CATransaction.commit()
        updateProgress()
        geometryChanged?()
    }

    private func updateProgress() {
        let duration = session?.state?.status.duration ?? visualInput?.duration ?? 0
        let position = session?.position ?? visualInput?.position ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeEnd = duration.isFinite && duration > 0 && position.isFinite ? CGFloat(min(1, max(0, position / duration))) : 0
        CATransaction.commit()
    }

    @objc private func previousPressed() { session?.control(.previous) }
    @objc private func playPressed() { session?.control(.playback(.togglePlayPause)) }
    @objc private func nextPressed() { session?.control(.next) }
    @objc private func closePressed() { session?.closePlayback() }
    @objc private func openPressed() { openAction?() }
}
