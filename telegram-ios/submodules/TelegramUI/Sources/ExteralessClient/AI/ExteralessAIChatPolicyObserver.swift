import AccountContext
import ChatMessageItemView
import Display
import ExteralessCore
import Foundation

@MainActor
private final class ExteralessAIChatPolicyObserver {
    weak var controller: ChatControllerImpl?
    private var observation: ClientSettingsObservation?
    init(controller: ChatControllerImpl) {
        self.controller = controller
        let stateKey = "ai.manualTranslations." + String(controller.context.account.id.int64)
        observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.contains(stateKey) || keys.contains("ai.translatorMode") || keys.contains("ai.telegramUIAutoTranslate") || keys.contains("ai.translationProvider") || keys.contains("ai.transcribeProvider") || keys.contains(AINativeVisibilityPolicy.editorKey) || keys.contains(AINativeVisibilityPolicy.messageSummaryKey) else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
    private func refresh() {
        guard let controller, controller.isNodeLoaded else { return }
        controller.chatDisplayNode.historyNode.forEachItemNode { node in
            if let item = (node as? ChatMessageItemView)?.item {
                let _ = controller.controllerInteraction?.requestMessageUpdate(item.message.id, false, nil)
            }
        }
        controller.updateChatPresentationInterfaceState(transition: .immediate, interactive: false, force: true, { $0 })
    }
    deinit { observation?.cancel() }
}

@MainActor
private enum ExteralessAIChatObservers {
    static var values: [ObjectIdentifier: ExteralessAIChatPolicyObserver] = [:]
    static func register(_ controller: ChatControllerImpl) {
        values = values.filter { $0.value.controller != nil }
        let id = ObjectIdentifier(controller)
        if values[id] == nil { values[id] = ExteralessAIChatPolicyObserver(controller: controller) }
    }
}

extension ChatControllerImpl {
    @MainActor func exteralessAIObserveSettings() { ExteralessAIChatObservers.register(self) }
}
