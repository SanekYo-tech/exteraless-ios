import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import UniformTypeIdentifiers

final class ExteralessFavoriteStickersController: ExteralessToolsListController, UIDocumentPickerDelegate {
    private var observation: Disposable?
    private var snapshot: ExteralessLocalFavoriteSnapshot?
    private var inspected: ToolsFavoriteStickerArchive?
    private var visibleCount = 100
    private var picking = false

    override init(context: AccountContext) {
        super.init(context: context)
        title = "Favorite-sticker backup"
        observation = (exteralessLocalFavoriteStickers(engine: context.engine) |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.contextAvailable else { return }
            self.snapshot = value
            self.render()
        }, error: { [weak self] error in self?.toolsError = error.localizedDescription; self?.render() })
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observation?.dispose() }

    override func clearToolsContext() { observation?.dispose(); observation = nil; super.clearToolsContext() }

    override func render() {
        var sections = operationSections()
        guard let snapshot else {
            sections.append(PluginListSection(rows: [PluginListRow(id: "loading-favorites", title: "Reading this account's local favorites…")]))
            setSections(sections)
            return
        }
        sections.append(PluginListSection(title: "Telegram account \(snapshot.userId)", footer:
            "The independent local list retains up to 10,000 sticker documents. Cloud favorite limits are separate. Import merges only this Telegram user ID and does not issue favorite/send RPCs.", rows: [
                PluginListRow(id: "counts", title: "\(snapshot.local.count) retained locally · \(snapshot.cloud.count) in native cloud cache",
                    detail: snapshot.skippedCloudRecords == 0 ? nil : "\(snapshot.skippedCloudRecords) unsupported native records were not exported."),
                exteralessToolsAction("export-favorites", "Export favorite stickers…", enabled: !isBusy && contextAvailable) { [weak self] in self?.export(snapshot) },
                exteralessToolsAction("retain-favorites", "Keep current favorites locally", enabled: !isBusy && contextAvailable && !snapshot.combined.isEmpty) { [weak self] in
                    self?.importArchive(ToolsFavoriteStickerArchive(accounts: [String(snapshot.userId): snapshot.combined]))
                },
                exteralessToolsAction("import-favorites", "Inspect favorite-sticker backup…", enabled: !isBusy && !picking && contextAvailable) { [weak self] in self?.pick() }
            ]))
        if let inspected {
            let count = inspected.accounts[String(snapshot.userId)]?.count
            sections.append(PluginListSection(title: "Verified backup", rows: [
                PluginListRow(id: "inspection", title: "\(inspected.accounts.count) account records", detail: count.map { "\($0) stickers for this account" } ?? "No record for this account"),
                exteralessToolsAction("apply-favorites", "Merge into local favorites", enabled: count != nil && !isBusy && contextAvailable) { [weak self] in self?.importArchive(inspected) }
            ]))
        }
        let localIds = Set(snapshot.local.map(\.id))
        var rows = snapshot.combined.prefix(visibleCount).map { sticker -> PluginListRow in
            var row = PluginListRow(id: String(sticker.id), title: sticker.displayText.isEmpty ? sticker.fileName : sticker.displayText,
                                    detail: "\(sticker.id) · \(localIds.contains(sticker.id) ? "Local" : "Cloud cache")")
            row.enabled = !isBusy && contextAvailable
            row.action = { [weak self] in self?.open(sticker) }
            if localIds.contains(sticker.id) { row.remove = { [weak self] in self?.remove(sticker.id) } }
            return row
        }
        if rows.count < snapshot.combined.count {
            rows.append(exteralessToolsAction("more-favorites", "Show 100 more", enabled: !isBusy && contextAvailable) { [weak self] in
                self?.visibleCount += 100
                self?.render()
            })
        }
        sections.append(PluginListSection(title: "Favorites", footer: "Tap to open the sticker's native pack, or copy its ID if no pack reference is available. Swipe removes only a locally retained copy.", rows: rows))
        setSections(sections)
    }

    private func export(_ snapshot: ExteralessLocalFavoriteSnapshot) {
        let archive = ToolsFavoriteStickerArchive(accounts: [String(snapshot.userId): snapshot.combined])
        runToolsOperation(title: "Building favorite-sticker archive…", operation: {
            try await Task.detached { try exteralessToolsTemporaryFile(data: archive.encode(), name: "favorite-stickers.exteraless-favorites") }.value
        }, discard: exteralessToolsDiscardTemporaryFile, completion: { [weak self] url in
            guard let self else { return }
            exteralessToolsShare(url, from: self, removeOnCompletion: true)
        })
    }

    private func pick() {
        picking = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picking = false; render() }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picking = false
        guard urls.count == 1, let url = urls.first else { render(); return }
        runToolsOperation(title: "Validating favorite-sticker backup…", operation: {
            try await Task.detached {
                try ToolsFavoriteStickerArchive.decode(exteralessToolsReadPickedFile(url, maximumBytes: ToolsFavoriteStickerArchive.maximumBytes))
            }.value
        }, completion: { [weak self] value in self?.inspected = value })
    }

    private func importArchive(_ archive: ToolsFavoriteStickerArchive) {
        let engine = context.engine
        canCancelWork = false
        runToolsOperation(title: "Merging local favorites…", operation: {
            try await exteralessToolsFirst(exteralessImportLocalFavoriteStickers(engine: engine, archive: archive))
        }, completion: { [weak self] count in
            self?.inspected = nil
            self?.canCancelWork = true
            self?.toolsStatus = "Retained \(count) additional stickers locally."
        })
    }

    private func remove(_ id: Int64) {
        let engine = context.engine
        runToolsOperation(title: "Removing local copy…", operation: {
            try await exteralessToolsFirst(exteralessRemoveLocalFavoriteSticker(engine: engine, id: id))
        }, completion: { [weak self] removed in self?.toolsStatus = removed ? "Local copy removed." : "No local copy remained." })
    }

    private func open(_ sticker: ToolsFavoriteSticker) {
        let pack: StickerPackReference
        if let id = sticker.pack?.id, let hash = sticker.pack?.accessHash { pack = .id(id: id, accessHash: hash) }
        else if let name = sticker.pack?.name { pack = .name(name) }
        else { UIPasteboard.general.string = String(sticker.id); toolsStatus = "Sticker ID copied."; render(); return }
        let controller = context.sharedContext.makeStickerPackScreen(context: context, updatedPresentationData: nil,
            mainStickerPack: pack, stickerPacks: [pack], loadedStickerPacks: [], actionTitle: nil, isEditing: false,
            expandIfNeeded: false, parentNavigationController: navigationController as? NavigationController,
            sendSticker: nil, actionPerformed: nil)
        present(controller, in: .window(.root))
    }
}
