import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

/// A bounded client of ordinary channel history. The native database is the only persistent
/// cache; the feed retains a display window plus bounded per-channel lookahead.
final class ExteralessFeedTimeline {
    private struct Source {
        var cursor: EngineMessage.Index?
        var complete = false
        var loaded = false
        var reload: FeedPresentationPolicy.Reload?
        var frontier: ChatFeedPosition? { self.reload?.highestDiscarded ?? self.cursor.map(ExteralessFeedTimeline.position) }
    }

    private let pageSource: (EnginePeer.Id, EngineMessage.Index?) -> Signal<ExteralessFeedHistoryPage, NoError>
    private let windowSource: (Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>
    private let clearProjection: () -> Void
    private var configuration = ChatFeedConfiguration()
    private var channels: [Int64: ExteralessFeedChannel] = [:]
    private var sources: [Int64: Source] = [:]
    private var entries: [ChatFeedIdentity: ChatFeedEntry] = [:]
    private(set) var messages: [ChatFeedIdentity: EngineMessage] = [:]
    private(set) var projections: [ChatFeedIdentity: ExteralessFeedMessageProjection] = [:]
    private var unavailableProjections = Set<ChatFeedIdentity>()
    private var windowUpperBound: ChatFeedPosition?
    private var consumedAlbumTails: [ChatFeedIdentity: ChatFeedPosition] = [:]
    private(set) var visible: [ChatFeedEntry] = []
    private(set) var failedChannels = Set<Int64>()
    private(set) var hasNewPosts = false
    private(set) var hasNewerGap = false
    private(set) var hasFrontierGap = false
    private(set) var requestedCount = 40
    private(set) var browsingOlder = false
    private(set) var scopeGeneration: UInt64 = 0
    private var enoughForPage = false
    private var active = false
    private var round = ChatFeedLoadRound()
    private var requests: [Int64: MetaDisposable] = [:]
    private var timeout: SwiftSignalKit.Timer?
    private var headsToRefresh = Set<Int64>()
    private var headRequests = Set<Int64>()
    private let window = MetaDisposable()
    private var observedIds = Set<EngineMessage.Id>()
    private var observationGeneration: UInt64 = 0
    private var refreshWork: DispatchWorkItem?
    private var refreshGate = ChatFeedRefreshGate()
    var updated: (() -> Void)?

    convenience init(engine: TelegramEngine) {
        let projection = ExteralessFeedProjectionSession(engine: engine)
        self.init(pageSource: { peer, before in exteralessFeedHistoryPage(engine: engine, peerId: peer, before: before, count: 20) }, projectionSource: { ids in projection.observe(ids: ids) }, clearProjection: { projection.clear() })
    }

    init(pageSource: @escaping (EnginePeer.Id, EngineMessage.Index?) -> Signal<ExteralessFeedHistoryPage, NoError>, projectionSource: @escaping (Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>, clearProjection: @escaping () -> Void = {}) {
        self.pageSource = pageSource
        self.windowSource = projectionSource
        self.clearProjection = clearProjection
    }

    deinit {
        for request in self.requests.values { request.dispose() }
        self.window.dispose()
        self.timeout?.invalidate()
        self.refreshWork?.cancel()
    }

    var pendingCount: Int { self.round.pending.count }
    var channelCount: Int { self.sources.count }
    var loadedChannelCount: Int { self.sources.values.filter(\.loaded).count }
    var isProjecting: Bool { self.entries.keys.contains { self.projections[$0] == nil } }
    var hasUnavailableContent: Bool { !self.unavailableProjections.isEmpty }
    var hasMore: Bool { self.sources.values.contains { !$0.complete || $0.reload != nil } || self.entries.count > self.visible.count }
    var reachedEnd: Bool { !self.sources.isEmpty && !self.hasMore && !self.isProjecting && self.round.pending.isEmpty && self.failedChannels.isEmpty && !self.hasFrontierGap && !self.hasNewerGap }

    var posts: [ExteralessFeedPost] {
        return FeedPresentationPolicy.posts(self.visible).compactMap { entries in
            guard let first = entries.first, let channel = self.channels[first.identity.peerId] else { return nil }
            let projections = entries.compactMap { self.projections[$0.identity] }.sorted { $0.message.id < $1.message.id }
            guard projections.count == entries.count, let peer = projections.first?.peer else { return nil }
            let currentChannel = ExteralessFeedChannel(peer: peer, archived: projections.first?.isArchived ?? channel.archived, topMessageIndex: channel.topMessageIndex, topMessageVersion: channel.topMessageVersion, readCounters: channel.readCounters, isMuted: channel.isMuted)
            return ExteralessFeedPost(entries: entries, projections: projections, channel: currentChannel)
        }
    }

    static func identity(_ id: EngineMessage.Id) -> ChatFeedIdentity {
        ChatFeedIdentity(peerId: id.peerId.toInt64(), namespace: id.namespace, messageId: id.id)
    }

    static func position(_ index: EngineMessage.Index) -> ChatFeedPosition {
        ChatFeedPosition(timestamp: index.timestamp, identity: self.identity(index.id), orderingPeerId: -index.id.peerId.id._internalGetInt64Value())
    }

    func start() {
        guard !self.active else { return }
        self.active = true
        self.observeWindow()
        if !self.browsingOlder { self.headsToRefresh.formUnion(self.sources.filter { $0.value.loaded }.map(\.key)) }
        self.loadNextRound()
    }

    func stop() {
        self.active = false
        self.cancelRound(markFailed: false)
        self.observationGeneration &+= 1
        self.window.set(nil)
        self.observedIds.removeAll()
        self.refreshWork?.cancel()
        self.refreshWork = nil
        self.refreshGate.cancel()
    }

    func clear() {
        self.stop()
        self.clearProjection()
        self.channels.removeAll()
        self.sources.removeAll()
        self.entries.removeAll()
        self.messages.removeAll()
        self.projections.removeAll()
        self.unavailableProjections.removeAll()
        self.consumedAlbumTails.removeAll()
        self.visible.removeAll()
    }

    func configure(channels: [ExteralessFeedChannel], configuration: ChatFeedConfiguration) {
        let configurationChanged = self.configuration != configuration
        self.configuration = configuration
        let included = channels.filter { configuration.includes($0.id, archived: $0.archived) }
        let next = Dictionary(uniqueKeysWithValues: included.map { ($0.id, $0) })
        let membershipChanged = Set(next.keys) != Set(self.channels.keys)
        if configurationChanged || membershipChanged { self.scopeGeneration &+= 1 }
        for (id, channel) in next {
            if let previous = self.channels[id], previous.topMessageId != channel.topMessageId || previous.topMessageVersion != channel.topMessageVersion {
                if self.sources[id]?.loaded == true {
                    if self.browsingOlder { self.hasNewPosts = true }
                    else { self.headsToRefresh.insert(id) }
                }
            }
        }
        if membershipChanged { self.cancelRound(markFailed: false) }
        self.channels = next
        self.sources = self.sources.filter { next[$0.key] != nil }
        for id in next.keys where self.sources[id] == nil { self.sources[id] = Source() }
        self.entries = self.entries.filter { next[$0.key.peerId] != nil }
        self.messages = self.messages.filter { next[$0.key.peerId] != nil }
        self.projections = self.projections.filter { next[$0.key.peerId] != nil }
        self.unavailableProjections = self.unavailableProjections.filter { next[$0.peerId] != nil }
        self.visible = self.visible.filter { next[$0.identity.peerId] != nil }
        self.failedChannels.formIntersection(next.keys)
        self.headsToRefresh.formIntersection(next.keys)
        self.updateVisible()
        self.observeWindow()
        self.updated?()
        self.scheduleLoad()
    }

    func refresh() {
        self.scopeGeneration &+= 1
        self.cancelRound(markFailed: false)
        self.sources = Dictionary(uniqueKeysWithValues: self.channels.keys.map { ($0, Source()) })
        self.entries.removeAll()
        self.messages.removeAll()
        self.projections.removeAll()
        self.unavailableProjections.removeAll()
        self.windowUpperBound = nil
        self.consumedAlbumTails.removeAll()
        self.visible.removeAll()
        self.failedChannels.removeAll()
        self.headsToRefresh.removeAll()
        self.hasNewPosts = false
        self.hasNewerGap = false
        self.browsingOlder = false
        self.requestedCount = 40
        self.observeWindow()
        self.loadNextRound()
    }

    func loadMore() {
        guard self.active, self.round.pending.isEmpty else { return }
        if self.requestedCount >= 500, !self.visible.isEmpty {
            // A missing source has no proven bound for its unseen range. Finish that
            // frontier before consuming this window rather than guessing from another peer.
            guard self.sources.values.allSatisfy({ ($0.complete && $0.reload == nil) || $0.frontier != nil }) else {
                self.loadNextRound()
                return
            }
            self.scopeGeneration &+= 1
            let remaining = ChatFeedPolicy.remaining(after: self.visible, in: Array(self.entries.values))
            // Includes ordinary incomplete histories, not only evicted pages. Their next
            // page can be much newer than a buffered post in a different channel (FU-01).
            let incompleteFrontiers = self.sources.values.filter { !$0.complete || $0.reload != nil }.compactMap(\.frontier)
            let highestPending = (remaining.map(\.position) + incompleteFrontiers).max()
            let nextBound = highestPending ?? self.visible.map(\.position).min()
            if let nextBound {
                var tails = self.consumedAlbumTails.filter { $0.value <= nextBound }
                for entry in self.visible where entry.position <= nextBound { tails[entry.identity] = entry.position }
                // Native albums have small tails. Keep a hard metadata bound even for malformed
                // cross-window groups; retain the current window for an explicit refresh then.
                guard tails.count <= 500 else { self.hasNewPosts = true; self.hasNewerGap = true; self.updated?(); return }
                self.consumedAlbumTails = tails
                self.windowUpperBound = nextBound
            }
            for (peer, source) in self.sources {
                guard let reload = source.reload else { continue }
                let consumedBefore = self.visible.filter { $0.identity.peerId == peer && $0.position > reload.highestDiscarded }.map(\.position).min()
                let before = [reload.before, consumedBefore].compactMap { $0 }.min()
                self.sources[peer]?.reload = .init(highestDiscarded: reload.highestDiscarded, before: before)
            }
            self.entries = Dictionary(uniqueKeysWithValues: remaining.map { ($0.identity, $0) })
            self.messages = self.messages.filter { self.entries[$0.key] != nil }
            self.projections = self.projections.filter { self.entries[$0.key] != nil }
            self.unavailableProjections = self.unavailableProjections.filter { self.entries[$0] != nil }
            self.visible.removeAll()
            self.requestedCount = 40
            self.browsingOlder = true
            self.headsToRefresh.removeAll()
        } else {
            self.requestedCount = min(500, self.requestedCount + 40)
        }
        self.failedChannels.removeAll()
        self.loadNextRound()
    }

    func retry() { self.failedChannels.removeAll(); self.loadNextRound() }

    func cancelRound(markFailed: Bool) {
        if markFailed { self.failedChannels.formUnion(self.round.pending) }
        self.round.cancel()
        self.timeout?.invalidate()
        self.timeout = nil
        for request in self.requests.values { request.dispose() }
        self.requests.removeAll()
        self.headRequests.removeAll()
        if markFailed { self.updated?() }
    }

    private func updateVisible() {
        let bound = ChatFeedPolicy.safeLowerBound(self.sources.values.map { .init(oldestLoaded: $0.frontier, isComplete: $0.complete && $0.reload == nil) })
        self.hasFrontierGap = !bound.ready
        let available = Array(self.entries.values)
        let safe = bound.ready ? ChatFeedPolicy.ordered(available, allowedPeers: Set(self.sources.keys), lowerBound: bound.position, limit: self.requestedCount) : []
        self.enoughForPage = bound.ready && available.filter { bound.position == nil || $0.position >= bound.position! }.count >= self.requestedCount
        if bound.ready { self.visible = safe }
        // While an added source has no top page, keep already displayed posts with an explicit
        // gap state instead of replacing useful content with an empty/end screen.
        let retention = FeedPresentationPolicy.retention(entries: available)
        self.entries = self.entries.filter { retention.identities.contains($0.key) }
        self.messages = self.messages.filter { retention.identities.contains($0.key) }
        self.projections = self.projections.filter { retention.identities.contains($0.key) }
        self.unavailableProjections.formIntersection(retention.identities)
        for (id, reload) in retention.reloads {
            let previous = self.sources[id]?.reload
            let highest = max(previous?.highestDiscarded ?? reload.highestDiscarded, reload.highestDiscarded)
            let before = [previous?.before, reload.before].compactMap { $0 }.filter { $0 > highest }.min()
            self.sources[id]?.reload = .init(highestDiscarded: highest, before: before)
        }
    }

    private func scheduleLoad() {
        guard self.active else { return }
        self.refreshGate.request(now: ProcessInfo.processInfo.systemUptime)
        guard self.refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.refreshWork = nil
            guard self.refreshGate.consume(now: ProcessInfo.processInfo.systemUptime) else { self.scheduleLoad(); return }
            self.loadNextRound()
        }
        self.refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func loadNextRound() {
        guard self.active, self.round.pending.isEmpty, self.failedChannels.isEmpty else { return }
        self.updateVisible()
        let missing = self.sources.filter { !$0.value.loaded }.map(\.key).sorted()
        let candidates: [Int64]
        if !missing.isEmpty {
            candidates = missing
            self.headRequests.removeAll()
        } else if !self.headsToRefresh.isEmpty {
            candidates = self.headsToRefresh.sorted()
            self.headRequests = Set(candidates.prefix(4))
        } else if !self.enoughForPage {
            candidates = self.sources.filter { !$0.value.complete || $0.value.reload != nil }.sorted { lhs, rhs in
                guard let left = lhs.value.frontier else { return rhs.value.frontier != nil }
                guard let right = rhs.value.frontier else { return false }
                return left > right
            }.map(\.key)
            self.headRequests.removeAll()
        } else {
            self.observeWindow()
            self.updated?()
            return
        }
        let requests = self.round.begin(channels: Array(candidates.prefix(4)), now: ProcessInfo.processInfo.systemUptime)
        guard !requests.isEmpty else { self.observeWindow(); self.updated?(); return }
        let timer = SwiftSignalKit.Timer(timeout: 10, repeat: false, completion: { [weak self] in
            guard let self else { return }
            let failed = self.round.expire(now: ProcessInfo.processInfo.systemUptime)
            self.failedChannels.formUnion(failed)
            for id in failed { self.requests.removeValue(forKey: id)?.dispose() }
            self.observeWindow()
            self.updated?()
        }, queue: .mainQueue())
        self.timeout = timer
        timer.start()
        for request in requests {
            guard let channel = self.channels[request.channel] else { continue }
            let head = self.headRequests.contains(request.channel)
            let reload = self.sources[request.channel]?.reload
            let before = head ? nil : (reload != nil ? reload?.before.map(Self.index) : self.sources[request.channel]?.cursor)
            let disposable = MetaDisposable()
            self.requests[request.channel] = disposable
            disposable.set((self.pageSource(channel.peer.id, before) |> deliverOnMainQueue).start(next: { [weak self] page in
                guard let self, self.active, self.round.complete(request) else { return }
                self.requests.removeValue(forKey: request.channel)?.dispose()
                let crossesUnshownRange: Bool
                if !head, let upperBound = self.windowUpperBound {
                    crossesUnshownRange = page.messages.contains { Self.position($0.index) > upperBound }
                } else {
                    crossesUnshownRange = false
                }
                if crossesUnshownRange {
                    // Do not advance a real cursor across records rejected by a future-range
                    // bound. A changed/new source needs a fresh top window, never false end.
                    self.failedChannels.insert(request.channel)
                    self.hasNewPosts = true
                    self.hasNewerGap = true
                } else if !page.isAvailable || (!head && page.hasEarlier && (page.oldest == nil || page.oldest == before)) {
                    self.failedChannels.insert(request.channel)
                } else if head {
                    self.headsToRefresh.remove(request.channel)
                    let overlaps = page.messages.contains { self.messages[Self.identity($0.id)] != nil }
                    if overlaps || self.entries.keys.allSatisfy({ $0.peerId != request.channel }) || !page.hasEarlier {
                        self.merge(page.messages)
                    } else {
                        // A burst larger than a head page is a gap, not an unbroken incremental
                        // refresh. Keep the old window and explicitly offer a fresh top window.
                        self.hasNewPosts = true
                        self.hasNewerGap = true
                    }
                } else {
                    let pendingReload = self.sources[request.channel]?.reload
                    let stillMissing = pendingReload.flatMap { value in before.map { value.highestDiscarded >= Self.position($0) } == true ? value : nil }
                    self.sources[request.channel] = Source(cursor: page.oldest ?? before, complete: !page.hasEarlier, loaded: true, reload: stillMissing)
                    self.merge(page.messages)
                }
                self.updateVisible()
                self.observeWindow()
                self.updated?()
                if self.round.pending.isEmpty {
                    self.timeout?.invalidate()
                    self.timeout = nil
                    let generation = self.round.generation
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.active, self.round.generation == generation else { return }
                        self.loadNextRound()
                    }
                }
            }))
        }
        self.updated?()
    }

    private func merge(_ messages: [EngineMessage]) {
        for message in messages where self.channels[message.id.peerId.toInt64()] != nil && exteralessFeedMessageIsEligible(message) {
            let entry = ChatFeedEntry(position: Self.position(message.index), groupId: message.groupingKey, version: message.stableVersion)
            if let upperBound = self.windowUpperBound, entry.position > upperBound { continue }
            if self.consumedAlbumTails[entry.identity] != nil { continue }
            if let previous = self.entries[entry.identity], previous.version > entry.version { continue }
            self.entries[entry.identity] = entry
            self.messages[entry.identity] = message
        }
    }

    private func observeWindow() {
        guard self.active else { return }
        let ids = Set(self.messages.values.map(\.id))
        guard ids != self.observedIds else { return }
        self.observedIds = ids
        self.observationGeneration &+= 1
        let generation = self.observationGeneration
        guard !ids.isEmpty else { self.window.set(nil); self.clearProjection(); return }
        self.window.set((self.windowSource(ids) |> deliverOnMainQueue).start(next: { [weak self] projections in
            guard let self, self.active, self.observationGeneration == generation else { return }
            var changed = false
            for id in ids {
                let identity = Self.identity(id)
                guard self.entries[identity] != nil else { continue }
                if let projection = projections[id], projection.isEligible, self.configuration.includes(identity.peerId, archived: projection.isArchived) {
                    self.unavailableProjections.remove(identity)
                    if self.projections[identity]?.renderToken != projection.renderToken {
                        self.projections[identity] = projection
                        self.merge([projection.message])
                        changed = true
                    }
                } else {
                    self.projections.removeValue(forKey: identity)
                    if projections[id] != nil {
                        // Missing/restricted peer metadata is not deletion/end-of-history. Keep
                        // the bounded replay entry and keep observing so reversal can recover it.
                        self.unavailableProjections.insert(identity)
                    } else {
                        self.entries.removeValue(forKey: identity)
                        self.messages.removeValue(forKey: identity)
                        self.unavailableProjections.remove(identity)
                    }
                    changed = true
                }
            }
            if changed {
                self.visible.removeAll { self.entries[$0.identity] == nil }
                self.updateVisible()
                self.updated?()
                self.scheduleLoad()
            }
        }))
    }

    private static func index(_ position: ChatFeedPosition) -> EngineMessage.Index {
        EngineMessage.Index(id: EngineMessage.Id(peerId: EnginePeer.Id(position.identity.peerId), namespace: position.identity.namespace, id: position.identity.messageId), timestamp: position.timestamp)
    }
}
