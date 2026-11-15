import AccountContext
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import UIKit

final class ExteralessPlayerController: ExteralessChatTableController {
    private struct PlaybackIdentity: Hashable {
        let player: Int32
        let item: AnyHashable
    }
    private let playerDisposable = MetaDisposable()
    private var state: SharedMediaPlayerItemPlaybackState?
    private var playerType: MediaManagerPlayerType?
    private var renderKey = ""
    private let scrubber = UISlider()
    private var scrubbing = false
    private var seekLease = ChatPlaybackSeekLease<PlaybackIdentity>()
    private var modernSurface: ExteralessPlayerSurface?

    init(context: AccountContext) {
        super.init(context: context, title: "Now playing")
        self.scrubber.minimumValue = 0
        self.scrubber.maximumValue = 1
        self.scrubber.accessibilityLabel = "Playback position"
        self.scrubber.accessibilityIdentifier = "exteraless.player.position"
        self.scrubber.addTarget(self, action: #selector(self.scrubBegan), for: .touchDown)
        self.scrubber.addTarget(self, action: #selector(self.scrubEnded), for: [.touchUpInside, .touchUpOutside])
        self.scrubber.addTarget(self, action: #selector(self.scrubCancelled), for: .touchCancel)
        self.accountInvalidated = { [weak self] in
            self?.playerDisposable.set(nil)
            self?.scrubber.isEnabled = false
            self?.seekLease.cancel()
            self?.modernSurface?.session?.invalidate()
        }
        self.render()
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { self.playerDisposable.dispose() }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        if PlayerStylePolicy.current.modernPlayer {
            let surface = ExteralessPlayerSurface(context: self.context, controller: { [weak self] in self }, dismiss: { [weak self] in self?.dismiss() })
            self.modernSurface = surface
            self.tableView.isHidden = true
            self.displayNode.view.addSubview(surface)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard self.accountIsValid else { return }
        if let surface = self.modernSurface {
            surface.setActive(true)
            return
        }
        self.playerDisposable.set((self.context.sharedContext.mediaManager.globalMediaPlayerState |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.accountIsValid else { return }
            guard let (account, value, type) = value, account.id == self.context.account.id, case let .state(state) = value else {
                self.state = nil
                self.playerType = nil
                self.seekLease.cancel()
                self.render()
                return
            }
            self.state = state
            self.playerType = type
            if !self.scrubbing {
                self.scrubber.value = state.status.duration > 0 && state.status.timestamp.isFinite ? Float(min(1, max(0, state.status.timestamp / state.status.duration))) : 0
            }
            let key = "\(state.playerIndex):\(state.item.stableId):\(self.seconds(state.status.timestamp)):\(state.status.status):\(state.status.baseRate):\(state.order.rawValue):\(state.looping.rawValue)"
            if self.renderKey != key && !self.scrubbing {
                self.renderKey = key
                self.render()
            }
        }))
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.modernSurface?.setActive(false)
        self.playerDisposable.set(nil)
        self.scrubbing = false
        self.seekLease.cancel()
        super.viewWillDisappear(animated)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        if let surface = self.modernSurface {
            let sides = layout.sideInsets(forBandFrom: 0, to: layout.size.height)
            surface.layoutInsets = UIEdgeInsets(top: max(layout.safeInsets.top, self.navigationLayout(layout: layout).navigationFrame.maxY), left: sides.left, bottom: layout.intrinsicInsets.bottom, right: sides.right)
            transition.updateFrame(view: surface, frame: CGRect(origin: .zero, size: layout.size))
            return
        }
        self.scrubber.frame = CGRect(x: 20, y: 0, width: max(0, self.tableView.bounds.width - 40), height: 52)
        let header = self.tableView.tableHeaderView ?? UIView()
        header.frame = CGRect(x: 0, y: 0, width: self.tableView.bounds.width, height: 52)
        if self.scrubber.superview !== header { header.addSubview(self.scrubber) }
        self.tableView.tableHeaderView = header
    }

    private func control(_ action: SharedMediaPlayerControlAction) {
        guard self.accountIsValid, self.state != nil, let type = self.playerType else { return }
        self.context.sharedContext.mediaManager.playlistControl(action, type: type)
    }

    private func seek(_ delta: Double) {
        guard let state = self.state, let timestamp = ChatPlaybackPolicy.seekPosition(timestamp: state.status.timestamp, delta: delta, duration: state.status.duration) else { return }
        self.control(.seek(timestamp))
    }

    private func cycleSpeed() {
        guard let state = self.state, let type = self.playerType else { return }
        let next = ChatPlaybackPolicy.nextSpeed(after: state.status.baseRate)
        let rate = AudioPlaybackRate(next)
        if type == .voice {
            let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.context.sharedContext.accountManager) { $0.withUpdatedVoicePlaybackRate(rate) }.startStandalone()
            self.control(.setBaseRate(rate))
        } else {
            let playerIndex = state.playerIndex
            self.writeSettings({ try ClientSettings.shared.set(.number(next), for: "chats.musicPlaybackSpeed") }, completion: { [weak self] in
                guard let self, self.state?.playerIndex == playerIndex else { return }
                self.control(.setBaseRate(rate))
            })
        }
    }

    private func cycleRepeat() {
        guard let state = self.state else { return }
        let next: MusicPlaybackSettingsLooping
        switch state.looping {
        case .none: next = .all
        case .all: next = .item
        case .item: next = .none
        }
        let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.context.sharedContext.accountManager) { $0.withUpdatedLooping(next) }.startStandalone()
        self.control(.setLooping(next))
    }

    private func toggleShuffle() {
        guard let state = self.state else { return }
        let next: MusicPlaybackSettingsOrder = state.order == .random ? .regular : .random
        let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.context.sharedContext.accountManager) { $0.withUpdatedOrder(next) }.startStandalone()
        self.control(.setOrder(next))
    }

