import AccountContext
import ChatPresentationInterfaceState
import Display
import ExteralessCore
import Foundation
import PeerInfoUI
import PresentationDataUtils
import StatisticsUI
import SwiftSignalKit
import TelegramCore
import UIKit

extension ChatControllerImpl {
    public func exteralessPresentChatActions() {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else { return }
        let sheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = []
        func add(_ field: String, _ title: String, allowed: Bool = true, action: @escaping (ChatControllerImpl) -> Void) {
            guard allowed, ChatMenuPolicy.enabled(field) else { return }
            items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak self, weak sheet] in
                sheet?.dismissAnimated()
                guard let self, self.chatLocation.peerId == peer.id else { return }
                action(self)
            }))
        }
        add("chatMenuItemToBeginning", "Go to beginning") { $0.controllerInteraction?.navigateToFirstDateMessage(0, false) }
        add("chatMenuItemGoToMessage", "Go to message ID", allowed: peer.id.namespace != Namespaces.Peer.SecretChat) { $0.exteralessGoToMessage() }
        add("chatMenuItemHideTitle", self.chatTitleView?.isHidden == true ? "Show chat title" : "Hide chat title") { $0.chatTitleView?.isHidden.toggle() }
        add("showAddToBookmark", "Bookmarks") { $0.push(ExteralessBookmarksController(context: $0.context)) }
        if let linked = self.presentationInterfaceState.peerDiscussionId {
            add("chatMenuItemLinkedChat", "Open linked chat") { chat in
                let _ = (chat.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: linked)) |> deliverOnMainQueue).startStandalone(next: { [weak chat] peer in
                    guard let chat, let peer, let navigation = chat.navigationController as? NavigationController else { return }
                    chat.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: chat.context, chatLocation: .peer(peer), keepStack: .always))
                })
            }
        }
        if let channel = peer as? TelegramChannel {
            let admin = channel.flags.contains(.isCreator) || channel.adminRights != nil
            let group: Bool
            if case .group = channel.info { group = true } else { group = false }
            add("chatMenuItemBoostGroup", "Boost chat") { $0.controllerInteraction?.openGroupBoostInfo(channel.id, 0) }
            add("shortcutsMembers", "Members", allowed: admin || group) { $0.push(channelMembersController(context: $0.context, peerId: channel.id)) }
            add("shortcutsAdministrators", "Administrators", allowed: admin) { $0.push(channelAdminsController(context: $0.context, peerId: channel.id)) }
            add("shortcutsPermissions", "Permissions", allowed: channel.hasPermission(.banMembers)) { $0.push(channelPermissionsController(context: $0.context, peerId: channel.id)) }
            add("shortcutsRecentActions", "Recent actions", allowed: admin) { chat in
                chat.push(chat.context.sharedContext.makeChatRecentActionsController(context: chat.context, peer: EnginePeer(channel), adminPeerId: nil, starsState: nil))
            }
            let canViewStats = (self.contentData?.state.peerView?.cachedData as? CachedChannelData)?.flags.contains(.canViewStats) == true
            add("shortcutsStatistics", "Statistics", allowed: canViewStats) { chat in
                if case .group = channel.info { chat.push(groupStatsController(context: chat.context, peerId: channel.id)) }
                else { chat.push(channelStatsController(context: chat.context, peerId: channel.id, section: .stats, boostStatus: nil)) }
            }
        } else if peer is TelegramGroup {
            add("shortcutsMembers", "Members") { $0.push(channelMembersController(context: $0.context, peerId: peer.id)) }
            add("shortcutsAdministrators", "Administrators") { $0.push(channelAdminsController(context: $0.context, peerId: peer.id)) }
            add("shortcutsPermissions", "Permissions") { $0.push(channelPermissionsController(context: $0.context, peerId: peer.id)) }
        }
        add("chatMenuItemDeleteOwnMessages", "Delete my messages…", allowed: peer.id.namespace != Namespaces.Peer.SecretChat) { $0.exteralessSelectOwnMessagesForDeletion() }
        guard !items.isEmpty else { return }
        sheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, action: { [weak sheet] in sheet?.dismissAnimated() })])])
        self.present(sheet, in: .window(.root))
    }

    private func exteralessGoToMessage() {
        guard let peer = self.chatLocation.peerId else { return }
        let alert = UIAlertController(title: "Go to message", message: "Message ID", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_OK, style: .default, handler: { [weak self, weak alert] _ in
            guard let self, self.chatLocation.peerId == peer, let text = alert?.textFields?.first?.text, let id = Int32(text), id > 0 else { return }
            self.controllerInteraction?.navigateToMessageStandalone(EngineMessage.Id(peerId: peer, namespace: Namespaces.Message.Cloud, id: id))
        }))
        self.present(alert, animated: true)
    }

    private func exteralessSelectOwnMessagesForDeletion() {
        guard let peerId = self.chatLocation.peerId else { return }
        // Native search scopes by author and thread. The native deletion sheet owns rights,
        // delete-for-both choice and Undo; this shortcut never deletes as a side effect of loading.
        let _ = (self.context.engine.messages.searchMessages(location: .peer(peerId: peerId, fromId: self.context.account.peerId, tags: nil, reactions: nil, threadId: self.chatLocation.threadId, minDate: nil, maxDate: nil), query: "", state: nil)
        |> take(1) |> deliverOnMainQueue).startStandalone(next: { [weak self] result, _ in
            guard let self, self.chatLocation.peerId == peerId else { return }
            let messages: [EngineRawMessage] = Array(result.messages.prefix(100))
            guard !messages.isEmpty else { return }
            self.present(textAlertController(context: self.context, title: "Delete my messages", text: "Review the \(messages.count) most recent matching messages in the native deletion sheet. Repeat for older messages.", actions: [TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: { [weak self] in self?.interfaceInteraction?.deleteMessages(messages, nil, { _ in }) })]), in: .window(.root))
        })
    }
}
