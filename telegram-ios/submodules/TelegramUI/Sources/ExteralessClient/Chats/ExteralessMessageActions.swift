import AccountContext
import ChatControllerInteraction
import ChatPresentationInterfaceState
import ContextUI
import Display
import ExteralessCore
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit
import UndoUI

func exteralessMessageMediaSummary(_ message: EngineMessage) -> String {
    var result: [String] = []
    for media in message._asMessage().effectiveMedia {
        if media is TelegramMediaImage {
            result.append("Photo")
        } else if let file = media as? TelegramMediaFile {
            result.append(file.fileName ?? (file.isVoice ? "Voice message" : (file.isInstantVideo ? "Video message" : file.mimeType)))
        } else if let poll = media as? TelegramMediaPoll {
            result.append("Poll · " + poll.text)
        } else if media is TelegramMediaMap {
            result.append("Location")
        } else if media is TelegramMediaContact {
            result.append("Contact")
        }
    }
    return result.joined(separator: " · ")
}

/// Called by the common message-menu builder (see the coordinator hunk in docs/wave-2/chat.md).
/// Capability comes from Telegram's own menu calculation, and is checked again before enqueue.
func exteralessMessageContextActions(context: AccountContext, messages: [EngineRawMessage], canForward: Bool, copyProtected: Bool, interfaceInteraction: ChatPanelInterfaceInteraction, controllerInteraction: ChatControllerInteraction) -> [ContextMenuItem] {
    guard let first = messages.first, !messages.isEmpty else { return [] }
    var items: [ContextMenuItem] = []
    if ClientSettings.shared.bool("chats.showMessageID") {
        items.append(.action(ContextMenuActionItem(text: "Copy message ID", icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
        }, action: { _, finish in
            finish(.default)
            UIPasteboard.general.string = messages.map { String($0.id.id) }.joined(separator: "\n")
            controllerInteraction.displayUndo(.copy(text: "Message ID copied"))
        })))
    }
    if ClientSettings.shared.bool("chats.showMessageDetails") {
        items.append(.action(ContextMenuActionItem(text: "Message details", icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Info"), color: theme.contextMenu.primaryColor)
        }, action: { _, finish in
            finish(.default)
            controllerInteraction.navigationController()?.pushViewController(ExteralessMessageDetailsController(context: context, message: EngineMessage(first)))
        })))
    }
    let canUseContent = canForward && !copyProtected && messages.allSatisfy {
        $0.id.namespace == Namespaces.Message.Cloud && !$0.isCopyProtected() && !$0.media.contains(where: { $0 is TelegramMediaAction })
    }
    if canUseContent && ClientSettings.shared.bool("chats.showAddToSavedMessages") && first.id.peerId != context.account.peerId {
        items.append(.action(ContextMenuActionItem(text: "Save to Saved Messages", icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Save"), color: theme.contextMenu.primaryColor)
        }, action: { _, finish in
            finish(.default)
            guard let chat = interfaceInteraction.chatController() as? ChatControllerImpl,
                  chat.context === context, !chat.presentationInterfaceState.copyProtectionEnabled,
                  messages.allSatisfy({ !$0.isCopyProtected() }) else { return }
            let enqueued = messages.map { EnqueueMessage.forward(source: $0.id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil) }
            let _ = (enqueueMessages(account: context.account, peerId: context.account.peerId, messages: enqueued)
            |> deliverOnMainQueue).startStandalone(next: { [weak chat] ids in
                if let chat, chat.viewIfLoaded?.window != nil, ids.contains(where: { $0 != nil }) {
                    controllerInteraction.displayUndo(.forward(savedMessages: true, text: "Saved to Saved Messages"))
                }
            })
        })))
    }
    if canUseContent && ClientSettings.shared.bool("chats.showRepeat") {
        items.append(.action(ContextMenuActionItem(text: "Repeat", icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor)
        }, action: { _, finish in
            finish(.default)
            guard let chat = interfaceInteraction.chatController() as? ChatControllerImpl, chat.context === context else { return }
            chat.exteralessRepeat(messages)
        })))
    }
    items.append(contentsOf: exteralessAdditionalMessageActions(context: context, messages: messages, canForward: canForward, copyProtected: copyProtected, interfaceInteraction: interfaceInteraction, controllerInteraction: controllerInteraction))
    if ChatMenuPolicy.enabled("groupedMessageMenu"), items.count > 1 {
        let children = items
        return [.action(ContextMenuActionItem(text: "Message actions", icon: { _ in UIImage(systemName: "ellipsis") }, action: { controller, _ in
            let back = ContextMenuItem.action(ContextMenuActionItem(text: "Back", icon: { _ in UIImage(systemName: "chevron.backward") }, action: { controller, _ in controller?.popItems() }))
            controller?.pushItems(items: .single(ContextController.Items(content: .list([back, .separator] + children))))
        }))]
    }
    return items
}

