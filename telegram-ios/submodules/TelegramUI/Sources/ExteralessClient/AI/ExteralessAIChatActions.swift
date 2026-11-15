import AccountContext
import BrowserUI
import ChatMessageBubbleItemNode
import ChatMessageItemView
import ChatMessageRichDataBubbleContentNode
import ChatPresentationInterfaceState
import ContextUI
import Display
import ExteralessCore
import Foundation
import TelegramCore
import TextFormat
import UIKit

func exteralessAIEffectiveAutomaticLanguage(state: ChatPresentationInterfaceState) -> String? {
    let peerAutoTranslate = (state.renderedPeer?.chatMainPeer as? TelegramChannel)?.flags.contains(.autoTranslateEnabled) ?? false
    return AINativeTranslationTarget.resolve(isEnabled: state.translationState?.isEnabled == true, toLanguage: state.translationState?.toLang, appLanguage: state.strings.baseLanguageCode, isPremium: state.isPremium, peerAutoTranslate: peerAutoTranslate, policy: AITranslationPolicy())
}

@MainActor
func exteralessAIDisplayedRichPage(message: EngineMessage, messageNode: ChatMessageItemView?) -> InstantPage? {
    guard let bubble = messageNode as? ChatMessageBubbleItemNode else { return nil }
    for node in bubble.contentNodes {
        if let rich = node as? ChatMessageRichDataBubbleContentNode,
           let page = rich.exteralessAIDisplayedPage(messageId: message.id, stableVersion: message.stableVersion) { return page }
    }
    return nil
}

