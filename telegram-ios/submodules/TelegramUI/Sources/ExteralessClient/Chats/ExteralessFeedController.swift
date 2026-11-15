import AccountContext
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import SwiftSignalKit
import TelegramCore
import UIKit

/// The original four FeedConfig fields remain registered once, in ChatFeatures.
enum ExteralessFeedSettings {
    static let fields = FeedSettingsStore.keys
    private static let store = FeedSettingsStore(settings: ClientSettings.shared)

    static func read(account: String) -> ChatFeedConfiguration {
        self.store.read(account: account)
    }

    static func write(_ config: ChatFeedConfiguration, account: String, expected: ClientSettingsSnapshot) throws {
        try self.store.write(config, account: account, expected: expected)
    }
}

final class ExteralessFeedChannelsController: ExteralessChatTableController, UISearchBarDelegate {
    private let accountKey: String
    private let registry: ExteralessFeedChannelRegistry
    private let foreground = MetaDisposable()
    private var state = ExteralessFeedChannelRegistry.State()
    private let search = UISearchBar()
    private var query = ""

    init(context: AccountContext, channels: [ExteralessFeedChannel]) {
        self.accountKey = String(context.account.id.int64)
        self.registry = ExteralessFeedChannelRegistry(engine: context.engine)
        self.state.channels = channels
        super.init(context: context, title: "Feed channels")
        self.refreshAction = { [weak self] in self?.registry.refresh() }
        self.accountInvalidated = { [weak self] in self?.registry.stop(); self?.foreground.set(nil) }
        self.registry.updated = { [weak self] state in
            guard let self, self.accountIsValid else { return }
            self.state = state
            if !state.isLoading { self.tableView.refreshControl?.endRefreshing() }
            self.render()
        }
        self.search.placeholder = "Search channels"
        self.search.delegate = self
        self.render()
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.foreground.dispose() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.foreground.set((self.context.sharedContext.applicationBindings.applicationInForeground |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self, self.accountIsValid, self.screenIsVisible else { return }
            if active { self.registry.start() } else { self.registry.stop() }
        }))
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.registry.stop()
        self.foreground.set(nil)
        super.viewWillDisappear(animated)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.search.frame = CGRect(x: 0, y: 0, width: self.tableView.bounds.width, height: 56)
        self.tableView.tableHeaderView = self.search
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.query = String(searchText.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
        self.render()
    }

    private func change(_ update: (inout ChatFeedConfiguration) -> Void) {
        guard self.accountIsValid else { return }
        let before = ClientSettings.shared.readSnapshot()
        var config = FeedSettingsStore.configuration(account: self.accountKey, snapshot: before)
        update(&config)
        let value = config
        let accountKey = self.accountKey
        self.writeSettings({ try ExteralessFeedSettings.write(value, account: accountKey, expected: before) }, completion: { [weak self] in self?.render() })
    }

    private func render() {
        guard self.accountIsValid else { return }
        let config = ExteralessFeedSettings.read(account: self.accountKey)
        let ids = Set(self.state.channels.map(\.id))
        self.sections = [ExteralessChatSection(rows: [
            ExteralessChatRow(id: "feed.includeArchived", title: "Include archived channels", checked: config.includeArchived, action: { [weak self] in self?.change { $0.includeArchived.toggle() } }),
            ExteralessChatRow(id: "feed.addNewChannels", title: "Add newly joined channels", detail: self.state.isComplete ? nil : "Finish loading the channel list before taking a membership snapshot.", checked: config.addNewChannels, enabled: self.state.isComplete, action: { [weak self] in self?.change { $0.setAddNewChannels(!$0.addNewChannels, currentChannels: ids) } }),
            ExteralessChatRow(id: "feed.includeAll", title: "Include all channels", enabled: self.state.isComplete, action: { [weak self] in self?.change { $0.includeAll(ids) } }),
            ExteralessChatRow(id: "feed.excludeAll", title: "Exclude all channels", enabled: self.state.isComplete, action: { [weak self] in self?.change { config in for id in ids { config.setIncluded(id, included: false) } } })
        ])]
        if !self.state.isComplete || self.state.needsRetry {
            self.sections.append(ExteralessChatSection(rows: [ExteralessChatRow(id: "feed.channelPages", title: self.state.isLoading ? "Loading all channel pages…" : "Channel list is partial · Retry", detail: "\(ids.count) channels found. Gaps and timeouts are retryable; this is not the end of the list.", action: self.state.isLoading ? nil : { [weak self] in self?.registry.refresh() })]))
        }
        var shown: [ExteralessChatRow] = []
        var hidden: [ExteralessChatRow] = []
        let sorted = self.state.channels.sorted { lhs, rhs in
            let comparison = lhs.peer.debugDisplayTitle.localizedStandardCompare(rhs.peer.debugDisplayTitle)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        for channel in sorted {
            let title = channel.peer.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            guard self.query.isEmpty || title.localizedCaseInsensitiveContains(self.query) else { continue }
            let included = !config.excludedChannels.contains(channel.id) && (config.addNewChannels || config.knownChannels.contains(channel.id))
            let row = ExteralessChatRow(id: "feed.channel.\(channel.id)", title: title, detail: channel.archived ? "Archived" : nil, checked: included, action: { [weak self] in self?.change { $0.setIncluded(channel.id, included: !included) } })
            if included { shown.append(row) } else { hidden.append(row) }
        }
        if !shown.isEmpty { self.sections.append(ExteralessChatSection(title: "Included", rows: shown)) }
        if !hidden.isEmpty { self.sections.append(ExteralessChatSection(title: "Excluded", rows: hidden)) }
        self.reloadRows()
    }
}
