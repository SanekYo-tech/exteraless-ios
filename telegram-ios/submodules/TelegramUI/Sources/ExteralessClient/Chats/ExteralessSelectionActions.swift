import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import ChatRichTextEditorComposer
import ContextUI
import Display
import ExteralessCore
import Foundation
import Pasteboard
import SwiftSignalKit
import TelegramCore
import TextFormat
import UIKit

extension ChatControllerImpl: ExteralessChatSelectionActions {
    private func exteralessLoadSelection(_ ids: Set<EngineMessage.Id>, apply: @escaping (ChatControllerImpl, ExteralessSelectionActionSession, ExteralessChatExportSnapshot, ChatAvailableMessageActions) -> Void) {
        guard !ids.isEmpty, ids.count <= 100, self.presentationInterfaceState.interfaceState.selectionState?.selectedIds == ids else { return }
        let context = self.context
        let access = self.exteralessSelectionExportAccess(ids: ids)
        let session = ExteralessSelectionActionSession(access: access, actions: { keepUpdated in context.sharedContext.chatAvailableMessageActions(engine: context.engine, accountPeerId: context.account.peerId, messageIds: ids, keepUpdated: keepUpdated) })
        session.read(requiresCopy: false, operation: .presentation) { [weak self] snapshot, actions in
            guard let self else { return }
            apply(self, session, snapshot, actions)
        }
    }

