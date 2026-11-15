import AccountContext
import ChatControllerInteraction
import ChatRichTextEditorComposer
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import OpenUserGeneratedUrl
import Pasteboard
import SwiftSignalKit
import TelegramCore
import TextSelectionNode
import UIKit

extension ExteralessFeedController {
    func feedPresent(_ controller: ViewController) {
        guard self.accountIsValid else { return }
        // Keeping native overlays on this presentation context also makes obscuration visible
        // to the feed's receipt/media visibility gate.
        self.present(controller, in: .current)
    }

    func feedShowNotice(_ text: String) {
        guard self.accountIsValid else { return }
        let alert = UIAlertController(title: "Channel feed", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }

    func feedOpenPeer(_ peer: EnginePeer) {
        guard self.accountIsValid, let navigation = self.feedNavigationController else { return }
        self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: self.context, chatLocation: .peer(peer), keepStack: .always, showsUnreadChatsBackBadge: false))
    }

    func feedOpenSource(_ id: EngineMessage.Id, setupReply: Bool = false, timecode: Double? = nil, discussionPeer: EnginePeer.Id? = nil) {
        guard self.accountIsValid, let navigation = self.feedNavigationController else { return }
        let context = self.context
        if setupReply, id.peerId.namespace == Namespaces.Peer.CloudChannel, let message = self.feedCurrentMessage(id), message.attributes.contains(where: { $0 is ReplyThreadMessageAttribute }) {
            self.feedAction.set((context.engine.messages.fetchChannelReplyThreadMessage(messageId: id, atMessageId: nil)
            |> timeout(10, queue: .mainQueue(), alternate: .fail(.generic))
            |> deliverOnMainQueue).start(next: { [weak self] thread in
                guard let self, self.accountIsValid else { return }
                guard !thread.isNotAvailable else { self.feedShowNotice("This channel discussion is unavailable."); return }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: .replyThread(thread), keepStack: .always, showsUnreadChatsBackBadge: false))
            }, error: { [weak self] _ in self?.feedShowNotice("Couldn't load the discussion. Try again.") }))
            return
        }
        let peerId = discussionPeer ?? id.peerId
        self.feedAction.set((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> timeout(10, queue: .mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, self.accountIsValid else { return }
            guard let peer else { self.feedShowNotice("The source is unavailable in this account."); return }
            let subject: ChatControllerSubject? = peerId == id.peerId ? .message(id: .id(id), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: timecode, setupReply: setupReply, cachedAnchor: true) : nil
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: .peer(peer), subject: subject, keepStack: .always, showsUnreadChatsBackBadge: false))
        }))
    }

    func feedOpenURL(_ url: String, concealed: Bool, messageId: EngineMessage.Id) {
        guard self.accountIsValid else { return }
        let context = self.context
        self.feedAction.set(openUserGeneratedUrl(context: context, peerId: messageId.peerId, url: url, concealed: concealed, present: { [weak self] controller in
            self?.feedPresent(controller)
        }, openResolved: { [weak self] resolved in
            guard let self, self.accountIsValid else { return }
            context.sharedContext.openResolvedUrl(resolved, context: context, urlContext: .generic, navigationController: self.feedNavigationController, forceExternal: false, forceUpdate: false, openPeer: { [weak self] peer, _ in self?.feedOpenPeer(peer) }, sendFile: nil, sendSticker: nil, sendEmoji: nil, requestMessageActionUrlAuth: nil, joinVoiceChat: nil, present: { [weak self] controller, _ in self?.feedPresent(controller) }, dismissInput: { [weak self] in self?.view.endEditing(true) }, contentContext: nil, progress: nil, completion: nil)
        }))
    }

    func feedOpenMedia(_ message: EngineRawMessage, params: OpenMessageParams) -> Bool {
        guard self.feedCurrentMessage(message.id) != nil else { return false }
        let id = message.id
        let ids = Set(self.feedTimeline.posts.first { $0.messages.contains { $0.id == id } }?.messages.map(\.id) ?? [id])
        self.feedWithFreshMessages(ids, exporting: false, action: { [weak self] projections in
            guard let self, let current = projections.first(where: { $0.message.id == id }) else { return }
            self.feedOpenAuthorizedMedia(current, projections: projections, params: params)
        })
        return true
    }

    private func feedOpenAuthorizedMedia(_ current: ExteralessFeedMessageProjection, projections: [ExteralessFeedMessageProjection], params: OpenMessageParams) {
        let context = self.context
        let message = current.message._asMessage()
        self.feedMediaGeneration &+= 1
        let generation = self.feedMediaGeneration
        let exportGeneration = self.feedExportGeneration
        self.feedHiddenMedia.set(nil)
        self.feedUpdateHiddenMedia([:])
        let projected = self.feedWatchPresentationPolicy(projections, generation: generation)
        guard let permit = self.feedExportPermit else { return }
        let galleryUpdates = projected.get()
        |> map { values -> ([EngineRawMessage], Int32, Bool) in
            let messages = values.values.sorted { $0.message.id < $1.message.id }.map { $0.message._asMessage() }
            return (messages, Int32(messages.count), false)
        }
        let opened = context.sharedContext.openChatMessage(OpenChatMessageParams(
            context: context, updatedPresentationData: (self.presentationData, context.sharedContext.presentationData),
            chatLocation: .peer(id: message.id.peerId), chatFilterTag: nil, chatLocationContextHolder: nil,
            message: message, mediaSubject: params.mediaSubject, standalone: true, copyProtected: projections.contains(where: \.isCopyProtected), reverseMessageGalleryOrder: false, mode: params.mode,
            navigationController: self.feedNavigationController,
            dismissInput: { [weak self] in self?.view.endEditing(true) },
            present: { [weak self] controller, _, _ in
                guard let self, self.accountIsValid, self.screenIsVisible, self.feedMediaGeneration == generation, self.feedExportGeneration == exportGeneration else { return }
                self.feedActiveGallery = controller
                permit.presentWhenReady(controller, accountId: context.account.id.int64, from: self, prepare: { [weak self] _ in
                    guard let self else { return false }
                    return self.accountIsValid && self.screenIsVisible && self.feedMediaGeneration == generation && self.feedExportGeneration == exportGeneration
                }, present: { [weak self] controller in self?.feedPresent(controller) })
            },
            transitionNode: { _, _, _ in nil },
            addToTransitionSurface: { [weak self] view in self?.view.addSubview(view) },
            openUrl: { [weak self] url in self?.feedOpenURL(url, concealed: false, messageId: message.id) },
            openPeer: { [weak self] peer, _ in self?.feedOpenPeer(EnginePeer(peer)) },
            callPeer: { [weak self] _, _ in self?.feedOpenSource(message.id) },
            openConferenceCall: { [weak self] value in self?.feedOpenSource(value.id) },
            enqueueMessage: { [weak self] _ in self?.feedOpenSource(message.id, setupReply: true) },
            sendSticker: nil, sendEmoji: nil,
            setupTemporaryHiddenMedia: { [weak self] signal, _, media in
                self?.feedHiddenMedia.set((signal |> deliverOnMainQueue).start(next: { [weak self] entry in
                    guard let self, self.accountIsValid, self.feedMediaGeneration == generation else { return }
                    self.feedUpdateHiddenMedia(entry == nil ? [:] : [message.id: [media]])
                }))
            },
            chatAvatarHiddenMedia: { [weak self] signal, media in
                self?.feedHiddenMedia.set((signal |> deliverOnMainQueue).start(next: { [weak self] id in
                    guard let self, self.accountIsValid, self.feedMediaGeneration == generation else { return }
                    self.feedUpdateHiddenMedia(id.map { [$0: [media]] } ?? [:])
                }))
            },
            gallerySource: .custom(messages: galleryUpdates, messageId: message.id, loadMore: nil),
            navigateToMessageContext: { [weak self] message in self?.feedOpenSource(message.id) }
        ))
        if !opened { self.feedRetireExportFlow(); self.feedOpenSource(message.id) }
    }

    private func feedUpdateHiddenMedia(_ values: [EngineMessage.Id: [EngineRawMedia]]) {
        self.feedHiddenMediaValues = values
        for case let cell as ExteralessFeedMessageCell in self.tableView.visibleCells { cell.setHiddenMedia(values) }
    }

    func feedRetireExportFlow() {
        guard let permit = self.feedExportPermit else { return }
        self.feedExportPermit = nil
        self.feedExportScopeGeneration = nil
        self.feedMediaGeneration &+= 1
        permit.revoke()
        self.feedGalleryPolicy.set(nil)
        self.feedActiveGallery = nil
        self.feedHiddenMedia.set(nil)
        self.feedUpdateHiddenMedia([:])
    }

    func feedRetireChangedExportScope() {
        if let generation = self.feedExportScopeGeneration, generation != self.feedTimeline.scopeGeneration {
            self.feedRetireExportFlow()
        }
    }

    func feedOpenPollMedia(_ message: EngineRawMessage, subject: ChatControllerInteraction.PollMediaSubject) {
        let media: GalleryMediaSubject
        switch subject {
        case let .option(option): media = .pollOption(option.opaqueIdentifier)
        case .solution: media = .pollSolution
        }
        _ = self.feedOpenMedia(message, params: OpenMessageParams(mode: .default, mediaSubject: media))
    }

    func feedUpdateReaction(_ message: EngineRawMessage, reaction: ChatControllerInteractionReaction) {
        guard let current = self.feedCurrentMessage(message.id), exteralessFeedMessageIsEligible(current) else { return }
        guard case let .reaction(value) = reaction, value != .stars else { self.feedShowPostMenu(message.id); return }
        var selected = (mergedMessageReactions(attributes: current.attributes, isTags: false)?.reactions ?? []).filter(\.isSelected).map(\.value)
        if let index = selected.firstIndex(of: value) { selected.remove(at: index) } else { selected.append(value) }
        let updates = selected.compactMap { reaction -> UpdateMessageReaction? in
            switch reaction {
            case let .builtin(value): return .builtin(value)
            case let .custom(fileId): return .custom(fileId: fileId, file: nil)
            case .stars: return nil
            }
        }
        let ids = self.feedTimeline.posts.first(where: { $0.messages.contains { $0.id == current.id } })?.messages.map(\.id) ?? [current.id]
        self.context.engine.messages.setMessageReactions(ids: ids, reactions: updates)
    }

    func feedVote(_ id: EngineMessage.Id, options: [Data]) {
        guard let message = self.feedCurrentMessage(id), exteralessFeedMessageIsEligible(message), self.feedPollRequests[id] == nil, self.feedPollRequests.count < 4 else { return }
        self.feedPollActionState.pollMessageIdsInProgress[id] = options
        self.feedRenderRevision &+= 1
        self.scheduleRender()
        let request = MetaDisposable()
        self.feedPollRequests[id] = request
        request.set((self.context.engine.messages.requestMessageSelectPollOption(messageId: id, opaqueIdentifiers: options)
        |> timeout(10, queue: .mainQueue(), alternate: .fail(.generic))
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.feedFinishVote(id, failed: false)
        }, error: { [weak self] _ in self?.feedFinishVote(id, failed: true) }))
    }

    private func feedFinishVote(_ id: EngineMessage.Id, failed: Bool) {
        self.feedPollRequests.removeValue(forKey: id)?.dispose()
        guard self.accountIsValid else { return }
        self.feedPollActionState.pollMessageIdsInProgress.removeValue(forKey: id)
        self.feedRenderRevision &+= 1
        self.scheduleRender()
        if failed { self.feedShowNotice("The vote wasn't applied. Open the original post or try again.") }
    }

    func feedToggleSelection(_ ids: [EngineMessage.Id], selected: Bool) {
        guard self.accountIsValid else { return }
        let valid = ids.filter { self.feedCurrentMessage($0) != nil }
        if selected { self.feedSelectedIds.formUnion(valid) } else { self.feedSelectedIds.subtract(valid) }
        self.scheduleRender()
    }

    private func feedCanExport(_ message: EngineMessage) -> Bool {
        guard let projection = self.feedTimeline.projections[ExteralessFeedTimeline.identity(message.id)] else { return false }
        return projection.allowsExport(contentSettings: self.context.currentContentSettings.with { $0 })
    }

    private func feedWithFreshMessages(_ ids: Set<EngineMessage.Id>, exporting: Bool, action: @escaping ([ExteralessFeedMessageProjection]) -> Void) {
        let context = self.context
        let generation = self.feedExportGeneration
        let windowGeneration = self.feedTimeline.scopeGeneration
        self.feedFreshActions.perform(ids: ids, current: { [weak self] in
            guard let self else { return false }
            return self.accountIsValid && self.context === context && self.screenIsVisible && self.viewIfLoaded?.window != nil && self.feedExportGeneration == generation && self.feedTimeline.scopeGeneration == windowGeneration
        }, allowed: { [weak self] values in
            guard let self else { return false }
            let configuration = ExteralessFeedSettings.read(account: self.feedAccountKey)
            let contentSettings = context.currentContentSettings.with { $0 }
            return values.allSatisfy { value in
                self.feedCurrentMessage(value.message.id) != nil && configuration.includes(value.message.id.peerId.toInt64(), archived: value.isArchived) && (exporting ? value.allowsExport(contentSettings: contentSettings) : value.allowsMedia(contentSettings: contentSettings))
            }
        }, rejected: { [weak self] in
            self?.feedShowNotice("This content is unavailable, changed scope, or is protected.")
        }, action: action)
    }

    /// A sheet opened before a protection/scope change must not retain an old export affordance.
    /// The same fresh projection drives the gallery, while a policy change dismisses this owned
    /// presentation and requires reopening with its new native policy.
    private func feedWatchPresentationPolicy(_ initial: [ExteralessFeedMessageProjection], generation: UInt64) -> Promise<[EngineMessage.Id: ExteralessFeedMessageProjection]> {
        let context = self.context
        let ids = Set(initial.map { $0.message.id })
        let initialProtection = Dictionary(uniqueKeysWithValues: initial.map { ($0.message.id, $0.isCopyProtected) })
        self.feedExportPermit?.revoke()
        let permit = ExteralessContentExportPermit(accountId: context.account.id.int64, messageIds: ids, exportAllowed: initial.allSatisfy { $0.allowsExport(contentSettings: context.currentContentSettings.with { $0 }) })
        self.feedExportPermit = permit
        self.feedExportScopeGeneration = self.feedTimeline.scopeGeneration
        let projected = Promise<[EngineMessage.Id: ExteralessFeedMessageProjection]>()
        projected.set(.single(Dictionary(uniqueKeysWithValues: initial.map { ($0.message.id, $0) })) |> then(exteralessFeedMessageProjections(engine: context.engine, ids: ids)))
        let settings = Signal<Void, NoError> { subscriber in
            let observation = ClientSettings.shared.observe { keys in
                if keys.isEmpty || !keys.isDisjoint(with: ExteralessFeedSettings.fields) { subscriber.putNext(()) }
            }
            subscriber.putNext(())
            return ActionDisposable { observation.cancel() }
        }
        self.feedGalleryPolicy.set((combineLatest(projected.get(), settings, context.sharedContext.applicationBindings.applicationInForeground, context.sharedContext.activeAccountContexts) |> deliverOnMainQueue).start(next: { [weak self] values, _, foreground, accounts in
            guard let self, self.accountIsValid, self.context === context, self.feedMediaGeneration == generation else { return }
            let configuration = ExteralessFeedSettings.read(account: self.feedAccountKey)
            let contentSettings = context.currentContentSettings.with { $0 }
            let unchanged = foreground && accounts.primary === context && values.count == ids.count && values.allSatisfy { id, projection in
                ids.contains(id) && projection.allowsMedia(contentSettings: contentSettings) && configuration.includes(id.peerId.toInt64(), archived: projection.isArchived) && initialProtection[id] == projection.isCopyProtected
            }
            if !unchanged {
                self.feedRetireExportFlow()
            }
        }))
        return projected
    }

    func feedCopyText(messageId: EngineMessage.Id, text: String) {
        guard let previous = self.feedCurrentMessage(messageId) else { return }
        self.feedWithFreshMessages([messageId], exporting: true, action: { projections in
            guard let message = projections.first?.message, message.stableVersion == previous.stableVersion, message.text == previous.text, message.richText == previous.richText else { return }
            storeMessageTextInPasteboard(text, entities: nil)
        })
    }

    private func feedCopyPost(_ id: EngineMessage.Id) {
        self.feedWithFreshMessages([id], exporting: true, action: { projections in
            guard let message = projections.first?.message else { return }
            if let rich = message.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute {
                UIPasteboard.general.items = [richMessagePasteboardItem(fromInstantPage: rich.instantPage)]
            } else {
                storeMessageTextInPasteboard(message.text, entities: message.textEntitiesAttribute?.entities)
            }
        })
    }

    func feedTextAction(messageId: EngineMessage.Id, text: NSAttributedString, entities: [MessageTextEntity]?, action: TextSelectionAction) {
        guard let previous = self.feedCurrentMessage(messageId) else { return }
        switch action {
        case .copy:
            self.feedWithFreshMessages([messageId], exporting: true, action: { projections in
                guard let message = projections.first?.message, message.stableVersion == previous.stableVersion, message.text == previous.text, message.richText == previous.richText else { return }
                if let entities { storeMessageTextInPasteboard(text.string, entities: entities) }
                else { storeAttributedTextInPasteboard(text) }
            })
        case .share:
            self.feedShare([messageId])
        case .quote:
            self.feedOpenSource(messageId, setupReply: true)
        default:
            self.feedOpenSource(messageId)
        }
    }

    func feedShare(_ ids: [EngineMessage.Id]) {
        self.feedWithFreshMessages(Set(ids), exporting: true, action: { [weak self] projections in
            guard let self else { return }
            self.feedMediaGeneration &+= 1
            let generation = self.feedMediaGeneration
            let exportGeneration = self.feedExportGeneration
            _ = self.feedWatchPresentationPolicy(projections, generation: generation)
            guard let permit = self.feedExportPermit else { return }
            // Root descendants may outlive this panel. The flow owns the policy observer
            // until retirement/replacement, rather than the sheet's dismissed callback.
            let controller = self.context.sharedContext.makeShareController(context: self.context, params: ShareControllerParams(subject: .messages(projections.map { $0.message._asMessage() }), showInChat: { [weak self] message in self?.feedOpenSource(message.id) }, updatedPresentationData: (self.presentationData, self.context.sharedContext.presentationData), parentNavigationController: self.feedNavigationController))
            self.feedActiveGallery = controller
            permit.presentWhenReady(controller, accountId: self.context.account.id.int64, from: self, requiresExport: true, prepare: { [weak self] _ in
                guard let self else { return false }
                return self.accountIsValid && self.screenIsVisible && self.feedMediaGeneration == generation && self.feedExportGeneration == exportGeneration
            }, present: { [weak self] controller in self?.feedPresent(controller) })
        })
    }

    func feedShowPostMenu(_ id: EngineMessage.Id) {
        guard let message = self.feedCurrentMessage(id) else { return }
        let post = self.feedTimeline.posts.first { $0.messages.contains { $0.id == id } }
        let ids = post?.messages.map(\.id) ?? [id]
        let alert = UIAlertController(title: "Post actions", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Open original post", style: .default, handler: { [weak self] _ in self?.feedOpenSource(id) }))
        alert.addAction(UIAlertAction(title: "Reply / discussion", style: .default, handler: { [weak self] _ in self?.feedOpenSource(id, setupReply: true) }))
        alert.addAction(UIAlertAction(title: "Select post", style: .default, handler: { [weak self] _ in self?.feedToggleSelection(ids, selected: true) }))
        if self.feedCanExport(message) {
            if !message.text.isEmpty || message.attributes.contains(where: { $0 is RichTextMessageAttribute }) {
                alert.addAction(UIAlertAction(title: "Copy formatted text", style: .default, handler: { [weak self] _ in self?.feedCopyPost(id) }))
            }
            alert.addAction(UIAlertAction(title: "Share / forward", style: .default, handler: { [weak self] _ in self?.feedShare(ids) }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        self.feedPresentSheet(alert)
    }

    private func feedChannelActions(_ peerId: EnginePeer.Id) -> [(String, () -> Void)] {
        guard self.accountIsValid, let channel = self.feedChannels.channels.first(where: { $0.peer.id == peerId }) else { return [] }
        return [
            ("Open channel", { [weak self] in self?.feedOpenPeer(channel.peer) }),
            (channel.isMuted ? "Unmute channel" : "Mute channel", { [weak self] in
                guard let self, self.accountIsValid else { return }
                self.feedAction.set((self.context.engine.peers.togglePeerMuted(peerId: peerId, threadId: nil) |> deliverOnMainQueue).start(completed: { [weak self] in self?.feedRegistry.refresh() }))
            }),
            ("Select channel posts", { [weak self] in
                guard let self else { return }
                self.feedToggleSelection(self.feedTimeline.posts.filter { $0.channel.peer.id == peerId }.flatMap { $0.messages.map(\.id) }, selected: true)
            }),
            ("Exclude from feed", { [weak self] in self?.feedSetIncluded(peerId, included: false) })
        ]
    }

    func feedChannelMenu(_ peerId: EnginePeer.Id) -> UIMenu {
        UIMenu(children: self.feedChannelActions(peerId).map { title, action in UIAction(title: title, handler: { _ in action() }) })
    }

    func feedShowChannelMenu(_ peerId: EnginePeer.Id) {
        guard self.accountIsValid else { return }
        let channel = self.feedChannels.channels.first { $0.peer.id == peerId }
        let alert = UIAlertController(title: channel?.peer.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder), message: nil, preferredStyle: .actionSheet)
        for (title, action) in self.feedChannelActions(peerId) { alert.addAction(UIAlertAction(title: title, style: .default, handler: { _ in action() })) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        self.feedPresentSheet(alert)
    }

    private func feedPresentSheet(_ alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
        }
        self.present(alert, animated: true)
    }

    func feedSetIncluded(_ peerId: EnginePeer.Id, included: Bool) {
        guard self.accountIsValid else { return }
        let before = ClientSettings.shared.readSnapshot()
        var configuration = FeedSettingsStore.configuration(account: self.feedAccountKey, snapshot: before)
        configuration.setIncluded(peerId.toInt64(), included: included)
        let updated = configuration
        let accountKey = self.feedAccountKey
        self.writeSettings({ try ExteralessFeedSettings.write(updated, account: accountKey, expected: before) }, completion: { [weak self] in
            guard let self, self.accountIsValid else { return }
            self.feedUndoExclusion = included ? nil : peerId
            self.feedApplyConfiguration()
        })
    }
}
