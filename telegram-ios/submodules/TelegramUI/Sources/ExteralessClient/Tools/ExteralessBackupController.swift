import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit
import UniformTypeIdentifiers

public struct ExteralessToolsMaintenanceLease {
    public enum Outcome { case committed, rolledBack, needsRecovery }
    public let finish: @MainActor (Outcome) async throws -> Void

    public init(finish: @escaping @MainActor (Outcome) async throws -> Void) { self.finish = finish }
}

public struct ExteralessToolsBackupBindings {
    public let settings: ToolsBackupSettingsAccess
    /// Resolves a canonical location without mkdir, settings requests or Python.
    /// Actual protected mutations happen only after beginMaintenance returns.
    public let pluginLocation: @MainActor () throws -> ToolsBackupPluginLocation?
    public let beginMaintenance: @MainActor () async throws -> ExteralessToolsMaintenanceLease

    public init(settings: ToolsBackupSettingsAccess,
                pluginLocation: @escaping @MainActor () throws -> ToolsBackupPluginLocation?,
                beginMaintenance: @escaping @MainActor () async throws -> ExteralessToolsMaintenanceLease) {
        self.settings = settings
        self.pluginLocation = pluginLocation
        self.beginMaintenance = beginMaintenance
    }
}

@MainActor final class ExteralessToolsBackupService {
    var bindings: ExteralessToolsBackupBindings?
    private let restorer = ToolsBackupRestorer()

    init(bindings: ExteralessToolsBackupBindings?) { self.bindings = bindings }

    func export(includePlugins: Bool, legacy: Bool) async throws -> URL {
        let snapshot = ClientSettings.shared.readSnapshot()
        if let error = snapshot.lastError { throw error }
        let location = includePlugins ? try bindings?.pluginLocation() : nil
        if includePlugins && location == nil { throw ToolsError.unavailable("Plugin storage is not available.") }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return try await Task.detached(priority: .userInitiated) {
            let data: Data
            let name: String
            if legacy {
                data = try ToolsLegacyBackup.export(settings: snapshot.values.filter { !snapshot.secretKeys.contains($0.key) },
                                                    definitions: snapshot.definitions.filter { !snapshot.secretKeys.contains($0.key) })
                name = "exteraless-config.extera"
            } else {
                data = try ToolsBackupArchive.export(snapshot: snapshot, appVersion: version, plugins: location)
                name = "exteraless-config." + ToolsBackupArchive.fileExtension
            }
            return try exteralessToolsTemporaryFile(data: data, name: name)
        }.value
    }

    func inspect(_ url: URL) async throws -> ToolsBackupInspection {
        let snapshot = ClientSettings.shared.readSnapshot()
        return try await Task.detached(priority: .userInitiated) {
            let data = try exteralessToolsReadPickedFile(url, maximumBytes: ToolsBackupPolicy.maximumArchiveBytes)
            return try ToolsBackupArchive.inspect(data, definitions: snapshot.definitions, secretKeys: snapshot.secretKeys)
        }.value
    }

    func restore(_ inspection: ToolsBackupInspection, includePlugins: Bool) async throws -> ToolsBackupRestoreResult {
        guard let bindings else { throw ToolsError.unavailable("Atomic settings restore has not been bound by the application.") }
        let restorer = restorer
        let settings = bindings.settings
        let selected: ToolsBackupInspection
        if includePlugins { selected = inspection }
        else {
            let payload = try inspection.admittedPayload(includePluginSettings: false)
            let snapshot = try settings.snapshot()
            selected = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload), definitions: snapshot.definitions, secretKeys: snapshot.secretKeys)
        }
        let lease = try await bindings.beginMaintenance()
        let result: ToolsBackupRestoreResult
        do {
            let location = try bindings.pluginLocation()
            result = try await Task.detached(priority: .userInitiated) {
                return try restorer.restore(selected, settings: settings, plugins: location)
            }.value
        } catch {
            let uncertain: Bool
            if case .durability? = error as? ToolsBackupWriteFailure { uncertain = true }
            else { uncertain = (error as? ToolsError) == .rollbackFailed }
            let outcome: ExteralessToolsMaintenanceLease.Outcome = uncertain ? .needsRecovery : .rolledBack
            try await lease.finish(outcome)
            throw error
        }
        try await lease.finish(.committed)
        return result
    }

    func inspectRecovery() async throws -> ToolsBackupRecoveryInspection? {
        guard let bindings, let location = try bindings.pluginLocation() else { throw ToolsError.unavailable("Recovery storage has not been bound by the application.") }
        let restorer = restorer, settings = bindings.settings
        return try await Task.detached(priority: .userInitiated) {
            try restorer.inspectRecovery(settings: settings, plugins: location)
        }.value
    }

    func reconcileKeepingCurrent(_ review: ToolsBackupRecoveryInspection) async throws -> ToolsBackupReconciliationResult {
        guard let bindings else { throw ToolsError.unavailable("Recovery maintenance has not been bound by the application.") }
        let lease = try await bindings.beginMaintenance()
        let result: ToolsBackupReconciliationResult
        do {
            guard let location = try bindings.pluginLocation() else { throw ToolsError.rollbackFailed }
            let restorer = restorer, settings = bindings.settings
            result = try await Task.detached(priority: .userInitiated) {
                try restorer.reconcileKeepingCurrent(review, settings: settings, plugins: location)
            }.value
        } catch {
            try await lease.finish(.needsRecovery)
            throw error
        }
        // Commits the explicit keep-current decision, not the abandoned import.
        try await lease.finish(.committed)
        return result
    }
}

