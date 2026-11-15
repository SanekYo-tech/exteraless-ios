import AccountContext
import Foundation
import LocalizedPeerData
import SwiftSignalKit
import TelegramCore
import UIKit

/// Displays imported DeletedDialog descriptors without creating Telegram chat-list/server rows
/// or fetching the referenced top message. Opening a row reads only the local retained archive.
final class RetentionArchivePeersController: ExteralessChatTableController {
    private let request = MetaDisposable()

    init(context: AccountContext) {
        super.init(context: context, title: "Imported chat records")
        self.refreshAction = { [weak self] in self?.reload() }
        self.accountInvalidated = { [weak self] in self?.request.set(nil) }
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.request.dispose() }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); self.reload() }

    private func reload() {
        guard self.accountIsValid else { return }
        self.request.set((self.context.engine.messages.retainedChatDescriptors() |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.accountIsValid else { return }
            self.tableView.refreshControl?.endRefreshing()
            switch result {
            case let .success(peers):
                let formatter = DateFormatter()
                formatter.dateStyle = .medium; formatter.timeStyle = .short
                var rows = peers.map { peer in
                    ExteralessChatRow(id: "retention.chatRecord.\(peer.peerId.toInt64())", title: peer.peer?.compactDisplayTitle ?? "Peer \(peer.peerId.id._internalGetInt64Value())", detail: "\(peer.wasArchived ? "Archived" : "Main folder") · source top message #\(peer.topMessageId)\n" + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(peer.lastMessageDate))), action: { [weak self] in
                        guard let self, self.accountIsValid else { return }
                        self.pushChild(ExteralessRetentionHistoryController(context: self.context, scope: .peer(peer.peerId, threadId: nil)))
                    })
                }
                if rows.isEmpty { rows = [ExteralessChatRow(id: "retention.chatRecord.empty", title: "No retained chat records", enabled: false)] }
                self.sections = [ExteralessChatSection(footer: "Local imported metadata. A source top-message ID does not imply its content was received or restored. Clear the chat's retained history to remove its record.", rows: rows)]
                self.reloadRows()
            case let .failure(error): self.displayError(ExteralessRetentionPresentation.errorText(error))
            }
        }))
    }
}
