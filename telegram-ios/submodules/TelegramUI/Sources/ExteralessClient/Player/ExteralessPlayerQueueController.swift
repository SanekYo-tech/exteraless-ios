import AccountContext
import Display
import Foundation
import InstantPageUI
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences

/// Only used for a playlist that is not backed by chat history. Rows are the
/// actual InstantPage tracks, or the actual single item; no invented queue.
final class ExteralessPlayerQueueController: ExteralessChatTableController {
    private let initial: SharedMediaPlayerItemPlaybackState
    private var type: MediaManagerPlayerType
    private let playbackDisposable = MetaDisposable()
    private let accountDisposable = MetaDisposable()

    init(context: AccountContext, initial: SharedMediaPlayerItemPlaybackState, type: MediaManagerPlayerType) {
        self.initial = initial
        self.type = type
        super.init(context: context, title: "Queue")
        accountInvalidated = { [weak self] in
            self?.playbackDisposable.set(nil)
            self?.accountDisposable.set(nil)
        }
        render(initial)
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { playbackDisposable.dispose(); accountDisposable.dispose() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        accountDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            if value.primary?.account.id != self.context.account.id { self.invalidateAccount() }
        }))
        guard accountIsValid else { return }
        playbackDisposable.set((context.sharedContext.mediaManager.globalMediaPlayerState |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.accountIsValid else { return }
            guard let (account, value, type) = value, account.id == self.context.account.id, case let .state(state) = value, state.playlistId.isEqual(to: self.initial.playlistId) else { self.invalidateAccount(); return }
            self.type = type
            self.render(state)
        }))
    }

    override func viewWillDisappear(_ animated: Bool) { playbackDisposable.set(nil); super.viewWillDisappear(animated) }

    private func render(_ state: SharedMediaPlayerItemPlaybackState) {
        if let location = state.playlistLocation as? InstantPagePlaylistLocation, location.webPage != nil {
            let selected = (state.item.id as? InstantPagePlaylistItemIndexProviding)?.instantPageMediaIndex
            sections = [ExteralessChatSection(rows: location.tracks.map { track in
                var title = track.file.fileName ?? "Audio"
                var artist: String?
                for attribute in track.file.attributes {
                    if case let .Audio(_, _, trackTitle, performer, _) = attribute { title = trackTitle ?? title; artist = performer }
                }
                return ExteralessChatRow(id: "player.queue.\(track.index)", title: title, detail: artist, checked: selected == track.index, action: { [weak self] in self?.play(index: track.index, location: location) })
            })]
        } else {
            let title: String
            if let data = state.item.displayData, case let .music(value, _, _, _, _) = data { title = value ?? "Audio" } else { title = "Current audio" }
            sections = [ExteralessChatSection(footer: "This source contains one playable item.", rows: [ExteralessChatRow(id: "player.queue.current", title: title, checked: true, action: { [weak self] in
                guard let self, self.accountIsValid else { return }
                self.context.sharedContext.mediaManager.playlistControl(.playback(.togglePlayPause), type: self.type)
            })])]
        }
        reloadRows()
    }

    private func play(index: Int, location: InstantPagePlaylistLocation) {
        guard accountIsValid, let webpage = location.webPage, let selected = location.tracks.firstIndex(where: { $0.index == index }) else { return }
        let tracks = location.tracks.map { InstantPageMedia(index: $0.index, media: .file($0.file), url: nil, caption: nil, credit: nil) }
        let playlistId: InstantPageMediaPlaylistId = location.messageId.map { .richMessage(messageId: $0) } ?? .instantPage(webpageId: location.webpageId)
        let playlist = InstantPageMediaPlaylist(playlistId: playlistId, webPage: webpage, messageReference: location.messageReference, items: tracks, initialItemIndex: selected)
        var selectedType: MediaManagerPlayerType = location.tracks[selected].file.isVoice ? .voice : .music
        for attribute in location.tracks[selected].file.attributes {
            if case let .Video(_, _, flags, _, _, _) = attribute, flags.contains(.instantRoundVideo) { selectedType = .voice }
        }
        context.sharedContext.mediaManager.setPlaylist((context, playlist), type: selectedType, control: .playback(.play))
    }
}
