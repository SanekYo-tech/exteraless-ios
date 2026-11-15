import Foundation
import Postbox
import SwiftSignalKit

/// One metadata-only native view lease for the visible set. This does not keep channel history
/// views alive, fill holes, install read actions, or implement a second poll/webpage RPC loop.
public final class ExteralessFeedVisibleMetadataLease {
    private let input = Promise<(MessageHistoryView, ViewUpdateType, InitialMessageHistoryData?)>()
    private let disposable = MetaDisposable()
    private var disposed = false

    public init(engine: TelegramEngine) {
        self.disposable.set(engine.account.viewTracker.wrappedMessageHistorySignal(
            chatLocation: .customChatContents,
            signal: self.input.get(),
            fixedCombinedReadStates: nil,
            addHoleIfNeeded: false
        ).start())
    }

    public func update(messages: [EngineMessage]) {
        guard !self.disposed else { return }
        let messages = Array(messages.filter(exteralessFeedMessageIsEligible).prefix(32))
        let entries = messages.map {
            MessageHistoryEntry(message: $0._asMessage(), isRead: false, location: nil, monthLocation: nil, attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false))
        }.sorted()
        let view = MessageHistoryView(tag: nil, namespaces: .just([Namespaces.Message.Cloud]), entries: entries, holeEarlier: false, holeLater: false, isLoading: false)
        // The native wrapper's one viewId owns updatePolls/updatePendingWebpages. Replacing this
        // value preserves reference-counted producers for IDs that remain visible.
        self.input.set(.single((view, .Generic, nil)))
    }

    public func dispose() {
        guard !self.disposed else { return }
        self.disposed = true
        self.disposable.dispose()
    }

    deinit { self.disposable.dispose() }
}
