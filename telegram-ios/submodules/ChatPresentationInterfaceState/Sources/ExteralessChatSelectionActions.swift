import TelegramCore
import UIKit

/// Implemented by the real chat controller; reachable through the existing chatController closure.
public protocol ExteralessChatSelectionActions: AnyObject {
    func exteralessPresentSelectionActions(ids: Set<EngineMessage.Id>, source: UIView)
    func exteralessPerformLeftSelectionAction(ids: Set<EngineMessage.Id>)
    func exteralessPresentChatActions()
}
