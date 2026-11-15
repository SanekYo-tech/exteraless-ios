import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

/// Enumerates every native chat-list page, keeping only channel metadata. One page is in
/// flight at a time; a gap/stalled cursor stays explicitly partial and can be retried.
final class ExteralessFeedChannelRegistry {
    struct State {
        var channels: [ExteralessFeedChannel] = []
        var isComplete = false
        var isLoading = false
        var needsRetry = false
    }

    private let pageSource: (EngineChatList.Group, EngineChatList.Item.Index?) -> Signal<ExteralessFeedChannelPage, NoError>
    private let changeSource: Signal<Void, NoError>
    private let requestTimeout: TimeInterval
    private let changes = MetaDisposable()
    private let page = MetaDisposable()
    private var timeout: SwiftSignalKit.Timer?
    private var refreshWork: DispatchWorkItem?
    private var refreshGate = ChatFeedRefreshGate()
    private var generation: UInt64 = 0
    private var active = false
    private var refreshAfterScan = false
    private var scanned: [Int64: ExteralessFeedChannel] = [:]
    private var group: EngineChatList.Group = .root
    private var cursor: EngineChatList.Item.Index?
    private(set) var state = State()
    var updated: ((State) -> Void)?

    convenience init(engine: TelegramEngine) {
        self.init(pageSource: { group, before in exteralessFeedChannelPage(engine: engine, group: group, before: before) }, changes: exteralessFeedChannelChanges(engine: engine), requestTimeout: 10)
    }

    /// The native orchestration can be exercised with finite offline page signals, without
    /// constructing an Account or starting Telegram networking in a test process.
    init(pageSource: @escaping (EngineChatList.Group, EngineChatList.Item.Index?) -> Signal<ExteralessFeedChannelPage, NoError>, changes: Signal<Void, NoError>, requestTimeout: TimeInterval = 10) {
        self.pageSource = pageSource
        self.changeSource = changes
        self.requestTimeout = min(10, max(0.01, requestTimeout))
    }

    deinit {
        self.changes.dispose()
        self.page.dispose()
        self.timeout?.invalidate()
        self.refreshWork?.cancel()
    }

    func start() {
        guard !self.active else { return }
        self.active = true
        self.refresh()
        self.changes.set((self.changeSource |> deliverOnMainQueue).start(next: { [weak self] in
            self?.scheduleRefresh()
        }))
    }

    func stop() {
        self.active = false
        self.generation &+= 1
        self.changes.set(nil)
        self.page.set(nil)
        self.timeout?.invalidate()
        self.timeout = nil
        self.refreshWork?.cancel()
        self.refreshWork = nil
        self.refreshGate.cancel()
        self.refreshAfterScan = false
        self.state.isLoading = false
        self.scanned.removeAll()
    }

    func refresh() {
        guard self.active else { return }
        if self.state.isLoading { self.refreshAfterScan = true; return }
        self.generation &+= 1
        self.scanned.removeAll(keepingCapacity: true)
        self.group = .root
        self.cursor = nil
        self.state.isLoading = true
        self.state.needsRetry = false
        self.updated?(self.state)
        self.loadPage()
    }

    private func scheduleRefresh() {
        guard self.active else { return }
        self.refreshGate.request(now: ProcessInfo.processInfo.systemUptime)
        guard self.refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.refreshWork = nil
            guard self.refreshGate.consume(now: ProcessInfo.processInfo.systemUptime) else { self.scheduleRefresh(); return }
            self.refresh()
        }
        self.refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func loadPage() {
        guard self.active else { return }
        let generation = self.generation
        let cursor = self.cursor
        let group = self.group
        var accepted = false
        let timer = SwiftSignalKit.Timer(timeout: self.requestTimeout, repeat: false, completion: { [weak self] in
            guard let self, self.active, generation == self.generation, !accepted else { return }
            accepted = true
            self.finishPartial()
        }, queue: .mainQueue())
        self.timeout?.invalidate()
        self.timeout = timer
        timer.start()
        self.page.set((self.pageSource(group, cursor) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.active, generation == self.generation, !accepted else { return }
            for channel in result.channels { self.scanned[channel.id] = channel }
            if !self.state.isComplete {
                self.state.channels = self.scanned.values.sorted { $0.id < $1.id }
                self.updated?(self.state)
            }
            // Keep the native view subscribed while its hole fills. It may deliver several
            // loading snapshots; none of them advances the cursor or claims end-of-list.
            guard !result.hasGap else { return }
            accepted = true
            self.timeout?.invalidate()
            self.timeout = nil
            self.page.set(nil)
            let advanced = result.oldest.map { cursor == nil || $0 < cursor! } ?? false
            switch FeedPageProgress.evaluate(hasEarlier: result.hasEarlier, hasGap: false, advanced: advanced, succeeded: true) {
            case .retry:
                self.finishPartial()
            case .more:
                self.cursor = result.oldest
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.generation == generation else { return }
                    self.loadPage()
                }
            case .end:
                if group == .root {
                    self.group = .archive
                    self.cursor = nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.active, self.generation == generation else { return }
                        self.loadPage()
                    }
                } else {
                    self.state.channels = self.scanned.values.sorted { $0.id < $1.id }
                    self.scanned.removeAll(keepingCapacity: true)
                    self.state.isComplete = true
                    self.state.isLoading = false
                    self.state.needsRetry = false
                    self.updated?(self.state)
                    if self.refreshAfterScan { self.refreshAfterScan = false; self.scheduleRefresh() }
                }
            }
        }))
    }

    private func finishPartial() {
        self.generation &+= 1
        self.page.set(nil)
        self.timeout?.invalidate()
        self.timeout = nil
        var channels = Dictionary(uniqueKeysWithValues: self.state.channels.map { ($0.id, $0) })
        for (id, channel) in self.scanned { channels[id] = channel }
        self.state.channels = channels.values.sorted { $0.id < $1.id }
        self.scanned.removeAll(keepingCapacity: true)
        self.state.isComplete = false
        self.state.isLoading = false
        self.state.needsRetry = true
        self.refreshAfterScan = false
        self.updated?(self.state)
    }
}
