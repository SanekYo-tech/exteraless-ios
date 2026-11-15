import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramCore
import TelegramUIPreferences
import UIKit

private final class ExteralessPlayerDisplayLinkTarget: NSObject {
    var tick: (() -> Void)?
    @objc func update() { tick?() }
}

/// Adaptive UIKit full-player surface used by both native player routing and the
/// settings entry. A scrollable layout preserves controls at large text sizes.
final class ExteralessPlayerSurface: UIView, UIGestureRecognizerDelegate {
    let session: ExteralessPlayerSession?
    private let controller: () -> ViewController?
    private let dismissAction: () -> Void
    private let actions: ExteralessPlayerActions?
    private var visualInput: ExteralessPlayerVisualInput?
    private let visualSeek: ((PlayerLyricsTrack, Double) -> Void)?
    private var visualSeekLease = ChatPlaybackSeekLease<PlayerLyricsTrack>()
    private let scroll = UIScrollView()
    private let content = UIView()
    private let backgroundImage = UIImageView()
    private let blur = UIVisualEffectView()
    private let gradient = CAGradientLayer()
    private let artwork = ExteralessPlayerArtworkView(frame: .zero)
    private let close = UIButton(type: .system)
    private let source = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private let title = UILabel()
    private let artist = UILabel()
    private let like = UIButton(type: .system)
    private let progress = ExteralessPlayerProgressView(frame: .zero)
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private let seekBack = UIButton(type: .system)
    private let seekForward = UIButton(type: .system)
    private let previous = UIButton(type: .system)
    private let play = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let order = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private let actionsBackground = UIView()
    private let lyricsButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let lyrics: ExteralessPlayerLyricsView
    private let error = UILabel()
    private let displayLinkTarget = ExteralessPlayerDisplayLinkTarget()
    private var displayLink: CADisplayLink?
    private var wantsActive = false
    private var wavePhase = 0.0
    private var lyricsVisible = false
    private var swipe: UIPanGestureRecognizer!
    private var swipeIdentity: ExteralessPlaybackIdentity?
    private var palette: ExteralessPlayerPalette
    private struct LyricsSample {
        let track: PlayerLyricsTrack?
        let position: Double
        let duration: Double
        let advancing: Bool
    }
    private var lastLyricsSample: LyricsSample?
    private var currentStyle: PlayerStylePolicy { session?.style ?? visualInput?.style ?? PlayerStylePolicy() }
    private var currentPosition: Double { session?.position ?? visualInput?.position ?? 0 }
    private var currentDuration: Double { session?.state?.status.duration ?? visualInput?.duration ?? 0 }
    private var isAdvancing: Bool { session?.isAdvancing ?? (visualInput?.advancing == true && wantsActive) }
    private var isPlaying: Bool { session?.isPlaying ?? (visualInput?.advancing == true && wantsActive) }
    private var dark: Bool { session?.presentationData.theme.overallDarkAppearance ?? visualInput?.dark ?? false }
    var layoutInsets = UIEdgeInsets.zero { didSet { setNeedsLayout() } }

    convenience init(context: AccountContext, controller: @escaping () -> ViewController?, dismiss: @escaping () -> Void) {
        self.init(session: ExteralessPlayerSession(context: context), visualInput: nil, now: { CACurrentMediaTime() }, animateFollowing: true, controller: controller, dismiss: dismiss, seek: nil)
    }

    convenience init(visualInput: ExteralessPlayerVisualInput, now: @escaping () -> TimeInterval, animateFollowing: Bool, seek: @escaping (PlayerLyricsTrack, Double) -> Void) {
        self.init(session: nil, visualInput: visualInput, now: now, animateFollowing: animateFollowing, controller: { nil }, dismiss: {}, seek: seek)
    }

