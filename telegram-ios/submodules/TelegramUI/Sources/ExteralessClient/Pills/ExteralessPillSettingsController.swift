import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

class ExteralessPillTableController: ExteralessChatTableController {
    let pillRuntime: ExteralessPillRuntime
    private var settingsObserver: ClientSettingsObservation?
    private var registryObserver: PillCancellation?
    var settingsChanged: (() -> Void)?
    init(context: AccountContext, title: String) {
        self.pillRuntime = ExteralessPillRuntimes.get(context: context)
        super.init(context: context, title: title)
        self.pillRuntime.trackScreen(self)
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard self.pillRuntime.lease.isValid else { self.invalidateAccount(); return }
        self.settingsObserver = ClientSettings.shared.observe { [weak self] keys in
            guard exteralessPillSettingsAffectView(keys) else { return }
            DispatchQueue.main.async { [weak self] in guard let self, self.accountIsValid, self.screenIsVisible else { return }; self.settingsChanged?() }
        }
        self.registryObserver = PillPluginRegistry.shared.observe { [weak self] in
            DispatchQueue.main.async { [weak self] in guard let self, self.accountIsValid, self.screenIsVisible else { return }; self.settingsChanged?() }
        }
        self.settingsChanged?()
    }
    override func viewWillDisappear(_ animated: Bool) {
        self.settingsObserver?.cancel(); self.settingsObserver = nil
        self.registryObserver?.cancel(); self.registryObserver = nil
        super.viewWillDisappear(animated)
    }
    func writePillSettings(_ operation: @escaping @Sendable () throws -> Void, completion: @escaping () -> Void) {
        let lease = self.pillRuntime.lease
        self.writeSettings({ try lease.withCurrent(operation) }, completion: completion)
    }
}

