import ExteralessCore
import Foundation
import UIKit

/// Inline and karaoke presentations share real provider line/word timestamps.
/// Untimed lyrics remain readable; no synthesized word timings are presented.
final class ExteralessPlayerLyricsView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let mode = UISegmentedControl(items: ["Inline", "Karaoke"])
    private let table = UITableView(frame: .zero, style: .plain)
    private let status = UILabel()
    private let source = UILabel()
    private let retry = UIButton(type: .system)
    private let choose = UIButton(type: .system)
    private var lyrics: PlayerLyricsDocument?
    private var track: PlayerLyricsTrack?
    private var offset = 0.0
    private var position = 0.0
    private var duration = 0.0
    private var activeIndex: Int?
    private var visibleIndices: [Int] = []
    private var textColor = UIColor.label
    private var secondaryColor = UIColor.secondaryLabel
    private var primaryColor = UIColor.systemBlue
    private var currentPalette: ExteralessPlayerPalette?
    private var activeFont = UIFont.systemFont(ofSize: 23, weight: .semibold)
    private var inactiveFont = UIFont.systemFont(ofSize: 21, weight: .regular)
    private var lastAutomaticScroll: Int?
    private var resumeFollowAt: TimeInterval = 0
    var retryAction: (() -> Void)?
    var chooseAction: (() -> Void)?
    var enableAction: (() -> Void)?
    var modeChanged: (() -> Void)?
    var lineTapped: ((Int, PlayerLyricsDocument, Double, PlayerLyricsTrack) -> Void)?
    private var offerOnline = false
    private let now: () -> TimeInterval
    private let animateFollowing: Bool

    var preferredHeight: CGFloat { mode.selectedSegmentIndex == 0 ? 240 : 430 }

    override convenience init(frame: CGRect) {
        self.init(frame: frame, now: { CACurrentMediaTime() })
    }

    init(frame: CGRect, now: @escaping () -> TimeInterval, animateFollowing: Bool = true) {
        self.now = now
        self.animateFollowing = animateFollowing
        super.init(frame: frame)
        mode.selectedSegmentIndex = 0
        mode.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        mode.accessibilityIdentifier = "exteraless.player.lyrics.mode"
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.contentInsetAdjustmentBehavior = .never
        table.showsVerticalScrollIndicator = false
        table.accessibilityIdentifier = "exteraless.player.lyrics.lines"
        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = UIFont.preferredFont(forTextStyle: .body)
        source.font = UIFont.preferredFont(forTextStyle: .caption1)
        source.numberOfLines = 2
        source.textAlignment = .center
        retry.addTarget(self, action: #selector(retryPressed), for: .touchUpInside)
        choose.setTitle("Choose lyrics · Timing", for: .normal)
        choose.addTarget(self, action: #selector(choosePressed), for: .touchUpInside)
        for view in [mode, table, status, source, retry, choose] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: ExteralessPlayerSession.LyricsState, track: PlayerLyricsTrack?, palette: ExteralessPlayerPalette, position: Double, duration: Double, allowAutomaticScroll: Bool = true) {
        let previousLyrics = self.lyrics
        let previousTrack = self.track
        self.track = track
        let appearance = applyAppearance(palette)
        source.text = nil
        retry.isHidden = true
        choose.isEnabled = track != nil && chooseAction != nil
        offerOnline = false
        switch state {
        case let .displayDocument(document, userOffset):
            lyrics = document
            offset = userOffset
            status.text = document.instrumental ? "Instrumental" : nil
            source.text = document.provider + (document.synced ? " · Synced" : " · Plain text")
        case .idle: lyrics = nil; status.text = "Open lyrics to load this track."
        case .loading: lyrics = nil; status.text = "Loading lyrics…"
        case .unavailable: lyrics = nil; status.text = "Lyrics are available for music tracks."
        case let .failed(error):
            lyrics = nil
            status.text = error.localizedDescription
            retry.setTitle("Try again", for: .normal)
            retry.isHidden = false
        case let .result(result):
            lyrics = result.lyrics
            offset = result.userOffset
            if let lyrics = result.lyrics {
                status.text = lyrics.instrumental ? "Instrumental" : nil
                source.text = lyrics.provider + (lyrics.synced ? " · Synced" : " · Plain text") + (result.isUserSelection ? " · Your selection" : "")
                if result.userOffset != 0 { source.text! += String(format: " · Delay %+.1fs", result.userOffset) }
                if let warning = result.warning { source.text! += "\n" + warning.localizedDescription }
            } else if result.state == .offerOnline {
                offerOnline = true
                status.text = "Look up this track using LRCLIB and LRCMUX? Track title, artist, album and duration are sent to the services."
                retry.setTitle("Enable online lyrics", for: .normal)
                retry.isHidden = false
            } else {
                status.text = "No lyrics found. Choose a different match or import an LRC file."
                retry.setTitle("Search again", for: .normal)
                retry.isHidden = false
            }
        }
        table.isHidden = lyrics == nil || lyrics?.instrumental == true
        status.isHidden = !table.isHidden
        mode.isEnabled = lyrics != nil && lyrics?.instrumental != true
        let documentChanged = previousLyrics != lyrics || previousTrack != track
        if documentChanged {
            activeIndex = nil
            lastAutomaticScroll = nil
            rebuildIndices()
            table.reloadData()
        }
        updatePosition(position, duration: duration, allowAutomaticScroll: documentChanged || (allowAutomaticScroll && !appearance.changed))
        if appearance.changed { reapplyVisibleAppearance(fontChanged: appearance.fontChanged) }
        setNeedsLayout()
    }

    func updatePosition(_ position: Double, duration: Double, allowAutomaticScroll: Bool) {
        self.position = position
        self.duration = duration
        guard let lyrics else { return }
        let index = lyrics.index(at: position, userOffset: offset)
        if index != activeIndex {
            activeIndex = index
            rebuildIndices()
            table.reloadData()
        } else if mode.selectedSegmentIndex == 1, let index, let row = visibleIndices.firstIndex(of: index), let cell = table.cellForRow(at: IndexPath(row: row, section: 0)) {
            configure(cell, index: index)
        }
        if allowAutomaticScroll, mode.selectedSegmentIndex == 1, let index, lastAutomaticScroll != index, !table.isTracking, !table.isDecelerating, now() >= resumeFollowAt,
           let row = visibleIndices.firstIndex(of: index), table.bounds.height > 0 {
            lastAutomaticScroll = index
            table.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: animateFollowing && !UIAccessibility.isReduceMotionEnabled && !UIAccessibility.isVoiceOverRunning)
        }
    }

    private func rebuildIndices() {
        guard let lyrics else { visibleIndices = []; return }
        if mode.selectedSegmentIndex == 0 && lyrics.synced {
            let index = activeIndex ?? 0
            visibleIndices = Array(max(0, index - 1)..<min(lyrics.lines.count, index + 2))
        } else { visibleIndices = Array(lyrics.lines.indices) }
    }

    private func applyAppearance(_ palette: ExteralessPlayerPalette) -> (changed: Bool, fontChanged: Bool) {
        currentPalette = palette
        let text = palette.text.resolvedColor(with: traitCollection)
        let secondary = palette.secondary.resolvedColor(with: traitCollection)
        let primary = palette.primary.resolvedColor(with: traitCollection)
        let metrics = UIFontMetrics(forTextStyle: .title3)
        let active = metrics.scaledFont(for: UIFont.systemFont(ofSize: 23, weight: .semibold), compatibleWith: traitCollection)
        let inactive = metrics.scaledFont(for: UIFont.systemFont(ofSize: 21), compatibleWith: traitCollection)
        let fontChanged = !activeFont.isEqual(active) || !inactiveFont.isEqual(inactive)
        let changed = fontChanged || !textColor.isEqual(text) || !secondaryColor.isEqual(secondary) || !primaryColor.isEqual(primary)
        textColor = text
        secondaryColor = secondary
        primaryColor = primary
        activeFont = active
        inactiveFont = inactive
        tintColor = primary
        status.textColor = text
        source.textColor = secondary
        status.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        source.font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
        return (changed, fontChanged)
    }

    private func reapplyVisibleAppearance(fontChanged: Bool) {
        let savedOffset = table.contentOffset
        let anchor = table.indexPathsForVisibleRows?.min()
        let anchorOffset = anchor.map { table.rectForRow(at: $0).minY - savedOffset.y }
        for path in table.indexPathsForVisibleRows ?? [] {
            guard visibleIndices.indices.contains(path.row), let cell = table.cellForRow(at: path) else { continue }
            configure(cell, index: visibleIndices[path.row])
        }
        if fontChanged {
            UIView.performWithoutAnimation {
                table.beginUpdates()
                table.endUpdates()
                table.layoutIfNeeded()
                let desiredY: CGFloat
                if let anchor, let anchorOffset { desiredY = table.rectForRow(at: anchor).minY - anchorOffset }
                else { desiredY = savedOffset.y }
                let minimumY = -table.adjustedContentInset.top
                let maximumY = max(minimumY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
                table.setContentOffset(CGPoint(x: savedOffset.x, y: min(maximumY, max(minimumY, desiredY))), animated: false)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard let palette = currentPalette else { return }
        let appearance = applyAppearance(palette)
        if appearance.changed { reapplyVisibleAppearance(fontChanged: appearance.fontChanged) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mode.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 32)
        choose.frame = CGRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 44)
        source.frame = CGRect(x: 0, y: bounds.height - 85, width: bounds.width, height: 40)
        table.frame = CGRect(x: 0, y: 44, width: bounds.width, height: max(0, bounds.height - 135))
        status.frame = CGRect(x: 8, y: 42, width: max(0, bounds.width - 16), height: max(52, bounds.height - 142))
        retry.frame = CGRect(x: 0, y: bounds.height - 96, width: bounds.width, height: 44)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visibleIndices.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "lyric") ?? UITableViewCell(style: .default, reuseIdentifier: "lyric")
        configure(cell, index: visibleIndices[indexPath.row])
        return cell
    }

    private func configure(_ cell: UITableViewCell, index: Int) {
        guard let lyrics, lyrics.lines.indices.contains(index) else { return }
        let line = lyrics.lines[index]
        let active = index == activeIndex
        let font = active ? activeFont : inactiveFont
        let attributed = NSMutableAttributedString(string: line.text.isEmpty ? "♪" : line.text, attributes: [.font: font, .foregroundColor: active ? textColor : secondaryColor])
        if active, mode.selectedSegmentIndex == 1, !line.words.isEmpty {
            var searchRange = NSRange(location: 0, length: (line.text as NSString).length)
            for word in line.words {
                let token = word.text.trimmingCharacters(in: .whitespaces)
                let range = (line.text as NSString).range(of: token, options: [], range: searchRange)
                guard range.location != NSNotFound else { continue }
                if word.time <= position - offset { attributed.addAttribute(.foregroundColor, value: primaryColor, range: range) }
                searchRange = NSRange(location: range.location + range.length, length: (line.text as NSString).length - range.location - range.length)
            }
        } else if active, mode.selectedSegmentIndex == 1, let start = line.time {
            // Line-level karaoke interpolates only between the provider's real
            // line cues (or the real track end), not fabricated word timestamps.
            let end = lyrics.lines.indices.contains(index + 1) ? (lyrics.lines[index + 1].time ?? duration) : duration
            let fraction = end > start ? min(1, max(0, (position - offset - start) / (end - start))) : 1
            let boundary = line.text.index(line.text.startIndex, offsetBy: Int(Double(line.text.count) * fraction))
            let range = NSRange(line.text.startIndex..<boundary, in: line.text)
            if range.length > 0 { attributed.addAttribute(.foregroundColor, value: primaryColor, range: range) }
        }
        cell.textLabel?.attributedText = attributed
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.backgroundColor = .clear
        cell.selectionStyle = lyrics.synced ? .default : .none
        cell.accessibilityLabel = line.text
        cell.accessibilityHint = lyrics.synced ? "Seek to this line" : nil
        cell.accessibilityTraits = lyrics.synced ? .button : .staticText
        cell.accessibilityIdentifier = "exteraless.player.lyrics.line.\(index)"
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let lyrics, let track, visibleIndices.indices.contains(indexPath.row) else { return }
        lineTapped?(visibleIndices[indexPath.row], lyrics, offset, track)
    }
    var contentOffset: CGPoint { table.contentOffset }
    var currentIndex: Int? { activeIndex }
    func setKaraoke(_ value: Bool) {
        mode.selectedSegmentIndex = value ? 1 : 0
        mode.sendActions(for: .valueChanged)
    }
    func scrollManually(to offset: CGPoint) {
        scrollViewWillBeginDragging(table)
        table.setContentOffset(offset, animated: false)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { resumeFollowAt = now() + 5 }
    @objc private func changeMode() { rebuildIndices(); table.reloadData(); lastAutomaticScroll = nil; modeChanged?() }
    @objc private func retryPressed() { if offerOnline { enableAction?() } else { retryAction?() } }
    @objc private func choosePressed() { chooseAction?() }
}
