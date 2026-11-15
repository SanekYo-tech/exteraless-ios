import Display
import ExteralessCore
import Foundation
import TelegramCore

extension ChatControllerImpl {
    func updateExteralessDialogHistoryControls(policy: DialogPolicy) {
        self.chatDisplayNode.navigateButtons.downButton.isGestureEnabled = policy.rememberAllBackMessages
        self.chatDisplayNode.navigateButtons.downButton.activated = { [weak self] gesture, _ in
            gesture.cancel()
            guard let self, self.isNodeLoaded, exteralessDialogPolicy().rememberAllBackMessages else { return }
            self.contentData?.historyNavigationStack.removeAll()
            // The normal down action retains search/unread/end-of-history rules.
            self.chatDisplayNode.navigateButtons.downPressed?()
        }
    }
}