    @objc private func scrubBegan() {
        guard let state = self.state else { return }
        self.scrubbing = true
        self.seekLease.begin(identity: PlaybackIdentity(player: state.playerIndex, item: state.item.stableId))
    }
    @objc private func scrubCancelled() {
        self.scrubbing = false
        self.seekLease.cancel()
        if let state = self.state {
            self.scrubber.value = state.status.duration > 0 && state.status.timestamp.isFinite ? Float(min(1, max(0, state.status.timestamp / state.status.duration))) : 0
        }
        self.render()
    }
    @objc private func scrubEnded() {
        self.scrubbing = false
        guard let state = self.state else { return }
        if let timestamp = self.seekLease.finish(identity: PlaybackIdentity(player: state.playerIndex, item: state.item.stableId), fraction: Double(self.scrubber.value), duration: state.status.duration) {
            self.control(.seek(timestamp))
        } else {
            self.scrubCancelled()
        }
    }

    private func title(for item: SharedMediaPlaylistItem?) -> String {
        guard let display = item?.displayData else { return "Audio" }
        switch display {
        case let .music(title, performer, _, _, _): return [title, performer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        case let .voice(author, _): return "Voice message · " + (author?.compactDisplayTitle ?? "")
        case let .instantVideo(author, _, _): return "Video message · " + (author?.compactDisplayTitle ?? "")
        }
    }

    private func seconds(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(Double(Int32.max), max(0, value)))
    }

    private func render() {
        guard self.accountIsValid else { return }
        guard let state = self.state else {
            self.scrubber.isEnabled = false
            self.sections = [ExteralessChatSection(rows: [ExteralessChatRow(id: "player.empty", title: "Nothing playing in this account", detail: "Start music, a voice message or a video message in a chat.", enabled: false)])]
            self.reloadRows()
            return
        }
        self.scrubber.isEnabled = state.status.duration.isFinite && state.status.duration > 0
        let playing: Bool
        switch state.status.status {
        case .playing: playing = true
        case let .buffering(_, whilePlaying, _, _): playing = whilePlaying
        case .paused: playing = false
        }
        let duration = self.seconds(state.status.duration)
        let position = self.seconds(state.status.timestamp)
        let elapsed = String(format: "%d:%02d / %d:%02d", position / 60, position % 60, duration / 60, duration % 60)
        let seek = ChatPlaybackPolicy.seekDuration(index: ClientSettings.shared.integer("chats.doubleTapSeekDuration", default: 1))
        let rows: [ExteralessChatRow] = [
            ExteralessChatRow(id: "player.title", title: self.title(for: state.item), detail: elapsed, enabled: false),
            ExteralessChatRow(id: "player.playPause", title: playing ? "Pause" : "Play", action: { [weak self] in self?.control(.playback(.togglePlayPause)) }),
            ExteralessChatRow(id: "player.previous", title: "Previous", detail: self.title(for: state.previousItem), enabled: state.previousItem != nil || state.status.timestamp > 5, action: { [weak self] in self?.control(.previous) }),
            ExteralessChatRow(id: "player.next", title: "Next", detail: self.title(for: state.nextItem), enabled: state.nextItem != nil, action: { [weak self] in self?.control(.next) }),
            ExteralessChatRow(id: "player.backward", title: "Back \(Int(seek)) seconds", action: { [weak self] in self?.seek(-seek) }),
            ExteralessChatRow(id: "player.forward", title: "Forward \(Int(seek)) seconds", action: { [weak self] in self?.seek(seek) }),
            ExteralessChatRow(id: "player.speed", title: "Speed · \(state.status.baseRate)×", detail: "1 → 1.2 → 1.5 → 1.7 → 2 → 0.5", action: { [weak self] in self?.cycleSpeed() })
        ]
        self.sections = [ExteralessChatSection(rows: rows)]
        if self.playerType != .voice {
            let repeatTitle: String
            switch state.looping {
            case .none: repeatTitle = "Off"
            case .all: repeatTitle = "Queue"
            case .item: repeatTitle = "Track"
            }
            self.sections.append(ExteralessChatSection(rows: [
                ExteralessChatRow(id: "player.shuffle", title: "Shuffle", checked: state.order == .random, action: { [weak self] in self?.toggleShuffle() }),
                ExteralessChatRow(id: "player.repeat", title: "Repeat · " + repeatTitle, action: { [weak self] in self?.cycleRepeat() })
            ]))
        }
        self.reloadRows()
    }
}
