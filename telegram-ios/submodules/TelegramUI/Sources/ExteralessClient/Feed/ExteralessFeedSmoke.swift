#if DEBUG
import AccountContext
import ChatMessageItemImpl
import ExteralessCore
import Foundation
import SwiftUI
import TelegramCore
import UIKit

/// One UIKit fixture instance for the accountless harness bridge. The closures retain no new
/// permit and cannot renew the original 30-second lifetime. The renderer is the same private
/// controller used by ExteralessFeedSmoke's SwiftUI wrapper.
@MainActor
public func makeExteralessFeedSmoke(context: AccountContext, edited: Bool = false) -> (controller: UIViewController, setEdited: @MainActor (Bool) -> Void, dispose: @MainActor () -> Void)? {
    guard let fixture = ExteralessFeedOfflineFixture(engine: context.engine) else { return nil }
    guard let controller = ExteralessFeedSmokeController(accountContext: context, fixture: fixture, edited: edited) else { return nil }
    return (controller, { [weak controller] edited in controller?.update(edited: edited) }, { [weak controller] in controller?.invalidate() })
}

/// Prepared render smoke for a DEDICATED offline harness. Never offered in the account's
/// settings or app composition. The initializer refuses an ordinary logged-in account.
@MainActor
public struct ExteralessFeedSmoke: UIViewControllerRepresentable {
    public let context: AccountContext
    public let fixture: ExteralessFeedOfflineFixture
    public var edited: Bool

    public init?(context: AccountContext, edited: Bool = false) {
        guard let fixture = ExteralessFeedOfflineFixture(engine: context.engine) else { return nil }
        self.context = context
        self.fixture = fixture
        self.edited = edited
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        if let controller = ExteralessFeedSmokeController(accountContext: self.context, fixture: self.fixture, edited: self.edited) { return controller }
        return UIViewController()
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? ExteralessFeedSmokeController)?.update(edited: self.edited)
    }
}

private final class ExteralessFeedSmokeController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let fixture: ExteralessFeedOfflineFixture
    private let owner: ExteralessFeedController
    private let table = UITableView(frame: .zero, style: .plain)
    private var posts: [ExteralessFeedPost] = []
    private var png: Data
    private var revision: UInt64 = 0
    private var expiry: DispatchWorkItem?
    private var invalidated = false
    private var lastEdited: Bool?

    init?(accountContext: AccountContext, fixture: ExteralessFeedOfflineFixture, edited: Bool) {
        guard fixture.accepts(engine: accountContext.engine) else { return nil }
        self.context = accountContext
        self.fixture = fixture
        self.owner = ExteralessFeedController(context: accountContext)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        self.png = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).pngData { renderer in
            UIColor.systemTeal.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            UIColor.systemOrange.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        super.init(nibName: nil, bundle: nil)
        self.update(edited: edited)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.expiry?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.table.register(ExteralessFeedMessageCell.self, forCellReuseIdentifier: "fixture")
        self.table.dataSource = self
        self.table.delegate = self
        self.table.rowHeight = UITableView.automaticDimension
        self.table.estimatedRowHeight = 260
        self.table.separatorStyle = .none
        self.table.accessibilityIdentifier = "exteraless.feed.offlineSmoke"
        self.view.addSubview(self.table)
        guard !self.invalidated, self.fixture.accepts(engine: self.context.engine) else { self.invalidate(); return }
        let expiry = DispatchWorkItem { [weak self] in
            self?.invalidate()
        }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + self.fixture.remainingDuration, execute: expiry)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.table.frame = self.view.bounds
    }

    func update(edited: Bool) {
        guard !self.invalidated, self.fixture.accepts(engine: self.context.engine) else { self.invalidate(); return }
        guard self.lastEdited != edited else { self.updateVisibleCells(); return }
        self.lastEdited = edited
        let previousIds = self.posts.map(\.id)
        let messages = self.fixture.messages(png: self.png, edited: edited)
        let entries = messages.map { ChatFeedEntry(position: ExteralessFeedTimeline.position($0.index), groupId: $0.groupingKey, version: $0.stableVersion) }
        let byId = Dictionary(uniqueKeysWithValues: messages.map { (ExteralessFeedTimeline.identity($0.id), $0) })
        let ordered = ChatFeedPolicy.ordered(entries, allowedPeers: Set(entries.map { $0.identity.peerId }))
        self.posts = FeedPresentationPolicy.posts(ordered).compactMap { group in
            let messages = group.compactMap { byId[$0.identity] }.sorted { $0.id < $1.id }
            guard let first = messages.first, let peer = first.peers[first.id.peerId] else { return nil }
            let channel = ExteralessFeedChannel(peer: EnginePeer(peer), archived: false, topMessageIndex: first.index, topMessageVersion: first.stableVersion, readCounters: nil, isMuted: false)
            return ExteralessFeedPost(entries: group, messages: messages, channel: channel)
        }
        self.revision &+= 1
        if previousIds == self.posts.map(\.id), self.isViewLoaded {
            self.updateVisibleCells()
        } else { self.table.reloadData() }
    }

    private func updateVisibleCells() {
        guard self.isViewLoaded else { return }
        let presentation = self.context.sharedContext.currentPresentationData.with { $0 }
        self.table.backgroundColor = presentation.theme.list.plainBackgroundColor
        for case let cell as ExteralessFeedMessageCell in self.table.visibleCells {
            guard let index = self.table.indexPath(for: cell), self.posts.indices.contains(index.row) else { continue }
            self.configure(cell, post: self.posts[index.row])
        }
    }

    func invalidate() {
        guard !self.invalidated else { return }
        self.invalidated = true
        self.expiry?.cancel()
        self.posts.removeAll()
        self.owner.invalidateAccount()
        if self.isViewLoaded { self.table.reloadData() }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.posts.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard !self.invalidated, self.fixture.accepts(engine: self.context.engine) else { return UITableViewCell() }
        let post = self.posts[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "fixture", for: indexPath) as! ExteralessFeedMessageCell
        self.configure(cell, post: post)
        return cell
    }

    private func configure(_ cell: ExteralessFeedMessageCell, post: ExteralessFeedPost) {
        cell.isUserInteractionEnabled = false // Render smoke never dispatches Telegram actions.
        cell.heightUpdated = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalidated, self.fixture.accepts(engine: self.context.engine) else { return }
                self.table.beginUpdates()
                self.table.endUpdates()
            }
        }
        cell.configure(context: self.context, post: post, presentation: self.context.sharedContext.currentPresentationData.with { $0 }, width: self.table.bounds.width, viewportHeight: self.table.bounds.height, selected: nil, revision: self.revision, makeItem: { self.owner.feedMakeSmokeItem(post) })
    }
}
#endif
