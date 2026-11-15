import AccountContext
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import QuickLook
import SwiftSignalKit
import TelegramCore
import UIKit

/// All content arrives through TelegramEngine. No Postbox import or account-global content cache.
final class ExteralessRetentionHistoryController: ExteralessChatTableController, QLPreviewControllerDataSource {
    private let scope: ExteralessRetentionScope
    private let deletedOnly: Bool
    private let request = MetaDisposable()
    private let observation = MetaDisposable()
    private let errorObservation = MetaDisposable()
    private let operation = MetaDisposable()
    private var settingsObservation: ClientSettingsObservation?
    private var entries: [ExteralessRetentionEntry] = []
    private var cursor: EngineMessage.Index?
    private var hasMore = false
    private var loading = false
    private var generation: UInt64 = 0
    private var summary: ExteralessRetentionSummary?
    private var retentionError: ExteralessRetentionError?
    private var reloadWork: DispatchWorkItem?
    private var previewFile: ExteralessRetentionPreviewItem?
    private weak var preview: QLPreviewController?
    private weak var sharing: UIActivityViewController?

    init(context: AccountContext, scope: ExteralessRetentionScope, deletedOnly: Bool = false) {
        self.scope = scope
        self.deletedOnly = deletedOnly
        let title: String
        switch scope { case .message, .version: title = "Message history"; default: title = deletedOnly ? "Deleted messages" : "Retained messages" }
        super.init(context: context, title: title)
        self.refreshAction = { [weak self] in self?.context.engine.messages.refreshRetention(); self?.reloadHistory() }
        self.accountInvalidated = { [weak self] in self?.invalidateRetention() }
        self.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(self.exportPressed)),
            UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(self.clearPressed))
        ]
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.request.dispose()
        self.observation.dispose()
        self.errorObservation.dispose()
        self.operation.dispose()
        self.settingsObservation?.cancel()
        self.reloadWork?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard self.accountIsValid else { return }
        self.observation.set((self.context.engine.messages.retentionChanges() |> deliverOnMainQueue).start(next: { [weak self] in self?.scheduleReload() }))
        self.errorObservation.set((self.context.engine.messages.retentionErrors() |> deliverOnMainQueue).start(next: { [weak self] error in
            guard let self, self.accountIsValid else { return }
            self.retentionError = error
            self.renderRows()
        }))
        self.settingsObservation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || !keys.isDisjoint(with: RetentionFeatures.keys) else { return }
            DispatchQueue.main.async { self?.scheduleReload() }
        }
        self.reloadHistory()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.observation.set(nil)
        self.errorObservation.set(nil)
        self.settingsObservation?.cancel()
        self.settingsObservation = nil
        self.reloadWork?.cancel()
        super.viewWillDisappear(animated)
    }

    private func invalidateRetention() {
        self.generation &+= 1
        self.request.set(nil)
        self.observation.set(nil)
        self.errorObservation.set(nil)
        self.operation.set(nil)
        self.reloadWork?.cancel()
        self.settingsObservation?.cancel()
        self.entries.removeAll()
        self.summary = nil
        self.preview?.dismiss(animated: false)
        self.sharing?.dismiss(animated: false)
        self.previewFile = nil
    }

    private func scheduleReload() {
        self.reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadHistory() }
        self.reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reloadHistory() {
        guard self.accountIsValid else { return }
        self.generation &+= 1
        self.cursor = nil
        self.hasMore = false
        self.entries.removeAll()
        self.loadPage(reset: true)
    }

    private func loadPage(reset: Bool) {
        guard self.accountIsValid, reset || (!self.loading && self.hasMore) else { return }
        self.loading = true
        let generation = self.generation
        let signal: Signal<Result<ExteralessRetentionPage, ExteralessRetentionError>, NoError>
        switch self.scope {
        case .account:
            signal = self.context.engine.messages.retainedMessages(before: self.cursor, deletedOnly: self.deletedOnly)
        case let .peer(peerId, threadId):
            signal = self.context.engine.messages.retainedMessages(peerId: peerId, threadId: threadId, before: self.cursor, deletedOnly: self.deletedOnly)
        case let .message(id), let .version(id, _):
            signal = self.context.engine.messages.retainedVersions(messageId: id) |> map { result in
                result.map { values in ExteralessRetentionPage(entries: Array(values.reversed()), next: nil, hasMore: false) }
            }
        }
        self.request.set((combineLatest(signal, self.context.engine.messages.retentionSummary()) |> deliverOnMainQueue).start(next: { [weak self] result, summary in
            guard let self, self.accountIsValid, self.generation == generation else { return }
            self.loading = false
            self.tableView.refreshControl?.endRefreshing()
            if case let .success(summary) = summary { self.summary = summary }
            switch result {
            case let .success(page):
                if reset { self.entries = page.entries }
                else {
                    let existing = Set(self.entries.map { "\($0.message.id.peerId.toInt64()):\($0.message.id.namespace):\($0.message.id.id):\($0.sequence)" })
                    self.entries.append(contentsOf: page.entries.filter { !existing.contains("\($0.message.id.peerId.toInt64()):\($0.message.id.namespace):\($0.message.id.id):\($0.sequence)") })
                }
                self.cursor = page.next
                self.hasMore = page.hasMore
                self.renderRows()
            case let .failure(error):
                self.renderRows()
                self.displayError(ExteralessRetentionPresentation.errorText(error))
            }
        }))
        self.renderRows()
    }

    private func renderRows() {
        guard self.accountIsValid else { return }
        var sections: [ExteralessChatSection] = []
        if let error = self.retentionError {
            sections.append(ExteralessChatSection(rows: [ExteralessChatRow(id: "retention.failure", title: "Retention operation could not finish", detail: ExteralessRetentionPresentation.errorText(error), enabled: false)]))
        }
        if let summary = self.summary {
            let bytes = ByteCountFormatter.string(fromByteCount: summary.retainedMediaBytes, countStyle: .file)
            sections.append(ExteralessChatSection(footer: "Only versions and files received by this account are available. Oldest captures expire after \(RetentionPolicy.current.days) days.", rows: [
                ExteralessChatRow(id: "retention.summary", title: "\(summary.messageCount) messages · \(summary.versionCount) versions", detail: "\(bytes) encrypted media · \(summary.pendingMediaCount) awaiting local files", enabled: false)
            ]))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var rows: [ExteralessChatRow] = []
        for (index, entry) in self.entries.enumerated() {
            let author = entry.message.author?.compactDisplayTitle ?? String(entry.message.id.peerId.toInt64())
            let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.versionDate)))
            let status: String
            switch entry.reason { case .deleted: status = "Deleted"; case .edit: status = "Before edit"; case .expired: status = "Before media expired" }
            let content = entry.displayText.isEmpty ? (entry.attachments.first?.title ?? (entry.mediaOmitted ? "Media was excluded by retention settings" : "Message")) : String(entry.displayText.prefix(4000))
            let provenance = entry.message.exteralessRetention?.isImported == true ? "Imported from Ayu · " : ""
            rows.append(ExteralessChatRow(id: "retention.entry.\(index)", title: "\(status) · \(date)", detail: provenance + author + "\n" + content, action: { [weak self] in self?.openEntry(entry) }))
        }
        if rows.isEmpty { rows.append(ExteralessChatRow(id: "retention.empty", title: self.loading ? "Loading…" : "No locally retained versions", enabled: false)) }
        if self.hasMore { rows.append(ExteralessChatRow(id: "retention.more", title: self.loading ? "Loading…" : "Load earlier", enabled: !self.loading, action: { [weak self] in self?.loadPage(reset: false) })) }
        sections.append(ExteralessChatSection(rows: rows))
        self.sections = sections
        self.reloadRows()
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        cell.contentView.alpha = 1.0
        let row = self.sections[indexPath.section].rows[indexPath.row]
        if row.id.hasPrefix("retention.entry."), let index = Int(row.id.dropFirst("retention.entry.".count)), self.entries.indices.contains(index), self.entries[index].reason == .deleted {
            let policy = RetentionPolicy.current
            let font = cell.textLabel?.font ?? UIFont.preferredFont(forTextStyle: .body)
            let value = NSMutableAttributedString(attributedString: ExteralessRetentionPresentation.mark(policy: policy, fallbackColor: self.presentationData.theme.list.itemSecondaryTextColor, font: font))
            value.append(NSAttributedString(string: String(row.title.dropFirst("Deleted".count)), attributes: [.font: font, .foregroundColor: self.presentationData.theme.list.itemPrimaryTextColor]))
            cell.textLabel?.attributedText = value
            cell.contentView.alpha = policy.translucent ? 0.75 : 1.0
            cell.accessibilityLabel = "Deleted message. " + (row.detail ?? "")
        } else if row.id.hasPrefix("retention.entry."), let index = Int(row.id.dropFirst("retention.entry.".count)), self.entries.indices.contains(index), self.entries[index].reason == .edit {
            let font = cell.textLabel?.font ?? UIFont.preferredFont(forTextStyle: .body)
            let text = NSMutableAttributedString(attributedString: ExteralessRetentionPresentation.editedMark(policy: .current, color: self.presentationData.theme.list.itemSecondaryTextColor, font: font))
            text.append(NSAttributedString(string: String(row.title.dropFirst("Before edit".count)), attributes: [.font: font, .foregroundColor: self.presentationData.theme.list.itemPrimaryTextColor]))
            cell.textLabel?.attributedText = text
            cell.accessibilityLabel = "Before edit. " + (row.detail ?? "")
        } else {
            cell.textLabel?.attributedText = nil
            cell.textLabel?.text = row.title
            cell.accessibilityLabel = nil
        }
        return cell
    }

    private func openEntry(_ entry: ExteralessRetentionEntry) {
        guard self.accountIsValid else { return }
        let menu = UIAlertController(title: "Message \(entry.message.id.id)", message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "View edit history", style: .default, handler: { [weak self] _ in
            guard let self, self.accountIsValid else { return }
            let controller = ExteralessRetentionHistoryController(context: self.context, scope: .message(entry.message.id))
            self.pushChild(controller)
        }))
        if !entry.displayText.isEmpty {
            menu.addAction(UIAlertAction(title: "View full text", style: .default, handler: { [weak self] _ in
                guard let self, self.accountIsValid else { return }
                self.pushChild(ExteralessRetentionTextController(context: self.context, text: entry.displayText))
            }))
            menu.addAction(UIAlertAction(title: "Copy text", style: .default, handler: { [weak self] _ in
                if self?.accountIsValid == true { UIPasteboard.general.string = entry.displayText }
            }))
        }
        for attachment in entry.attachments {
            let title: String
            switch attachment.availability {
            case .retained: title = "Open " + attachment.title
            case .awaitingLocalData: title = "Check local " + attachment.title
            case .failed: title = "Retry retaining " + attachment.title
            case .notRetained: title = attachment.title + " — not retained"
            }
            let action = UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
                if case .failed = attachment.availability { self?.context.engine.messages.refreshRetention() }
                else { self?.openMedia(entry, attachment: attachment) }
            })
            if case .notRetained = attachment.availability { action.isEnabled = false }
            menu.addAction(action)
        }
        menu.addAction(UIAlertAction(title: "Export this version", style: .default, handler: { [weak self] _ in self?.export(.version(entry.message.id, sequence: entry.sequence)) }))
        menu.addAction(UIAlertAction(title: "Clear this retained version", style: .destructive, handler: { [weak self] _ in self?.confirmClear(.version(entry.message.id, sequence: entry.sequence)) }))
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        menu.popoverPresentationController?.sourceView = self.tableView
        menu.popoverPresentationController?.sourceRect = CGRect(x: self.tableView.bounds.midX, y: self.tableView.bounds.midY, width: 1, height: 1)
        self.present(menu, animated: true)
    }

    private func openMedia(_ entry: ExteralessRetentionEntry, attachment: ExteralessRetentionAttachment) {
        guard self.accountIsValid else { return }
        self.operation.set((self.context.engine.messages.retainedMedia(messageId: entry.message.id, sequence: entry.sequence, resourceId: attachment.resourceId) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.accountIsValid else { return }
            switch result {
            case let .success(file):
                self.previewFile = ExteralessRetentionPreviewItem(url: file.url, title: attachment.title)
                let preview = QLPreviewController()
                preview.dataSource = self
                self.preview = preview
                self.present(preview, animated: true)
            case let .failure(error): self.displayError(ExteralessRetentionPresentation.errorText(error))
            }
        }))
    }

    @objc private func exportPressed() { self.export(self.scope) }
    @objc private func clearPressed() { self.confirmClear(self.scope) }

    private func export(_ scope: ExteralessRetentionScope) {
        guard self.accountIsValid else { return }
        self.operation.set((self.context.engine.messages.exportRetention(scope) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.accountIsValid else { return }
            switch result {
            case let .success(data):
                let activity = UIActivityViewController(activityItems: [ExteralessRetentionExportItem(data: data)], applicationActivities: nil)
                activity.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?.first
                self.sharing = activity
                self.present(activity, animated: true)
            case let .failure(error): self.displayError(ExteralessRetentionPresentation.errorText(error))
            }
        }))
    }

    private func confirmClear(_ scope: ExteralessRetentionScope) {
        guard self.accountIsValid else { return }
        let alert = UIAlertController(title: "Clear retained history?", message: "Removes the selected local versions and releases their retained media.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
            guard let self, self.accountIsValid else { return }
            self.operation.set((self.context.engine.messages.clearRetention(scope) |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.accountIsValid else { return }
                switch result {
                case .success: self.reloadHistory()
                case let .failure(error): self.displayError(ExteralessRetentionPresentation.errorText(error))
                }
            }))
        }))
        self.present(alert, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { self.accountIsValid && self.previewFile != nil ? 1 : 0 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { self.previewFile ?? ExteralessRetentionPreviewItem(url: nil, title: "Unavailable") }
}

private final class ExteralessRetentionPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL?, title: String) { self.previewItemURL = url; self.previewItemTitle = title }
}