extension ChatControllerImpl {
    func exteralessConfirmBotCommand(_ command: String, send: @escaping () -> Void) {
        if !ClientSettings.shared.bool("chats.disableClickCommandToSend") { send(); return }
        let location = self.chatLocation
        let alert = textAlertController(context: self.context, title: "Send bot command?", text: String(command.prefix(512)), actions: [
            TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil, self.chatLocation == location, canSendMessagesToChat(self.presentationInterfaceState) else { return }
                send()
            })
        ])
        self.present(alert, in: .window(.root))
    }

    func exteralessRepeat(_ messages: [EngineRawMessage], asCopy: Bool = false) {
        guard !messages.isEmpty, self.chatLocation.peerId != nil,
              canSendMessagesToChat(self.presentationInterfaceState),
              !self.presentationInterfaceState.copyProtectionEnabled,
              messages.allSatisfy({ !$0.isCopyProtected() }) else { return }
        let location = self.chatLocation
        let send: () -> Void = { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil, self.chatLocation == location, canSendMessagesToChat(self.presentationInterfaceState),
                  !self.presentationInterfaceState.copyProtectionEnabled else { return }
            if self.presentationInterfaceState.slowmodeState != nil && self.presentationInterfaceState.subject != .scheduledMessages {
                self.present(textAlertController(context: self.context, title: nil, text: "Slow mode is active. Try again when the countdown ends.", actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            self.presentPaidMessageAlertIfNeeded(count: Int32(clamping: messages.count), completion: { [weak self] postpone in
                guard let self, self.viewIfLoaded?.window != nil, self.chatLocation == location, canSendMessagesToChat(self.presentationInterfaceState) else { return }
                let enqueued = messages.map { message in
                    EnqueueMessage.forward(source: message.id, threadId: self.chatLocation.threadId, grouping: .auto, attributes: [ForwardOptionsMessageAttribute(hideNames: asCopy, hideCaptions: false)], correlationId: nil)
                }
                // Native transformations preserve send-as, stars/postponement, scheduling and hooks.
                self.sendMessages(enqueued, postpone: postpone)
            })
        }
        if ClientSettings.shared.bool("chats.repeatConfirm", default: true) {
            self.present(textAlertController(context: self.context, title: "Repeat message?", text: asCopy ? "Send a copy without the original sender's name to this chat?" : "Forward this message to this chat?", actions: [
                TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: send)
            ]), in: .window(.root))
        } else {
            send()
        }
    }
}

final class ExteralessMessageDetailsController: ExteralessChatTableController {
    init(context: AccountContext, message: EngineMessage) {
        super.init(context: context, title: "Message details")
        var rows: [ExteralessChatRow] = []
        func add(_ id: String, _ title: String, _ value: String) {
            rows.append(ExteralessChatRow(id: "messageDetails." + id, title: title, detail: value, action: {
                UIPasteboard.general.string = value
                UIAccessibility.post(notification: .announcement, argument: "Copied")
            }))
        }
        let raw = message._asMessage()
        add("messageId", "Message ID", String(message.id.id))
        add("peerId", "Peer ID", String(message.id.peerId.id._internalGetInt64Value()))
        add("nativePeerKey", "Native peer key", String(message.id.peerId.toInt64()))
        if let author = raw.author { add("senderId", "Sender ID", String(author.id.id._internalGetInt64Value())) }
        if let thread = raw.threadId { add("threadId", "Thread ID", String(thread)) }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        func date(_ timestamp: Int32) -> String { formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp))) }
        add("date", "Sent", date(message.timestamp))
        if let forward = raw.forwardInfo { add("forwardedDate", "Original sent date", date(forward.date)) }
        for attribute in raw.attributes {
            if let edited = attribute as? EditedMessageAttribute, !edited.isHidden { add("editedDate", "Edited", date(edited.date)) }
            if let views = attribute as? ViewCountMessageAttribute { add("views", "Views", String(views.count)) }
        }
        for (index, media) in raw.effectiveMedia.enumerated() {
            if let file = media as? TelegramMediaFile {
                let prefix = "media\(index)."
                add(prefix + "id", "File ID", String(file.fileId.id))
                if let name = file.fileName { add(prefix + "name", "File name", name) }
                add(prefix + "mime", "MIME type", file.mimeType)
                if let size = file.size { add(prefix + "size", "Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                for attribute in file.attributes {
                    switch attribute {
                    case let .Video(duration, size, _, _, _, _):
                        add(prefix + "duration", "Duration", String(duration) + " s")
                        add(prefix + "dimensions", "Dimensions", "\(size.width) × \(size.height)")
                    case let .Audio(_, duration, title, performer, _):
                        add(prefix + "duration", "Duration", String(duration) + " s")
                        if let title { add(prefix + "title", "Title", title) }
                        if let performer { add(prefix + "performer", "Performer", performer) }
                    default: break
                    }
                }
            } else if let image = media as? TelegramMediaImage, let representation = image.representations.max(by: { $0.dimensions.width < $1.dimensions.width }) {
                add("image\(index).dimensions", "Dimensions", "\(representation.dimensions.width) × \(representation.dimensions.height)")
            }
        }
        self.sections = [ExteralessChatSection(footer: "Tap a value to copy it. Metadata comes from the message already available to this account.", rows: rows)]
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
