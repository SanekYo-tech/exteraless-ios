import AccountContext
import ChatControllerInteraction
import ChatHistoryEntry
import ChatMessageItem
import ChatMessageItemImpl
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit
import WallpaperBackgroundNode

final class ExteralessFeedController: ExteralessChatTableController {
    let feedTimeline: ExteralessFeedTimeline
    let feedReads: ExteralessFeedReadState
    let feedRegistry: ExteralessFeedChannelRegistry
    let feedWallpaper: WallpaperBackgroundNode
    let feedAction = MetaDisposable()
    let feedHiddenMedia = MetaDisposable()
    let feedGalleryPolicy = MetaDisposable()
    var feedExportPermit: ExteralessContentExportPermit?
    var feedExportScopeGeneration: UInt64?
    weak var feedActiveGallery: ViewController?
    var feedExportGeneration: UInt64 = 0
    lazy var feedFreshActions = ExteralessFeedFreshActions(fetch: { [unowned self] ids in exteralessFeedFreshMessages(engine: self.context.engine, ids: ids) })
    var feedHiddenMediaValues: [EngineMessage.Id: [EngineRawMedia]] = [:]
    var feedMediaGeneration: UInt64 = 0
    var feedPollRequests: [EngineMessage.Id: MetaDisposable] = [:]
    var feedPollActionState = ChatInterfacePollActionState()
    var feedSelectedIds = Set<EngineMessage.Id>()
    var feedUndoExclusion: EnginePeer.Id?
    var feedRenderRevision: UInt64 = 0
    private(set) var feedChannels = ExteralessFeedChannelRegistry.State()
    private(set) var feedConfiguration: ChatFeedConfiguration
    let feedAccountKey: String
    private var foreground = false
    private var applicationActive = false
    private var fullyVisible = false
    private var positioned = false
    private var menuVisible = false
    private var rendering = false
    private var heightUpdateQueued = false
    private var postRows: [String: ExteralessFeedPost] = [:]
    private var settingsObservation: ClientSettingsObservation?
    private let foregroundDisposable = MetaDisposable()
    private let reactionsDisposable = MetaDisposable()
    private let networkDisposable = MetaDisposable()
    private let accountPeerDisposable = MetaDisposable()
    private var networkType: MediaAutoDownloadNetworkType = .cellular
    private var availableReactions: AvailableReactions?
    private var accountPeer: EnginePeer?
    private var renderWork: DispatchWorkItem?
    private var renderGate = ChatFeedRefreshGate()
    private var reactionWork: DispatchWorkItem?
    private var reactionTimer: SwiftSignalKit.Timer?
    private var lastReactionRefresh: [EngineMessage.Id: TimeInterval] = [:]
    private var pillHeader: ExteralessPillHeaderView?
    private weak var occlusionWindow: UIWindow?
    private var occlusionSubscription: UUID?
    private var occlusionRects: [CGRect] = []
    private var baseContentInsets: UIEdgeInsets?
    private var keyboardRect: CGRect?
    private var applyingOcclusionInsets = false
    private lazy var headerLifecycle = ExteralessFeedHeaderLifecycle<ExteralessPillHeaderView>(make: { [unowned self] in
        let header = ExteralessPillHeaderView(context: self.context, open: { [weak self] controller in self?.pushChild(controller) })
        header.heightUpdated = { [weak self] in self?.updateHeaderHeight() }
        return header
    }, start: { $0.start() }, stop: { $0.stop() })
    private lazy var visibleMetadata = ExteralessFeedVisibleMetadata(makeLease: { [unowned self] in ExteralessFeedVisibleMetadataLease(engine: self.context.engine) })

