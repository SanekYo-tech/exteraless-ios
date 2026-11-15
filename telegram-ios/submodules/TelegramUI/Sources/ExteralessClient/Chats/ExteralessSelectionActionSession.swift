import AccountContext
import Foundation
import SwiftSignalKit
import TelegramCore

enum ExteralessSelectionExportAction: CaseIterable {
    case copy, forward, combine

    func isAvailable(_ snapshot: ExteralessChatExportSnapshot, _ actions: ChatAvailableMessageActions) -> Bool {
        guard snapshot.canCopy, !actions.isCopyProtected, !snapshot.messages.isEmpty else { return false }
        switch self {
        case .copy: return snapshot.messages.count == 1 || snapshot.messages.allSatisfy { $0.richText == nil }
        case .forward: return actions.options.contains(.forward)
        case .combine: return snapshot.messages.count > 1 && snapshot.messages.allSatisfy { $0.richText == nil && $0.media.allSatisfy { $0 is TelegramMediaWebpage } }
        }
    }
}

/// The actual selection-sheet callback path. Menu visibility is only a preview:
/// every saved callback reloads native action eligibility and the source scope.
@MainActor
final class ExteralessSelectionActionSession {
    let access: ExteralessChatExportAccess
    private let actions: (Bool) -> Signal<ChatAvailableMessageActions, NoError>
    private var watching = false
    private var chosen = false

    init(access: ExteralessChatExportAccess, actions: @escaping (Bool) -> Signal<ChatAvailableMessageActions, NoError>) {
        self.access = access
        self.actions = actions
    }

    func read(requiresCopy: Bool, operation: ExteralessContentExportPermit.Operation, _ body: @escaping (ExteralessChatExportSnapshot, ChatAvailableMessageActions) -> Void) {
        self.access.add((self.actions(false) |> take(1) |> deliverOnMainQueue).start(next: { available in
            self.access.perform(requiresCopy: requiresCopy, operation: operation) { snapshot in
                guard !requiresCopy || !available.isCopyProtected else { self.access.invalidate(); return }
                if !self.watching {
                    self.watching = true
                    self.access.add((self.actions(true) |> deliverOnMainQueue).start(next: { [weak self] current in
                        if current.options != available.options || current.isCopyProtected != available.isCopyProtected { self?.access.invalidate() }
                    }))
                }
                body(snapshot, available)
            }
        }))
    }

    func action(requiresCopy: Bool, operation: ExteralessContentExportPermit.Operation = .exportEffect, allowed: @escaping (ExteralessChatExportSnapshot, ChatAvailableMessageActions) -> Bool = { _, _ in true }, _ body: @escaping (ExteralessChatExportSnapshot, ChatAvailableMessageActions) -> Void) -> () -> Void {
        return {
            guard !self.chosen else { return }
            self.chosen = true
            self.read(requiresCopy: requiresCopy, operation: operation) { snapshot, available in
                guard allowed(snapshot, available) else { self.access.invalidate(); return }
                body(snapshot, available)
            }
        }
    }

    func action(_ kind: ExteralessSelectionExportAction, _ body: @escaping (ExteralessChatExportSnapshot, ChatAvailableMessageActions) -> Void) -> () -> Void {
        self.action(requiresCopy: true, allowed: kind.isAvailable, body)
    }
}
