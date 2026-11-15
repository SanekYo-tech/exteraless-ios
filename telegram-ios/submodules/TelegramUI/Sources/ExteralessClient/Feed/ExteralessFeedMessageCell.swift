import AccountContext
import AsyncDisplayKit
import AvatarNode
import ChatMessageItemImpl
import ChatMessageItemView
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import TelegramCore
import TelegramPresentationData
import UIKit

struct ExteralessFeedPost {
    let entries: [ChatFeedEntry]
    let messages: [EngineMessage]
    let channel: ExteralessFeedChannel
    let projections: [ExteralessFeedMessageProjection]
    var id: FeedPostIdentity { FeedPostIdentity(self.entries[0]) }
    var primaryId: EngineMessage.Id { self.messages[0].id }

    init(entries: [ChatFeedEntry], projections: [ExteralessFeedMessageProjection], channel: ExteralessFeedChannel) {
        self.entries = entries
        self.projections = projections
        self.messages = projections.map(\.message)
        self.channel = channel
    }

    /// Local render-only fixtures supply immutable peers, without an Account transaction.
    init(entries: [ChatFeedEntry], messages: [EngineMessage], channel: ExteralessFeedChannel) {
        self.init(entries: entries, projections: messages.map { ExteralessFeedMessageProjection(message: $0, peer: channel.peer, group: channel.archived ? .archive : .root) }, channel: channel)
    }
}

