import AccountContext
import FetchManagerImpl
import Foundation
import PluginHost
import SwiftSignalKit
import TelegramCore

/// Existing native Signals, not a polling loop. Only a real FetchManagerImpl
/// supplies downloading-list events; MediaManager's facade supplies playback.
final class NativeServiceLivePublishers {
    let events: Set<NativeServiceNotification>
    private let lifetime = DisposableSet()
    private let messageRead = MetaDisposable()
    private let context: AccountContext
    private let scope: NativeServiceSnapshots.Scope
    private let snapshots: NativeServiceControllerSnapshots
    private let emit: @Sendable (NativeServiceNotification, [PluginJSONValue]) -> Void
    private var lastRoot: EngineChatList?
    private var lastArchive: EngineChatList?
    private var downloads: PluginJSONValue?
    private var playback = NativeServicePlaybackReducer()
    private var messageId: EngineMessage.Id?
    private var messageValue: PluginJSONValue?
    private var latestState: SharedMediaPlayerItemPlaybackState?
    private var messageGeneration = UUID()

    @MainActor init(context: AccountContext, scope: NativeServiceSnapshots.Scope, snapshots: NativeServiceControllerSnapshots,
                    emit: @escaping @Sendable (NativeServiceNotification, [PluginJSONValue]) -> Void) {
        self.context = context
        self.scope = scope
        self.snapshots = snapshots
        self.emit = emit
        var events: Set<NativeServiceNotification> = [.dialogsNeedReload, .messagePlayingDidStart,
            .messagePlayingPlayStateChanged, .messagePlayingDidSeek, .messagePlayingProgressDidChanged]
        if context.fetchManager is FetchManagerImpl { events.insert(.onDownloadingFilesChanged) }
        self.events = events
        for (group, count, archive) in [(EngineChatList.Group.root, 64, false), (.archive, 16, true)] {
            lifetime.add((context.engine.messages.chatList(group: group, count: count) |> deliverOnMainQueue).start(next: { [weak self] list in
                guard let self, self.snapshots.values.isCurrent(scope) else { return }
                let previous = archive ? self.lastArchive : self.lastRoot
                if archive { self.lastArchive = list } else { self.lastRoot = list }
                if let previous, previous != list, !list.isLoading { self.emit(.dialogsNeedReload, []) }
            }))
        }
        if let fetchManager = context.fetchManager as? FetchManagerImpl {
            lifetime.add((fetchManager.entriesSummary |> deliverOnMainQueue).start(next: { [weak self] entries in
                guard let self, self.snapshots.values.isCurrent(scope) else { return }
                let value = PluginJSONValue.object(["total": .integer(Int64(entries.count)), "truncated": .bool(entries.count > 128),
                    "entries": .array(entries.prefix(128).map { entry in
                        var result: [String: PluginJSONValue] = ["resourceId": .string(entry.resourceReference.resource.id.stringRepresentation),
                            "paused": .bool(entry.isPaused)]
                        if case let .messageId(id) = entry.id.locationKey {
                            result["messageId"] = .integer(Int64(id.id))
                            result["peerId"] = .integer(id.peerId.toInt64())
                        }
                        return .object(result)
                    })])
                let previous = self.downloads
                self.downloads = value
                snapshots.publish(value, key: "downloads", scope: scope, source: "FetchManagerImpl.entriesSummary")
                if let previous, previous != value { self.emit(.onDownloadingFilesChanged, []) }
            }))
        }
        lifetime.add((context.sharedContext.mediaManager.globalMediaPlayerState |> deliverOnMainQueue).start(next: { [weak self] value in
            self?.receive(value)
        }))
    }

    @MainActor private func receive(_ value: (Account, SharedMediaPlayerItemPlaybackStateOrLoading, MediaManagerPlayerType)?) {
        guard snapshots.values.isCurrent(scope) else { return }
        guard let (account, state, _) = value, account.id.int64 == scope.recordId else {
            messageRead.set(nil)
            messageGeneration = UUID()
            messageId = nil
            messageValue = nil
            latestState = nil
            snapshots.publish(.object(["active": .bool(false)]), key: "playback", scope: scope, source: "MediaManager.globalMediaPlayerState")
            for (event, arguments) in playback.receive(nil) { emit(event, arguments) }
            return
        }
        guard case let .state(state) = state else {
            messageRead.set(nil)
            messageGeneration = UUID()
            messageId = nil
            messageValue = nil
            latestState = nil
            snapshots.publish(.null, key: "playback", scope: scope, source: "MediaManager.loading")
            return
        }
        let id = (state.item.id as? PeerMessagesMediaPlaylistItemId)?.messageId
            ?? (state.playlistId as? InstantPagePlaylistIdProviding)?.instantPageRichMessageId
        guard let id else {
            // A URL/Instant View track has no Android MessageObject identity.
            messageRead.set(nil)
            messageGeneration = UUID()
            messageId = nil
            messageValue = nil
            latestState = nil
            snapshots.publish(.null, key: "playback", scope: scope, source: "MediaManager.nonMessagePlaylist")
            return
        }
        latestState = state
        if messageId != id {
            messageId = id
            messageValue = nil
            let generation = UUID()
            messageGeneration = generation
            snapshots.publish(.null, key: "playback", scope: scope, source: "MediaManager.messageLoading")
            messageRead.set((nativeServiceCachedMessageValue(account: context.account, id: id) |> deliverOnMainQueue).start(next: { [weak self] value in
                guard let self, self.messageGeneration == generation, self.snapshots.values.isCurrent(self.scope), value != .null,
                      let json = try? PluginJSONValue(jsonObject: value.jsonObject) else { return }
                self.messageValue = json
                self.publishPlayer()
            }))
        } else {
            publishPlayer()
        }
    }

    @MainActor private func publishPlayer() {
        guard let state = latestState, let id = messageId, let message = messageValue else { return }
        let status: String
        switch state.status.status {
        case .playing: status = "playing"
        case .paused: status = "paused"
        case let .buffering(_, whilePlaying, _, _): status = whilePlaying ? "bufferingPlaying" : "bufferingPaused"
        }
        guard let frame = try? NativeServicePlaybackFrame(identity: "\(id.peerId.toInt64()):\(id.namespace):\(id.id)",
            messageId: Int64(id.id), message: message, state: status, position: state.status.timestamp,
            duration: state.status.duration, rate: state.status.baseRate, seekId: Int64(state.status.seekId)) else { return }
        snapshots.publish(frame.value, key: "playback", scope: scope, source: "MediaManager.MediaPlayerStatus")
        for (event, arguments) in playback.receive(frame) { emit(event, arguments) }
    }

    func dispose() { lifetime.dispose(); messageRead.dispose() }
    deinit { lifetime.dispose(); messageRead.dispose() }
}
