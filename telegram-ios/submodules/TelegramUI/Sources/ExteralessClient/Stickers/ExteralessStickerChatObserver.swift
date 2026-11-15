import ChatMessageItemView
import Display
import ExteralessCore
import Foundation

/// Held by its ChatController through the coordinator's insertion hunk. Visible
/// messages are remeasured using the existing history path; message data/drafts
/// are not rewritten when a display preference or font changes.
@MainActor
final class ExteralessStickerChatObserver {
    private weak var controller: ChatControllerImpl?
    private var settings: ClientSettingsObservation?
    private var fontObserver: NSObjectProtocol?

    init(controller: ChatControllerImpl) {
        self.controller = controller
        self.settings = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || !keys.isDisjoint(with: ["chats.stickerSize", "chats.dontSendGreetingSticker"]) else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.fontObserver = NotificationCenter.default.addObserver(forName: StickerFeatures.emojiChangedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        guard let controller, controller.isNodeLoaded else { return }
        controller.chatDisplayNode.historyNode.forEachItemNode { node in
            if let item = (node as? ChatMessageItemView)?.item {
                controller.controllerInteraction?.requestMessageUpdate(item.message.id, false, nil)
            }
        }
        controller.updateChatPresentationInterfaceState(transition: .immediate, interactive: false, force: true, { $0 })
    }

    deinit {
        self.settings?.cancel()
        if let observer = self.fontObserver { NotificationCenter.default.removeObserver(observer) }
    }
}
