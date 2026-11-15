import ExteralessCore
import Foundation

/// Uses the real Tools archive, journal and maintenance lease. Cloud has no
/// plugin settings files and never invents a second plugin pause/recovery scheme.
@MainActor final class ExteralessCloudArchiveHost {
    let settings: ClientSettings
    let credentials: any CloudCredentialStorage
    let bindings: ExteralessToolsBackupBindings

    init(settings: ClientSettings, credentials: any CloudCredentialStorage, bindings: ExteralessToolsBackupBindings) {
        self.settings = settings
        self.credentials = credentials
        self.bindings = bindings
    }

    func restore(_ plan: CloudRestorePlan, includeApiKeys: Bool, admission: CloudRestoreAdmission) async throws -> CloudRestoreResult {
        let settings = self.settings
        let credentials = self.credentials
        return try await perform(inspection: plan.publicInspection, admission: admission,
            verify: {
                try plan.verifyCredentialTarget(includeApiKeys: includeApiKeys && CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys, storage: credentials)
                try plan.verifyLocalPreview(settings: settings)
            }, restoreKeys: {
                try CloudSettingsArchive.restoreMissingCredentials(plan, settings: settings,
                    includeApiKeys: includeApiKeys, credentials: credentials,
                    permitKeys: { CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys })
            })
    }

    func restore(_ plan: CloudLegacyRestorePlan, includeApiKeys: Bool, admission: CloudRestoreAdmission) async throws -> CloudRestoreResult {
        let settings = self.settings
        let credentials = self.credentials
        return try await perform(inspection: plan.publicInspection, admission: admission,
            verify: {
                try plan.verifyCredentialTarget(includeApiKeys: includeApiKeys && CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys, storage: credentials)
                try plan.verifyLocalPreview(settings: settings)
            }, restoreKeys: {
                try CloudLegacySettingsArchive.restoreMissingCredentials(plan, settings: settings,
                    includeApiKeys: includeApiKeys, credentials: credentials,
                    permitKeys: { CloudSyncPolicy(snapshot: settings.readSnapshot()).includeApiKeys })
            })
    }

    private func perform(inspection: ToolsBackupInspection, admission: CloudRestoreAdmission,
                         verify: @escaping @Sendable () throws -> Void,
                         restoreKeys: @escaping @Sendable () throws -> CloudRestoreResult) async throws -> CloudRestoreResult {
        try Task.checkCancellation()
        // Never let Tools' current-schema validation expand the reviewed Cloud
        // write set by receiving the original archive's excluded public fields.
        try CloudPublicRestoreProjection.validate(inspection)
        let lease = try await bindings.beginMaintenance()
        let access = bindings.settings
        var publicCommitted = false
        let result: CloudRestoreResult
        do {
            try Task.checkCancellation()
            guard let location = try bindings.pluginLocation() else { throw CloudError.maintenanceUnavailable }
            try admission.beginCommit()
            _ = try await Task.detached(priority: .userInitiated) {
                let restorer = ToolsBackupRestorer(beforeSettingsCommit: verify)
                return try restorer.restore(inspection, settings: access, plugins: location)
            }.value
            publicCommitted = true
            result = try await Task.detached(priority: .userInitiated) { try restoreKeys() }.value
        } catch {
            let outcome: ExteralessToolsMaintenanceLease.Outcome
            if publicCommitted { outcome = .committed }
            else if (error as? ToolsError) == .rollbackFailed { outcome = .needsRecovery }
            else if case .durability? = error as? ToolsBackupWriteFailure { outcome = .needsRecovery }
            else { outcome = .rolledBack }
            try await lease.finish(outcome)
            if publicCommitted { throw CloudError.restorePartiallyApplied }
            if error is CancellationError { throw error }
            if (error as? ClientSettingsError) == .concurrentModification { throw CloudError.settingsChanged }
            throw (error as? CloudError) ?? .localStorage
        }
        try await lease.finish(.committed)
        return result
    }
}
