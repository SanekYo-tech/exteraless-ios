import AccountContext
import AVFoundation
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

struct ExteralessPlaybackIdentity: Hashable {
    let player: Int32
    let item: AnyHashable
    let resource: String
    let duration: Int64
}

@MainActor
enum ExteralessPlayerServices {
    private static var clients: [Int64: PlayerLyricsClient] = [:]

    static func lyrics(context: AccountContext) -> PlayerLyricsClient {
        let id = context.account.id.int64
        if let client = clients[id] { return client }
        let directory = URL(fileURLWithPath: context.sharedContext.basePath, isDirectory: true)
            .appendingPathComponent("exteraless-player", isDirectory: true)
            .appendingPathComponent(String(id), isDirectory: true)
        let client = PlayerLyricsClient(cacheURL: directory.appendingPathComponent("lyrics-v1.json"))
        clients[id] = client
        return client
    }

    static func clear(account: Int64) {
        if let client = clients.removeValue(forKey: account) { Task { await client.invalidate() } }
    }
}

/// One UI lease on the real MediaManager. Commands never construct a replacement
/// playlist, seek a later track, or resume playback merely because a view appears.
@MainActor
final class ExteralessPlayerSession {
    enum LyricsState {
        case idle, loading, unavailable, failed(PlayerLyricsError), result(PlayerLyricsResult)
        /// Explicit local presentation input; never a provider/backend result.
        case displayDocument(PlayerLyricsDocument, offset: Double)
    }

    let context: AccountContext
    let lyricsClient: PlayerLyricsClient
    private(set) var state: SharedMediaPlayerItemPlaybackState?
    private(set) var type: MediaManagerPlayerType?
    private(set) var presentationData: PresentationData
    private(set) var style = PlayerStylePolicy.current
    private(set) var accountIsValid = true
    private(set) var active = false
    private(set) var savedIds: Set<Int64>?
    private(set) var profileSavePending = false
    private(set) var lyricsState: LyricsState = .idle
    private(set) var lyricTrack: PlayerLyricsTrack?
    private(set) var embeddedLyrics: PlayerLyricsDocument?
    private(set) var album: String?
    private(set) var operationError: String?
    var updated: (() -> Void)?
    var invalidated: (() -> Void)?