    private init(session: ExteralessPlayerSession?, visualInput: ExteralessPlayerVisualInput?, now: @escaping () -> TimeInterval, animateFollowing: Bool, controller: @escaping () -> ViewController?, dismiss: @escaping () -> Void, seek: ((PlayerLyricsTrack, Double) -> Void)?) {
        self.session = session
        self.visualInput = visualInput
        self.visualSeek = seek
        self.lyrics = ExteralessPlayerLyricsView(frame: .zero, now: now, animateFollowing: animateFollowing)
        self.controller = controller
        self.dismissAction = dismiss
        self.actions = session.map { ExteralessPlayerActions(session: $0, controller: controller, dismiss: dismiss) }
        if let session { self.palette = .make(theme: session.presentationData.theme, image: nil, fromArtwork: false) }
        else { self.palette = visualInput!.palette }
        self.lyricsVisible = visualInput != nil
        self.wantsActive = visualInput != nil
        super.init(frame: .zero)
        backgroundImage.contentMode = .scaleAspectFill
        backgroundImage.clipsToBounds = true
        backgroundImage.isUserInteractionEnabled = false
        blur.isUserInteractionEnabled = false
        addSubview(backgroundImage)
        addSubview(blur)
        layer.addSublayer(gradient)
        addSubview(scroll)
        scroll.addSubview(content)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        title.numberOfLines = 2
        title.adjustsFontForContentSizeCategory = true
        artist.numberOfLines = 2
        artist.adjustsFontForContentSizeCategory = true
        remaining.textAlignment = .right
        elapsed.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        remaining.font = elapsed.font
        error.font = UIFont.preferredFont(forTextStyle: .footnote)
        error.numberOfLines = 0
        error.textAlignment = .center
        for view in [artwork, close, source, more, title, artist, like, progress, elapsed, remaining, seekBack, seekForward, previous, play, nextButton, order, repeatButton, actionsBackground, lyrics, error] { content.addSubview(view) }
        for view in [lyricsButton, queueButton, speedButton] { actionsBackground.addSubview(view) }
        configure(close, symbol: "chevron.down", label: "Minimize player", selector: #selector(closePressed))
        configure(source, symbol: nil, label: "Show track source", selector: #selector(sourcePressed))
        configure(more, symbol: "ellipsis", label: "Player actions", selector: #selector(morePressed))
        configure(like, symbol: "heart", label: "Save to My Profile", selector: #selector(likePressed))
        configure(previous, symbol: "backward.end.fill", label: "Previous track", selector: #selector(previousPressed))
        configure(play, symbol: "play.fill", label: "Play", selector: #selector(playPressed))
        configure(nextButton, symbol: "forward.end.fill", label: "Next track", selector: #selector(nextPressed))
        configure(order, symbol: "shuffle", label: "Playback order", selector: #selector(orderPressed))
        configure(repeatButton, symbol: "repeat", label: "Repeat", selector: #selector(repeatPressed))
        configure(seekBack, symbol: nil, label: "Seek backward", selector: #selector(seekBackPressed))
        configure(seekForward, symbol: nil, label: "Seek forward", selector: #selector(seekForwardPressed))
        configure(lyricsButton, symbol: nil, label: "Lyrics", selector: #selector(lyricsPressed))
        configure(queueButton, symbol: nil, label: "Queue", selector: #selector(queuePressed))
        configure(speedButton, symbol: nil, label: "Playback speed", selector: #selector(speedPressed))
        queueButton.setTitle("Queue", for: .normal)
        lyricsButton.setTitle("Lyrics", for: .normal)
        source.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
        play.layer.cornerCurve = .continuous
        actionsBackground.layer.cornerCurve = .continuous
        actionsBackground.layer.cornerRadius = 22
        progress.began = { [weak self] in
            guard let self else { return }
            if let session = self.session { session.beginScrub() }
            else if let input = self.visualInput, self.wantsActive { self.visualSeekLease.begin(identity: input.track) }
        }
        progress.ended = { [weak self] fraction in
            guard let self else { return }
            if let session = self.session { session.finishScrub(fraction) }
            else if let input = self.visualInput, self.wantsActive, let time = self.visualSeekLease.finish(identity: input.track, fraction: fraction, duration: input.duration) { self.visualSeek?(input.track, time) }
        }
        progress.cancelled = { [weak self] in self?.session?.cancelScrub(); self?.visualSeekLease.cancel() }
        lyrics.lineTapped = { [weak self] index, document, offset, track in
            guard let self else { return }
            if let session = self.session { session.seekLine(index, lyrics: document, offset: offset, track: track) }
            else if let input = self.visualInput, self.wantsActive, input.track == track, let time = document.seekTime(line: index, userOffset: offset, duration: input.duration) { self.visualSeek?(track, time) }
        }
        lyrics.retryAction = { [weak session] in session?.requestLyrics(refresh: true) }
        lyrics.enableAction = { [weak session] in session?.enableOnlineLyrics() }
        if session != nil { lyrics.chooseAction = { [weak self] in self?.openLyricsSelection() } }
        lyrics.modeChanged = { [weak self] in self?.setNeedsLayout() }
        actions?.lyrics = { [weak self] in self?.toggleLyrics() }
        actions?.chooseLyrics = { [weak self] in self?.openLyricsSelection() }
        artwork.imageChanged = { [weak self] image in
            guard let self else { return }
            self.backgroundImage.image = image
            self.applyPalette()
            self.updateLyricsPresentation(sample: self.lyricsSample(), allowAutomaticScroll: false)
            self.setNeedsLayout()
        }
        session?.updated = { [weak self] in self?.render() }
        session?.invalidated = { [weak self] in
            self?.actions?.cancel()
            self?.artwork.clear()
            self?.backgroundImage.image = nil
            self?.stopClock()
        }
        swipe = UIPanGestureRecognizer(target: self, action: #selector(coverPanned(_:)))
        swipe.delegate = self
        artwork.addGestureRecognizer(swipe)
        displayLinkTarget.tick = { [weak self] in self?.tick() }
        accessibilityIdentifier = "exteraless.player.modern"
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    private func configure(_ button: UIButton, symbol: String?, label: String, selector: Selector) {
        if let symbol { button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)), for: .normal) }
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "exteraless.player." + label.lowercased().replacingOccurrences(of: " ", with: ".")
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 14
    }

    func setActive(_ active: Bool) {
        wantsActive = active
        if active && window != nil { session?.start(); render() }
        else { session?.stop(); visualSeekLease.cancel(); artwork.stopLoading(); stopClock() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsActive && window != nil { session?.start(); if visualInput != nil { render() } }
        else if window == nil { session?.stop(); artwork.clear(); stopClock() }
    }

    private func render() {
        let style = currentStyle
        let sample = lyricsSample()
        let allowFollow = lyricsMayFollow(sample)
        applyPalette()
        let available = session.map { $0.accountIsValid && $0.state != nil && $0.active } ?? (visualInput != nil && wantsActive)
        close.isEnabled = session != nil
        title.text = session.map { $0.accountIsValid ? $0.titleAndArtist.0 : "Account changed" } ?? visualInput?.title
        artist.text = session.map { $0.accountIsValid ? $0.titleAndArtist.1 : "Reopen the player from the active account." } ?? visualInput?.artist
        title.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: UIFont.systemFont(ofSize: CGFloat([21, 25, 29][style.titleSize]), weight: .semibold))
        artist.font = UIFont.preferredFont(forTextStyle: .subheadline)
        title.textAlignment = style.titleCentered ? .center : .natural
        artist.textAlignment = title.textAlignment
        source.setTitle(session?.sourceMessageId != nil ? "Show in chat" : "Profile music", for: .normal)
        source.isEnabled = session?.sourceMessageId != nil || session?.profileMusicPeerId != nil
        source.isHidden = !style.showSource || !available || !source.isEnabled
        like.isHidden = !style.showLike || (session != nil && session?.type != .music)
        like.isEnabled = session?.canSaveToProfile == true
        like.setImage(UIImage(systemName: session?.isSavedToProfile == true ? "heart.fill" : "heart"), for: .normal)
        like.accessibilityLabel = session?.isSavedToProfile == true ? "Remove from My Profile" : "Save to My Profile"
        like.accessibilityValue = session?.profileSavePending == true ? "Saving" : nil
        play.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: CGFloat(29 * style.controlsScale), weight: .semibold)), for: .normal)
        play.accessibilityLabel = isPlaying ? "Pause" : "Play"
        play.isEnabled = available && session != nil
        previous.isEnabled = available && session != nil && (session?.state?.previousItem != nil || currentPosition > 5)
        nextButton.isEnabled = available && session?.state?.nextItem != nil
        more.isEnabled = available && session != nil
        order.isHidden = !style.showModes || session?.type == .voice
        repeatButton.isHidden = order.isHidden
        order.isEnabled = available && session != nil
        repeatButton.isEnabled = available && session != nil
        let orderSymbol: String
        switch session?.state?.order { case .random?: orderSymbol = "shuffle"; case .reversed?: orderSymbol = "arrow.up"; default: orderSymbol = "arrow.down" }
        order.setImage(UIImage(systemName: orderSymbol), for: .normal)
        repeatButton.setImage(UIImage(systemName: session?.state?.looping == .item ? "repeat.1" : "repeat"), for: .normal)
        order.accessibilityValue = session?.state?.order == .random ? "Shuffle" : (session?.state?.order == .reversed ? "Reverse order" : "Regular order")
        repeatButton.accessibilityValue = session?.state?.looping == MusicPlaybackSettingsLooping.none ? "Off" : (session?.state?.looping == .item ? "Track" : "Queue")
        actionsBackground.isHidden = !style.showActions
        for button in [lyricsButton, queueButton, speedButton, seekBack, seekForward] { button.isEnabled = available && session != nil }
        lyricsButton.isEnabled = available && (session?.type == .music || visualInput != nil)
        speedButton.setTitle(String(format: "%g×", session?.state?.status.baseRate ?? 1), for: .normal)
        let seek = visualInput != nil ? 10 : Int(ChatPlaybackPolicy.seekDuration(index: ClientSettings.shared.integer("chats.doubleTapSeekDuration", default: 1)))
        seekBack.setTitle("−\(seek)s", for: .normal)
        seekForward.setTitle("+\(seek)s", for: .normal)
        swipe.isEnabled = style.coverSwipe && available && session != nil && !lyricsVisible
        if let session {
            artwork.update(context: session.context, state: session.state, style: style, playing: session.isPlaying, visible: wantsActive && session.active && !lyricsVisible, surface: palette.surface)
        } else if let input = visualInput {
            artwork.updateVisual(image: input.artwork, style: style, playing: input.advancing, visible: wantsActive && !lyricsVisible, surface: palette.surface)
            backgroundImage.image = input.artwork
        }
        error.text = session?.operationError
        error.isHidden = session?.operationError == nil
        lyrics.isHidden = !lyricsVisible
        updateLyricsPresentation(sample: sample, allowAutomaticScroll: allowFollow)
        if wantsActive && session?.active == true && sample.advancing && window != nil {
            if displayLink == nil {
                let link = CADisplayLink(target: displayLinkTarget, selector: #selector(ExteralessPlayerDisplayLinkTarget.update))
                link.preferredFramesPerSecond = 30
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else { stopClock() }
        tick(sample: sample, allowAutomaticScroll: allowFollow)
        lastLyricsSample = sample
        setNeedsLayout()
    }

    private func applyPalette() {
        if let session { palette = .make(theme: session.presentationData.theme, image: artwork.image, fromArtwork: !session.style.themeColors) }
        else if let visualInput { palette = visualInput.palette }
        backgroundColor = palette.surface
        title.textColor = palette.text
        artist.textColor = palette.secondary
        elapsed.textColor = palette.secondary
        remaining.textColor = palette.secondary
        error.textColor = palette.text
        for button in [close, source, more, like, previous, nextButton, order, repeatButton, seekBack, seekForward] { button.tintColor = palette.primary }
        play.tintColor = palette.surface
        play.backgroundColor = palette.primary
        order.alpha = session?.state?.order == .regular ? 0.65 : 1
        repeatButton.alpha = session?.state?.looping == MusicPlaybackSettingsLooping.none ? 0.65 : 1
        actionsBackground.backgroundColor = currentStyle.actionsIsland ? palette.elevated : .clear
        for button in [lyricsButton, queueButton, speedButton] {
            button.tintColor = palette.primary
            button.backgroundColor = currentStyle.actionsIsland ? .clear : palette.elevated
        }
        let background = currentStyle.background
        blur.effect = background == .blur ? UIBlurEffect(style: dark ? .dark : .light) : nil
        blur.isHidden = background != .blur
        backgroundImage.isHidden = background != .blur && currentStyle.cover != .full
        let topAlpha: CGFloat = background == .gradient ? 0.8 : 0.36
        gradient.colors = [palette.surface.withAlphaComponent(topAlpha).cgColor, palette.surface.withAlphaComponent(0.80).cgColor, palette.surface.cgColor]
        gradient.locations = [0, 0.65, 1]
        gradient.isHidden = background == .solid && currentStyle.cover != .full
        if background == .gradient { backgroundImage.isHidden = true; gradient.colors = [palette.elevated.cgColor, palette.surface.cgColor] ; gradient.locations = [0, 1] }
        overrideUserInterfaceStyle = dark ? .dark : .light
    }

    private func lyricsSample() -> LyricsSample {
        let position = currentPosition
        let duration = currentDuration
        return LyricsSample(track: session?.lyricTrack ?? visualInput?.track, position: position.isFinite ? position : 0, duration: duration.isFinite ? duration : 0, advancing: isAdvancing)
    }

    private func lyricsMayFollow(_ sample: LyricsSample) -> Bool {
        guard let previous = lastLyricsSample else { return true }
        // A repeated paused sample is presentation work, even if the manual
        // following deadline expired between render and its trailing tick.
        return sample.advancing || sample.track != previous.track || sample.position != previous.position || sample.duration != previous.duration
    }

    private func updateLyricsPresentation(sample: LyricsSample, allowAutomaticScroll: Bool) {
        let state: ExteralessPlayerSession.LyricsState = session?.lyricsState ?? visualInput.map { .displayDocument($0.lyrics, offset: $0.offset) } ?? .idle
        lyrics.update(state: state, track: sample.track, palette: palette, position: sample.position, duration: sample.duration, allowAutomaticScroll: allowAutomaticScroll)
    }

    private func stopClock() { displayLink?.invalidate(); displayLink = nil }

    private func tick() {
        let sample = lyricsSample()
        tick(sample: sample, allowAutomaticScroll: lyricsMayFollow(sample))
        lastLyricsSample = sample
    }

    private func tick(sample: LyricsSample, allowAutomaticScroll: Bool) {
        let position = sample.position
        let duration = sample.duration
        if currentStyle.wavy && !UIAccessibility.isReduceMotionEnabled && sample.advancing { wavePhase = CACurrentMediaTime() * 2 }
        let active = session.map { $0.active && $0.accountIsValid } ?? (visualInput != nil && wantsActive)
        progress.update(fraction: duration > 0 ? position / duration : 0, enabled: active && duration > 0, wavy: currentStyle.wavy, phase: wavePhase, color: palette.primary, secondary: palette.secondary)
        elapsed.text = Self.time(position)
        remaining.text = "−" + Self.time(max(0, duration - position))
        if lyricsVisible { lyrics.updatePosition(position, duration: duration, allowAutomaticScroll: allowAutomaticScroll) }
    }

    private static func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(min(360_000, max(0, value))) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let style = currentStyle
        let left = layoutInsets.left + 18
        let width = max(0, bounds.width - left - layoutInsets.right - 18)
        var y = layoutInsets.top + 4
        close.frame = CGRect(x: left, y: y, width: 44, height: 44)
        more.frame = CGRect(x: left + width - 44, y: y, width: 44, height: 44)
        source.frame = CGRect(x: left + 48, y: y, width: max(0, width - 96), height: 44)
        y += 52
        let titleHeight = max(34, title.sizeThatFits(CGSize(width: max(1, width - 52), height: 150)).height)
        let artistHeight = max(22, artist.sizeThatFits(CGSize(width: max(1, width - 52), height: 100)).height)
        func layoutTitle() {
            let trailing: CGFloat = like.isHidden ? 0 : 48
            let leading: CGFloat = style.titleCentered ? trailing : 0
            title.frame = CGRect(x: left + leading, y: y, width: max(0, width - leading - trailing), height: titleHeight)
            artist.frame = CGRect(x: left + leading, y: y + titleHeight + 4, width: max(0, width - leading - trailing), height: artistHeight)
            like.frame = CGRect(x: left + width - 44, y: y + 1, width: 44, height: 44)
            y += titleHeight + artistHeight + 20
        }
        if style.titleAbove || lyricsVisible { layoutTitle() }
        let coverWidth = min(440, width) * CGFloat(style.coverScale)
        var coverHeight = style.cover == .wide ? coverWidth * 0.58 : coverWidth
        if style.cover == .full { coverHeight = min(360, max(140, bounds.height * 0.30)) }
        if lyricsVisible { coverHeight = 0 }
        let artworkFrame = CGRect(x: left + (width - coverWidth) / 2, y: y, width: coverWidth, height: coverHeight)
        artwork.frame = artworkFrame
        artwork.isHidden = lyricsVisible || style.cover == .full
        y += coverHeight + (lyricsVisible ? 0 : 22)
        if !style.titleAbove && !lyricsVisible { layoutTitle() }
        if lyricsVisible {
            lyrics.frame = CGRect(x: left, y: y, width: width, height: lyrics.preferredHeight)
            y += lyrics.preferredHeight + 12
        }
        for block in style.order {
            switch block {
            case .progress:
                progress.frame = CGRect(x: left, y: y, width: width, height: 44)
                y += 36
                elapsed.frame = CGRect(x: left, y: y, width: max(44, width * 0.25), height: 44)
                remaining.frame = CGRect(x: left + width * 0.75, y: y, width: width * 0.25, height: 44)
                seekBack.frame = CGRect(x: left + width / 2 - 50, y: y, width: 48, height: 44)
                seekForward.frame = CGRect(x: left + width / 2 + 2, y: y, width: 48, height: 44)
                y += 46
            case .controls:
                let playSize = CGFloat(72 * style.controlsScale)
                let height = max(76, playSize)
                play.frame = CGRect(x: left + (width - playSize) / 2, y: y + (height - playSize) / 2, width: playSize, height: playSize)
                play.layer.cornerRadius = playSize * 0.36
                let spacing = min(width / 3, playSize / 2 + 46)
                previous.frame = CGRect(x: left + width / 2 - spacing - 22, y: y + (height - 44) / 2, width: 44, height: 44)
                nextButton.frame = CGRect(x: left + width / 2 + spacing - 22, y: y + (height - 44) / 2, width: 44, height: 44)
                order.frame = CGRect(x: left, y: y + (height - 44) / 2, width: 44, height: 44)
                repeatButton.frame = CGRect(x: left + width - 44, y: y + (height - 44) / 2, width: 44, height: 44)
                // Narrow windows keep all five controls on distinct hit targets.
                if !order.isHidden && width < 350 {
                    previous.center.x = left + 66
                    nextButton.center.x = left + width - 66
                    order.frame.origin.y = y + height
                    repeatButton.frame.origin.y = y + height
                    y += 40
                }
                y += height + 16
            case .actions:
                guard style.showActions else { continue }
                actionsBackground.frame = CGRect(x: left, y: y, width: width, height: 52)
                let gap: CGFloat = style.actionsIsland ? 0 : 8
                let buttonWidth = max(0, (width - gap * 2) / 3)
                for (index, button) in [lyricsButton, queueButton, speedButton].enumerated() {
                    button.frame = CGRect(x: CGFloat(index) * (buttonWidth + gap), y: 0, width: buttonWidth, height: 52)
                }
                y += 68
            }
        }
        if !error.isHidden { error.frame = CGRect(x: left, y: y, width: width, height: 60); y += 68 }
        y += layoutInsets.bottom + 12
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: y)
        scroll.contentSize = content.bounds.size
        let backgroundHeight = style.coverExtend ? bounds.height : max(0, artworkFrame.maxY)
        backgroundImage.frame = CGRect(x: 0, y: 0, width: bounds.width, height: backgroundHeight)
        blur.frame = backgroundImage.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipe, currentStyle.coverSwipe else { return false }
        let velocity = swipe.velocity(in: artwork)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    @objc private func coverPanned(_ gesture: UIPanGestureRecognizer) {
        guard let session else { return }
        switch gesture.state {
        case .began: swipeIdentity = session.identity
        case .ended:
            defer { swipeIdentity = nil }
            let translation = gesture.translation(in: artwork)
            guard abs(translation.x) >= 70, session.accepts(swipeIdentity) else { return }
            session.control(translation.x < 0 ? .next : .previous, identity: swipeIdentity)
        case .cancelled, .failed: swipeIdentity = nil
        default: break
        }
    }

    private func toggleLyrics() {
        lyricsVisible.toggle()
        if lyricsVisible { session?.requestLyrics() }
        render()
    }

    private func openLyricsSelection() {
        guard let session, let track = session.lyricTrack, let parent = controller() else { return }
        let candidates: [PlayerLyricsCandidate]
        if case let .result(result) = session.lyricsState { candidates = result.candidates } else { candidates = [] }
        let screen = ExteralessLyricsSelectionController(context: session.context, track: track, candidates: candidates, changed: { [weak self] in
            guard let self, self.session?.lyricTrack == track, self.session?.active == true else { return }
            self.session?.requestLyrics(refresh: true)
        })
        if let parent = parent as? ExteralessChatTableController { parent.pushChild(screen) } else { parent.push(screen) }
    }

    @objc private func accessibilityChanged() { render() }
    @objc private func closePressed() { dismissAction() }
    @objc private func sourcePressed() { actions?.showSource() }
    @objc private func morePressed() { actions?.menu(from: more) }
    @objc private func likePressed() { session?.toggleProfileSave() }
    @objc private func previousPressed() { session?.control(.previous) }
    @objc private func playPressed() { session?.control(.playback(.togglePlayPause)) }
    @objc private func nextPressed() { session?.control(.next) }
    @objc private func orderPressed() { session?.cycleOrder() }
    @objc private func repeatPressed() { session?.cycleRepeat() }
    @objc private func seekBackPressed() { session?.seek(delta: -ChatPlaybackPolicy.seekDuration(index: ClientSettings.shared.integer("chats.doubleTapSeekDuration", default: 1))) }
    @objc private func seekForwardPressed() { session?.seek(delta: ChatPlaybackPolicy.seekDuration(index: ClientSettings.shared.integer("chats.doubleTapSeekDuration", default: 1))) }
    @objc private func lyricsPressed() { toggleLyrics() }
    @objc private func queuePressed() { actions?.openQueue() }
    @objc private func speedPressed() { session?.cycleSpeed() }

    var visualLyricsContentOffset: CGPoint { lyrics.contentOffset }
    var visualActiveLyricsIndex: Int? { lyrics.currentIndex }
    func visualSetKaraoke(_ value: Bool) { lyrics.setKaraoke(value) }
    func visualSetLyricsVisible(_ value: Bool) { if value != lyricsVisible { toggleLyrics() } }
    func visualScrollLyrics(to offset: CGPoint) { lyrics.scrollManually(to: offset) }
    func visualPlaybackTick() { if visualInput != nil && wantsActive { tick() } }
    func updateVisualInput(_ input: ExteralessPlayerVisualInput) {
        guard visualInput != nil, wantsActive else { return }
        if visualInput?.track != input.track { visualSeekLease.cancel() }
        visualInput = input
        render()
    }
}
