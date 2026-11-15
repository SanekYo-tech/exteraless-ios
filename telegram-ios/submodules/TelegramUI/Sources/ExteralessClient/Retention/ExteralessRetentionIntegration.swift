import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
public final class ExteralessRetentionIntegration {
    private final class ScreenReference {
        weak var screen: ExteralessChatTableController?
        init(_ screen: ExteralessChatTableController) { self.screen = screen }
    }
    private static weak var active: ExteralessRetentionIntegration?
    private var context: AccountContext?
    private var screens: [ScreenReference] = []
    private let accountsDisposable = MetaDisposable()
    private var foregroundObserver: NSObjectProtocol?

    public init() {
        Self.active = self
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "retention.archive", title: "Retained messages and media", section: "Retained messages", action: { context, parent in
                Self.open(context: context, parent: parent, scope: .account)
            }),
            ExteralessSettingsAction(id: "retention.importAyu", title: "Import Ayu message database", section: "Retained messages", action: { [weak self] context, parent in
                guard let self, self.context?.account === context.account else { return }
                self.present(ExteralessAyuImportController(context: context), parent: parent)
            }),
            ExteralessSettingsAction(id: "retention.chatRecords", title: "Imported chat records", section: "Retained messages", action: { [weak self] context, parent in
                guard let self, self.context?.account === context.account else { return }
                self.present(RetentionArchivePeersController(context: context), parent: parent)
            }),
            ExteralessSettingsAction(id: "retention.exceptions", title: "Retention for a chat or sender", section: "Retained messages", action: { [weak self] context, parent in
                guard let self, self.context?.account === context.account else { return }
                let selector = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: "Retention exceptions"))
                selector.peerSelected = { [weak self, weak parent, weak selector] peer, _ in
                    selector?.dismiss()
                    guard let self, let parent, self.context?.account === context.account else { return }
                    self.present(ExteralessRetentionPeerController(context: context, peerId: peer.id), parent: parent)
                }
                parent.push(selector)
            })
        ])
        self.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.context?.engine.messages.refreshRetention() }
        }
    }

    public func update(context: AccountContext) {
        if self.context === context { context.engine.messages.refreshRetention(); return }
        self.clearContext()
        self.context = context
        context.engine.messages.refreshRetention()
        self.accountsDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self, let context, self.context === context else { return }
            for item in value.accounts { item.1.engine.messages.refreshRetention() }
        }))
    }

    public func clearContext() {
        self.accountsDisposable.set(nil)
        for reference in self.screens { reference.screen?.invalidateAccount() }
        self.screens.removeAll()
        self.context = nil
    }

    deinit {
        self.accountsDisposable.dispose()
        if let observer = self.foregroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    static func open(context: AccountContext, parent: ViewController, scope: ExteralessRetentionScope, deletedOnly: Bool = false) {
        guard let active = Self.active, active.context?.account === context.account else { return }
        active.present(ExteralessRetentionHistoryController(context: context, scope: scope, deletedOnly: deletedOnly), parent: parent)
    }

    private func present(_ screen: ExteralessChatTableController, parent: ViewController) {
        guard self.context?.account === screen.context.account else { return }
        self.screens.removeAll { $0.screen == nil }
        self.screens.append(ScreenReference(screen))
        parent.push(screen)
    }
}