/// The only remaining common-file work is calling these adapters at the two
/// insertion points in docs/wave-2/ai.md. All chat state access lives here.
extension ChatControllerImpl {
    @MainActor
    func exteralessAIContextItems(message: EngineMessage) -> [ContextMenuItem] {
        exteralessAIObserveSettings()
        let raw = message._asMessage()
        guard ExteralessAIEntry.textActions != nil,
              !presentationInterfaceState.copyProtectionEnabled, !raw.isCopyProtected(),
              !raw.containsSecretMedia, raw.id.peerId.namespace != Namespaces.Peer.SecretChat,
              message.adAttribute == nil, !raw.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) else { return [] }
        let selected = exteralessAIVisibleText(message: message)
        let policy = AITranslationPolicy()
        var items: [ContextMenuItem] = []
        if !selected.text.isEmpty {
            items.append(.action(ContextMenuActionItem(text: "AI Text Actions", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, complete in
                let present: () -> Void = { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        let expected = self.presentationInterfaceState.interfaceState.effectiveInputState
                        let visible = self.exteralessAIVisibleText(message: message)
                        let input = ExteralessAITextInput(text: visible.text, entities: visible.entities, messageId: message.id, contextMessageIds: self.exteralessAIReplyIds(message: raw), capability: self.exteralessAISelectionCapability(message: raw, canCopy: true), applyResult: { [weak self] result in
                            self?.exteralessAIInsert(result, expected: expected, replacing: nil) ?? false
                        })
                        self.chatDisplayNode.dismissInput()
                        ExteralessAIEntry.textActions?(self.context, self, input)
                    }
                }
                if let controller { controller.dismiss(completion: present) }
                else { complete(.default); present() }
            })))
        }
        if policy.showMessageTranslate && (!selected.text.isEmpty || raw.media.contains { $0 is TelegramMediaPoll }) {
            let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: exteralessAIAutomaticLanguage, isSummarized: controllerInteraction?.summarizedMessageIds.contains(message.id) == true)
            items.append(.action(ContextMenuActionItem(text: display.selection.canHideManual ? "Hide translation" : "Translate in chat", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, complete in
                let present: () -> Void = { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated { ExteralessAIEntry.translateMessage?(self.context, self, message, self.exteralessAIAutomaticLanguage, self.controllerInteraction?.summarizedMessageIds.contains(message.id) == true) }
                }
                if let controller { controller.dismiss(completion: present) } else { complete(.default); present() }
            })))
        }
        if policy.showLLMTranslate && !selected.text.isEmpty {
            items.append(.action(ContextMenuActionItem(text: "Translate with LLM", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, complete in
                let present: () -> Void = { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        let visible = self.exteralessAIVisibleText(message: message)
                        ExteralessAIEntry.translateWithLLM?(self.context, self, .init(text: visible.text, entities: visible.entities, messageId: message.id, contextMessageIds: self.exteralessAIReplyIds(message: raw), capability: self.exteralessAISelectionCapability(message: raw, canCopy: true)))
                    }
                }
                if let controller { controller.dismiss(completion: present) } else { complete(.default); present() }
            })))
        }
        if let file = raw.effectiveMedia.compactMap({ $0 as? TelegramMediaFile }).first(where: { $0.isVoice || $0.isInstantVideo }), ExteralessAIEntry.transcribe != nil {
            items.append(.action(ContextMenuActionItem(text: "Transcribe with selected provider", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, complete in
                let present: () -> Void = { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated { ExteralessAIEntry.transcribe?(self.context, self, message.id, file) }
                }
                if let controller { controller.dismiss(completion: present) }
                else { complete(.default); present() }
            })))
        }
        if !presentationInterfaceState.interfaceState.effectiveInputState.isEmpty {
            items.append(.action(ContextMenuActionItem(text: "AI Draft Actions", icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, complete in
                let present: () -> Void = { [weak self] in
                    MainActor.assumeIsolated { self?.exteralessAIPresentDraft() }
                }
                if let controller { controller.dismiss(completion: present) }
                else { complete(.default); present() }
            })))
        }
        return items
    }

    /// Called from the existing .translate selection branch. `text` already is
    /// the user's selection and its entities are relative to that selection.
    @MainActor
    func exteralessAITranslateSelection(message: EngineRawMessage?, canCopy: Bool, text: NSAttributedString, entities: [MessageTextEntity]?) -> Bool {
        let capability = exteralessAISelectionCapability(message: message, canCopy: canCopy)
        guard capability.allowsExternalProcessing, !text.string.isEmpty, ExteralessAIEntry.translate != nil else { return false }
        let expected = presentationInterfaceState.interfaceState.effectiveInputState
        let input = ExteralessAITextInput(text: text.string, entities: entities ?? generateChatInputTextEntities(text), messageId: message?.id, chatId: chatLocation.peerId, contextMessageIds: message.map { self.exteralessAIReplyIds(message: $0) } ?? [], capability: capability, applyResult: { [weak self] result in
            self?.exteralessAIInsert(result, expected: expected, replacing: nil) ?? false
        })
        let present: () -> Void = { [weak self] in
            guard let self else { return }
            self.chatDisplayNode.dismissInput()
            ExteralessAIEntry.translate?(self.context, self, input)
        }
        if let controller = currentContextController { controller.dismiss(completion: present) }
        else { present() }
        return true
    }

    @MainActor
    func exteralessAISpeakSelection(message: EngineRawMessage?, canCopy: Bool, text: String) -> Bool {
        guard !text.isEmpty, ExteralessAIEntry.speak != nil else { return false }
        let present: () -> Void = { [weak self] in
            guard let self else { return }
            ExteralessAIEntry.speak?(self.context, self, .init(text: text, messageId: message?.id, capability: self.exteralessAISelectionCapability(message: message, canCopy: canCopy)))
        }
        if let controller = currentContextController { controller.dismiss(completion: present) }
        else { present() }
        return true
    }

    @MainActor
    func exteralessAIPresentDraft() {
        let expected = presentationInterfaceState.interfaceState.effectiveInputState
        guard !expected.isEmpty else { return }
        let range = expected.selectionRange.isEmpty ? NSRange(location: 0, length: expected.content.length) : NSRange(location: expected.selectionRange.lowerBound, length: expected.selectionRange.count)
        let plain: String
        let entities: [MessageTextEntity]
        let selectedRange: NSRange?
        if expected.selectionRange.isEmpty && !expected.content.isEntityExpressible() {
            plain = markdownStringFromInstantPage(instantPage(from: expected.content))
            entities = []
            selectedRange = nil
        } else {
            let inputText = expected.inputText
            plain = inputText.string
            entities = generateChatInputTextEntities(inputText)
            selectedRange = range
        }
        let input = ExteralessAITextInput(text: plain, entities: entities, selectedRange: selectedRange, chatId: chatLocation.peerId, applyResult: { [weak self] result in
            self?.exteralessAIInsert(result, expected: expected, replacing: range) ?? false
        })
        chatDisplayNode.dismissInput()
        ExteralessAIEntry.textActions?(context, self, input)
    }

    @MainActor
    private func exteralessAIInsert(_ result: ExteralessAIInsertion, expected: ChatTextInputState, replacing range: NSRange?) -> Bool {
        guard canSendMessagesToChat(presentationInterfaceState), presentationInterfaceState.interfaceState.effectiveInputState == expected else { return false }
        let range = range ?? NSRange(location: expected.selectionRange.lowerBound, length: expected.selectionRange.count)
        let fragment = result.attributedText()
        var applied = false
        updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            state.updatedInterfaceState { state in
                guard state.effectiveInputState == expected else { return state }
                applied = true
                return state.withUpdatedEffectiveInputState(state.effectiveInputState.replacingFlatRange(range, with: fragment))
            }
        })
        return applied
    }

    private func exteralessAIReplyIds(message: EngineRawMessage) -> [EngineMessage.Id] {
        message.attributes.compactMap { ($0 as? ReplyMessageAttribute)?.messageId }
    }

    @MainActor
    func exteralessAISelectionCapability(message: EngineRawMessage?, canCopy: Bool) -> ExteralessAIProcessingCapability {
        let copy = canCopy && !presentationInterfaceState.copyProtectionEnabled && message?.isCopyProtected() != true && message?.containsSecretMedia != true
        return ExteralessAIProcessingCapability(messageId: message?.id, expectedStableVersion: message?.stableVersion, peerId: message?.id.peerId ?? chatLocation.peerId, threadId: message?.threadId, allowsExternalProcessing: copy && (message?.id.peerId ?? chatLocation.peerId)?.namespace != Namespaces.Peer.SecretChat, allowsCopy: copy)
    }

    @MainActor
    var exteralessAIAutomaticLanguage: String? {
        exteralessAIEffectiveAutomaticLanguage(state: presentationInterfaceState)
    }

    @MainActor
    func exteralessAIVisibleText(message: EngineMessage) -> (text: String, entities: [MessageTextEntity]) {
        let raw = message._asMessage()
        if let restricted = raw.attributes.first(where: { $0 is RestrictedContentMessageAttribute }) as? RestrictedContentMessageAttribute,
           let restrictedText = restricted.platformText(platform: "ios", contentSettings: context.currentContentSettings.with({ $0 })) {
            return (restrictedText, [])
        }
        var displayedPage: InstantPage?
        if isNodeLoaded {
            chatDisplayNode.historyNode.forEachItemNode { node in
                if displayedPage == nil { displayedPage = exteralessAIDisplayedRichPage(message: message, messageNode: node as? ChatMessageItemView) }
            }
        }
        let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: exteralessAIAutomaticLanguage, isSummarized: controllerInteraction?.summarizedMessageIds.contains(message.id) == true, displayedRichPage: displayedPage)
        return (display.page.map { markdownStringFromInstantPage($0) } ?? display.text, display.entities)
    }
}
