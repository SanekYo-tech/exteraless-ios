import AccountContext
import ExteralessCore
import Foundation
import UIKit

@MainActor final class ExteralessCloudController: ExteralessCloudListController {
    private let settings: ClientSettings
    private let session: CloudSyncSession
    private var plan: CloudRestorePlan?
    private var legacyPlan: CloudLegacyRestorePlan?

    init(context: AccountContext, settings: ClientSettings, session: CloudSyncSession) {
        self.settings = settings
        self.session = session
        super.init(context: context)
        title = "Cloud settings"
        cancelExternal = { [weak session] in session?.cancel() }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        externalBusy = session.isBusy
        allowsCancellation = session.canCancel
        let available = contextAvailable && !session.isClosed
        let policy = CloudSyncPolicy(snapshot: settings.readSnapshot())
        var sections = operationSections()
        if case let .failed(error) = session.status, operationFailure == nil {
            var row = PluginListRow(id: "cloud-session-error", title: "Cloud settings", detail: error.errorDescription)
            row.style = .error
            sections.append(PluginListSection(rows: [row]))
        } else if session.isBusy && operationMessage == nil {
            var row = PluginListRow(id: "cloud-session-status", title: statusText)
            row.loading = true
            sections.append(PluginListSection(rows: [row]))
        }
        var auto = PluginListRow(id: "cloud-auto", title: "Automatically sync settings", detail: "Active account · foreground only")
        auto.enabled = available && !isBusy
        auto.toggle = (policy.autoSync, { [weak self] value in self?.setFlag("cloud.autoSync", value) })
        var keys = PluginListRow(id: "cloud-keys", title: "Include service API keys", detail: "AI, translation and transcription keys only")
        keys.enabled = available && !isBusy
        keys.toggle = (policy.includeApiKeys, { [weak self] value in self?.setFlag("cloud.includeApiKeys", value) })
        sections.append(PluginListSection(title: "Synchronization", footer: "Uses the original exteralesscloudbot account storage. Like Android, it is transport-encrypted, not end-to-end encrypted. Turning key inclusion off excludes future backups; old revisions remain until deleted. Telegram App hashes, account credentials, prompts and chat history are excluded.", rows: [auto, keys]))
        sections.append(PluginListSection(rows: [
            PluginListRow(id: "cloud-local-date", title: "Last successful sync or restore", detail: dateText(session.state.lastSuccessfulSyncMilliseconds)),
            exteralessCloudAction("cloud-sync", "Sync now", enabled: available && !isBusy) { [weak self] in self?.sync() },
            exteralessCloudAction("cloud-preview", "Preview cloud backups", enabled: available && !isBusy) { [weak self] in self?.loadCatalog() }
        ]))
        if let catalog = session.latestCatalog {
            var rows: [PluginListRow] = []
            if catalog.heads.isEmpty {
                rows.append(PluginListRow(id: "cloud-empty", title: "No native backup", detail: catalog.hasAndroidBackup
                    ? "An Android settings backup is available for explicit preview below."
                    : "Sync now to create a backup for this account."))
            }
            if catalog.hasAndroidBackup {
                rows.append(exteralessCloudAction("cloud-android-preview", "Preview Android settings backup",
                    detail: "Original SharedPreferences format · mapped/skipped fields and service-key destinations",
                    enabled: available && !isBusy) { [weak self] in self?.previewAndroid() })
            }
            let orderedRevisions = catalog.headRevisions + catalog.revisions.filter { !catalog.heads.contains($0.id) }
                .sorted { $0.createdAtMilliseconds > $1.createdAtMilliseconds }
            for revision in orderedRevisions {
                rows.append(exteralessCloudAction("cloud-revision-" + revision.id.uuidString,
                    dateText(revision.createdAtMilliseconds), detail: (catalog.heads.contains(revision.id) ? "Current revision " : "Previous revision ") + String(revision.id.uuidString.prefix(8)),
                    enabled: available && !isBusy) { [weak self] in self?.preview(revision, heads: catalog.heads) })
            }
            if !catalog.heads.isEmpty {
                rows.append(exteralessCloudAction("cloud-use-local", "Use this device's settings…", detail: "Creates a new revision after the reviewed cloud heads",
                    enabled: available && !isBusy) { [weak self] in self?.confirmUpload(heads: catalog.heads) })
                var delete = exteralessCloudAction("cloud-delete", "Delete native cloud backup history…", enabled: available && !isBusy) { [weak self] in
                    self?.confirmDelete(heads: catalog.heads)
                }
                delete.style = .destructive
                rows.append(delete)
            }
            sections.append(PluginListSection(title: catalog.heads.count > 1 ? "Conflicting revisions — choose a preview" : "Remote backup", rows: rows))
        }
        let orphaned = session.latestCatalog.map { $0.heads.isEmpty && $0.hasNativeData } ?? false
        if session.status == .failed(.malformedRemote) || orphaned {
            var repair = exteralessCloudAction("cloud-repair-delete", "Remove incomplete native backup data…", enabled: available && !isBusy) { [weak self] in self?.confirmRepair() }
            repair.style = .destructive
            sections.append(PluginListSection(rows: [repair]))
        }
        if let plan {
            let keysText = policy.includeApiKeys && plan.includedApiKeys ? "Included service keys follow this preview's add/retain decisions." : "This preview restores public settings without service keys. Preview again to include keys."
            sections.append(PluginListSection(title: "Restore preview", footer: keysText + " A local or remote change after this preview requires a new preview.", rows: [
                PluginListRow(id: "cloud-plan", title: "\(plan.settingCount) supported settings · \(plan.credentialCount) service keys",
                    detail: "\(plan.ignoredCount) fields have no portable registered equivalent. Existing service keys are retained."),
                exteralessCloudAction("cloud-restore", "Restore this revision…",
                    detail: session.restore == nil ? "Waiting for application maintenance/recovery binding" : nil,
                    enabled: available && !isBusy && session.restore != nil) { [weak self] in self?.confirmRestore(plan) }
            ]))
        }
        if let legacyPlan {
            var rows = [PluginListRow(id: "legacy-summary", title: "\(legacyPlan.mapped.count) mapped · \(legacyPlan.skipped.count) skipped · \(legacyPlan.credentialCount) keys",
                detail: "\(legacyPlan.settingCount) native settings. Source timestamps are not assigned as this account's sync date.")]
            rows.append(exteralessCloudAction("legacy-restore", legacyPlan.credentialCount > 0 ? "Restore and authorize listed incoming keys…" : "Restore mapped Android settings…",
                detail: session.restoreAndroid == nil ? "Waiting for application maintenance binding" : nil,
                enabled: available && !isBusy && session.restoreAndroid != nil && (legacyPlan.settingCount > 0 || (policy.includeApiKeys && legacyPlan.credentialCount > 0))) { [weak self] in self?.confirmAndroidRestore(legacyPlan) })
            sections.append(PluginListSection(title: "Android restore preview", footer: "Only the fields listed as mapped are applied. Existing API keys and their origin bindings are retained. Imported variable-endpoint keys are authorized only for the destinations listed below, after confirmation.", rows: rows))
            for (title, fields) in [("Mapped preferences", legacyPlan.mapped), ("Included service credentials", legacyPlan.credentialGroups), ("Skipped preferences", legacyPlan.skipped)] where !fields.isEmpty {
                let rows = fields.enumerated().map { index, field -> PluginListRow in
                    let identity = field.originalIDs.isEmpty ? "Source preference (no inventory ID): " + field.sourcePreference : field.originalIDs.joined(separator: ", ")
                    let detail = [field.sourcePreference, field.nativeKeys.joined(separator: ", "), field.reason?.explanation, field.detail]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                    return PluginListRow(id: "legacy-" + title + "-\(index)", title: identity, detail: detail)
                }
                sections.append(PluginListSection(title: title, rows: rows))
            }
        }
        setSections(sections)
    }