    private var acceptsAccount = false
    private var lyricsRequested = false
    private var peerCopyProtected = true
    private var seekLease = ChatPlaybackSeekLease<ExteralessPlaybackIdentity>()
    private var lyricsGeneration = PlayerLyricsGeneration()
    private var lyricsTask: Task<Void, Never>?
    private var metadataAsset: AVURLAsset?
    private var metadataTimeout: DispatchWorkItem?
    private let playbackDisposable = MetaDisposable()
    private let accountDisposable = MetaDisposable()
    private let savedDisposable = MetaDisposable()
    private let protectionDisposable = MetaDisposable()
    private let metadataDisposable = MetaDisposable()
    private let operationDisposable = MetaDisposable()
    private let presentationDisposable = MetaDisposable()
    private var settingsObservation: ClientSettingsObservation?
    private static let settingsWriter = DispatchQueue(label: "Exteraless.Player.Settings", qos: .utility)

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.lyricsClient = ExteralessPlayerServices.lyrics(context: context)
    }

    var identity: ExteralessPlaybackIdentity? {
        guard let state, let file else { return nil }
        let duration = state.status.duration.isFinite ? Int64(max(0, min(PlayerLyricsLimits.maximumTrackDuration, state.status.duration)) * 1000) : 0
        return ExteralessPlaybackIdentity(player: state.playerIndex, item: state.item.stableId, resource: file.media.resource.id.stringRepresentation, duration: duration)
    }

    var file: FileMediaReference? {
        guard let source = state?.item.playbackData?.source else { return nil }
        if case let .telegramFile(reference, _, _) = source { return reference }
        return nil
    }

    var sourceMessageId: EngineMessage.Id? {
        guard let file else { return nil }
        if case let .message(message, _) = file { return message.id }
        return nil
    }

    var profileMusicPeerId: EnginePeer.Id? {
        if let location = state?.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(context, _, _) = location { return context.peerId }
        return nil
    }

    var isPlaying: Bool {
        guard let state else { return false }
        switch state.status.status {
        case .playing: return true
        case let .buffering(_, whilePlaying, _, _): return whilePlaying
        case .paused: return false
        }
    }

    var isAdvancing: Bool {
        if let state, case .playing = state.status.status { return true }
        return false
    }

    var position: Double {
        guard let state else { return 0 }
        return PlayerTimelinePolicy.position(timestamp: state.status.timestamp, generationTimestamp: state.status.generationTimestamp, now: CACurrentMediaTime(), duration: state.status.duration, rate: state.status.baseRate, advancing: isAdvancing)
    }

    var canShare: Bool {
        guard active, acceptsAccount, accountIsValid, !peerCopyProtected, let source = state?.item.playbackData?.source else { return false }
        if case let .telegramFile(_, copyProtected, viewOnce) = source { return !copyProtected && !viewOnce }
        return false
    }

    var canSaveToProfile: Bool {
        guard canShare, type == .music, let file, savedIds != nil, !profileSavePending,
              file.media.resource is CloudDocumentMediaResource else { return false }
        if case let .message(message, _) = file, message.isSecret == true || message.id?.peerId.namespace == Namespaces.Peer.SecretChat { return false }
        return true
    }

    var isSavedToProfile: Bool { file.map { savedIds?.contains($0.media.fileId.id) == true } ?? false }

    var titleAndArtist: (String, String) {
        guard let data = state?.item.displayData else { return ("Nothing playing", "Start audio in this account") }
        switch data {
        case let .music(title, performer, _, _, _): return (title ?? "Unknown track", performer ?? "Unknown artist")
        case let .voice(author, _): return ("Voice message", author?.compactDisplayTitle ?? "")
        case let .instantVideo(author, _, _): return ("Video message", author?.compactDisplayTitle ?? "")
        }
    }

    func start() {
        guard !active, accountIsValid else { return }
        active = true
        style = .current
        accountDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.active else { return }
            guard value.primary?.account.id == self.context.account.id else { self.invalidate(); return }
            self.acceptsAccount = true
        }))
        guard active else { return }
        presentationDisposable.set((context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            self?.presentationData = data
            self?.updated?()
        }))
        savedDisposable.set((context.engine.peers.savedMusicIds() |> deliverOnMainQueue).start(next: { [weak self] ids in
            self?.savedIds = ids
            self?.updated?()
        }))
        playbackDisposable.set(combineLatest(queue: .mainQueue(), context.sharedContext.activeAccountContexts, context.sharedContext.mediaManager.globalMediaPlayerState).start(next: { [weak self] accounts, value in
            guard let self, self.active, self.accountIsValid else { return }
            guard accounts.primary?.account.id == self.context.account.id else { self.invalidate(); return }
            self.acceptsAccount = true
            let previous = self.identity
            if let (account, value, type) = value, account.id == self.context.account.id, case let .state(state) = value {
                self.state = state
                self.type = type
            } else {
                self.state = nil
                self.type = nil
            }
            if previous != self.identity {
                self.seekLease.cancel()
                self.cancelLyrics()
                self.operationDisposable.set(nil)
                self.profileSavePending = false
                self.operationError = nil
                self.album = nil
                self.embeddedLyrics = nil
                self.updateProtection()
                self.updateTrack()
                self.loadEmbeddedMetadata()
                if self.lyricsRequested { self.loadLyrics() }
            }
            self.updated?()
        }))
        settingsObservation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.contains(where: PlayerFeatures.owns) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                let old = self.style
                self.style = .current
                if old.onlineLyrics != self.style.onlineLyrics {
                    self.cancelLyrics()
                    if self.lyricsRequested { self.loadLyrics() }
                }
                self.updated?()
            }
        }
        updated?()
    }

    func stop() {
        active = false
        acceptsAccount = false
        playbackDisposable.set(nil)
        accountDisposable.set(nil)
        savedDisposable.set(nil)
        protectionDisposable.set(nil)
        presentationDisposable.set(nil)
        operationDisposable.set(nil)
        profileSavePending = false
        settingsObservation?.cancel()
        settingsObservation = nil
        seekLease.cancel()
        cancelLyrics()
        metadataDisposable.set(nil)
        metadataTimeout?.cancel()
        metadataTimeout = nil
        metadataAsset?.cancelLoading()
        metadataAsset = nil
        // Reappearing must refresh metadata/protection even on the same track.
        state = nil
        type = nil
        lyricTrack = nil
    }

    func invalidate() {
        guard accountIsValid else { return }
        accountIsValid = false
        stop()
        lyricsState = .unavailable
        updated?()
        invalidated?()
    }

    func accepts(_ identity: ExteralessPlaybackIdentity?) -> Bool {
        active && acceptsAccount && accountIsValid && identity != nil && self.identity == identity
    }

    func control(_ action: SharedMediaPlayerControlAction, identity: ExteralessPlaybackIdentity? = nil) {
        guard accepts(identity ?? self.identity), let type else { return }
        context.sharedContext.mediaManager.playlistControl(action, type: type)
    }

    func closePlayback() {
        guard accepts(identity), let type else { return }
        context.sharedContext.mediaManager.setPlaylist(nil, type: type, control: .playback(.pause))
    }

    func beginScrub() { if let identity, accepts(identity) { seekLease.begin(identity: identity) } }
    func cancelScrub() { seekLease.cancel() }
    func finishScrub(_ fraction: Double) {
        guard let identity, let state, accepts(identity) else { seekLease.cancel(); return }
        if let timestamp = seekLease.finish(identity: identity, fraction: fraction, duration: state.status.duration) { control(.seek(timestamp), identity: identity) }
    }

    func seekLine(_ index: Int, lyrics: PlayerLyricsDocument, offset: Double, track: PlayerLyricsTrack) {
        guard lyricTrack == track, let state, let timestamp = lyrics.seekTime(line: index, userOffset: offset, duration: state.status.duration), let identity else { return }
        // Line taps use the same identity lease as continuous scrubbing.
        beginScrub()
        if let value = seekLease.finish(identity: identity, fraction: timestamp / state.status.duration, duration: state.status.duration) { control(.seek(value), identity: identity) }
    }

    func seek(delta: Double) {
        guard let state, let timestamp = ChatPlaybackPolicy.seekPosition(timestamp: position, delta: delta, duration: state.status.duration) else { return }
        control(.seek(timestamp))
    }

    func cycleSpeed() {
        guard let state, let type, let identity, accepts(identity) else { return }
        let next = ChatPlaybackPolicy.nextSpeed(after: state.status.baseRate)
        let rate = AudioPlaybackRate(next)
        if type == .voice {
            let _ = updateMusicPlaybackSettingsInteractively(accountManager: context.sharedContext.accountManager) { $0.withUpdatedVoicePlaybackRate(rate) }.startStandalone()
            control(.setBaseRate(rate), identity: identity)
        } else {
            writeSetting(.number(next), key: "chats.musicPlaybackSpeed") { [weak self] in self?.control(.setBaseRate(rate), identity: identity) }
        }
    }

    func cycleRepeat() {
        guard let state, type != .voice else { return }
        let next: MusicPlaybackSettingsLooping
        switch state.looping { case .none: next = .all; case .all: next = .item; case .item: next = .none }
        let _ = updateMusicPlaybackSettingsInteractively(accountManager: context.sharedContext.accountManager) { $0.withUpdatedLooping(next) }.startStandalone()
        control(.setLooping(next))
    }

    func cycleOrder() {
        guard let state, type != .voice else { return }
        let next: MusicPlaybackSettingsOrder
        switch state.order { case .regular: next = .reversed; case .reversed: next = .random; case .random: next = .regular }
        let _ = updateMusicPlaybackSettingsInteractively(accountManager: context.sharedContext.accountManager) { $0.withUpdatedOrder(next) }.startStandalone()
        control(.setOrder(next))
    }

    func toggleProfileSave() {
        guard canSaveToProfile, let file, let identity else { return }
        profileSavePending = true
        operationError = nil
        updated?()
        let completed: () -> Void = { [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.profileSavePending = false
            self.updated?()
        }
        let ownList: ProfileSavedMusicContext?
        if let location = state?.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(context, _, _) = location, context.peerId == self.context.account.peerId { ownList = context }
        else { ownList = nil }
        let save = !isSavedToProfile
        let signal = ownList?.updateMusic(file: file, isSaved: save) ?? updateSavedMusic(engine: context.engine, file: file, isSaved: save)
        operationDisposable.set((signal |> deliverOnMainQueue).start(error: { [weak self] _ in
            guard let self, self.accepts(identity) else { return }
            self.profileSavePending = false
            self.operationError = save ? "Couldn't add this track to your profile." : "Couldn't remove this track from your profile."
            self.updated?()
        }, completed: completed))
    }

    func requestLyrics(refresh: Bool = false) {
        lyricsRequested = true
        loadLyrics(refresh: refresh)
    }

    func enableOnlineLyrics() {
        writeSetting(.bool(true), key: "appearance.lrclibAllowed") { [weak self] in
            self?.style = .current
            self?.requestLyrics(refresh: true)
        }
    }

    func writeSetting(_ value: ClientSettingValue, key: String, completion: @escaping () -> Void = {}) {
        guard active, accountIsValid else { return }
        Self.settingsWriter.async { [weak self] in
            let failed: Bool
            do { try ClientSettings.shared.set(value, for: key); failed = false } catch { failed = true }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.accountIsValid else { return }
                if failed { self.operationError = "Couldn't save the player setting."; self.updated?() }
                else { completion() }
            }
        }
    }

    private func updateProtection() {
        protectionDisposable.set(nil)
        peerCopyProtected = true
        guard let id = sourceMessageId else { peerCopyProtected = false; return }
        guard id.peerId.namespace != Namespaces.Peer.SecretChat else { return }
        let identity = self.identity
        let signal: Signal<Bool, NoError>
        if id.peerId.namespace == Namespaces.Peer.CloudUser {
            signal = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.CopyProtectionEnabled(id: id.peerId), TelegramEngine.EngineData.Item.Peer.MyCopyProtectionEnabled(id: id.peerId)) |> map { $0 || $1 }
        } else { signal = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.CopyProtectionEnabled(id: id.peerId)) }
        let protected = combineLatest(signal, context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: id))) |> map { peerProtected, message -> Bool in
            guard let message else { return true }
            return peerProtected || message._asMessage().isCopyProtected() || message._asMessage().containsSecretMedia
        }
        protectionDisposable.set((protected |> deliverOnMainQueue).start(next: { [weak self] protected in
            guard let self, self.accepts(identity) else { return }
            self.peerCopyProtected = protected
            self.updated?()
        }))
    }

    private func updateTrack() {
        guard type == .music, let file, let state else { lyricTrack = nil; return }
        let query = PlayerLyricsQuery(artist: titleAndArtist.1 == "Unknown artist" ? nil : titleAndArtist.1, title: titleAndArtist.0, album: album, duration: state.status.duration)
        lyricTrack = PlayerLyricsTrack(account: context.account.id.int64, resource: file.media.resource.id.stringRepresentation, duration: state.status.duration, query: query)
    }

    private func cancelLyrics() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsGeneration.cancel()
        lyricsState = .idle
    }

    private func loadLyrics(refresh: Bool = false) {
        cancelLyrics()
        guard active, accountIsValid, let track = lyricTrack else { lyricsState = .unavailable; updated?(); return }
        let token = lyricsGeneration.begin(track)
        let client = lyricsClient, embedded = embeddedLyrics, allowed = style.onlineLyrics
        lyricsState = .loading
        updated?()
        lyricsTask = Task { [weak self] in
            do {
                let result = try await client.lookup(track: track, onlineAllowed: allowed, embedded: embedded, refresh: refresh)
                guard !Task.isCancelled, let self, self.active, self.accountIsValid, self.lyricsGeneration.accepts(token) else { return }
                self.lyricsState = .result(result)
                self.updated?()
            } catch {
                guard !Task.isCancelled, let self, self.active, self.lyricsGeneration.accepts(token) else { return }
                let error = (error as? PlayerLyricsError) ?? .network
                if error != .cancelled { self.lyricsState = .failed(error); self.updated?() }
            }
        }
    }

    private func loadEmbeddedMetadata() {
        metadataDisposable.set(nil)
        metadataAsset?.cancelLoading()
        metadataTimeout?.cancel()
        metadataAsset = nil
        guard type == .music, let file, let identity else { return }
        metadataDisposable.set((context.engine.resources.data(resource: EngineMediaResource(file.media.resource))
        |> filter { $0.isComplete }
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self, self.accepts(identity) else { return }
            let asset = AVURLAsset(url: URL(fileURLWithPath: data.path))
            self.metadataAsset = asset
            let timeout = DispatchWorkItem { [weak self, weak asset] in
                guard let self, let asset, self.metadataAsset === asset else { return }
                self.metadataAsset = nil
                asset.cancelLoading()
            }
            self.metadataTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            asset.loadValuesAsynchronously(forKeys: ["lyrics", "commonMetadata"]) { [weak self, weak asset] in
                guard let asset else { return }
                var error: NSError?
                let text = asset.statusOfValue(forKey: "lyrics", error: &error) == .loaded ? asset.lyrics : nil
                let lyrics = text.flatMap { try? PlayerLyricsDocument.parse($0, source: .file, provider: "Embedded lyrics") }
                let album: String?
                if asset.statusOfValue(forKey: "commonMetadata", error: &error) == .loaded {
                    album = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: .commonIdentifierAlbumName).first?.stringValue
                } else { album = nil }
                DispatchQueue.main.async { [weak self, weak asset] in
                    guard let self, let asset, self.accepts(identity), self.metadataAsset === asset else { return }
                    self.metadataTimeout?.cancel()
                    self.metadataAsset = nil
                    self.embeddedLyrics = lyrics
                    self.album = album.map { String($0.prefix(512)) }
                    self.updateTrack()
                    if self.lyricsRequested { self.loadLyrics() }
                }
            }
        }))
    }

    deinit {
        playbackDisposable.dispose(); accountDisposable.dispose(); savedDisposable.dispose()
        protectionDisposable.dispose(); metadataDisposable.dispose(); operationDisposable.dispose(); presentationDisposable.dispose()
        settingsObservation?.cancel(); lyricsTask?.cancel(); metadataTimeout?.cancel(); metadataAsset?.cancelLoading()
    }
}
