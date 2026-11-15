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

/// Use beside the normal Forward action. Native target selection, sending rights,
/// bot guard, paid-message UI and the normal enqueue pipeline remain the consumers.
@MainActor
func exteralessProtectedCopyAction(context: AccountContext, messages: [EngineMessage], peerProtected: Bool, parent: ViewController) -> ContextMenuItem? {
    guard exteralessCanOfferProtectedCopy(messages: messages, peerProtected: peerProtected) else { return nil }
    let ids = messages.map(\.id)
    let identity = exteralessPrivacyExtrasIdentity(context.account)
    return .action(ContextMenuActionItem(text: "Forward as a new copy", icon: { theme in
        generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor)
    }, action: { [weak parent] _, finish in
        finish(.default)
        guard let parent, ExteralessHiddenAccounts.shared.permitsCurrentAccountAction(identity) else { return }
        let selector = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: "Forward as a copy", selectForumThreads: true))
        selector.peerSelected = { [weak selector, weak parent] peer, threadId in
            selector?.dismiss()
            guard let parent, let navigation = parent.navigationController as? NavigationController,
                  ClientSettings.shared.bool("privacy.forwardProtectedAsCopy"), ExteralessHiddenAccounts.shared.permitsCurrentAccountAction(identity) else { return }
            let location: NavigateToChatControllerParams.Location
            if let threadId {
                let forum: Bool
                let monoforum: Bool
                if case let .channel(channel) = peer { forum = channel.flags.contains(.isForum); monoforum = channel.isMonoForum }
                else if case let .user(user) = peer { forum = user.isForum; monoforum = false }
                else { forum = false; monoforum = false }
                location = .replyThread(ChatReplyThreadMessage(peerId: peer.id, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: forum, isMonoforumPost: monoforum, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false).normalized)
            } else { location = .peer(peer) }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: location, completion: { controller in
                guard let chat = controller as? ChatControllerImpl, chat.context === context, chat.chatLocation.peerId == peer.id else { return }
                let targetLocation = chat.chatLocation
                let _ = (exteralessPrepareProtectedCopies(account: context.account, ids: ids, threadId: targetLocation.threadId)
                |> deliverOnMainQueue).startStandalone(next: { [weak chat] result in
                    guard let chat, chat.context === context, chat.chatLocation == targetLocation,
                          chat.viewIfLoaded?.window != nil, ExteralessHiddenAccounts.shared.permitsCurrentAccountAction(identity), ClientSettings.shared.bool("privacy.forwardProtectedAsCopy"), canSendMessagesToChat(chat.presentationInterfaceState) else { return }
                    switch result {
                    case let .success(copies):
                        chat.presentPaidMessageAlertIfNeeded(count: Int32(copies.count), completion: { [weak chat] postpone in
                            guard let chat, chat.context === context, chat.chatLocation == targetLocation,
                                  chat.viewIfLoaded?.window != nil, ExteralessHiddenAccounts.shared.permitsCurrentAccountAction(identity), ClientSettings.shared.bool("privacy.forwardProtectedAsCopy"), canSendMessagesToChat(chat.presentationInterfaceState) else { return }
                            chat.sendMessages(copies, postpone: postpone)
                        })
                    case let .failure(error):
                        let text = error == .mediaNotDownloaded ? "Download the original media in this account, then try again." : "This content is no longer available to copy."
                        chat.present(textAlertController(context: context, title: "Unable to prepare copy", text: text, actions: [TextAlertAction(type: .defaultAction, title: chat.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    }
                })
            }, forceOpenChat: true))
        }
        parent.push(selector)
    }))
}
