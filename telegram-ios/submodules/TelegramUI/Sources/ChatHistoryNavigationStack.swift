import Foundation
import UIKit
import TelegramCore
import ExteralessCore

struct ChatHistoryNavigationStack {
    private var messageIndices = DialogHistoryStack<EngineMessage.Index>()
    
    mutating func add(_ index: EngineMessage.Index) {
        self.messageIndices.add(index, rememberAll: exteralessDialogPolicy().rememberAllBackMessages)
    }
    
    mutating func removeLast() -> EngineMessage.Index? {
        return messageIndices.pop(rememberAll: exteralessDialogPolicy().rememberAllBackMessages)
    }
    
    var isEmpty: Bool {
        return self.messageIndices.isEmpty
    }
    
    mutating func filterOutIndicesLessThan(_ index: EngineMessage.Index) {
        self.messageIndices.prune(rememberAll: exteralessDialogPolicy().rememberAllBackMessages, where: { $0 <= index })
    }

    mutating func removeAll() { self.messageIndices.removeAll() }
}