/// Shares bytes directly. Plaintext history is not written to a shared temp/preferences folder.
private final class ExteralessRetentionExportItem: NSObject, UIActivityItemSource {
    let data: Data
    init(data: Data) { self.data = data }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { Data() }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { self.data }
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { "public.json" }
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { "Retained message history" }
}

private final class ExteralessRetentionTextController: ExteralessChatTableController {
    init(context: AccountContext, text: String) {
        super.init(context: context, title: "Retained text")
        self.sections = [ExteralessChatSection(rows: [ExteralessChatRow(id: "retention.text", title: text)])]
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class ExteralessRetentionPeerController: ExteralessChatTableController {
    private let peerId: EnginePeer.Id
    private let request = MetaDisposable()
    private var value = RetentionPeerExceptions()

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.peerId = peerId
        super.init(context: context, title: "Retention exceptions")
        self.refreshAction = { [weak self] in self?.read() }
        self.accountInvalidated = { [weak self] in self?.request.set(nil) }
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.request.dispose() }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); self.read() }

    private func read() {
        guard self.accountIsValid else { return }
        self.request.set((self.context.engine.messages.retentionPeerExceptions(peerId: self.peerId) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.accountIsValid else { return }
            self.tableView.refreshControl?.endRefreshing()
            switch result { case let .success(value): self.value = value; self.render(); case let .failure(error): self.displayError(ExteralessRetentionPresentation.errorText(error)) }
        }))
    }

    private func render() {
        let policy = RetentionPolicy.current
        self.sections = [ExteralessChatSection(footer: "A mark matches this chat and messages authored by this peer. Marks belong only to the current account.", rows: [
            ExteralessChatRow(id: "retention.exception.deleted", title: "Mark for deleted-message retention", detail: policy.deletedOnlyMarked ? "Only marked chats/senders are kept" : "Marked chats/senders are excluded", checked: self.value.deleted, action: { [weak self] in self?.toggle(deleted: true) }),
            ExteralessChatRow(id: "retention.exception.edited", title: "Mark for edit-history retention", detail: policy.editedOnlyMarked ? "Only marked chats/senders are kept" : "Marked chats/senders are excluded", checked: self.value.edited, action: { [weak self] in self?.toggle(deleted: false) })
        ])]
        self.reloadRows()
    }

    private func toggle(deleted: Bool) {
        guard self.accountIsValid else { return }
        var updated = self.value
        if deleted { updated.deleted.toggle() } else { updated.edited.toggle() }
        self.request.set((self.context.engine.messages.setRetentionPeerExceptions(peerId: self.peerId, value: updated) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.accountIsValid else { return }
            switch result { case .success: self.read(); case let .failure(error): self.displayError(ExteralessRetentionPresentation.errorText(error)) }
        }))
    }
}
