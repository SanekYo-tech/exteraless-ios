import AccountContext
import ChatControllerInteraction
import ChatPresentationInterfaceState
import ChatScheduleTimeController
import ContextUI
import Display
import ExteralessCore
import Foundation
import PeerInfoUI
import SwiftSignalKit
import TelegramCore
import UIKit

func exteralessAdditionalMessageActions(context: AccountContext, messages: [EngineRawMessage], canForward: Bool, copyProtected: Bool, interfaceInteraction: ChatPanelInterfaceInteraction, controllerInteraction: ChatControllerInteraction) -> [ContextMenuItem] {
    guard let first = messages.first, first.adAttribute == nil else { return [] }
    var result: [ContextMenuItem] = []
    let safeContent = !copyProtected && messages.allSatisfy { !$0.isCopyProtected() && !$0.containsSecretMedia && $0.id.namespace == Namespaces.Message.Cloud && !$0.media.contains { $0 is TelegramMediaExpiredContent || $0 is TelegramMediaAction } }
    func add(_ field: String, _ title: String, allowed: Bool = true, needsContent: Bool = false, _ action: @escaping (ChatControllerImpl) -> Void) {
        guard allowed, ChatMenuPolicy.enabled(field), !needsContent || safeContent else { return }
        result.append(.action(ContextMenuActionItem(id: AnyHashable("exteraless." + field), text: title, icon: { _ in nil }, action: { _, finish in
            finish(.default)
            guard let chat = interfaceInteraction.chatController() as? ChatControllerImpl, chat.context === context,
                  !needsContent || (!chat.presentationInterfaceState.copyProtectionEnabled && messages.allSatisfy { !$0.isCopyProtected() && !$0.containsSecretMedia }) else { return }
            action(chat)
        })))
    }
    add("showRepeatAsCopy", "Repeat as copy", allowed: canForward, needsContent: true) { $0.exteralessRepeat(messages, asCopy: true) }
    add("showNoQuoteForward", "Forward without sender", allowed: canForward, needsContent: true) { $0.exteralessForwardWithoutNames(messages, hideCaptions: false) }
    add("showSetReminder", "Set reminder", allowed: canForward, needsContent: true) { $0.exteralessRemind(messages) }
    add("showAddToBookmark", "Toggle bookmark", allowed: first.id.namespace == Namespaces.Message.Cloud) { $0.exteralessToggleBookmark(first) }
    add("showShareMessages", "Share messages", allowed: canForward, needsContent: true) { chat in
        chat.present(context.sharedContext.makeShareScreen(context: context, params: ShareControllerParams(subject: .messages(messages), externalShare: true)), in: .window(.root))
    }
    if let author = first.author as? TelegramUser, author.id != context.account.peerId, author.id != first.id.peerId {
        add("showReplyInPrivate", "Reply privately", needsContent: true) { chat in
            guard let navigation = chat.navigationController as? NavigationController else { return }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: .peer(EnginePeer(author)), keepStack: .always, setupController: { controller in
                (controller as? ChatControllerImpl)?.updateChatPresentationInterfaceState(animated: false, interactive: true, { state in
                    state.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(.init(messageId: first.id, quote: nil, innerSubject: nil)) }
                })
            }))
        }
    }
    let hasImage = first.paidContent == nil && first.effectiveMedia.contains { $0 is TelegramMediaImage }
    let file = first.paidContent == nil ? first.effectiveMedia.compactMap { $0 as? TelegramMediaFile }.first : nil
    add("showCopyPhoto", "Copy photo", allowed: hasImage, needsContent: true) { $0.exteralessImageAction(first, action: .copy) }
    add("showCopyFrame", "Copy first video frame", allowed: file?.isVideo == true, needsContent: true) { $0.exteralessImageAction(first, action: .copy, timestamp: 0) }
    add("showCopyAsSticker", "Copy as sticker", allowed: hasImage || file?.isSticker == true, needsContent: true) { $0.exteralessImageAction(first, action: .copySticker) }
    add("showAddToStickers", "Create sticker", allowed: hasImage || file?.isSticker == true, needsContent: true) { $0.exteralessImageAction(first, action: .createSticker) }
    add("showDeleteDownloadedFile", "Delete downloaded media", allowed: hasImage || file != nil) { chat in
        let _ = (context.engine.resources.clearStorage(messages: messages.map(EngineMessage.init)) |> deliverOnMainQueue).startStandalone(completed: { [weak chat] in
            chat?.controllerInteraction?.displayMessageTooltip(first.id, "Downloaded media cleared", false, nil, nil)
        })
    }
    if let channel = first.peers[first.id.peerId] as? TelegramChannel, channel.hasPermission(.banMembers), let author = first.author {
        add("showAdminActions", "Moderate message author") { chat in
            let _ = (context.sharedContext.chatAvailableMessageActions(engine: context.engine, accountPeerId: context.account.peerId, messageIds: Set(messages.map(\.id)), keepUpdated: false) |> take(1) |> deliverOnMainQueue).startStandalone(next: { [weak chat] available in
                guard let chat, available.banAuthor?.id == author.id || available.banAuthors.contains(where: { $0.id == author.id }) else { return }
                chat.presentBanMessageOptions(accountPeerId: context.account.peerId, author: EnginePeer(author), messageIds: Set(messages.map(\.id)), options: available.options)
            })
        }
        add("showChangePermissions", "Author permissions") { chat in
            let _ = (context.engine.peers.fetchChannelParticipant(peerId: channel.id, participantId: author.id) |> take(1) |> deliverOnMainQueue).startStandalone(next: { [weak chat] participant in
                guard let chat else { return }
                chat.push(channelBannedMemberController(context: context, peerId: channel.id, memberId: author.id, initialParticipant: participant, updated: { _ in }, upgradedToSupergroup: { _, completion in completion() }))
            })
        }
    }
    result.append(.action(ContextMenuActionItem(text: "Chat actions", icon: { _ in UIImage(systemName: "ellipsis.circle") }, action: { _, finish in
        finish(.default)
        (interfaceInteraction.chatController() as? ChatControllerImpl)?.exteralessPresentChatActions()
    })))
    return result
}

extension ChatControllerImpl {
    func exteralessRemind(_ messages: [EngineRawMessage]) {
        let context = self.context
        let controller = ChatScheduleTimeScreen(context: context, mode: .reminders, currentTime: nil, isDark: self.presentationData.theme.overallDarkAppearance, completion: { [weak self] result in
            guard let self, self.context === context, self.viewIfLoaded?.window != nil, !self.presentationInterfaceState.copyProtectionEnabled, messages.allSatisfy({ !$0.isCopyProtected() && !$0.containsSecretMedia }) else { return }
            let enqueued = messages.map { EnqueueMessage.forward(source: $0.id, threadId: nil, grouping: .auto, attributes: [OutgoingScheduleInfoMessageAttribute(scheduleTime: result.time, repeatPeriod: result.repeatPeriod)], correlationId: nil).withNotificationOverride(silent: result.silentPosting) }
            let _ = (enqueueMessages(account: context.account, peerId: context.account.peerId, messages: enqueued) |> deliverOnMainQueue).startStandalone(next: { [weak self] ids in
                if ids.contains(where: { $0 != nil }), let first = messages.first { self?.controllerInteraction?.displayMessageTooltip(first.id, "Reminder scheduled in Saved Messages", false, nil, nil) }
            })
        })
        self.present(controller, in: .window(.root))
    }
}
