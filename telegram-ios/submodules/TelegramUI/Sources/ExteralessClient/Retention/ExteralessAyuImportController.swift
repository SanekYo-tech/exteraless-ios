import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import UniformTypeIdentifiers

final class ExteralessAyuImportController: ExteralessChatTableController, UIDocumentPickerDelegate {
    private let request = MetaDisposable()
    private var url: URL?
    private var accessing = false
    private var busy = false
    private var receipt: ExteralessAyuImportReceipt?
    private var peerMappings: [Int64: EnginePeer.Id] = [:]

    init(context: AccountContext) {
        super.init(context: context, title: "Import Ayu message database")
        self.accountInvalidated = { [weak self] in self?.stop() }
        self.render()
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.request.dispose(); if self.accessing { self.url?.stopAccessingSecurityScopedResource() } }

    private func stop() {
        self.request.set(nil)
        if self.accessing { self.url?.stopAccessingSecurityScopedResource() }
        self.accessing = false
        self.url = nil
        self.receipt = nil
        self.peerMappings.removeAll()
    }

    private func render() {
        var rows = [ExteralessChatRow(id: "retention.import.pick", title: self.busy ? "Importing…" : "Choose SQLite export", enabled: !self.busy, action: { [weak self] in self?.pick() })]
        if self.url != nil {
            rows.append(ExteralessChatRow(id: "retention.import.retry", title: "Merge selected database", enabled: !self.busy, action: { [weak self] in self?.run() }))
        }
        if let receipt {
            rows.append(ExteralessChatRow(id: "retention.import.result", title: "Imported \(receipt.importedVersions) versions", detail: "\(receipt.duplicates) duplicates · \(receipt.expired) expired · \(receipt.otherAccounts) belonging to other accounts", enabled: false))
            rows.append(ExteralessChatRow(id: "retention.import.observations", title: "\(receipt.importedReadDates) read dates · \(receipt.importedContentReadDates) played dates", detail: "\(receipt.importedActivities) last-seen observations · \(receipt.importedChatDescriptors) local chat records", enabled: false))
            rows.append(ExteralessChatRow(id: "retention.import.skipped", title: "Auxiliary merge", detail: "\(receipt.auxiliaryDuplicates) duplicates · \(receipt.auxiliaryExpired) expired · \(receipt.auxiliaryUnsetDates) unset dates · \(receipt.auxiliaryQuotaSkipped) beyond storage limits · \(receipt.auxiliarySelfActivities) global self-activity rows excluded", enabled: false))
            for dialog in receipt.unresolvedPeers.sorted() {
                let transferable = dialog != 0 && dialog != Int64.min && !(dialog > 0 && dialog & 0x4000000000000000 != 0)
                rows.append(ExteralessChatRow(id: "retention.import.peer.\(dialog)", title: "Unresolved Android peer \(dialog)", detail: transferable ? "Select the matching peer already known to this account, then merge again." : "Android secret-chat session IDs are not transferable to another device.", enabled: transferable && !self.busy, action: transferable ? { [weak self] in self?.resolve(dialog) } : nil))
            }
            if receipt.mediaWithoutFiles > 0 {
                rows.append(ExteralessChatRow(id: "retention.import.media", title: "\(receipt.mediaWithoutFiles) versions contain external media paths", detail: "The SQLite export contains metadata. Android file paths are not opened on iOS.", enabled: false))
            }
        }
        self.sections = [ExteralessChatSection(footer: "Message and read tables are matched to this account. Original global last-seen rows apply only to its known users. Dates stay Unix seconds; source dates, first reads and storage limits are preserved. Chat records are local archive metadata.", rows: rows)]
        if self.isNodeLoaded { self.reloadRows() }
    }

    private func pick() {
        guard self.accountIsValid, !self.busy else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard self.accountIsValid, let url = urls.first else { return }
        self.stop()
        self.url = url
        self.accessing = url.startAccessingSecurityScopedResource()
        self.run()
    }

    private func run() {
        guard self.accountIsValid, !self.busy, let url else { return }
        self.busy = true
        self.render()
        self.request.set((self.context.engine.messages.importAyuDatabase(url: url, peerMappings: self.peerMappings) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.accountIsValid else { return }
            self.busy = false
            switch result {
            case let .success(receipt): self.receipt = receipt; self.render()
            case let .failure(error): self.render(); self.displayError(ExteralessRetentionPresentation.errorText(error))
            }
        }))
    }

    private func resolve(_ dialog: Int64) {
        guard self.accountIsValid, !self.busy, dialog != 0, dialog != Int64.min, !(dialog > 0 && dialog & 0x4000000000000000 != 0) else { return }
        let bareId = dialog < 0 ? -dialog : dialog
        let selector = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, filter: [.excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: "Select peer \(bareId)"))
        selector.peerSelected = { [weak self, weak selector] peer, _ in
            selector?.dismiss()
            guard let self, self.accountIsValid else { return }
            let namespaces = dialog < 0 ? [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel] : [Namespaces.Peer.CloudUser]
            guard peer.id.id._internalGetInt64Value() == bareId, namespaces.contains(peer.id.namespace) else {
                self.displayError("The selected chat does not match this exported dialog ID.")
                return
            }
            self.peerMappings[dialog] = peer.id
            self.run()
        }
        self.push(selector)
    }
}