final class ExteralessBackupController: ExteralessToolsListController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let service: ExteralessToolsBackupService
    private var includePlugins = false
    private var restorePlugins = true
    private var inspection: ToolsBackupInspection?
    private var picking = false
    private var recovery: ToolsBackupRecoveryInspection?

    init(context: AccountContext, service: ExteralessToolsBackupService) {
        self.service = service
        super.init(context: context)
        self.title = "Configuration backup"
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        var sections = operationSections()
        var exportRows: [PluginListRow] = []
        if service.bindings != nil {
            var row = PluginListRow(id: "include-plugins", title: "Include plugin settings", detail: "Registered non-secret configuration fields only")
            row.enabled = !isBusy && contextAvailable
            row.toggle = (includePlugins, { [weak self] value in self?.includePlugins = value; self?.render() })
            exportRows.append(row)
        }
        exportRows.append(exteralessToolsAction("export", "Export backup…", enabled: !isBusy && contextAvailable) { [weak self] in self?.export(legacy: false) })
        exportRows.append(exteralessToolsAction("export-extera", "Export .extera-compatible settings…", detail: "Common Android/iOS configuration fields", enabled: !isBusy && contextAvailable) { [weak self] in self?.export(legacy: true) })
        sections.append(PluginListSection(title: "Export", footer: "A self-contained, versioned configuration archive with a SHA-256 checksum. API keys and other ClientSettings secrets stay in Keychain. Accounts, chat history, plugin code and permission grants are not part of the archive.", rows: exportRows))
        sections.append(PluginListSection(title: "Import", rows: [
            exteralessToolsAction("inspect", "Choose and inspect backup…", detail: ".exteraless-backup or .extera · up to 24 MiB",
                                  enabled: !isBusy && !picking && contextAvailable) { [weak self] in self?.pick() }
        ]))
        if service.bindings != nil {
            var rows = [exteralessToolsAction("review-recovery", "Review recovery…", enabled: !isBusy && contextAvailable) { [weak self] in self?.reviewRecovery() }]
            if let recovery {
                rows.append(PluginListRow(id: "recovery-summary", title: "An interrupted restore needs a decision",
                    detail: "Journal v\(recovery.journalVersion) · \(recovery.classification.rawValue)\n\(recovery.observed.values.count) public settings · \(recovery.currentPluginFiles?.count ?? 0) current plugin files\n\(recovery.observationIsFresh ? "Fresh readonly public observation" : "Cached public observation — not disk-write ownership proof")"))
                for key in recovery.observed.values.keys.sorted().prefix(20) {
                    let stored = recovery.observed.storedKeys.contains(key)
                    rows.append(PluginListRow(id: "recovery-" + key, title: key,
                        detail: "Observed override: \(stored ? "stored" : "absent/default") · before: \(recovery.before?.storedKeys.contains(key) == true ? "stored" : "absent/unknown")"))
                }
                rows.append(exteralessToolsAction("reconcile-current", "Keep current configuration…", enabled: !isBusy && contextAvailable) { [weak self] in self?.confirmReconciliation() })
            }
            sections.append(PluginListSection(title: "Recovery", footer: "Ambiguous writes are not rolled back by matching target values. Review keeps live state and retains original recovery evidence; the real Host lease controls resuming plugins.", rows: rows))
        }
        if let inspection {
            let integrity = inspection.origin == .native ? "SHA-256 verified" : "Legacy .extera — this format has no checksum"
            var rows = [PluginListRow(id: "inspection", title: integrity,
                                     detail: "\(inspection.settingCount) supported settings (\(inspection.resetting.count) restored to this installation's defaults) · \(inspection.pluginFileCount) plugin settings files\n\(inspection.payload.appVersion) · \(inspection.payload.createdAt)")]
            if inspection.pluginFileCount > 0 {
                var row = PluginListRow(id: "restore-plugins", title: "Restore plugin settings")
                row.enabled = !isBusy && contextAvailable && service.bindings != nil
                row.toggle = (restorePlugins, { [weak self] value in self?.restorePlugins = value; self?.render() })
                rows.append(row)
            }
            if !inspection.ignoredKeys.isEmpty {
                rows.append(PluginListRow(id: "ignored", title: "\(inspection.ignoredKeys.count) fields have no registered iOS equivalent",
                                          detail: inspection.ignoredKeys.prefix(20).joined(separator: ", ")))
            }
            rows.append(exteralessToolsAction("restore", "Apply configuration…", enabled: !isBusy && contextAvailable && service.bindings != nil
                                              && (inspection.settingCount > 0 || (restorePlugins && inspection.pluginFileCount > 0))) { [weak self] in self?.confirmRestore() })
            let footer = service.bindings == nil ? "Restore requires the application's atomic settings/maintenance binding."
                : "Review completed without running plugin code. Applying merges these fields into your configuration and preserves other local fields. Plugins are paused for the transaction."
            sections.append(PluginListSection(title: "Preview", footer: footer, rows: rows))
        }
        setSections(sections)
    }

    private func export(legacy: Bool) {
        canCancelWork = true
        let service = service
        let includePlugins = includePlugins && !legacy
        runToolsOperation(title: "Building configuration archive…", operation: {
            try await service.export(includePlugins: includePlugins, legacy: legacy)
        }, discard: exteralessToolsDiscardTemporaryFile, completion: { [weak self] url in
            guard let self else { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return }
            exteralessToolsShare(url, from: self, removeOnCompletion: true)
        })
    }

    private func pick() {
        picking = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.presentationController?.delegate = self
        present(picker, animated: true)
        render()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picking = false
        guard urls.count == 1, let url = urls.first, contextAvailable else { render(); return }
        inspectFile(url)
    }

    /// Coordinator can use this for a downloaded chat document; it goes through
    /// exactly the same bounded data-only inspection and explicit apply step.
    func inspectFile(_ url: URL) {
        canCancelWork = true
        let service = service
        runToolsOperation(title: "Validating backup…", operation: { try await service.inspect(url) }, completion: { [weak self] value in
            self?.inspection = value
            self?.restorePlugins = true
        })
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picking = false; render() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { picking = false; render() }

    private func confirmRestore() {
        guard let inspection else { return }
        let alert = UIAlertController(title: "Apply configuration?", message: "Apply \(inspection.settingCount) settings and \(restorePlugins ? inspection.pluginFileCount : 0) plugin configuration files from this backup?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self] _ in
            guard let self, self.contextAvailable else { return }
            self.canCancelWork = false
            let service = self.service
            let includePlugins = self.restorePlugins
            self.runToolsOperation(title: "Applying configuration atomically…", operation: {
                try await service.restore(inspection, includePlugins: includePlugins)
            }, completion: { [weak self] result in
                self?.inspection = nil
                self?.canCancelWork = true
                self?.toolsStatus = "Restored \(result.settings) settings and \(result.pluginFiles) plugin configuration files."
            })
        })
        present(alert, animated: true)
    }

    private func reviewRecovery() {
        canCancelWork = true
        let service = service
        runToolsOperation(title: "Inspecting recovery record…", operation: { try await service.inspectRecovery() }, completion: { [weak self] value in
            self?.recovery = value
            self?.toolsStatus = value == nil ? "No unresolved recovery record." : "Review the retained state before choosing how to proceed."
        })
    }

    private func confirmReconciliation() {
        guard let recovery else { return }
        let alert = UIAlertController(title: "Keep current configuration?",
            message: "This leaves live client and plugin settings as they are. The interrupted restore journal is archived and its original/staged copies are retained. Plugins resume only after the Host finishes maintenance. It does not apply the old backup.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Keep current", style: .default) { [weak self] _ in
            guard let self, self.contextAvailable else { return }
            self.canCancelWork = false
            let service = self.service
            self.runToolsOperation(title: "Recording recovery decision…", operation: {
                try await service.reconcileKeepingCurrent(recovery)
            }, completion: { [weak self] result in
                self?.recovery = nil
                self?.canCancelWork = true
                self?.toolsStatus = "Current configuration kept. Recovery evidence: \(result.evidenceURL.lastPathComponent)"
            })
        })
        present(alert, animated: true)
    }
}
