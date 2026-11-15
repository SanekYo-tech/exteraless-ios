import AccountContext
import ChatMessageDateAndStatusNode
import ChatPresentationInterfaceState
import Display
import ExteralessCore
import Foundation
import SaveToCameraRoll
import SwiftSignalKit
import TelegramCore
import UIKit

extension ChatControllerNode: ExteralessChatMessageActionHost {
    func exteralessPerformMessageAction(message: EngineMessage, action: Int) {
        guard let chat = self.interfaceInteraction?.chatController() as? ChatControllerImpl,
              let action = ChatDoubleTapAction(rawValue: action) else { return }
        chat.exteralessPerformDoubleTapAction(message: message, action: action)
    }
}

extension ChatControllerImpl {
    func exteralessPerformDoubleTapAction(message: EngineMessage, action: ChatDoubleTapAction) {
        guard self.viewIfLoaded?.window != nil else { return }
        let location = self.chatLocation
        guard location.peerId?.namespace != Namespaces.Peer.SecretChat,
              message.id.namespace == Namespaces.Message.Cloud,
              message.adAttribute == nil,
              self.presentationInterfaceState.interfaceState.selectionState == nil else { return }
        switch self.presentationInterfaceState.subject {
        case .none, .some(.message): break
        default: return
        }
        guard let group = self.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(message.id),
              group.contains(where: { $0.id == message.id }) else { return }
        let ids = Set(group.map(\.id))
        let _ = (self.context.sharedContext.chatAvailableMessageActions(engine: self.context.engine, accountPeerId: self.context.account.peerId, messageIds: ids, keepUpdated: false)
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] capabilities in
            guard let self, self.viewIfLoaded?.window != nil, self.chatLocation == location,
                  let current = self.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(message.id),
                  Set(current.map(\.id)) == ids,
                  let raw = current.first(where: { $0.id == message.id }) else { return }
            let canUseContent = !self.presentationInterfaceState.copyProtectionEnabled && !capabilities.isCopyProtected && current.allSatisfy {
                !$0.isCopyProtected() && !$0.containsSecretMedia && $0.adAttribute == nil && !$0.media.contains { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }
            }
            func unavailable() {
                self.controllerInteraction?.displayMessageTooltip(raw.id, "This action is unavailable for this message.", false, nil, nil)
            }
            switch action {
            case .disabled: break
            case .quickReaction, .reactions, .reply:
                // These are handled at the original gesture node, where native eligibility lives.
                break
            case .translate:
                guard canUseContent else { unavailable(); return }
                MainActor.assumeIsolated {
                    let automaticLanguage = self.presentationInterfaceState.translationState.flatMap { $0.isEnabled ? $0.toLang : nil }
                    let isSummarized = self.controllerInteraction?.summarizedMessageIds.contains(raw.id) == true
                    if exteralessPresentMessageTranslationSheet(context: self.context, from: self, message: EngineMessage(raw), automaticLanguage: automaticLanguage, isSummarized: isSummarized) { return }
                    if let translate = ExteralessAIEntry.translateMessage { translate(self.context, self, EngineMessage(raw), automaticLanguage, isSummarized) }
                    else { unavailable() }
                }
            case .translateLLM:
                guard canUseContent else { unavailable(); return }
                MainActor.assumeIsolated {
                    guard let translate = ExteralessAIEntry.translateWithLLM else { unavailable(); return }
                    let selected = self.exteralessAIVisibleText(message: EngineMessage(raw))
                    guard !selected.text.isEmpty else { unavailable(); return }
                    let input = ExteralessAITextInput(text: selected.text, entities: selected.entities, messageId: raw.id, chatId: raw.id.peerId, contextMessageIds: raw.attributes.compactMap { ($0 as? ReplyMessageAttribute)?.messageId })
                    translate(self.context, self, input)
                }
            case .save:
                guard canUseContent, capabilities.options.contains(.forward), raw.id.peerId != self.context.account.peerId else { unavailable(); return }
                self.exteralessSaveToSavedMessages(current)
            case .repeatMessage, .repeatAsCopy:
                guard canUseContent, capabilities.options.contains(.forward) else { unavailable(); return }
                self.exteralessRepeat(current, asCopy: action == .repeatAsCopy)
            case .edit:
                guard canEditMessage(context: self.context, limitsConfiguration: self.context.currentLimitsConfiguration.with { EngineConfiguration.Limits($0) }, message: raw),
                      self.presentationInterfaceState.interfaceState.mediaDraftState == nil else { unavailable(); return }
                if raw.media.contains(where: { $0 is TelegramMediaTodo }) { self.interfaceInteraction?.editTodoMessage(raw.id, nil, false) }
                else { self.interfaceInteraction?.setupEditMessage(raw.id, { _ in }) }
            case .delete:
                guard !capabilities.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty, !capabilities.disableDelete else { unavailable(); return }
                self.interfaceInteraction?.deleteMessages(current, nil, { _ in })
            case .forward:
                guard canUseContent, capabilities.options.contains(.forward) else { unavailable(); return }
                self.interfaceInteraction?.forwardMessages(current)
            case .download:
                guard canUseContent, raw.paidContent == nil else { unavailable(); return }
                self.exteralessSaveToDevice(raw)
            }
        })
    }

    func exteralessSaveToSavedMessages(_ messages: [EngineRawMessage]) {
        guard !self.presentationInterfaceState.copyProtectionEnabled,
              messages.allSatisfy({ !$0.isCopyProtected() && !$0.containsSecretMedia && $0.id.namespace == Namespaces.Message.Cloud }) else { return }
        let enqueued = messages.map { EnqueueMessage.forward(source: $0.id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil) }
        let _ = (enqueueMessages(account: self.context.account, peerId: self.context.account.peerId, messages: enqueued)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] ids in
            guard let self, self.viewIfLoaded?.window != nil, ids.contains(where: { $0 != nil }) else { return }
            self.controllerInteraction?.displayUndo(.forward(savedMessages: true, text: "Saved to Saved Messages"))
        })
    }

    func exteralessSaveToDevice(_ message: EngineRawMessage) {
        guard !message.containsSecretMedia, !message.isCopyProtected(), message.paidContent == nil, !self.presentationInterfaceState.copyProtectionEnabled else { return }
        if let file = message.effectiveMedia.compactMap({ $0 as? TelegramMediaFile }).first {
            if !file.isMusic {
                self.present(self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: .media(FileMediaReference.message(message: MessageReference(message), media: file).abstract, nil), externalShare: true, immediateExternalShare: true)), in: .window(.root))
                return
            }
            let disposable = self.saveMediaDisposable ?? MetaDisposable()
            self.saveMediaDisposable = disposable
            disposable.set(saveMediaToFiles(context: self.context, fileReference: .message(message: MessageReference(message), media: file), present: { [weak self] controller, arguments in
                self?.present(controller, in: .window(.root), with: arguments)
            }))
        } else if let image = message.effectiveMedia.compactMap({ $0 as? TelegramMediaImage }).first {
            let disposable = self.saveMediaDisposable ?? MetaDisposable()
            self.saveMediaDisposable = disposable
            disposable.set((saveToCameraRoll(context: self.context, userLocation: .peer(message.id.peerId), mediaReference: ImageMediaReference.message(message: MessageReference(message), media: image).abstract)
            |> deliverOnMainQueue).start(completed: { [weak self] in
                self?.controllerInteraction?.displayUndo(.mediaSaved(text: "Image saved"))
            }))
        } else {
            self.controllerInteraction?.displayMessageTooltip(message.id, "No downloadable media in this message.", false, nil, nil)
        }
    }
}