    private var statusText: String {
        switch session.status {
        case .syncing: return "Syncing settings…"
        case .reading: return "Reading cloud backup metadata…"
        case .restoring: return "Restoring reviewed settings…"
        case .deleting: return "Deleting native backup history…"
        default: return "Cloud settings"
        }
    }

    private func setFlag(_ key: String, _ value: Bool) {
        let settings = self.settings
        runWriter("Saving cloud preference…", writer: {
            try settings.applyPublic([key: .bool(value)])
        }, completion: { [weak self] _ in self?.plan = nil; self?.legacyPlan = nil })
    }

    private func sync(heads: Set<UUID>? = nil) {
        let session = self.session
        run("Syncing settings…", operation: { try await session.syncNow(acknowledging: heads) }, completion: { [weak self] result in
            self?.plan = nil
            self?.legacyPlan = nil
            self?.operationMessage = result.uploaded ? "Synced \(result.settings) settings and \(result.credentials) service keys." : "Cloud settings are already up to date."
        })
    }

    private func loadCatalog() {
        let session = self.session
        run("Reading cloud backup metadata…", operation: { try await session.loadCatalog() }, completion: { [weak self] _ in self?.plan = nil; self?.legacyPlan = nil })
    }

    private func preview(_ revision: CloudRevision, heads: Set<UUID>) {
        let session = self.session
        run("Validating cloud backup…", operation: { try await session.preview(revision, expectedHeads: heads) }, completion: { [weak self] in self?.plan = $0; self?.legacyPlan = nil })
    }

