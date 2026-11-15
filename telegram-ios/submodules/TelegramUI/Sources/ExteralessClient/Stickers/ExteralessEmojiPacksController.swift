import AccountContext
import Emoji
import ExteralessCore
import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ExteralessEmojiPacksController: ExteralessSettingsListController, UIDocumentPickerDelegate {
    private let library: ExteralessEmojiPacks
    private var observer: NSObjectProtocol?

    init(context: AccountContext, packs: ExteralessEmojiPacks) {
        self.library = packs
        super.init(context: context)
        self.title = "Emoji Packs"
        self.observer = NotificationCenter.default.addObserver(forName: ExteralessEmojiPacks.changed, object: packs, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func refresh() { self.library.reload(); self.tableView.refreshControl?.endRefreshing(); self.render() }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if self.isMovingFromParent || self.isBeingDismissed { self.library.cancel() }
    }

    override func render() {
        let policy = StickerPolicy()
        let busy = self.isBusy || self.library.status != nil || !self.library.active
        var sections: [ExteralessSettingsSection] = []
        var stock = ExteralessSettingsRow(id: "native.default", title: "Default · iOS Emoji", detail: "Restore Telegram's native font")
        stock.accessory = !policy.systemEmoji && (policy.emojiPack.isEmpty || policy.emojiPack == "default") ? .checkmark : .none
        stock.action = { [weak self] in self?.library.selectNative(system: false) }
        stock.enabled = !busy
        var system = ExteralessSettingsRow(id: "native.system", title: "Use System Emoji", detail: "Keep the selected pack for later")
        system.accessory = policy.systemEmoji ? .checkmark : .none
        system.action = { [weak self] in self?.library.selectNative(system: true) }
        system.enabled = !busy
        let preview = ExteralessSettingsRow(id: "native.preview", title: "Emoji Preview")
        sections.append(ExteralessSettingsSection(footer: "Default and System both use the Apple emoji font provided by this iOS version. Imported fonts affect app-rendered emoji; the iOS keyboard, notifications and other apps use their system font.", rows: [stock, system, preview]))

        var importRow = ExteralessSettingsRow(id: "import", title: "Import Font from Files…")
        importRow.style = .accent
        importRow.enabled = !busy
        importRow.action = { [weak self] in self?.pickFont() }
        sections.append(ExteralessSettingsSection(title: "App Font Packs", footer: "TrueType/OpenType, up to 32 MiB per font and 96 MiB total. Registration and a visible emoji glyph probe must succeed. Font files stay in this account's app storage.", rows: [importRow]))
        let appliedSHA = ExteralessEmojiRendering.shared.appliedSHA256(accountId: self.context.account.id.int64)
        for pack in self.library.packs {
            var row = ExteralessSettingsRow(id: pack.id, title: pack.name, detail: "v\(pack.version) · \(pack.byteCount) bytes · \(pack.fileExtension.uppercased())\n\(pack.origin.label)\nSHA-256: \(pack.sha256)")
            row.enabled = !busy
            row.accessory = !policy.systemEmoji && policy.emojiPack == pack.id && appliedSHA == pack.sha256 ? .checkmark : .disclosure
            row.action = { [weak self] in self?.manage(pack) }
            sections.append(ExteralessSettingsSection(footer: pack.license, rows: [row]))
        }

        var enabled = ExteralessSettingsRow(id: "downloads", title: "Download Emoji Packs")
        enabled.enabled = self.library.active && !self.isBusy
        enabled.toggle = (policy.downloadEmojiPacks, { [weak self] value in
            self?.perform({ try ClientSettings.shared.set(.bool(value), for: "chats.downloadEmojiPacks") }, completion: { [weak self] in
                if value { self?.library.refreshCatalog() } else { self?.library.cancelRemoteOperation() }
            })
        })
        var rows = [enabled]
        if policy.downloadEmojiPacks {
            var refresh = ExteralessSettingsRow(id: "catalog.refresh", title: "Refresh Original Catalog", detail: "https://t.me/\(EmojiCatalog.source) · #emojiv2")
            refresh.action = { [weak self] in self?.library.refreshCatalog() }
            refresh.enabled = !busy
            rows.append(refresh)
            var url = ExteralessSettingsRow(id: "download.url", title: "Download from HTTPS URL…")
            url.action = { [weak self] in self?.urlPrompt() }
            url.enabled = !busy
            rows.append(url)
        }
        sections.append(ExteralessSettingsSection(title: "Remote Sources", footer: "Catalog access reads the original public Telegram source without joining it. A downloaded font's source, size and SHA-256 are shown before it is selected. Embedded license metadata is shown when present.", rows: rows))
        if policy.downloadEmojiPacks, let catalog = self.library.catalog {
            let entries = catalog.entries.filter { $0.id != "default" && $0.id != "apple" }
            let rows = entries.map { entry -> ExteralessSettingsRow in
                let installed = self.library.packs.first(where: { $0.id == "remote.\(entry.id)" })
                let update = installed.map { $0.version < entry.version } ?? false
                var row = ExteralessSettingsRow(id: "catalog.\(entry.id)", title: entry.name, detail: "Version \(entry.version)" + (update ? " · Update available" : "") + "\nhttps://t.me/\(EmojiCatalog.source)/\(entry.file)")
                row.action = { [weak self] in self?.library.download(entry) }
                row.enabled = !busy
                row.accessory = .disclosure
                return row
            }
            sections.append(ExteralessSettingsSection(title: "Available Fonts", footer: "Last successful refresh: \(DateFormatter.localizedString(from: catalog.fetchedAt, dateStyle: .medium, timeStyle: .short))", rows: rows))
        }
        if let candidate = self.library.candidate {
            let font = candidate.face.inspection
            var use = ExteralessSettingsRow(id: "candidate.use", title: "Use Font in This App", detail: "\(candidate.name) · \(font.fileExtension.uppercased()) · \(font.byteCount) bytes\n\(candidate.origin.label)\nSHA-256: \(font.sha256)")
            use.style = .accent
            use.action = { [weak self] in self?.library.installCandidate() }
            use.enabled = !busy
            var discard = ExteralessSettingsRow(id: "candidate.discard", title: "Discard")
            discard.action = { [weak self] in self?.library.cancel() }
            sections.append(ExteralessSettingsSection(title: "Font Passed Native Probe", footer: font.license, rows: [ExteralessSettingsRow(id: "candidate.preview", title: "Preview"), use, discard]))
        }
        if let status = self.library.status {
            var cancel = ExteralessSettingsRow(id: "cancel", title: "Cancel", detail: status)
            cancel.action = { [weak self] in self?.library.cancel() }
            sections.append(ExteralessSettingsSection(rows: [cancel]))
        }
        var clear = ExteralessSettingsRow(id: "cache.clear", title: "Remove Unused Downloaded Fonts")
        clear.enabled = !busy
        clear.action = { [weak self] in self?.library.clearUnusedDownloads() }
        sections.append(ExteralessSettingsSection(footer: "The selected font and fonts imported from Files are retained.", rows: [clear]))
        if let error = self.library.errorText {
            var row = ExteralessSettingsRow(id: "font.error", title: "Font Not Applied", detail: error)
            row.style = .destructive
            sections.append(ExteralessSettingsSection(rows: [row]))
        }
        self.setSections(sections + self.operationSections())
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = self.sections[indexPath.section].rows[indexPath.row].id
        if id == "native.preview" || id == "candidate.preview" {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.textAlignment = .center
            cell.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
            if id == "candidate.preview", let candidate = self.library.candidate {
                cell.textLabel?.attributedText = ExteralessEmojiRendering.shared.preview(candidate.face)
            } else {
                cell.textLabel?.attributedText = ExteralessEmojiRendering.shared.attributedText(NSAttributedString(string: "😀  😉  😔  😨", attributes: [.font: UIFont.systemFont(ofSize: 32)]), accountId: self.context.account.id.int64)
            }
            return cell
        }
        return super.tableView(tableView, cellForRowAt: indexPath)
    }

    private func pickFont() {
        let types = [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf")].compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.data] : types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.context.sharedContext.applicationBindings.presentNativeController(picker)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { self.library.importFile(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    private func manage(_ pack: EmojiStoredPack) {
        let alert = UIAlertController(title: pack.name, message: "v\(pack.version) · \(pack.byteCount) bytes", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Use Font", style: .default, handler: { [weak self] _ in self?.library.select(pack) }))
        alert.addAction(UIAlertAction(title: "Remove Font", style: .destructive, handler: { [weak self] _ in self?.library.remove(pack) }))
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.popoverPresentationController?.sourceView = self.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
        self.context.sharedContext.applicationBindings.presentNativeController(alert)
    }

    private func urlPrompt() {
        let alert = UIAlertController(title: "Download Emoji Font", message: "HTTPS .ttf or .otf · 32 MiB maximum", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://…/emoji.ttf"; $0.keyboardType = .URL; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addTextField { $0.placeholder = "Expected SHA-256 (optional for user download)"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Download", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            do {
                let url = try EmojiFontHTTPClient.validatedURL(fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                let sha = fields[1].text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                guard sha.isEmpty || EmojiFontInspection.isSHA256(sha) else { throw EmojiPackError.checksumMismatch }
                self.library.download(url: url, expectedSHA256: sha.isEmpty ? nil : sha)
            } catch { self.errorText = error.localizedDescription; self.render() }
        }))
        self.context.sharedContext.applicationBindings.presentNativeController(alert)
    }
}