    public func exteralessPresentSelectionActions(ids: Set<EngineMessage.Id>, source: UIView) {
        self.exteralessLoadSelection(ids) { chat, session, snapshot, actions in
            let messages = snapshot.messages.map { $0._asMessage() }
            var items: [ActionSheetItem] = []
            let sheet = ActionSheetController(presentationData: chat.presentationData)
            func add(_ field: String?, _ title: String, allowed: Bool = true, export: ExteralessSelectionExportAction? = nil, eligible: @escaping (ChatControllerImpl, [EngineRawMessage], ChatAvailableMessageActions) -> Bool = { _, _, _ in true }, _ action: @escaping (ChatControllerImpl, [EngineRawMessage]) -> Void) {
                guard allowed, field.map({ ChatMenuPolicy.enabled($0) }) ?? true else { return }
                let perform = session.action(requiresCopy: export != nil, operation: export != nil ? .exportEffect : .presentation, allowed: { [weak chat] current, available in
                    guard let chat, field.map({ ChatMenuPolicy.enabled($0) }) ?? true else { return false }
                    return (export?.isAvailable(current, available) ?? true) && eligible(chat, current.messages.map { $0._asMessage() }, available)
                }, { [weak chat] current, _ in
                    guard let chat else { return }
                    action(chat, current.messages.map { $0._asMessage() })
                })
                items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    perform()
                }))
            }
            let canCopy = snapshot.canCopy && !actions.isCopyProtected
            let canForward = canCopy && actions.options.contains(.forward)
            add("ActionBarButtonCopy", "Copy", allowed: ExteralessSelectionExportAction.copy.isAvailable(snapshot, actions), export: .copy) { chat, messages in
                if let first = messages.first, let rich = first.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute {
                    UIPasteboard.general.items = [richMessagePasteboardItem(fromInstantPage: rich.instantPage)]
                } else { storeInputTextInPasteboard(chat.exteralessCombinedText(messages, separator: "\n\n")) }
                session.access.cancel()
            }
            if let first = messages.first {
                let canReply: Bool
                if let interaction = chat.controllerInteraction, case .reply = interaction.canSetupReply(first) { canReply = true } else { canReply = false }
                add("ActionBarButtonReply", "Reply", allowed: messages.count == 1 && canReply, eligible: { chat, messages, _ in
                    guard messages.count == 1, let first = messages.first, let interaction = chat.controllerInteraction, case .reply = interaction.canSetupReply(first) else { return false }
                    return true
                }) { chat, messages in
                    guard let first = messages.first else { return }
                    session.access.cancel()
                    chat.interfaceInteraction?.cancelMessageSelection(.immediate)
                    chat.controllerInteraction?.setupReply(first.id)
                }
                add("ActionBarButtonEdit", "Edit", allowed: messages.count == 1 && canEditMessage(context: chat.context, limitsConfiguration: chat.context.currentLimitsConfiguration.with { EngineConfiguration.Limits($0) }, message: first), eligible: { chat, messages, _ in
                    guard messages.count == 1, let first = messages.first else { return false }
                    return canEditMessage(context: chat.context, limitsConfiguration: chat.context.currentLimitsConfiguration.with { EngineConfiguration.Limits($0) }, message: first)
                }) { chat, messages in
                    guard let first = messages.first else { return }
                    session.access.cancel()
                    chat.interfaceInteraction?.cancelMessageSelection(.immediate)
                    chat.interfaceInteraction?.setupEditMessage(first.id, { _ in })
                }
            }
            add("ActionBarButtonForward", "Forward", allowed: canForward, export: .forward) { chat, messages in chat.forwardMessages(messages: messages, resetCurrent: false, exportAccess: session.access) }
            add("showNoQuoteForward", "Forward without sender", allowed: canForward, export: .forward) { chat, messages in chat.exteralessForwardWithoutNames(messages, hideCaptions: false, exportAccess: session.access) }
            add("ActionBarButtonSelectBetween", "Select between", allowed: messages.count >= 2, eligible: { _, messages, _ in messages.count >= 2 }) { chat, messages in session.access.cancel(); chat.exteralessSelectBetween(messages) }
            add(nil, "Combine into draft", allowed: ExteralessSelectionExportAction.combine.isAvailable(snapshot, actions), export: .combine) { chat, _ in chat.exteralessCombineIntoDraft(session) }
            guard !items.isEmpty else { return }
            sheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [ActionSheetButtonItem(title: chat.presentationData.strings.Common_Cancel, color: .accent, action: { [weak sheet] in session.access.cancel(); sheet?.dismissAnimated() })])])
            guard session.access.own(sheet, presented: true) else { return }
            chat.present(sheet, in: .window(.root))
        }
    }

    public func exteralessPerformLeftSelectionAction(ids: Set<EngineMessage.Id>) {
        self.exteralessLoadSelection(ids) { chat, session, snapshot, actions in
            let messages = snapshot.messages.map { $0._asMessage() }
            let canForward = actions.options.contains(.forward) && !actions.isCopyProtected && snapshot.canCopy
            let action = ChatMenuPolicy.leftAction(rawValue: ClientSettings.shared.integer("chats.leftBottomButton"), canForward: canForward, canSelectBetween: messages.count >= 2)
            let perform = session.action(requiresCopy: ![1, 4].contains(action), operation: [1, 4].contains(action) ? .presentation : .exportEffect, allowed: { _, available in [1, 4].contains(action) || available.options.contains(.forward) }) { [weak chat] snapshot, _ in
                guard let chat else { return }
                let messages = snapshot.messages.map { $0._asMessage() }
                switch action {
                case 0: chat.exteralessForwardWithoutNames(messages, hideCaptions: false, exportAccess: session.access)
                case 1:
                    guard let first = messages.first, let interaction = chat.controllerInteraction, case .reply = interaction.canSetupReply(first) else { return }
                    session.access.cancel()
                    chat.interfaceInteraction?.cancelMessageSelection(.immediate)
                    chat.controllerInteraction?.setupReply(first.id)
                case 2:
                    let enqueued = messages.map { EnqueueMessage.forward(source: $0.id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil) }
                    session.access.add((exteralessForwardExportSignal(context: chat.context, access: session.access, { enqueueMessages(account: chat.context.account, peerId: chat.context.account.peerId, messages: enqueued) }) |> deliverOnMainQueue).start(next: { ids in
                        if session.access.isCurrent, ids.contains(where: { $0 != nil }) { chat.controllerInteraction?.displayUndo(.forward(savedMessages: true, text: "Saved to Saved Messages")) }
                        session.access.cancel()
                    }))
                case 3:
                    let controller = chat.context.sharedContext.makeShareScreen(context: chat.context, params: ShareControllerParams(subject: .messages(messages)))
                    guard session.access.own(controller) else { return }
                    session.access.permit.presentWhenReady(controller, accountId: chat.context.account.id.int64, from: chat, requiresExport: true, present: { [weak chat] controller in
                        session.read(requiresCopy: true, operation: .presentation) { _, _ in
                            guard session.access.handoffNativeExport(to: controller) else { return }
                            chat?.present(controller, in: .window(.root))
                        }
                    })
                case 4: session.access.cancel(); chat.exteralessSelectBetween(messages)
                case 5: chat.exteralessForwardWithoutNames(messages, hideCaptions: true, exportAccess: session.access)
                default: break
                }
            }
            perform()
        }
    }

    func exteralessForwardWithoutNames(_ messages: [EngineRawMessage], hideCaptions: Bool, exportAccess: ExteralessChatExportAccess? = nil) {
        let access = exportAccess ?? self.exteralessSelectionExportAccess(ids: Set(messages.map(\.id)), expected: messages.map(EngineMessage.init), requireSelection: false)
        access.perform(operation: .exportPreparation) { [weak self] snapshot in
            self?.forwardMessages(messages: snapshot.messages.map { $0._asMessage() }, options: ChatInterfaceForwardOptionsState(hideNames: true, hideCaptions: hideCaptions, unhideNamesOnCaptionChange: false), resetCurrent: false, exportAccess: access)
        }
    }

    private func exteralessSelectBetween(_ messages: [EngineRawMessage]) {
        guard let first = messages.first, let last = messages.last, first.id.peerId == last.id.peerId else { return }
        var ids: [EngineMessage.Id] = []
        self.chatDisplayNode.historyNode.forEachMessageInCurrentHistoryView { message in
            if message.id.peerId == first.id.peerId, message.index >= first.index, message.index <= last.index { ids.append(message.id) }
            return ids.count < 100
        }
        self.controllerInteraction?.toggleMessagesSelection(ids, true)
    }

    private func exteralessCombinedText(_ messages: [EngineRawMessage], separator: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let punctuation = CharacterSet(charactersIn: ",.!?:;()，。！？：；（）")
        let languageCode: String?
        if #available(iOS 16.0, *) { languageCode = Locale.current.language.languageCode?.identifier }
        else { languageCode = Locale.current.languageCode }
        for message in messages {
            if result.length > 0 {
                if let separator { result.append(NSAttributedString(string: separator)) }
                else if let last = result.string.unicodeScalars.last, !punctuation.contains(last) {
                    result.append(NSAttributedString(string: languageCode == "zh" ? "，" : ","))
                }
            }
            result.append(chatInputStateStringWithAppliedEntities(message.text, entities: message.textEntitiesAttribute?.entities ?? []))
        }
        return result
    }

    private func exteralessCombineIntoDraft(_ session: ExteralessSelectionActionSession) {
        let existing = self.presentationInterfaceState.interfaceState.effectiveInputState
        let apply = { [weak self] in
            session.read(requiresCopy: true, operation: .exportEffect) { [weak self] snapshot, actions in
                guard let self, self.presentationInterfaceState.interfaceState.effectiveInputState == existing else { return }
                let messages = snapshot.messages.map { $0._asMessage() }
                guard ExteralessSelectionExportAction.combine.isAvailable(snapshot, actions) else { session.access.invalidate(); return }
                let text = self.exteralessCombinedText(messages, separator: nil)
                session.access.cancel()
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                    state.updatedInterfaceState { state in
                        var result = state.withoutSelectionState().withUpdatedEffectiveInputState(ChatTextInputState(inputText: text))
                        if ClientSettings.shared.integer("chats.combineMessage") == 0, let reply = messages.first?.attributes.compactMap({ $0 as? ReplyMessageAttribute }).first {
                            result = result.withUpdatedReplyMessageSubject(.init(messageId: reply.messageId, quote: nil, innerSubject: nil))
                        } else { result = result.withUpdatedReplyMessageSubject(nil) }
                        return result
                    }
                })
            }
        }
        if existing.isEmpty { apply() }
        else {
            let controller = textAlertController(context: self.context, title: "Replace draft?", text: "The selected messages will be combined into an editable draft.", actions: [TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: { session.access.cancel() }), TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: apply)])
            guard session.access.own(controller, presented: true) else { return }
            self.present(controller, in: .window(.root))
        }
    }
}