/// The class name and initializer remain compatible with ExteralessChatIntegration.
final class ExteralessPillSettingsController: ExteralessPillTableController {
    private var available: [PillDescriptor] = []
    private var visibleIds: [Int] = []
    private var activeSection: Int?
    init(context: AccountContext) {
        super.init(context: context, title: "Status pills")
        self.settingsChanged = { [weak self] in self?.render() }
        self.refreshAction = { [weak self] in self?.render(); self?.tableView.refreshControl?.endRefreshing() }
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Reorder", style: .plain, target: self, action: #selector(self.toggleEditing))
        self.render()
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func render() {
        guard self.accountIsValid else { return }
        do {
            let config = try self.pillRuntime.configuration()
            self.available = try self.pillRuntime.descriptors()
            let availableIds = Set(self.available.map(\.id))
            self.visibleIds = config.layout.visible(available: availableIds)
            let dormant = config.layout.active.filter { !availableIds.contains($0) }.count + config.layout.hidden.filter { !availableIds.contains($0) }.count
            self.sections = []
            if let error = self.pillRuntime.migrationError {
                self.sections.append(.init(rows: [.init(id: "pills.migrationError", title: error, action: { [weak self] in
                    guard let self else { return }; let store = self.pillRuntime.store
                    self.writePillSettings({ try store.migrateLegacyRates() }, completion: { [weak self] in self?.render() })
                })]))
            }
            self.activeSection = self.sections.count
            self.sections.append(.init(title: "Active", footer: "Tap to hide; the info button opens readings and options. Reorder by dragging. \(dormant) unavailable Android/plugin IDs are retained in the saved layout.", rows: self.visibleIds.isEmpty ? [.init(id: "pills.empty", title: "No active status pills", enabled: false)] : self.visibleIds.compactMap { id in
                self.available.first(where: { $0.id == id }).map { descriptor in .init(id: "pills.item.\(id)", title: descriptor.title, checked: true, action: { [weak self] in self?.toggle(id, enabled: false) }) }
            }))
            self.sections.append(.init(title: "Available", rows: self.available.filter { !self.visibleIds.contains($0.id) }.map { descriptor in
                .init(id: "pills.item.\(descriptor.id)", title: descriptor.title, action: { [weak self] in self?.toggle(descriptor.id, enabled: true) })
            }))
            self.sections.append(.init(footer: "Only the selected, visible status subscribes. Automatic refresh stops in the background. Long-press the header for settings; swipe it vertically or horizontally to change status.", rows: [
                .init(id: "pills.addRate", title: "Add currency pair", detail: "\(config.instances.count) of \(PillRateInstance.maximumCount)", enabled: config.instances.count < PillRateInstance.maximumCount, action: { [weak self] in
                    guard let self else { return }; let store = self.pillRuntime.store
                    let reserved = Set(PillPluginRegistry.shared.descriptors.map(\.id))
                    self.writePillSettings({ _ = try store.addRate(pair: .init(base: "USD", target: "AUTO"), reservedIds: reserved) }, completion: { [weak self] in self?.render() })
                }),
                .init(id: "pills.weather", title: "Weather settings", action: { [weak self] in guard let self else { return }; self.pushChild(ExteralessPillWeatherSettingsController(context: self.context)) }),
                .init(id: "pills.loop", title: "Loop scrolling", checked: config.layout.loop, action: { [weak self] in
                    guard let self else { return }
                    let before = ClientSettings.shared.readSnapshot()
                    let value = before.values["chats.infiniteScrolling"] != .bool(false)
                    self.writePillSettings({ try ClientSettings.shared.applyPublic(["chats.infiniteScrolling": .bool(!value)], expected: before) }, completion: { [weak self] in self?.render() })
                }),
                .init(id: "pills.reset", title: "Reset layout", detail: "Restore Cache and Proxy", action: { [weak self] in self?.resetLayout() })
            ]))
        } catch {
            self.activeSection = nil; self.available = []; self.visibleIds = []
            self.sections = [.init(rows: [.init(id: "pills.configurationError", title: "Rate configuration needs repair", detail: "The saved value has been preserved. Check pairs before saving; the maximum is 12.", action: { [weak self] in self?.repairRates() })])]
        }
        self.reloadRows()
    }
    private func toggle(_ id: Int, enabled: Bool) {
        let before = ClientSettings.shared.readSnapshot()
        guard var layout = try? PillConfiguration(values: before.values).layout else { return }
        layout.setActive(id, enabled: enabled)
        let patch = layout.patch
        self.writePillSettings({ try ClientSettings.shared.applyPublic(patch, expected: before) }, completion: { [weak self] in self?.render() })
    }
    private func resetLayout() {
        let before = ClientSettings.shared.readSnapshot()
        let patch = PillLayout(loop: before.values["chats.infiniteScrolling"] != .bool(false)).patch
        self.writePillSettings({ try ClientSettings.shared.applyPublic(patch, expected: before) }, completion: { [weak self] in self?.render() })
    }
    private func repairRates() {
        let alert = UIAlertController(title: "Rate pairs", message: "Format: 100:BTC>USD;101:XAU>EUR. The original value is not discarded when validation fails.", preferredStyle: .alert)
        alert.addTextField { $0.text = ClientSettings.shared.string("chats.rateInstancesRaw"); $0.autocapitalizationType = .allCharacters }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let raw = alert?.textFields?.first?.text else { return }
            let before = ClientSettings.shared.readSnapshot()
            self.writePillSettings({
                _ = try PillRateInstance.parse(raw)
                try ClientSettings.shared.applyPublic(["chats.rateInstancesRaw": .string(raw)], expected: before)
            }, completion: { [weak self] in self?.render() })
        })
        self.context.sharedContext.applicationBindings.presentNativeController(alert)
    }
    @objc private func toggleEditing() {
        self.tableView.setEditing(!self.tableView.isEditing, animated: true)
        self.tableView.allowsSelectionDuringEditing = true
        self.navigationItem.rightBarButtonItem?.title = self.tableView.isEditing ? "Done" : "Reorder"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        if self.sections[indexPath.section].rows[indexPath.row].id.hasPrefix("pills.item.") { cell.accessoryType = .detailButton; cell.editingAccessoryType = .detailButton }
        else { cell.editingAccessoryType = .none }
        return cell
    }
    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard self.accountIsValid, let id = Int(self.sections[indexPath.section].rows[indexPath.row].id.split(separator: ".").last ?? "") else { return }
        self.pushChild(ExteralessPillDetailController(context: self.context, id: id))
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { indexPath.section == self.activeSection && self.visibleIds.indices.contains(indexPath.row) }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        proposedDestinationIndexPath.section == self.activeSection && self.visibleIds.indices.contains(proposedDestinationIndexPath.row) ? proposedDestinationIndexPath : sourceIndexPath
    }
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let before = ClientSettings.shared.readSnapshot()
        guard var layout = try? PillConfiguration(values: before.values).layout,
              self.visibleIds.indices.contains(sourceIndexPath.row), self.visibleIds.indices.contains(destinationIndexPath.row) else { self.render(); return }
        var ids = self.visibleIds
        let moved = ids.remove(at: sourceIndexPath.row); ids.insert(moved, at: destinationIndexPath.row)
        do { try layout.reorder(ids, available: Set(self.available.map(\.id))) } catch { self.render(); return }
        let patch = layout.patch
        self.render() // Restore the source of truth until the durable move commits (also covers a failed write).
        self.writePillSettings({ try ClientSettings.shared.applyPublic(patch, expected: before) }, completion: { [weak self] in self?.render() })
    }
}