/// Hosts the same item/node used by native history, rather than a text/media summary.
/// UIKit owns the cell's frame. Every queued node/height/media apply has a composite lease.
final class ExteralessFeedMessageCell: UITableViewCell, UIContextMenuInteractionDelegate {
    private let avatar = AvatarNode(font: Font.regular(15.0))
    private let channelButton = UIButton(type: .system)
    private let dateLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let bubble = UIView()
    private var bubbleHeight: NSLayoutConstraint!
    private var itemNode: ListViewItemNode?
    private var item: ChatMessageItemImpl?
    private var lease = FeedRenderLease()
    private var messages: [EngineMessage] = []
    private var renderTokens: [UUID] = []
    private var theme: PresentationTheme?
    private var presentation: PresentationData?
    private var revision: UInt64 = 0
    private var hiddenMedia: [EngineMessage.Id: [EngineRawMedia]] = [:]
    private var width: CGFloat = 0
    private var renderedSelection: Bool?
    private var renderToken: FeedRenderLease.Token?
    private var layoutParams: ListViewItemLayoutParams?
    private var rendererKind: RendererKind?
    private var renderedPostId: FeedPostIdentity?
    private var renderedPrimaryId: EngineMessage.Id?
    private(set) var post: ExteralessFeedPost?
    private(set) var nativeReady = false
    var renderedNodeIdentity: ObjectIdentifier? { self.itemNode.map(ObjectIdentifier.init) }
    var heightUpdated: (() -> Void)?
    var showChannelMenu: (() -> Void)?
    var channelMenu: (() -> UIMenu)?
    var menuVisibilityChanged: ((Bool) -> Void)?
    var showPostMenu: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .none
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.contentView.addSubview(self.avatar.view)
        self.contentView.addSubview(self.channelButton)
        self.contentView.addSubview(self.dateLabel)
        self.contentView.addSubview(self.moreButton)
        self.contentView.addSubview(self.bubble)
        self.avatar.view.translatesAutoresizingMaskIntoConstraints = false
        self.channelButton.translatesAutoresizingMaskIntoConstraints = false
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = false
        self.moreButton.translatesAutoresizingMaskIntoConstraints = false
        self.bubble.translatesAutoresizingMaskIntoConstraints = false
        self.bubbleHeight = self.bubble.heightAnchor.constraint(equalToConstant: 180)
        NSLayoutConstraint.activate([
            self.avatar.view.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 12),
            self.avatar.view.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 10),
            self.avatar.view.widthAnchor.constraint(equalToConstant: 34),
            self.avatar.view.heightAnchor.constraint(equalToConstant: 34),
            self.channelButton.leadingAnchor.constraint(equalTo: self.avatar.view.trailingAnchor, constant: 10),
            self.channelButton.trailingAnchor.constraint(equalTo: self.moreButton.leadingAnchor, constant: -4),
            self.channelButton.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 5),
            self.channelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            self.dateLabel.leadingAnchor.constraint(equalTo: self.channelButton.leadingAnchor),
            self.dateLabel.trailingAnchor.constraint(equalTo: self.channelButton.trailingAnchor),
            self.dateLabel.topAnchor.constraint(equalTo: self.channelButton.bottomAnchor),
            self.moreButton.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -4),
            self.moreButton.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 4),
            self.moreButton.widthAnchor.constraint(equalToConstant: 44),
            self.moreButton.heightAnchor.constraint(equalToConstant: 44),
            self.bubble.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            self.bubble.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.bubble.topAnchor.constraint(equalTo: self.dateLabel.bottomAnchor, constant: 8),
            self.bubble.topAnchor.constraint(greaterThanOrEqualTo: self.avatar.view.bottomAnchor, constant: 6),
            self.bubble.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -10),
            self.bubbleHeight
        ])
        self.channelButton.contentHorizontalAlignment = .leading
        self.channelButton.titleLabel?.numberOfLines = 2
        self.channelButton.addTarget(self, action: #selector(self.channelPressed), for: .touchUpInside)
        self.avatar.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.channelPressed)))
        self.avatar.view.addInteraction(UIContextMenuInteraction(delegate: self))
        self.moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        self.moreButton.accessibilityLabel = "Post actions"
        self.moreButton.addTarget(self, action: #selector(self.postPressed), for: .touchUpInside)
        self.dateLabel.numberOfLines = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.lease.cancel()
        self.renderToken = nil
        self.layoutParams = nil
        self.nativeReady = false
        self.itemNode?.visibility = .none
        self.itemNode?.extractedBackgroundNode?.view.removeFromSuperview()
        self.itemNode?.view.removeFromSuperview()
        self.itemNode = nil
        self.item = nil
        self.rendererKind = nil
        self.renderedPostId = nil
        self.renderedPrimaryId = nil
        self.hiddenMedia.removeAll()
        self.messages.removeAll()
        self.renderTokens.removeAll()
        self.post = nil
        self.showChannelMenu = nil
        self.channelMenu = nil
        self.showPostMenu = nil
        self.heightUpdated = nil
        self.menuVisibilityChanged = nil
        self.bubbleHeight.constant = 180
    }

    func configure(context: AccountContext, post: ExteralessFeedPost, presentation: PresentationData, width: CGFloat, viewportHeight: CGFloat, selected: Bool?, revision: UInt64, makeItem: () -> ChatMessageItemImpl) {
        let tokens = post.projections.map(\.renderToken)
        let changed = self.post?.id != post.id || self.renderTokens != tokens || self.width != width || self.presentation != presentation || self.renderedSelection != selected || self.revision != revision || self.renderToken?.accountId != context.account.id.int64
        let kind = Self.rendererKind(post.messages[0])
        let compatible = self.renderedPostId == post.id && self.renderedPrimaryId == post.primaryId && self.rendererKind == kind && self.renderToken?.accountId == context.account.id.int64
        self.post = post
        self.channelButton.setTitle(post.channel.peer.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder), for: .normal)
        self.channelButton.titleLabel?.font = Font.semibold(presentation.listsFontSize.baseDisplaySize)
        self.channelButton.setTitleColor(presentation.theme.list.itemPrimaryTextColor, for: .normal)
        self.dateLabel.font = Font.regular(12)
        self.dateLabel.textColor = presentation.theme.list.itemSecondaryTextColor
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        self.dateLabel.text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(post.messages[0].timestamp)))
        self.moreButton.tintColor = presentation.theme.list.itemAccentColor
        self.avatar.setPeerV2(context: context, theme: presentation.theme, peer: post.channel.peer, displayDimensions: CGSize(width: 34, height: 34))
        self.avatar.frame = CGRect(origin: self.avatar.frame.origin, size: CGSize(width: 34, height: 34))
        self.accessibilityIdentifier = "exteraless.feed.post.\(post.primaryId.peerId.toInt64()).\(post.primaryId.namespace).\(post.primaryId.id)"
        guard changed || self.itemNode == nil else { return }
        self.messages = post.messages
        self.renderTokens = tokens
        self.width = width
        self.theme = presentation.theme
        self.presentation = presentation
        self.revision = revision
        self.renderedSelection = selected
        self.nativeReady = false
        let token = self.lease.begin(accountId: context.account.id.int64, post: post.id)
        self.renderToken = token
        let item = makeItem()
        item.controllerInteraction.hiddenMedia = self.hiddenMedia
        self.item = item
        let params = ListViewItemLayoutParams(width: max(1, width), leftInset: 0, rightInset: 0, availableHeight: max(1, viewportHeight), isStandalone: true)
        self.layoutParams = params
        if compatible, let node = self.itemNode {
            // Native updateNode keeps content-node-local quote expansion, pending poll choices
            // and media state. A new node is needed only for a different identity/renderer kind.
            self.updateNode(node, item: item, params: params, token: token)
            return
        }
        item.nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, neighbors: ListViewItemNeighbors(previous: nil, next: nil), completion: { [weak self] node, apply in
            guard let self, self.lease.accepts(token) else { return }
            self.itemNode?.visibility = .none
            self.itemNode?.extractedBackgroundNode?.view.removeFromSuperview()
            self.itemNode?.view.removeFromSuperview()
            self.itemNode = node
            self.rendererKind = kind
            self.renderedPostId = post.id
            self.renderedPrimaryId = post.primaryId
            if let background = node.extractedBackgroundNode { self.bubble.addSubview(background.view) }
            self.bubble.addSubview(node.view)
            let height = node.contentSize.height + node.insets.top + node.insets.bottom
            node.frame = CGRect(x: 0, y: 0, width: width, height: height)
            node.extractedBackgroundNode?.frame = node.frame
            apply().1(ListViewItemApply())
            node.updateFrame(node.frame, within: CGSize(width: width, height: max(height, viewportHeight)))
            self.bubbleHeight.constant = max(1, height)
            self.nativeReady = true
            if let current = self.layoutParams, abs(current.width - width) > 0.5 { self.relayout() }
            else { self.heightUpdated?() }
        })
    }

    func setVisibleRect(_ rect: CGRect, active: Bool) -> (visible: CGFloat, height: CGFloat) {
        guard let node = self.itemNode, self.nativeReady else { return (0, 0) }
        let local = self.bubble.convert(rect, from: self.contentView)
        let intersection = local.intersection(node.frame)
        let height = max(0, intersection.isNull ? 0 : intersection.height)
        self.item?.controllerInteraction.canPlayMedia = active
        node.visibility = active && height > 0 ? .visible(min(1, height / max(1, node.frame.height)), intersection.offsetBy(dx: -node.frame.minX, dy: -node.frame.minY)) : .none
        return (height, node.frame.height)
    }

    func clearVisibility() {
        self.item?.controllerInteraction.canPlayMedia = false
        self.itemNode?.visibility = .none
    }

    func bubbleFrame(in view: UIView) -> CGRect? {
        guard self.nativeReady, let node = self.itemNode else { return nil }
        return self.bubble.convert(node.frame, to: view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let actualWidth = self.bubble.bounds.width
        if let previous = self.layoutParams, actualWidth > 1, abs(previous.width - actualWidth) > 0.5 {
            self.width = actualWidth
            self.layoutParams = ListViewItemLayoutParams(width: actualWidth, leftInset: 0, rightInset: 0, availableHeight: previous.availableHeight, isStandalone: true)
            self.relayout()
        }
    }

    func setHiddenMedia(_ media: [EngineMessage.Id: [EngineRawMedia]]) {
        self.hiddenMedia = media
        self.item?.controllerInteraction.hiddenMedia = media
        (self.itemNode as? ChatMessageItemView)?.updateHiddenMedia()
    }

    func relayout() {
        guard self.nativeReady, let item = self.item, let node = self.itemNode, let previousToken = self.renderToken, let params = self.layoutParams else { return }
        let token = self.lease.begin(accountId: previousToken.accountId, post: previousToken.post)
        self.renderToken = token
        self.updateNode(node, item: item, params: params, token: token)
    }

    private func updateNode(_ node: ListViewItemNode, item: ChatMessageItemImpl, params: ListViewItemLayoutParams, token: FeedRenderLease.Token) {
        item.updateNode(async: { $0() }, node: { node }, params: params, neighbors: ListViewItemNeighbors(previous: nil, next: nil), animation: .None, completion: { [weak self] layout, apply in
            guard let self, self.lease.accepts(token), self.itemNode === node else { return }
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            node.frame = CGRect(x: 0, y: 0, width: params.width, height: layout.size.height)
            node.extractedBackgroundNode?.frame = node.frame
            apply(ListViewItemApply())
            node.updateFrame(node.frame, within: CGSize(width: params.width, height: max(params.availableHeight, layout.size.height)))
            self.bubbleHeight.constant = max(1, layout.size.height)
            self.nativeReady = true
            if let current = self.layoutParams, abs(current.width - params.width) > 0.5 { self.relayout() }
            else { self.heightUpdated?() }
        })
    }

    private enum RendererKind { case bubble, sticker, animatedSticker }
    private static func rendererKind(_ message: EngineMessage) -> RendererKind {
        // Same cloud-message selection as ChatMessageItemImpl. Feed disables large-emoji
        // substitution and rejects secret/service rows before they reach this host.
        var kind = RendererKind.bubble
        for media in message.media {
            if let file = media as? TelegramMediaFile {
                if file.isVideoSticker { return .animatedSticker }
                if file.isAnimatedSticker, let size = file.size, size > 0 && size <= 128 * 1024 { return .animatedSticker }
                for attribute in file.attributes {
                    switch attribute {
                    case .Sticker:
                        if let size = file.size, size > 0 && size <= 512 * 1024 { return .sticker }
                        return kind
                    case let .Video(_, _, flags, _, _, _):
                        if flags.contains(.instantRoundVideo) { return .bubble }
                    default: break
                    }
                }
            } else if media is TelegramMediaDice { kind = .animatedSticker }
        }
        return kind
    }

    @objc private func channelPressed() { self.showChannelMenu?() }
    @objc private func postPressed() { self.showPostMenu?() }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { [weak self] _ in self?.channelMenu?() })
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        self.menuVisibilityChanged?(true)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        let completion = self.menuVisibilityChanged
        if let animator { animator.addCompletion { completion?(false) } } else { completion?(false) }
    }
}
