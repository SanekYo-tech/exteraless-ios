import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit
import UniformTypeIdentifiers

final class ExteralessIconPacksController: ExteralessAppearanceListController, UIDocumentPickerDelegate {
    enum Mode { case list, pack(String), editor }
    private enum PickTarget { case archive, icon(pack: String, resource: String) }

    private let mode: Mode
    private var packs: [AppearanceIconPackMetadata] = []
    private var pickTarget: PickTarget?
    private var exportURL: URL?
    private var renderingError: String?

    init(context: AccountContext, mode: Mode) {
        self.mode = mode
        super.init(context: context)
        self.title = "Icon Packs"
        NotificationCenter.default.addObserver(self, selector: #selector(self.iconResourcesChanged), name: AppearanceFeatures.resourcesChangedNotification, object: nil)
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func refresh() {
        self.perform(title: "Loading icon packs…", operation: {
            try await ExteralessIconPacks.shared.store.list()
        }, completion: { [weak self] packs in
            self?.packs = packs
            self?.iconResourcesChanged()
        })
    }

    override func render() {
        let settings = ClientSettings.shared
        var sections: [PluginListSection] = []
        switch self.mode {
        case .list:
            var enabled = PluginListRow(id: "enabled", title: "Enable Custom Icon Packs")
            enabled.enabled = !self.isBusy
            enabled.toggle = (settings.bool("appearance.enabled"), { [weak self] value in
                self?.save(.bool(value), key: "appearance.enabled")
            })
            var rows = [enabled]
            let active = AppearanceIconPackPolicy.activeIds(settings.string("appearance.activePacks"))
            let ordered = self.packs.sorted { lhs, rhs in
                let l = active.firstIndex(of: lhs.packId) ?? Int.max
                let r = active.firstIndex(of: rhs.packId) ?? Int.max
                return l == r ? lhs.packName.localizedStandardCompare(rhs.packName) == .orderedAscending : l < r
            }
            for pack in ordered {
                let supported = pack.icons.keys.filter { AppearanceIconNames.mapping(for: $0) != nil }.count
                var row = PluginListRow(id: pack.packId, title: pack.packName, detail: "\(supported) mapped / \(pack.icons.count) icons" + (active.contains(pack.packId) ? " · Priority \((active.firstIndex(of: pack.packId) ?? 0) + 1)" : " · Inactive"))
                row.accessory = .disclosure
                row.action = { [weak self] in
                    guard let self else { return }
                    self.push(ExteralessIconPacksController(context: self.context, mode: .pack(pack.packId)))
                }
                rows.append(row)
            }
            sections.append(PluginListSection(footer: "The first active pack wins when icons overlap. Mapped in-app menu and tab icons are tinted by the current theme. Unmapped Android resources are preserved for export.", rows: rows))
            var create = PluginListRow(id: "create", title: "Create Icon Pack")
            create.style = .accent
            create.action = { [weak self] in self?.namePrompt(pack: nil) }
            var importRow = PluginListRow(id: "import", title: "Import .icons Archive")
            importRow.style = .accent
            importRow.action = { [weak self] in self?.pick(.archive) }
            create.enabled = !self.isBusy
            importRow.enabled = !self.isBusy
            sections.append(PluginListSection(rows: [create, importRow]))
        case let .pack(id):
            guard let pack = self.packs.first(where: { $0.packId == id }) else {
                self.setSections(self.operationSections() + [PluginListSection(rows: [PluginListRow(id: "missing", title: "Pack is not available")])])
                return
            }
            self.title = pack.packName
            let active = AppearanceIconPackPolicy.activeIds(settings.string("appearance.activePacks"))
            var use = PluginListRow(id: "use", title: "Use This Pack", detail: pack.packId)
            use.toggle = (active.contains(id), { [weak self] _ in
                self?.save(.string(AppearanceIconPackPolicy.toggled(id, in: active).joined(separator: ",")), key: "appearance.activePacks")
            })
            var priority = PluginListRow(id: "priority", title: "Move to Highest Priority")
            priority.action = { [weak self] in self?.save(.string(([id] + active.filter { $0 != id }).joined(separator: ",")), key: "appearance.activePacks") }
            var edit = PluginListRow(id: "edit", title: "Edit Icons")
            edit.action = { [weak self] in
                self?.perform(title: "Opening editor…", operation: {
                    try await ExteralessAppearancePersistence.set(.string(id), for: "appearance.editingPackId")
                }, completion: { [weak self] in
                    guard let self else { return }
                    self.push(ExteralessIconPacksController(context: self.context, mode: .editor))
                })
            }
            var rename = PluginListRow(id: "rename", title: "Rename Pack")
            rename.action = { [weak self] in self?.namePrompt(pack: pack) }
            var export = PluginListRow(id: "export", title: "Export .icons Archive")
            export.action = { [weak self] in self?.export(id) }
            var remove = PluginListRow(id: "remove", title: "Delete Pack")
            remove.style = .destructive
            remove.action = { [weak self] in self?.remove(id) }
            var rows = [use, priority, edit, rename, export, remove]
            for index in rows.indices { rows[index].enabled = !self.isBusy }
            sections.append(PluginListSection(footer: "\(pack.author) · \(pack.version)", rows: rows))
        case .editor:
            self.title = "Edit Icons"
            let id = settings.string("appearance.editingPackId")
            if let pack = self.packs.first(where: { $0.packId == id }) {
                let rows = AppearanceIconNames.mappings.map { mapping -> PluginListRow in
                    let key = pack.icons[mapping.asset] != nil ? mapping.asset : mapping.android
                    var row = PluginListRow(id: mapping.asset, title: mapping.android, detail: mapping.asset + (pack.icons[key] != nil ? " · Custom" : " · Original"))
                    row.enabled = !self.isBusy
                    row.action = { [weak self] in self?.pick(.icon(pack: id, resource: key)) }
                    if pack.icons[key] != nil {
                        row.remove = { [weak self] in
                            self?.perform(title: "Restoring icon…", operation: {
                                try await ExteralessIconPacks.shared.store.replaceIcon(id: id, resource: key, data: nil)
                            }, completion: { [weak self] in self?.reloadAfterMutation() })
                        }
                    }
                    return row
                }
                sections.append(PluginListSection(title: pack.packName, footer: "Tap to select a transparent PNG, JPEG, WebP or SVG. Swipe a custom icon to restore it. These are in-app icons; the iOS launcher and notification icon are managed by iOS.", rows: rows))
            } else {
                sections.append(PluginListSection(rows: [PluginListRow(id: "choose", title: "Choose a pack in Icon Packs first", detail: "No editable pack is selected.")]))
            }
        }
        if let renderingError = self.renderingError {
            var row = PluginListRow(id: "render-error", title: "Icons could not be applied", detail: renderingError)
            row.style = .error
            sections.append(PluginListSection(rows: [row]))
        }
        sections += self.operationSections()
        self.setSections(sections)
    }

    @objc private func iconResourcesChanged() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.renderingError = ExteralessIconPacks.shared.errorText
            self.render()
        }
    }

