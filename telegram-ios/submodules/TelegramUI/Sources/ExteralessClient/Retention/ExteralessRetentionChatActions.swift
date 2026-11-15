import AccountContext
import ChatPresentationInterfaceState
import ContextUI
import Display
import ExteralessCore
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit

extension ChatControllerImpl {
    @MainActor
    func exteralessOpenRetainedContextMenu(messageId: EngineMessage.Id) -> Bool {
        guard let message = self.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) else { return false }
        return self.exteralessOpenRetainedContextMenu(message: message)
    }

    /// Early exit before stock message-menu RPCs. An archive message has no live server target.
    /// Export/clear/full text/media are the same real account-scoped screen actions as Settings.
    @MainActor
    func exteralessOpenRetainedContextMenu(message: EngineMessage) -> Bool {
        guard message.exteralessRetention != nil else { return false }
        let menu = UIAlertController(title: "Retained message", message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "View history, export or clear", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            ExteralessRetentionIntegration.open(context: self.context, parent: self, scope: .message(message.id))
        }))
        if RetentionPolicy.current.replyToDeletedAsQuote, canSendMessagesToChat(self.presentationInterfaceState) {
            menu.addAction(UIAlertAction(title: "Reply as a quote", style: .default, handler: { [weak self] _ in
                self?.interfaceInteraction?.setupReplyMessage(message.id, nil, { _, completed in completed() })
            }))
        }
        if RetentionPolicy.current.showMessageHide {
            menu.addAction(UIAlertAction(title: "Hide for this session", style: .default, handler: { [weak self] _ in self?.exteralessHideMessageLocally(message.id) }))
        }
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        menu.popoverPresentationController?.sourceView = self.view
        menu.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
        self.present(menu, animated: true)
        return true
    }

    /// Joined with the stock live-message context-menu signal. The row exists only when the
    /// account really has a previous locally observed version, not merely an "edited" bit.
    func exteralessRetentionContextItems(message: EngineMessage) -> Signal<[ContextMenuItem], NoError> {
        let context = self.context
        let sessionItems = MainActor.assumeIsolated { self.exteralessRetentionSessionItems(message: message) }
        guard RetentionPolicy.current.saveEdits, let author = message.author, author.id != context.account.peerId,
              !message.media.contains(where: { media in
                  guard let expired = media as? TelegramMediaExpiredContent else { return false }
                  switch expired.data { case .voiceMessage, .videoMessage: return true; default: return false }
              }) else { return .single(sessionItems) }
        return context.engine.messages.retainedVersions(messageId: message.id)
        |> deliverOnMainQueue
        |> map { [weak self] result -> [ContextMenuItem] in
            guard let self, case let .success(versions) = result, !versions.isEmpty else { return sessionItems }
            return sessionItems + [.action(ContextMenuActionItem(text: "View edit history", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] controller, complete in
                let present: () -> Void = { [weak self] in
                    guard let self, self.context === context else { return }
                    MainActor.assumeIsolated { ExteralessRetentionIntegration.open(context: context, parent: self, scope: .message(message.id)) }
                }
                if let controller { controller.dismiss(completion: present) }
                else { complete(.default); present() }
            }))]
        }
    }

    @MainActor
    private func exteralessHideMessageLocally(_ id: EngineMessage.Id) {
        let ids = self.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(id)?.map(\.id) ?? [id]
        self.chatDisplayNode.historyNode.ignoreMessageIds.formUnion(ids)
    }

    @MainActor
    private func exteralessRetentionSessionItems(message: EngineMessage) -> [ContextMenuItem] {
        let policy = RetentionPolicy.current
        var result: [ContextMenuItem] = []
        if policy.showMessageHide {
            result.append(.action(ContextMenuActionItem(text: "Hide for this session", icon: { theme in
                UIImage(systemName: "eye.slash")?.withTintColor(theme.contextMenu.primaryColor, renderingMode: .alwaysOriginal)
            }, action: { [weak self] _, complete in
                complete(.default)
                MainActor.assumeIsolated { self?.exteralessHideMessageLocally(message.id) }
            })))
        }
        var group = false
        if let id = self.chatLocation.peerId, let peer = message._asMessage().peers[id] {
            if peer is TelegramGroup { group = true }
            else if let channel = peer as? TelegramChannel, case .group = channel.info { group = true }
        }
        if case let .replyThread(thread) = self.chatLocation, thread.effectiveTopId == message.id { group = false }
        if self.subject == .scheduledMessages { group = false }
        if policy.showViewHistory, group, let author = message.author {
            result.append(.action(ContextMenuActionItem(text: "View sender history", icon: { theme in
                UIImage(systemName: "clock.arrow.circlepath")?.withTintColor(theme.contextMenu.primaryColor, renderingMode: .alwaysOriginal)
            }, action: { [weak self] _, complete in
                complete(.default)
                MainActor.assumeIsolated { self?.activateSearch(domain: .member(author._asPeer())) }
            })))
        }
        return result
    }

    /// Chat-level menu adapter, matching NaConfig's two original visibility controls.
    @MainActor
    func exteralessRetentionChatItems() -> [ContextMenuItem] {
        let policy = RetentionPolicy.current
        guard policy.saveDeleted, let peerId = self.chatLocation.peerId else { return [] }
        let scope = ExteralessRetentionScope.peer(peerId, threadId: self.chatLocation.threadId)
        var result: [ContextMenuItem] = []
        if policy.menuViewDeleted {
            result.append(.action(ContextMenuActionItem(text: "View deleted messages", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] controller, complete in
                let open: () -> Void = { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated { ExteralessRetentionIntegration.open(context: self.context, parent: self, scope: scope, deletedOnly: true) }
                }
                if let controller { controller.dismiss(completion: open) } else { complete(.default); open() }
            })))
        }
        if policy.menuClearDeleted {
            result.append(.action(ContextMenuActionItem(text: "Clear retained history", textColor: .destructive, icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
            }, action: { [weak self] controller, complete in
                let open: () -> Void = { [weak self] in
                    guard let self else { return }
                    let clear: () -> Void = { [weak self] in
                        guard let self else { return }
                        let _ = (self.context.engine.messages.clearRetention(scope) |> deliverOnMainQueue).startStandalone(next: { [weak self] result in
                            guard let self else { return }
                            if case let .failure(error) = result {
                                self.present(textAlertController(context: self.context, title: "Retention", text: ExteralessRetentionPresentation.errorText(error), actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                            }
                        })
                    }
                    self.present(textAlertController(context: self.context, title: "Clear retained history?", text: "Removes this chat's local versions and retained media.", actions: [
                        TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
                        TextAlertAction(type: .destructiveAction, title: "Clear", action: clear)
                    ]), in: .window(.root))
                }
                if let controller { controller.dismiss(completion: open) } else { complete(.default); open() }
            })))
        }
        return result
    }
}