    init(context: AccountContext) {
        self.feedAccountKey = String(context.account.id.int64)
        self.feedConfiguration = ExteralessFeedSettings.read(account: self.feedAccountKey)
        self.feedTimeline = ExteralessFeedTimeline(engine: context.engine)
        self.feedReads = ExteralessFeedReadState(context: context)
        self.feedRegistry = ExteralessFeedChannelRegistry(engine: context.engine)
        self.feedWallpaper = createWallpaperBackgroundNode(context: context, forChatDisplay: true)
        super.init(context: context, title: "Channel feed", tableStyle: ClientSettings.shared.bool("chats.wideFeedPosts") ? .plain : .insetGrouped)
        self.refreshAction = { [weak self] in self?.refreshFeed() }
        self.accountInvalidated = { [weak self] in self?.invalidateFeed() }
        self.feedTimeline.updated = { [weak self] in
            self?.feedRetireChangedExportScope()
            self?.scheduleRender()
            self?.updateVisiblePosts()
        }
        self.feedReads.updated = { [weak self] in self?.scheduleRender() }
        self.feedRegistry.updated = { [weak self] state in
            guard let self, self.accountIsValid else { return }
            self.feedChannels = state
            self.feedConfiguration = ExteralessFeedSettings.read(account: self.feedAccountKey)
            self.feedTimeline.configure(channels: state.channels, configuration: self.feedConfiguration)
            if self.foreground { self.feedReads.update(channels: state.channels, configuration: self.feedConfiguration) }
            self.updateVisiblePosts()
            self.scheduleRender()
        }
        self.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Channels", style: .plain, target: self, action: #selector(self.openChannels)),
            UIBarButtonItem(title: "Read all", style: .plain, target: self, action: #selector(self.markAllPressed))
        ]
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.foregroundDisposable.dispose()
        self.reactionsDisposable.dispose()
        self.networkDisposable.dispose()
        self.accountPeerDisposable.dispose()
        self.feedAction.dispose()
        self.feedHiddenMedia.dispose()
        self.feedGalleryPolicy.dispose()
        self.feedExportPermit?.revoke()
        if let subscription = self.occlusionSubscription {
            Task { @MainActor in ExteralessContentOcclusions.shared.unsubscribe(subscription) }
        }
        for request in self.feedPollRequests.values { request.dispose() }
        self.renderWork?.cancel()
        self.reactionWork?.cancel()
        self.reactionTimer?.invalidate()
        self.settingsObservation?.cancel()
    }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.tableView.register(ExteralessFeedMessageCell.self, forCellReuseIdentifier: "feed.nativePost")
        self.tableView.separatorStyle = .none
        self.tableView.estimatedRowHeight = 240
        self.tableView.backgroundView = self.feedWallpaper.view
        self.feedWallpaper.update(wallpaper: self.presentationData.chatWallpaper, animated: false)
    }

    override func reloadRows() {
        self.feedWallpaper.update(wallpaper: self.presentationData.chatWallpaper, animated: false)
        super.reloadRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard self.accountIsValid else { return }
        self.pillHeader = self.headerLifecycle.prepare()
        self.updateHeaderHeight()
        self.headerLifecycle.setVisible(self.foreground)
        self.feedConfiguration = ExteralessFeedSettings.read(account: self.feedAccountKey)
        self.settingsObservation?.cancel()
        self.settingsObservation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || !keys.isDisjoint(with: ExteralessFeedSettings.fields) || keys.contains("appearance.showFeedUnreadCounter") else { return }
            DispatchQueue.main.async {
                guard let self, self.accountIsValid, self.screenIsVisible else { return }
                self.feedConfiguration = ExteralessFeedSettings.read(account: self.feedAccountKey)
                self.feedTimeline.configure(channels: self.feedChannels.channels, configuration: self.feedConfiguration)
                if self.foreground { self.feedReads.update(channels: self.feedChannels.channels, configuration: self.feedConfiguration) }
                self.scheduleRender()
            }
        }
        self.foregroundDisposable.set((combineLatest(self.context.sharedContext.applicationBindings.applicationInForeground, self.context.sharedContext.applicationBindings.applicationIsActive) |> deliverOnMainQueue).start(next: { [weak self] foreground, active in
            guard let self, self.accountIsValid, self.screenIsVisible else { return }
            self.applicationActive = active
            if self.foreground != foreground {
                self.foreground = foreground
                if foreground { self.startFeed() } else { self.pauseFeed() }
            }
            self.updateVisiblePosts()
        }))
        self.headerLifecycle.setVisible(self.foreground)
        self.render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.fullyVisible = true
        self.reconcileOcclusionSubscription()
        self.updateVisiblePosts()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.fullyVisible = false
        self.foreground = false
        self.pauseFeed()
        self.foregroundDisposable.set(nil)
        self.settingsObservation?.cancel()
        self.settingsObservation = nil
        super.viewWillDisappear(animated)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.baseContentInsets = self.tableView.contentInset
        if let height = layout.inputHeight, height > 0 {
            self.keyboardRect = CGRect(x: 0, y: max(0, layout.size.height - height), width: layout.size.width, height: height)
        } else {
            self.keyboardRect = nil
        }
        self.reconcileOcclusionSubscription()
        self.applyOcclusionInsets()
        self.feedWallpaper.updateLayout(size: self.tableView.bounds.size, displayMode: .aspectFill, transition: transition)
        self.updateHeaderHeight()
        self.scheduleRender()
    }

    private func updateHeaderHeight() {
        guard let header = self.pillHeader else { return }
        header.frame = CGRect(x: 0, y: 0, width: self.tableView.bounds.width, height: header.preferredHeight)
        self.tableView.tableHeaderView = header
    }

    private func startFeed() {
        self.reconcileOcclusionSubscription()
        self.feedTimeline.configure(channels: self.feedChannels.channels, configuration: self.feedConfiguration)
        self.feedTimeline.start()
        self.feedRegistry.start()
        self.feedReads.update(channels: self.feedChannels.channels, configuration: self.feedConfiguration)
        self.headerLifecycle.setVisible(true)
        self.reactionsDisposable.set((self.context.engine.stickers.availableReactions() |> deliverOnMainQueue).start(next: { [weak self] value in
            self?.availableReactions = value
            self?.feedRenderRevision &+= 1
            self?.scheduleRender()
        }))
        self.networkDisposable.set((self.context.account.networkType |> deliverOnMainQueue).start(next: { [weak self] value in
            self?.networkType = MediaAutoDownloadNetworkType(value)
            self?.feedRenderRevision &+= 1
            self?.scheduleRender()
        }))
        self.accountPeerDisposable.set((self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
            self?.accountPeer = peer
            self?.feedRenderRevision &+= 1
            self?.scheduleRender()
        }))
        self.reactionTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 20, repeat: true, completion: { [weak self] in self?.scheduleReactionRefresh() }, queue: .mainQueue())
        self.reactionTimer = timer
        timer.start()
    }

    private func pauseFeed() {
        self.feedExportGeneration &+= 1
        self.feedFreshActions.cancel()
        self.visibleMetadata.stop()
        self.clearOcclusionSubscription()
        self.feedTimeline.stop()
        self.feedRegistry.stop()
        self.feedReads.pause()
        self.headerLifecycle.setVisible(false)
        self.reactionsDisposable.set(nil)
        self.networkDisposable.set(nil)
        self.accountPeerDisposable.set(nil)
        self.renderWork?.cancel()
        self.renderWork = nil
        self.renderGate.cancel()
        self.reactionWork?.cancel()
        self.reactionWork = nil
        self.reactionTimer?.invalidate()
        self.reactionTimer = nil
        for cell in self.tableView.visibleCells { (cell as? ExteralessFeedMessageCell)?.clearVisibility() }
        self.tableView.refreshControl?.endRefreshing()
    }

    private func invalidateFeed() {
        self.pauseFeed()
        self.feedRetireExportFlow()
        self.feedTimeline.clear()
        self.feedReads.invalidate()
        self.feedFreshActions.invalidate()
        self.feedAction.set(nil)
        self.feedHiddenMedia.set(nil)
        self.feedHiddenMediaValues.removeAll()
        for request in self.feedPollRequests.values { request.dispose() }
        self.feedPollRequests.removeAll()
        self.feedSelectedIds.removeAll()
        self.postRows.removeAll()
        self.lastReactionRefresh.removeAll()
        self.settingsObservation?.cancel()
        self.settingsObservation = nil
        self.foregroundDisposable.set(nil)
    }

    private func refreshFeed() {
        guard self.foreground, self.accountIsValid else { return }
        self.positioned = false
        self.feedRegistry.refresh()
        self.feedTimeline.refresh()
        self.tableView.setContentOffset(CGPoint(x: 0, y: -self.tableView.contentInset.top), animated: false)
        self.scheduleRender()
    }

    @objc private func openChannels() {
        guard self.accountIsValid else { return }
        self.pushChild(ExteralessFeedChannelsController(context: self.context, channels: self.feedChannels.channels))
    }

    @objc private func markAllPressed() {
        guard self.accountIsValid, self.feedChannels.isComplete, !self.feedChannels.isLoading, !self.feedReads.markingAll else { return }
        let alert = UIAlertController(title: "Mark feed as read?", message: "Marks the included channels in this account as read. Your Privacy read-receipt policy still applies.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Mark as read", style: .default, handler: { [weak self] _ in
            guard let self, self.accountIsValid else { return }
            self.feedReads.markAllRead(completion: { [weak self] in self?.scheduleRender() })
        }))
        self.present(alert, animated: true)
    }

    func scheduleRender() {
        guard self.accountIsValid, self.screenIsVisible else { return }
        self.renderGate.request(now: ProcessInfo.processInfo.systemUptime)
        guard self.renderWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.accountIsValid, self.screenIsVisible else { return }
            self.renderWork = nil
            guard self.renderGate.consume(now: ProcessInfo.processInfo.systemUptime) else { self.scheduleRender(); return }
            self.render()
        }
        self.renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private struct Anchor {
        let id: String
        let offset: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        guard self.positioned, let index = self.tableView.indexPathsForVisibleRows?.first,
              self.sections.indices.contains(index.section), self.sections[index.section].rows.indices.contains(index.row) else { return nil }
        return Anchor(id: self.sections[index.section].rows[index.row].id, offset: self.tableView.rectForRow(at: index).minY - self.tableView.contentOffset.y)
    }

    private func indexPath(for id: String) -> IndexPath? {
        for (section, value) in self.sections.enumerated() {
            if let row = value.rows.firstIndex(where: { $0.id == id }) { return IndexPath(row: row, section: section) }
        }
        return nil
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let index = self.indexPath(for: anchor.id) else { return }
        let y = self.tableView.rectForRow(at: index).minY - anchor.offset
        let minY = -self.tableView.contentInset.top
        let maxY = max(minY, self.tableView.contentSize.height - self.tableView.bounds.height + self.tableView.contentInset.bottom)
        self.tableView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
    }

    private static func rowId(_ post: ExteralessFeedPost) -> String {
        switch post.id {
        case let .message(id): return "feed.post.\(id.peerId).\(id.namespace).\(id.messageId)"
        case let .album(peer, namespace, group): return "feed.album.\(peer).\(namespace).\(group)"
        }
    }

    private func render() {
        guard self.accountIsValid else { return }
        self.rendering = true
        let anchor = self.captureAnchor()
        let posts = self.feedTimeline.posts
        self.feedSelectedIds.formIntersection(Set(self.feedTimeline.messages.values.map(\.id)))
        self.lastReactionRefresh = self.lastReactionRefresh.filter { self.feedTimeline.messages[ExteralessFeedTimeline.identity($0.key)] != nil }
        let unread = self.feedReads.tracker.unreadCount
        let badgeEnabled = ClientSettings.shared.bool("appearance.showFeedUnreadCounter", default: true)
        self.title = badgeEnabled && unread > 0 ? "Channel feed · \(unread)" : "Channel feed"
        self.tabBarItem.title = "Feed"
        let partial = !self.feedChannels.isComplete
        self.tabBarItem.badgeValue = badgeEnabled ? (unread > 0 ? String(unread) + (partial ? "+" : "") : (partial ? "…" : nil)) : nil
        self.navigationItem.rightBarButtonItems?.last?.isEnabled = self.feedChannels.isComplete && !self.feedChannels.isLoading && !self.feedReads.markingAll
        var sections: [ExteralessChatSection] = []
        if self.feedTimeline.hasNewPosts {
            sections.append(.init(rows: [.init(id: "feed.new", title: "New posts · Return to newest", detail: self.feedTimeline.hasNewerGap ? "The newer history has a gap larger than one page. Refresh to load a complete top window." : "The current reading position is retained until you refresh.", action: { [weak self] in self?.refreshFeed() })]))
        }
        if !self.feedChannels.isComplete {
            sections.append(.init(rows: [.init(id: "feed.channelPages", title: self.feedChannels.isLoading ? "Loading all channel pages…" : "Channel list is partial · Retry", detail: "\(self.feedChannels.channels.count) channels found. The timeline remains partial until all pages are available.", action: self.feedChannels.isLoading ? nil : { [weak self] in self?.feedRegistry.refresh() })]))
        }
        if self.feedTimeline.hasFrontierGap, !posts.isEmpty {
            sections.append(.init(rows: [.init(id: "feed.gap", title: "Waiting for a channel history gap", detail: "Previously loaded posts are retained. Their order is partial until the missing source loads.", enabled: false)]))
        }
        if !self.feedTimeline.failedChannels.isEmpty {
            sections.append(.init(rows: [.init(id: "feed.retry", title: "Retry \(self.feedTimeline.failedChannels.count) unavailable channels", detail: "Loaded posts and cursors are retained. A timeout is not the beginning of history.", action: { [weak self] in self?.feedTimeline.retry() })]))
        }
        if self.feedTimeline.hasUnavailableContent {
            sections.append(.init(rows: [.init(id: "feed.contentUnavailable", title: "Post information unavailable · Refresh", detail: "Current peer or reply information is incomplete. This is not the end of history.", action: { [weak self] in self?.refreshFeed() })]))
        } else if self.feedTimeline.isProjecting {
            sections.append(.init(rows: [.init(id: "feed.projecting", title: "Updating post information…", enabled: false)]))
        }
        if self.feedTimeline.pendingCount > 0 {
            sections.append(.init(rows: [.init(id: "feed.loading", title: "Loading posts · \(self.feedTimeline.loadedChannelCount)/\(self.feedTimeline.channelCount) channels", detail: "Tap to cancel", action: { [weak self] in self?.feedTimeline.cancelRound(markFailed: true) })]))
        } else if !self.feedChannels.isLoading {
            self.tableView.refreshControl?.endRefreshing()
        }
        if !self.feedSelectedIds.isEmpty {
            sections.append(.init(rows: [
                .init(id: "feed.shareSelection", title: "Share \(self.feedSelectedIds.count) selected messages", action: { [weak self] in guard let self else { return }; self.feedShare(Array(self.feedSelectedIds)) }),
                .init(id: "feed.clearSelection", title: "Clear selection", action: { [weak self] in self?.feedSelectedIds.removeAll(); self?.scheduleRender() })
            ]))
        }
        if let peerId = self.feedUndoExclusion {
            sections.append(.init(rows: [.init(id: "feed.undoExclude", title: "Channel excluded · Undo", action: { [weak self] in self?.feedSetIncluded(peerId, included: true) })]))
        }
        let boundary = FeedPresentationPolicy.unreadBoundary(posts: posts.map(\.entries), isUnread: { self.feedReads.tracker.isUnread($0) })
        self.postRows.removeAll(keepingCapacity: true)
        var rows: [ExteralessChatRow] = []
        for (index, post) in posts.enumerated() {
            let id = Self.rowId(post)
            self.postRows[id] = post
            rows.append(.init(id: id, title: ""))
            if boundary == index + 1 {
                rows.append(.init(id: "feed.unread", title: "Unread posts", detail: "\(unread) unread in included channels", enabled: false))
            }
        }
        if !rows.isEmpty { sections.append(.init(rows: rows)) }
        if self.feedTimeline.pendingCount == 0 && self.feedTimeline.failedChannels.isEmpty {
            if self.feedTimeline.hasMore {
                sections.append(.init(rows: [.init(id: "feed.more", title: self.feedTimeline.requestedCount >= 500 ? "Next window of older posts" : "Load older posts", action: { [weak self] in
                    guard let self else { return }
                    if self.feedTimeline.requestedCount >= 500 {
                        self.positioned = false
                        self.tableView.setContentOffset(CGPoint(x: 0, y: -self.tableView.contentInset.top), animated: false)
                    }
                    self.feedTimeline.loadMore()
                })]))
            } else if self.feedTimeline.reachedEnd, self.feedChannels.isComplete, !self.feedChannels.isLoading {
                sections.append(.init(rows: [.init(id: "feed.end", title: posts.isEmpty ? "No posts yet" : "Beginning of available history", enabled: false)]))
            } else if self.feedChannels.isComplete && self.feedTimeline.channelCount == 0 {
                sections.append(.init(rows: [.init(id: "feed.empty", title: "No channels selected", detail: "Choose joined channels or include the archive.", action: { [weak self] in self?.openChannels() })]))
            }
        }
        let oldIds = self.sections.flatMap { $0.rows.map(\.id) }
        let newRows = sections.flatMap(\.rows)
        let newIds = newRows.map(\.id)
        let wasSingleSection = self.sections.count == 1
        self.sections = [.init(rows: newRows)]
        self.feedWallpaper.update(wallpaper: self.presentationData.chatWallpaper, animated: false)
        if !wasSingleSection || !self.isNodeLoaded {
            self.reloadRows()
        } else if oldIds != newIds {
            // Retain native media nodes for unchanged IDs. reloadData on every read-counter
            // update would restart video/download/expanded-quote state while scrolling.
            let difference = newIds.difference(from: oldIds)
            let removed = difference.removals.compactMap { change -> IndexPath? in
                if case let .remove(offset, _, _) = change { return IndexPath(row: offset, section: 0) }
                return nil
            }
            let inserted = difference.insertions.compactMap { change -> IndexPath? in
                if case let .insert(offset, _, _) = change { return IndexPath(row: offset, section: 0) }
                return nil
            }
            UIView.performWithoutAnimation {
                self.tableView.performBatchUpdates({
                    self.tableView.deleteRows(at: removed, with: .none)
                    self.tableView.insertRows(at: inserted, with: .none)
                })
            }
        }
        for cell in self.tableView.visibleCells {
            guard let index = self.tableView.indexPath(for: cell), newRows.indices.contains(index.row) else { continue }
            let row = newRows[index.row]
            if let cell = cell as? ExteralessFeedMessageCell, let post = self.postRows[row.id] {
                self.configure(cell, post: post)
            } else {
                cell.textLabel?.text = row.title
                cell.detailTextLabel?.text = row.detail
            }
        }
        self.tableView.layoutIfNeeded()
        self.restore(anchor)
        if !self.positioned && !posts.isEmpty && !self.feedTimeline.hasFrontierGap {
            if !self.feedTimeline.browsingOlder, let index = self.indexPath(for: "feed.unread") {
                self.tableView.scrollToRow(at: index, at: .bottom, animated: false)
            }
        }
        self.rendering = false
        DispatchQueue.main.async { [weak self] in self?.settleInitialPosition(); self?.updateVisiblePosts() }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = self.sections[indexPath.section].rows[indexPath.row].id
        guard let post = self.postRows[id] else { return super.tableView(tableView, cellForRowAt: indexPath) }
        let cell = tableView.dequeueReusableCell(withIdentifier: "feed.nativePost", for: indexPath) as! ExteralessFeedMessageCell
        self.configure(cell, post: post)
        return cell
    }

    private func configure(_ cell: ExteralessFeedMessageCell, post: ExteralessFeedPost) {
        cell.heightUpdated = { [weak self] in self?.nativeHeightChanged() }
        cell.showChannelMenu = { [weak self] in self?.feedShowChannelMenu(post.channel.peer.id) }
        cell.channelMenu = { [weak self] in self?.feedChannelMenu(post.channel.peer.id) ?? UIMenu(children: []) }
        cell.showPostMenu = { [weak self] in self?.feedShowPostMenu(post.primaryId) }
        cell.menuVisibilityChanged = { [weak self] value in self?.menuVisible = value; self?.updateVisiblePosts() }
        let selection: Bool? = self.feedSelectedIds.isEmpty ? nil : post.messages.allSatisfy { self.feedSelectedIds.contains($0.id) }
        let width = cell.contentView.bounds.width > 1 ? cell.contentView.bounds.width : self.tableView.bounds.width - (self.tableView.style == .insetGrouped ? 40 : 0)
        cell.configure(context: self.context, post: post, presentation: self.presentationData, width: max(1, width), viewportHeight: self.viewport.height, selected: selection, revision: self.feedRenderRevision, makeItem: { self.makeItem(post) })
        cell.setHiddenMedia(self.feedHiddenMediaValues)
    }

    private func makeItem(_ post: ExteralessFeedPost, presentation: PresentationData? = nil) -> ChatMessageItemImpl {
        let presentation = presentation ?? self.presentationData
        let interaction = exteralessFeedMessageInteraction(owner: self, post: post)
        let attributes = ChatMessageEntryAttributes()
        let content: ChatMessageItemContent
        let values = post.messages.map { message -> (EngineRawMessage, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, EngineMessageHistoryEntryLocation?) in
            let selection: ChatHistoryMessageSelection = self.feedSelectedIds.isEmpty ? .none : .selectable(selected: self.feedSelectedIds.contains(message.id), num: nil)
            return (message._asMessage(), true, selection, attributes, nil)
        }
        if values.count == 1, let first = values.first { content = .message(message: first.0, read: first.1, selection: first.2, attributes: first.3, location: nil) }
        else { content = .group(messages: values) }
        return ChatMessageItemImpl(
            presentationData: ChatPresentationData(theme: ChatPresentationThemeData(theme: presentation.theme, wallpaper: presentation.chatWallpaper), fontSize: presentation.chatFontSize, strings: presentation.strings, dateTimeFormat: presentation.dateTimeFormat, nameDisplayOrder: presentation.nameDisplayOrder, disableAnimations: UIAccessibility.isReduceMotionEnabled, largeEmoji: false, chatBubbleCorners: presentation.chatBubbleCorners, animatedEmojiScale: 1.0, isPreview: false),
            context: self.context,
            chatLocation: .peer(id: post.channel.peer.id),
            associatedData: ChatMessageItemAssociatedData(automaticDownloadPeerType: .channel, automaticDownloadPeerId: post.channel.peer.id, automaticDownloadNetworkType: self.networkType, isCopyProtectionEnabled: post.projections.contains(where: \.isCopyProtected), availableReactions: self.availableReactions, availableMessageEffects: nil, savedMessageTags: nil, defaultReaction: nil, areStarReactionsEnabled: false, isPremium: self.accountPeer?.isPremium ?? false, accountPeer: self.accountPeer, forceInlineReactions: true, isInline: true, showSensitiveContent: self.context.currentContentSettings.with { $0.ignoreContentRestrictionReasons.contains("sensitive") }, isParticipant: true),
            controllerInteraction: interaction, content: content, disableDate: true
        )
    }

    #if DEBUG
    func feedMakeSmokeItem(_ post: ExteralessFeedPost) -> ChatMessageItemImpl {
        let presentation = self.context.sharedContext.currentPresentationData.with { $0 }
        self.feedWallpaper.update(wallpaper: presentation.chatWallpaper, animated: false)
        return self.makeItem(post, presentation: presentation)
    }
    #endif

    private func nativeHeightChanged() {
        guard !self.heightUpdateQueued else { return }
        self.heightUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightUpdateQueued = false
            guard self.accountIsValid, self.screenIsVisible, !self.rendering else { return }
            let anchor = self.captureAnchor()
            self.rendering = true
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
                self.tableView.layoutIfNeeded()
                self.restore(anchor)
            }
            self.rendering = false
            self.settleInitialPosition()
            self.updateVisiblePosts()
        }
    }

    private var viewport: CGRect {
        let insets = self.tableView.contentInset
        return CGRect(x: self.tableView.bounds.minX, y: self.tableView.bounds.minY + insets.top, width: self.tableView.bounds.width, height: max(0, self.tableView.bounds.height - insets.top - insets.bottom))
    }

    private var receiptsEnabled: Bool {
        self.accountIsValid && self.foreground && self.applicationActive && self.fullyVisible && self.positioned && !self.rendering && !self.heightUpdateQueued && !self.applyingOcclusionInsets && !self.menuVisible && self.presentedViewController == nil && self.presentationContext.controllers.isEmpty && self.viewIfLoaded?.window != nil
    }

    private func settleInitialPosition() {
        guard !self.positioned, !self.rendering, !self.heightUpdateQueued, !self.feedTimeline.hasFrontierGap, !self.feedTimeline.visible.isEmpty else { return }
        let cells = self.tableView.visibleCells.compactMap { $0 as? ExteralessFeedMessageCell }
        guard !cells.isEmpty, cells.allSatisfy(\.nativeReady) else { return }
        if !self.feedTimeline.browsingOlder, let index = self.indexPath(for: "feed.unread") {
            self.tableView.scrollToRow(at: index, at: .bottom, animated: false)
            self.tableView.layoutIfNeeded()
        }
        guard self.tableView.visibleCells.compactMap({ $0 as? ExteralessFeedMessageCell }).allSatisfy(\.nativeReady) else { return }
        self.positioned = true
    }

    private func updateVisiblePosts() {
        guard self.isNodeLoaded, !self.applyingOcclusionInsets, !self.rendering else { return }
        let viewport = self.viewport
        let occlusions = self.currentOcclusions().map(Self.geometry)
        var seen: [ChatFeedPosition] = []
        var metadata: [ExteralessFeedMessageProjection] = []
        let mediaActive = self.accountIsValid && self.foreground && self.applicationActive && self.fullyVisible && !self.rendering && !self.menuVisible && self.presentedViewController == nil && self.presentationContext.controllers.isEmpty
        for case let cell as ExteralessFeedMessageCell in self.tableView.visibleCells {
            let rect = cell.contentView.convert(viewport, from: self.tableView)
            let frame = cell.bubbleFrame(in: self.tableView)
            let hasVisibleContent = frame.map { FeedContentGeometry.visibleArea(post: Self.geometry($0), viewport: Self.geometry(viewport), occlusions: occlusions) > 0 } ?? false
            _ = cell.setVisibleRect(rect, active: hasVisibleContent && mediaActive)
            if hasVisibleContent, let post = cell.post {
                metadata.append(contentsOf: post.messages.compactMap { self.feedTimeline.projections[ExteralessFeedTimeline.identity($0.id)] })
            }
            if let frame, FeedContentGeometry.admitsReceipt(post: Self.geometry(frame), viewport: Self.geometry(viewport), onScreen: Self.geometry(self.tableView.bounds), occlusions: occlusions, active: self.receiptsEnabled, positioned: self.positioned), let post = cell.post {
                seen.append(contentsOf: post.entries.map(\.position))
            }
        }
        self.visibleMetadata.update(projections: metadata, active: mediaActive)
        if !seen.isEmpty { self.feedReads.seen(seen) }
        self.scheduleReactionRefresh()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { self.updateVisiblePosts() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { self.updateVisiblePosts() }
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) { (cell as? ExteralessFeedMessageCell)?.clearVisibility() }

    private func scheduleReactionRefresh() {
        guard self.receiptsEnabled, self.reactionWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reactionWork = nil
            guard self.receiptsEnabled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            var ids = Set<EngineMessage.Id>()
            for case let cell as ExteralessFeedMessageCell in self.tableView.visibleCells where cell.nativeReady {
                for message in cell.post?.messages ?? [] where now - (self.lastReactionRefresh[message.id] ?? -100) >= 20 { ids.insert(message.id) }
            }
            let peers = Set(ids.map(\.peerId).sorted().prefix(4))
            ids = Set(ids.filter { peers.contains($0.peerId) })
            for id in ids { self.lastReactionRefresh[id] = now }
            if !ids.isEmpty { exteralessFeedRefreshReactions(engine: self.context.engine, messageIds: ids) }
        }
        self.reactionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    var feedNavigationController: NavigationController? { self.navigationController as? NavigationController }

    func feedCurrentMessage(_ id: EngineMessage.Id) -> EngineMessage? {
        guard self.accountIsValid else { return nil }
        return self.feedTimeline.messages[ExteralessFeedTimeline.identity(id)]
    }

    func feedRelayout(_ id: EngineMessage.Id) {
        guard self.accountIsValid else { return }
        for case let cell as ExteralessFeedMessageCell in self.tableView.visibleCells where cell.post?.messages.contains(where: { $0.id == id }) == true { cell.relayout() }
    }

    func feedApplyConfiguration() {
        self.feedExportGeneration &+= 1
        self.feedConfiguration = ExteralessFeedSettings.read(account: self.feedAccountKey)
        self.feedTimeline.configure(channels: self.feedChannels.channels, configuration: self.feedConfiguration)
        if self.foreground { self.feedReads.update(channels: self.feedChannels.channels, configuration: self.feedConfiguration) }
        self.updateVisiblePosts()
        self.scheduleRender()
    }

    private static func geometry(_ rect: CGRect) -> FeedContentGeometry.Rect {
        FeedContentGeometry.Rect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    private func currentOcclusions() -> [CGRect] {
        var rects: [CGRect] = []
        if let window = self.occlusionWindow, self.viewIfLoaded?.window === window {
            rects = self.occlusionRects.map { self.tableView.convert($0, from: window) }
        }
        if let keyboard = self.keyboardRect { rects.append(self.tableView.convert(keyboard, from: self.view)) }
        return rects
    }

    private func reconcileOcclusionSubscription() {
        guard self.screenIsVisible, self.accountIsValid, let window = self.viewIfLoaded?.window else { return }
        guard self.occlusionWindow !== window || self.occlusionSubscription == nil else { return }
        self.clearOcclusionSubscription()
        self.occlusionWindow = window
        self.occlusionSubscription = ExteralessContentOcclusions.shared.subscribe(accountId: self.context.account.id.int64, window: window, updated: { [weak self, weak window] snapshot in
            guard let self, let window, self.accountIsValid, self.screenIsVisible, self.occlusionWindow === window, snapshot.accountId == self.context.account.id.int64 else { return }
            self.occlusionRects = snapshot.rects
            self.applyOcclusionInsets()
            self.updateVisiblePosts()
        })
    }

    private func clearOcclusionSubscription() {
        if let subscription = self.occlusionSubscription { ExteralessContentOcclusions.shared.unsubscribe(subscription) }
        self.occlusionSubscription = nil
        self.occlusionWindow = nil
        self.occlusionRects.removeAll()
        self.applyOcclusionInsets()
    }

    private func applyOcclusionInsets() {
        guard let base = self.baseContentInsets, self.isNodeLoaded, !self.applyingOcclusionInsets else { return }
        self.applyingOcclusionInsets = true
        defer { self.applyingOcclusionInsets = false }
        let viewport = CGRect(x: self.tableView.bounds.minX, y: self.tableView.bounds.minY + base.top, width: self.tableView.bounds.width, height: max(0, self.tableView.bounds.height - base.top - base.bottom))
        let extra = FeedContentGeometry.additionalInsets(viewport: Self.geometry(viewport), occlusions: self.currentOcclusions().map(Self.geometry))
        var insets = base
        insets.top += CGFloat(extra.top)
        insets.bottom += CGFloat(extra.bottom)
        guard insets != self.tableView.contentInset else { return }
        let old = self.tableView.contentInset
        let atTop = self.tableView.contentOffset.y <= -old.top + 1
        let atBottom = self.tableView.contentSize.height > self.tableView.bounds.height && self.tableView.contentOffset.y >= self.tableView.contentSize.height - self.tableView.bounds.height + old.bottom - 1
        self.tableView.contentInset = insets
        self.tableView.scrollIndicatorInsets = insets
        if atTop { self.tableView.setContentOffset(CGPoint(x: 0, y: -insets.top), animated: false) }
        else if atBottom { self.tableView.setContentOffset(CGPoint(x: 0, y: max(-insets.top, self.tableView.contentSize.height - self.tableView.bounds.height + insets.bottom)), animated: false) }
    }
}
