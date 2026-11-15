import ExteralessCore
import Foundation
import PluginHost

/// Typed adapter over the actual nonterminal Host lease. No start/stop/finalize
/// or newest-owner lookup is hidden in inspection/export.
@MainActor public enum ExteralessToolsHostMaintenance {
    public static func begin(host: PluginHost, timeout: TimeInterval = 10) async throws -> ExteralessToolsMaintenanceLease {
        let lease = try await host.beginSettingsMaintenance(timeout: timeout)
        return ExteralessToolsMaintenanceLease { outcome in
            let resume: Bool
            switch outcome {
            case .committed, .rolledBack: resume = true
            case .needsRecovery: resume = false
            }
            try await lease.finish(resume: resume)
        }
    }

    /// Call on a newly constructed host BEFORE host.start(). The Host lease does
    /// not initialize Python and, for a fresh host, has no unload hooks to invoke.
    public static func recoverBeforeStart(host: PluginHost, settingsDirectory: URL,
                                          settings: ClientSettings = .shared) async throws {
        let lease = try await host.beginSettingsMaintenance(timeout: 10)
        let access = ToolsBackupSettingsAccess.clientSettings(settings)
        let location = ToolsBackupPluginLocation(directory: settingsDirectory, exportableFields: [:])
        do {
            try await Task.detached(priority: .userInitiated) {
                try ToolsBackupRestorer().recover(settings: access, plugins: location)
            }.value
        } catch {
            try await lease.finish(resume: false)
            throw error
        }
        try await lease.finish(resume: true)
    }
}
