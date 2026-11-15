import Foundation

/// Data-only review token. A cached public observation is labelled explicitly and
/// never used as proof that a disk write/rollback belongs to Tools.
public struct ToolsBackupRecoveryInspection: Sendable {
    public enum Classification: String, Sendable { case ambiguous, alreadyBefore, legacyUncommitted }
    public let transactionId: UUID
    public let journalVersion: Int
    public let journalSHA256: String
    public let classification: Classification
    public let before: ToolsBackupSettingsState?
    public let target: ToolsBackupSettingsState?
    public let observed: ToolsBackupSettingsState
    public let observationIsFresh: Bool
    public let currentPluginFiles: [String: String]?
    public let pluginDirectoryExisted: Bool
    public let evidenceName: String
}

public struct ToolsBackupReconciliationResult: Sendable {
    public let transactionId: UUID
    public let evidenceURL: URL
}