    private func save(_ value: ClientSettingValue, key: String) {
        self.perform(title: "Saving…", operation: { try await ExteralessAppearancePersistence.set(value, for: key) }, completion: { [weak self] in self?.reloadAfterMutation() })
    }

    private func reloadAfterMutation() {
        Task { @MainActor [weak self] in
            ExteralessIconPacks.shared.reload()
            self?.refresh()
        }
    }

    private func namePrompt(pack: AppearanceIconPackMetadata?) {
        guard !self.isBusy else { return }
        let alert = UIAlertController(title: pack == nil ? "Create Icon Pack" : "Rename Pack", message: nil, preferredStyle: .alert)
        alert.addTextField { field in field.text = pack?.packName; field.placeholder = "Pack name" }
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Done, style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.perform(title: "Saving pack…", operation: {
                if let pack { try await ExteralessIconPacks.shared.store.rename(id: pack.packId, name: name) }
                else { _ = try await ExteralessIconPacks.shared.store.create(name: name) }
            }, completion: { [weak self] in self?.reloadAfterMutation() })
        }))
        self.context.sharedContext.applicationBindings.presentNativeController(alert)
    }

    private func pick(_ target: PickTarget) {
        guard !self.isBusy, self.pickTarget == nil, self.exportURL == nil else { return }
        self.pickTarget = target
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.context.sharedContext.applicationBindings.presentNativeController(picker)
    }

    private func remove(_ id: String) {
        self.perform(title: "Removing pack…", operation: {
            try await ExteralessIconPacks.shared.store.remove(id: id)
            let settings = ClientSettings.shared
            let ids = AppearanceIconPackPolicy.activeIds(settings.string("appearance.activePacks")).filter { $0 != id }
            try await ExteralessAppearancePersistence.set(.string(ids.joined(separator: ",")), for: "appearance.activePacks")
            if settings.string("appearance.editingPackId") == id {
                try await ExteralessAppearancePersistence.set(.string(""), for: "appearance.editingPackId")
            }
        }, completion: { [weak self] in
            self?.reloadAfterMutation()
            self?.navigationController?.popViewController(animated: true)
        })
    }

    private func export(_ id: String) {
        self.perform(title: "Exporting pack…", operation: {
            let data = try await ExteralessIconPacks.shared.store.export(id: id)
            return try await Task.detached(priority: .userInitiated) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("exteraless-\(UUID().uuidString).icons")
                try data.write(to: url, options: .atomic)
                return url
            }.value
        }, completion: { [weak self] url in
            guard let self else { return }
            self.exportURL = url
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            self.context.sharedContext.applicationBindings.presentNativeController(picker)
        })
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if self.exportURL != nil { self.cleanupExport(); return }
        guard let target = self.pickTarget, let url = urls.first else { self.pickTarget = nil; return }
        self.pickTarget = nil
        self.perform(title: "Importing icons…", operation: {
            switch target {
            case .archive: _ = try await ExteralessIconPacks.shared.importArchive(at: url)
            case let .icon(pack, resource): try await ExteralessIconPacks.shared.replaceIcon(packId: pack, resource: resource, url: url)
            }
        }, completion: { [weak self] in self?.reloadAfterMutation() })
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.pickTarget = nil
        self.cleanupExport()
    }

    private func cleanupExport() {
        guard let url = self.exportURL else { return }
        self.exportURL = nil
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }

    deinit {
        if let url = self.exportURL { DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) } }
    }
}