    private func previewAndroid() {
        let session = self.session
        run("Reading and mapping Android settings…", operation: { try await session.previewAndroid() }, completion: { [weak self] in
            self?.plan = nil
            self?.legacyPlan = $0
        })
    }

    private func confirmAndroidRestore(_ plan: CloudLegacyRestorePlan) {
        let keys = CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys ? plan.credentialCount : 0
        confirm(title: "Restore the reviewed Android settings?",
            message: "Apply \(plan.settingCount) settings and add up to \(keys) incoming keys for the destinations in this preview. Existing keys/bindings are preserved. \(plan.skipped.count) source fields stay skipped.",
            action: keys > 0 ? "Restore and authorize listed keys" : "Restore settings") { [weak self] in
            guard let self else { return }
            let session = self.session
            self.run("Applying Android settings…", operation: { try await session.restoreAndroid(plan) }, completion: { [weak self] result in
                self?.legacyPlan = nil
                self?.operationMessage = "Applied \(result.settings) settings; added \(result.addedCredentials) keys, retained \(result.retainedCredentials) existing keys."
            })
        }
    }

    private func confirmRestore(_ plan: CloudRestorePlan) {
        confirm(title: "Restore these settings?", message: "Apply \(plan.settingCount) settings from the reviewed revision. Existing API keys and account authorizations are retained.", action: "Restore") { [weak self] in
            guard let self else { return }
            let session = self.session
            self.run("Restoring settings…", operation: { try await session.restore(plan) }, completion: { [weak self] result in
                self?.plan = nil
                self?.operationMessage = "Restored \(result.settings) settings. Added \(result.addedCredentials) keys; retained \(result.retainedCredentials) existing keys."
            })
        }
    }

    private func confirmUpload(heads: Set<UUID>) {
        confirm(title: "Use this device's settings?", message: "Create a new revision from this device after the cloud revisions you reviewed. Older revisions remain recoverable.", action: "Upload settings") { [weak self] in self?.sync(heads: heads) }
    }

    private func confirmDelete(heads: Set<UUID>) {
        confirm(title: "Delete native cloud history?", message: "Delete this account's native settings revisions and included service keys from cloud storage. An Android-format backup is retained.", action: "Delete", destructive: true) { [weak self] in
            guard let self else { return }
            let session = self.session
            self.run("Deleting native backup history…", operation: { try await session.deleteNativeHistory(expectedHeads: heads) }, completion: { [weak self] _ in
                self?.plan = nil
                self?.operationMessage = "Native cloud history deleted."
            })
        }
    }

    private func confirmRepair() {
        confirm(title: "Remove proven incomplete cloud data?", message: "Remove only malformed records or failed uploads this session can prove abandoned. Healthy history, its dependencies and unproven in-flight chunks are retained. Changed or ambiguous storage requires a fresh review.", action: "Remove", destructive: true) { [weak self] in
            guard let self else { return }
            let session = self.session
            self.run("Removing incomplete backup data…", operation: { try await session.deleteDamagedNativeData() }, completion: { [weak self] _ in
                self?.plan = nil
                self?.operationMessage = "Proven incomplete records removed; healthy and unproven data retained."
            })
        }
    }

    private func confirm(title: String, message: String, action: String, destructive: Bool = false, perform: @escaping () -> Void) {
        guard contextAvailable else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { [weak self] _ in
            guard self?.contextAvailable == true else { return }
            perform()
        })
        present(alert, animated: true)
    }

    private func dateText(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
