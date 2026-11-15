import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

/// All closures retain the engine that admitted the action. Account replacement invalidates
/// the UI lease; a transaction already submitted can finish only in its original account.
final class ExteralessFeedReadState {
    private let engine: TelegramEngine
    private let accountId: Int64
    private let counters = MetaDisposable()
    private let receipt = MetaDisposable()
    private let markAll = MetaDisposable()
    private var timer: SwiftSignalKit.Timer?
    private var peerIds = Set<EnginePeer.Id>()
    private var lastSnapshots: [FeedUnreadTracker.Snapshot] = []
    private var topMessageIds: [EnginePeer.Id: EngineMessage.Id] = [:]
    private var paused = true
    private var invalidated = false
    private var markGeneration: UInt64 = 0
    private var countersGeneration: UInt64 = 0
    private(set) var tracker: FeedUnreadTracker
    private(set) var markingAll = false
    var updated: (() -> Void)?

    init(context: AccountContext) {
        self.engine = context.engine
        self.accountId = context.account.id.int64
        self.tracker = FeedUnreadTracker(accountId: context.account.id.int64)
    }

    deinit {
        self.counters.dispose()
        self.receipt.dispose()
        self.markAll.dispose()
        self.timer?.invalidate()
    }

    func update(channels: [ExteralessFeedChannel], configuration: ChatFeedConfiguration) {
        guard !self.invalidated else { return }
        let included = channels.filter { configuration.includes($0.id, archived: $0.archived) }
        let ids = Set(included.map { $0.peer.id })
        self.topMessageIds = Dictionary(uniqueKeysWithValues: included.compactMap { channel in
            channel.topMessageId.map { (channel.peer.id, $0) }
        })
        let changed = ids != self.peerIds
        self.peerIds = ids
        if changed || self.lastSnapshots.isEmpty {
            self.lastSnapshots = included.compactMap { channel in
                channel.readCounters.map { exteralessFeedReadSnapshot(peerId: channel.peer.id, counters: $0, topMessageId: channel.topMessageId) }
            }
        }
        self.tracker.update(included: Set(ids.map { .init(id: $0.toInt64(), namespace: Namespaces.Message.Cloud) }), snapshots: self.lastSnapshots)
        if changed || self.paused {
            self.paused = false
            self.countersGeneration &+= 1
            let generation = self.countersGeneration
            self.counters.set((self.engine.data.subscribe(EngineDataMap(ids.sorted().map { TelegramEngine.EngineData.Item.Messages.PeerReadCounters(id: $0) })) |> deliverOnMainQueue).start(next: { [weak self] values in
                guard let self, !self.invalidated, self.peerIds == ids, self.countersGeneration == generation else { return }
                self.lastSnapshots = values.map { exteralessFeedReadSnapshot(peerId: $0.key, counters: $0.value, topMessageId: self.topMessageIds[$0.key]) }
                self.tracker.update(included: Set(ids.map { .init(id: $0.toInt64(), namespace: Namespaces.Message.Cloud) }), snapshots: self.lastSnapshots)
                self.updated?()
            }))
        }
        self.updated?()
    }

    func seen(_ positions: [ChatFeedPosition]) {
        guard !self.paused, !self.invalidated, !self.markingAll else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var changed = false
        for position in positions { changed = self.tracker.seen(position, now: now) || changed }
        if changed { self.updated?(); self.scheduleFlush() }
    }

    func pause() {
        self.paused = true
        self.countersGeneration &+= 1
        self.counters.set(nil)
        self.timer?.invalidate()
        self.timer = nil
        self.flush(force: true)
    }

    func invalidate() {
        self.invalidated = true
        self.paused = true
        self.markGeneration &+= 1
        self.countersGeneration &+= 1
        self.counters.set(nil)
        self.receipt.set(nil)
        self.markAll.set(nil)
        self.timer?.invalidate()
        self.timer = nil
        self.tracker.invalidate()
        self.topMessageIds.removeAll()
    }

    func markAllRead(completion: @escaping () -> Void) {
        guard !self.invalidated, !self.markingAll else { return }
        self.markingAll = true
        self.markGeneration &+= 1
        let generation = self.markGeneration
        let ids = self.peerIds.sorted()
        self.tracker.discardPending(for: Set(ids.map { .init(id: $0.toInt64(), namespace: Namespaces.Message.Cloud) }))
        self.markBatch(ids: ids, offset: 0, generation: generation, completion: completion)
        self.updated?()
    }

    private func markBatch(ids: [EnginePeer.Id], offset: Int, generation: UInt64, completion: @escaping () -> Void) {
        guard !self.invalidated, self.markGeneration == generation else { return }
        guard offset < ids.count else {
            self.markingAll = false
            self.updated?()
            completion()
            return
        }
        let engine = self.engine
        let batch = Array(ids.dropFirst(offset).prefix(32))
        // The same helper as the native chat-list Mark Read action. It updates local counters
        // and mentions, while the Privacy owner's existing synchronization gates decide packets.
        let signals: [Signal<Void, NoError>] = batch.map { peerId in
            engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> mapToSignal { peer in
                guard let peer, exteralessFeedChannelIsEligible(peer) else { return .single(()) }
                return Signal<Void, NoError> { subscriber in
                    return engine.messages.togglePeersUnreadMarkInteractively(peerIds: [peerId], setToValue: false).start(completed: {
                        subscriber.putNext(())
                        subscriber.putCompletion()
                    })
                }
            }
        }
        self.markAll.set((combineLatest(signals) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.markBatch(ids: ids, offset: offset + batch.count, generation: generation, completion: completion)
            }
        }))
    }

    private func scheduleFlush() {
        guard self.timer == nil, self.tracker.due != nil, !self.paused, !self.invalidated else { return }
        let timer = SwiftSignalKit.Timer(timeout: max(0.01, (self.tracker.due ?? 0) - ProcessInfo.processInfo.systemUptime), repeat: false, completion: { [weak self] in
            self?.timer = nil
            self?.flush(force: false)
        }, queue: .mainQueue())
        self.timer = timer
        timer.start()
    }

    private func flush(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !self.invalidated, let batch = self.tracker.takeBatch(now: now, force: force), batch.accountId == self.accountId else { return }
        let engine = self.engine
        let signals: [Signal<ChatFeedIdentity?, NoError>] = batch.positions.map { position in
            let id = EngineMessage.Id(peerId: EnginePeer.Id(position.identity.peerId), namespace: position.identity.namespace, id: position.identity.messageId)
            let index = EngineMessage.Index(id: id, timestamp: position.timestamp)
            return engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id.peerId)) |> mapToSignal { peer in
                guard let peer, exteralessFeedChannelIsEligible(peer) else { return .single(nil) }
                return engine.messages.applyMaxReadIndexInteractively(index: index) |> map { Optional(position.identity) }
            }
        }
        self.receipt.set((combineLatest(signals) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] applied in
            guard let self, !self.invalidated else { return }
            if self.tracker.complete(batch, applied: Set(applied.compactMap { $0 }), now: ProcessInfo.processInfo.systemUptime) {
                self.updated?()
                if self.paused {
                    // A departed/unavailable peer is retried only after the next membership
                    // snapshot; never spin a background loop on an unapplicable receipt.
                    if applied.allSatisfy({ $0 != nil }) {
                        DispatchQueue.main.async { [weak self] in self?.flush(force: true) }
                    }
                } else {
                    self.scheduleFlush()
                }
            }
        }))
    }
}
