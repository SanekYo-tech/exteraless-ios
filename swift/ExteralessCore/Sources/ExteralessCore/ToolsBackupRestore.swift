import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ToolsBackupSettingsSnapshot: Sendable {
    public let definitions: [ClientSettingDefinition]
    public let values: [String: ClientSettingValue]
    public let storedKeys: Set<String>
    public let secretKeys: Set<String>
    public let lastError: ClientSettingsError?

    public init(definitions: [ClientSettingDefinition], values: [String: ClientSettingValue], storedKeys: Set<String>,
                secretKeys: Set<String> = [], lastError: ClientSettingsError? = nil) {
        let protected = secretKeys.union(definitions.filter(\.isSecret).map(\.key))
        var visible: [String: ClientSettingValue] = [:]
        for definition in definitions where !protected.contains(definition.key) {
            visible[definition.key] = values[definition.key] ?? definition.defaultValue
        }
        self.definitions = definitions
        self.values = visible
        self.storedKeys = storedKeys.intersection(Set(visible.keys))
        self.secretKeys = protected
        self.lastError = lastError
    }

    public init(_ snapshot: ClientSettingsSnapshot, allowingRecovery: Bool = false) throws {
        if !allowingRecovery, let error = snapshot.lastError { throw error }
        self.init(definitions: snapshot.definitions, values: snapshot.values, storedKeys: snapshot.storedKeys,
                  secretKeys: snapshot.secretKeys, lastError: snapshot.lastError)
    }

    public func state(for keys: Set<String>) throws -> ToolsBackupSettingsState {
        guard keys.isSubset(of: Set(values.keys)), keys.isDisjoint(with: secretKeys) else {
            throw ToolsError.invalidArchive("A restore key is missing or classified as secret.")
        }
        return try ToolsBackupSettingsState(values: values.filter { keys.contains($0.key) }, storedKeys: storedKeys.intersection(keys))
    }
}

public struct ToolsBackupSettingsAccess: Sendable {
    /// Coherent public values, presence, definitions and classification. A recovery
    /// binding may expose a storage error in lastError instead of hiding the snapshot.
    public let snapshot: @Sendable () throws -> ToolsBackupSettingsSnapshot
    /// One affected-key CAS batch. Never implement this by looping over set/reset.
    /// Throw ToolsBackupWriteFailure.rejected only if no public value was committed;
    /// storage/durability/unknown failures must remain .durability (or unclassified).
    public let applyAtomically: @Sendable ([String: ClientSettingValue], Set<String>, ClientSettingsSnapshot) throws -> Void
    /// Optional fresh, readonly public observation. A cached readSnapshot is NOT
    /// enough to confirm disk is already-before. Never bind reload/migrating writes.
    public let readCurrent: (@Sendable () throws -> ToolsBackupSettingsSnapshot)?

    public init(snapshot: @escaping @Sendable () throws -> ToolsBackupSettingsSnapshot,
                readCurrent: (@Sendable () throws -> ToolsBackupSettingsSnapshot)? = nil,
                applyAtomically: @escaping @Sendable ([String: ClientSettingValue], Set<String>, ClientSettingsSnapshot) throws -> Void) {
        self.snapshot = snapshot
        self.readCurrent = readCurrent
        self.applyAtomically = applyAtomically
    }

    public static func clientSettings(_ store: ClientSettings = .shared) -> Self {
        Self(snapshot: { try ToolsBackupSettingsSnapshot(store.readSnapshot(), allowingRecovery: true) },
             applyAtomically: { values, resetting, expected in
                 do { try store.applyPublic(values, resetting: resetting, expected: expected) }
                 catch let error as ClientSettingsError {
                     if case .storageFailure = error { throw ToolsBackupWriteFailure.durability(error.localizedDescription) }
                     throw ToolsBackupWriteFailure.rejected(error.localizedDescription)
                 }
             })
    }
}

public struct ToolsBackupRestoreResult: Sendable, Equatable {
    public let settings: Int
    public let pluginFiles: Int
}

/// The maintenance lease owns *all* plugin-storage writers. ClientSettings has an
/// independent CAS boundary, so native edits are never overwritten during rollback.
public final class ToolsBackupRestorer: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let fault: @Sendable (ToolsBackupFaultPoint) throws -> Void

    private enum Phase: String, Codable { case prepared, pluginsApplied, clientPending, clientApplied, clientRejected, rollingBack, rolledBack, committed, needsRecovery, reconciled }
    private enum ClientWrite: String, Codable { case notAttempted, rejected, applied, uncertain }
    private enum PluginWrite: String, Codable { case notStarted, swapAttempted, confirmed }
    private struct Journal: Codable {
        let version: Int
        let transactionId: UUID
        let before: ToolsBackupSettingsState
        let target: ToolsBackupSettingsState
        let originalFiles: [String: String]?
        let targetFiles: [String: String]?
        var phase: Phase
        var clientWrite: ClientWrite
        var pluginWrite: PluginWrite?
    }
    private struct LegacyJournal: Decodable {
        let version: Int
        let transactionId: UUID
        let previousSettings: [String: ClientSettingValue]
        let includesPluginSettings: Bool
        let committed: Bool
    }
    private struct SwapReceipt {
        let directory: ToolsFileIdentity
        let files: [String: ToolsFileMetadata]
    }
    private struct ReconciliationMarker: Codable {
        let version: Int
        let transactionId: UUID
        let phase: String
        let evidenceName: String
        let journalSHA256: String
    }

    public init(beforeSettingsCommit: @escaping @Sendable () throws -> Void = {},
                fault: @escaping @Sendable (ToolsBackupFaultPoint) throws -> Void = { _ in }) {
        self.fault = { point in
            if case .beforeClientCommit = point { try beforeSettingsCommit() }
            try fault(point)
        }
    }

    public func restore(_ inspection: ToolsBackupInspection, settings: ToolsBackupSettingsAccess,
                        plugins: ToolsBackupPluginLocation? = nil) throws -> ToolsBackupRestoreResult {
        lock.lock()
        defer { lock.unlock() }
        guard let plugins else { throw ToolsError.unavailable("Restore requires the application's settings directory for recovery.") }
        try ToolsBackupPolicy.validateLocation(plugins)
        try recoverLocked(settings: settings, plugins: plugins)
        let snapshot = try settings.snapshot()
        // A cached error can describe a prior rejected request. The public batch
        // validates the current disk and affected keys under its own file lock.
        let checked = try ToolsBackupArchive.revalidate(inspection, definitions: snapshot.definitions, secretKeys: snapshot.secretKeys)
        let keys = Set(checked.settings.keys).union(checked.resetting)
        let before = try snapshot.state(for: keys)
        var targetValues = checked.settings
        for definition in snapshot.definitions where checked.resetting.contains(definition.key) {
            targetValues[definition.key] = definition.defaultValue
        }
        let target = try ToolsBackupSettingsState(values: targetValues, storedKeys: Set(checked.settings.keys))
        let root = ToolsFileSafety.canonicalFileURL(plugins.directory)
        let parent = root.deletingLastPathComponent()
        let id = UUID()
        let stage = try child(stageName(id), parent)
        let backup = try child(backupName(id), parent)
        let journalURL = try child("tools-settings-restore.json", parent)
        var originalFiles: [String: String]?
        var targetFiles: [String: String]?
        var stageCreated = false
        var backupCreated = false
        let schemaFiles = Set(checked.payload.pluginSettings.map(\.path))
        // Preparation cannot modify either live settings store.
        do {
            #if canImport(Darwin) || canImport(Glibc)
            let parentDescriptor = try ToolsDirectoryDescriptor.open(parent, create: true)
            if !checked.payload.pluginSettings.isEmpty {
                try plugins.withSchemaAuthority(files: schemaFiles, use: .restore) {
                _ = try parentDescriptor.child(root.lastPathComponent, create: true)
                _ = try parentDescriptor.createNewDirectory(stage.lastPathComponent)
                stageCreated = true
                originalFiles = try copySettingsDirectory(root, to: stage)
                for entry in checked.payload.pluginSettings {
                    try plugins.validateSnapshot(file: entry.path, settingsSHA256: originalFiles?[entry.path])
                    guard let allowed = plugins.exportableFields[entry.path], Set(entry.values.keys).isSubset(of: allowed) else {
                        throw ToolsError.invalidArchive("The plugin's cached native schema does not allow these fields. Unknown fields are not imported.")
                    }
                    try plugins.schemas[entry.path]?.validate(entry.values)
                    let file = try child(entry.path, stage)
                    let previous = fileManager.fileExists(atPath: file.path)
                        ? try ToolsBackupArchive.decodeSettings(ToolsFileSafety.read(file, maximumBytes: ToolsBackupPolicy.maximumPluginFileBytes)) : [:]
                    let bytes = try ToolsFileSafety.encode(ToolsBackupPolicy.merging(entry.values, into: previous))
                    guard bytes.count <= ToolsBackupPolicy.maximumPluginFileBytes else { throw ToolsError.sizeLimit }
                    try ToolsBackupJournalIO.write(bytes, to: file)
                }
                targetFiles = try directoryManifest(stage)
                _ = try parentDescriptor.createNewDirectory(backup.lastPathComponent)
                backupCreated = true
                guard try copySettingsDirectory(root, to: backup) == originalFiles else { throw ToolsBackupWriteFailure.rejected("Plugin settings changed while preparing the backup.") }
                }
            }
            #else
            throw ToolsError.unavailable("Descriptor-bound settings restore is unavailable on this platform.")
            #endif
        } catch {
            if stageCreated { try? fileManager.removeItem(at: stage) }
            if backupCreated { try? fileManager.removeItem(at: backup) }
            throw error
        }
        var journal = Journal(version: 3, transactionId: id, before: before, target: target,
                              originalFiles: originalFiles, targetFiles: targetFiles, phase: .prepared,
                              clientWrite: .notAttempted, pluginWrite: .notStarted)
        // These are invocation-local receipts, never reconstructed from hashes or
        // from a journal that might precede a completed rollback.
        var clientWrite = ClientWrite.notAttempted
        var pluginWrite = PluginWrite.notStarted
        var swapReceipt: SwapReceipt?
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            // No live store was touched. A completed atomic journal can be recovered;
            // retain the original instead of losing a possible recovery record.
            throw ToolsError.rollbackFailed
        }
        do {
            try fault(.afterPrepared)
            if let originalFiles {
                try plugins.withSchemaAuthority(files: schemaFiles, use: .restore) {
                guard try directoryManifest(root) == originalFiles else { throw ToolsBackupWriteFailure.rejected("Plugin settings changed before commit.") }
                for file in schemaFiles { try plugins.validateSnapshot(file: file, settingsSHA256: originalFiles[file]) }
                journal.pluginWrite = .swapAttempted
                try writeJournal(journal, to: journalURL)
                pluginWrite = .swapAttempted
                swapReceipt = try replaceDirectory(root, with: stage)
                pluginWrite = .confirmed
                journal.pluginWrite = .confirmed
                journal.phase = .pluginsApplied
                try writeJournal(journal, to: journalURL)
                }
            }
            try fault(.beforeClientCommit)
            journal.phase = .clientPending
            journal.clientWrite = .uncertain
            try writeJournal(journal, to: journalURL)
            try fault(.afterClientPending)
            clientWrite = .uncertain
            do {
                try settings.applyAtomically(checked.settings, checked.resetting,
                                             before.expectedSnapshot(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys))
            } catch let error as ToolsBackupWriteFailure {
                if case .rejected = error {
                    clientWrite = .rejected
                    journal.clientWrite = .rejected
                    journal.phase = .clientRejected
                    try writeJournal(journal, to: journalURL)
                }
                throw error
            }
            clientWrite = .applied
            journal.clientWrite = .applied
            journal.phase = .clientApplied
            try writeJournal(journal, to: journalURL)
            try fault(.afterClientCommit)
            try fault(.beforeCommitMarker)
            journal.phase = .committed
            try writeJournal(journal, to: journalURL)
        } catch {
            // Uncertain/durability failures retain both images for recovery. In
            // particular, never assume a throwing CAS batch did not rename its file.
            if clientWrite == .uncertain || pluginWrite == .swapAttempted || isDurabilityFailure(error) || journal.phase == .committed {
                if journal.phase != .committed { journal.phase = .needsRecovery; try? writeJournal(journal, to: journalURL) }
                throw ToolsError.rollbackFailed
            }
            do {
                try fault(.beforeRollback)
                journal.phase = .rollingBack
                try writeJournal(journal, to: journalURL)
                try rollback(journal, clientWrite: clientWrite, pluginWrite: pluginWrite, receipt: swapReceipt,
                             settings: settings, root: root, backup: backup)
                try fault(.beforeRollbackMarker)
                journal.phase = .rolledBack
                try writeJournal(journal, to: journalURL)
                cleanup(journal, parent: parent)
            } catch { throw ToolsError.rollbackFailed }
            throw error
        }
        cleanup(journal, parent: parent)
        return .init(settings: checked.settingCount, pluginFiles: checked.pluginFileCount)
    }

    /// Run under the maintenance lease BEFORE plugin admission/startup. A restarted
    /// process has no atomic write witness: only readonly already-before confirmation
    /// can retire a nonterminal journal automatically. Otherwise explicit review is required.
    public func recover(settings: ToolsBackupSettingsAccess, plugins: ToolsBackupPluginLocation) throws {
        lock.lock()
        defer { lock.unlock() }
        try ToolsBackupPolicy.validateLocation(plugins)
        try recoverLocked(settings: settings, plugins: plugins)
    }

    /// No mkdir, migration, setters or Host startup. The optional fresh reader is
    /// explicit because ClientSettings.readSnapshot() is only an in-process cache.
    public func inspectRecovery(settings: ToolsBackupSettingsAccess, plugins: ToolsBackupPluginLocation) throws -> ToolsBackupRecoveryInspection? {
        lock.lock(); defer { lock.unlock() }
        try ToolsBackupPolicy.validateLocation(plugins)
        return try recoveryInspection(settings: settings, plugins: plugins)
    }

    /// An explicit user decision, under the real maintenance lease. It never writes
    /// live settings. Evidence and original/staged directories remain locally retained.
    public func reconcileKeepingCurrent(_ review: ToolsBackupRecoveryInspection, settings: ToolsBackupSettingsAccess,
                                       plugins: ToolsBackupPluginLocation) throws -> ToolsBackupReconciliationResult {
        lock.lock(); defer { lock.unlock() }
        do {
            try ToolsBackupPolicy.validateLocation(plugins)
            guard let current = try recoveryInspection(settings: settings, plugins: plugins),
                  current.transactionId == review.transactionId, current.journalSHA256 == review.journalSHA256,
                  current.observed == review.observed, current.observationIsFresh == review.observationIsFresh,
                  current.currentPluginFiles == review.currentPluginFiles,
                  current.pluginDirectoryExisted == review.pluginDirectoryExisted else { throw ToolsError.rollbackFailed }
            let parent = plugins.directory.deletingLastPathComponent()
            let active = try child("tools-settings-restore.json", parent)
            let evidence = try child(current.evidenceName, parent)
            let bytes = try ToolsFileSafety.read(active, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
            guard ToolsSHA256.hex(bytes) == current.journalSHA256 else { throw ToolsError.rollbackFailed }
            #if canImport(Darwin) || canImport(Glibc)
            let directory = try ToolsDirectoryDescriptor.open(parent)
            if fileManager.fileExists(atPath: evidence.path) {
                guard ToolsSHA256.hex(try ToolsFileSafety.read(evidence, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)) == current.journalSHA256 else { throw ToolsError.rollbackFailed }
            } else {
                let output = try ToolsWriteDescriptor(parent: directory, name: "reconcile-\(UUID().uuidString).partial")
                defer { output.discard() }
                try output.write(bytes)
                try output.synchronize()
                guard try directory.publish(output.name, as: current.evidenceName, identity: output.identity) else { throw ToolsError.rollbackFailed }
            }
            #else
            throw ToolsError.unavailable("Durable recovery reconciliation is unavailable on this platform.")
            #endif
            guard ToolsSHA256.hex(try ToolsFileSafety.read(active, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)) == current.journalSHA256 else { throw ToolsError.rollbackFailed }
            let marker = ReconciliationMarker(version: 3, transactionId: current.transactionId, phase: "reconciled",
                                               evidenceName: current.evidenceName, journalSHA256: current.journalSHA256)
            try ToolsBackupJournalIO.write(ToolsFileSafety.encode(marker), to: active)
            cleanupReconciledJournal(parent: parent)
            return .init(transactionId: current.transactionId, evidenceURL: evidence)
        } catch { throw ToolsError.rollbackFailed }
    }

    private func recoveryInspection(settings: ToolsBackupSettingsAccess, plugins: ToolsBackupPluginLocation) throws -> ToolsBackupRecoveryInspection? {
        let root = ToolsFileSafety.canonicalFileURL(plugins.directory)
        let file = try child("tools-settings-restore.json", root.deletingLastPathComponent())
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let bytes = try ToolsFileSafety.read(file, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
        try ToolsFileSafety.checkJSON(bytes, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
        struct Header: Decodable { let version: Int; let phase: String? }
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        if header.version == 3, header.phase == "reconciled" {
            try validateReconciliation(JSONDecoder().decode(ReconciliationMarker.self, from: bytes), parent: root.deletingLastPathComponent())
            return nil
        }
        let snapshot = try settings.readCurrent?() ?? settings.snapshot()
        let id: UUID
        let keys: Set<String>
        let before: ToolsBackupSettingsState?
        let target: ToolsBackupSettingsState?
        let originalFiles: [String: String]?
        let classification: ToolsBackupRecoveryInspection.Classification
        if header.version == 1 {
            let legacy = try JSONDecoder().decode(LegacyJournal.self, from: bytes)
            if legacy.committed { return nil }
            id = legacy.transactionId
            keys = Set(legacy.previousSettings.keys)
            before = nil; target = nil; originalFiles = nil
            classification = .legacyUncommitted
        } else {
            guard header.version == 2 || header.version == 3 else { throw ToolsError.rollbackFailed }
            let journal = try JSONDecoder().decode(Journal.self, from: bytes)
            try validateJournal(journal)
            if journal.phase == .committed || journal.phase == .rolledBack { return nil }
            id = journal.transactionId
            keys = Set(journal.before.values.keys)
            let publicKeys = keys.intersection(snapshot.values.keys).subtracting(snapshot.secretKeys)
            before = try ToolsBackupSettingsState(values: journal.before.values.filter { publicKeys.contains($0.key) }, storedKeys: journal.before.storedKeys.intersection(publicKeys))
            target = try ToolsBackupSettingsState(values: journal.target.values.filter { publicKeys.contains($0.key) }, storedKeys: journal.target.storedKeys.intersection(publicKeys))
            originalFiles = journal.originalFiles
            classification = try isAlreadyBefore(journal, settings: settings, root: root) ? .alreadyBefore : .ambiguous
        }
        let exists = fileManager.fileExists(atPath: root.path)
        let files = exists ? try directoryManifest(root) : nil
        // Read the actual plugin directory even for a client-only journal: explicit
        // review must not silently accept a different plugin namespace on retry.
        _ = originalFiles
        let publicKeys = keys.intersection(snapshot.values.keys).subtracting(snapshot.secretKeys)
        return .init(transactionId: id, journalVersion: header.version, journalSHA256: ToolsSHA256.hex(bytes),
            classification: classification, before: before, target: target, observed: try snapshot.state(for: publicKeys),
            observationIsFresh: settings.readCurrent != nil, currentPluginFiles: files, pluginDirectoryExisted: exists,
            evidenceName: "tools-settings-reconciled-" + id.uuidString + ".json")
    }

    private func validateReconciliation(_ marker: ReconciliationMarker, parent: URL) throws {
        guard marker.version == 3, marker.phase == "reconciled",
              marker.evidenceName == "tools-settings-reconciled-" + marker.transactionId.uuidString + ".json",
              ToolsSHA256.hex(try ToolsFileSafety.read(child(marker.evidenceName, parent), maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)) == marker.journalSHA256 else { throw ToolsError.rollbackFailed }
    }

    private func cleanupReconciledJournal(parent: URL) {
        // A durable marker can be retried; original/stage directories are deliberately retained.
        do {
            try fileManager.removeItem(at: child("tools-settings-restore.json", parent))
            try ToolsBackupJournalIO.synchronizeDirectory(parent)
        } catch { }
    }

    private func recoverLocked(settings: ToolsBackupSettingsAccess, plugins: ToolsBackupPluginLocation) throws {
        let root = ToolsFileSafety.canonicalFileURL(plugins.directory)
        let parent = root.deletingLastPathComponent()
        let file = try child("tools-settings-restore.json", parent)
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            let bytes = try ToolsFileSafety.read(file, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
            try ToolsFileSafety.checkJSON(bytes, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
            struct Header: Decodable { let version: Int; let phase: String? }
            let header = try JSONDecoder().decode(Header.self, from: bytes)
            let version = header.version
            if version == 3, header.phase == "reconciled" {
                let marker = try JSONDecoder().decode(ReconciliationMarker.self, from: bytes)
                try validateReconciliation(marker, parent: parent)
                cleanupReconciledJournal(parent: parent)
                return
            }
            if version == 1 {
                let old = try JSONDecoder().decode(LegacyJournal.self, from: bytes)
                // An uncommitted v1 journal never recorded presence or the after
                // image. Guessing either would overwrite native edits/defaults.
                guard old.committed else { throw ToolsError.unavailable("Legacy recovery needs review: version 1 did not retain override presence or CAS state. Original files are retained.") }
                cleanup(id: old.transactionId, parent: parent)
                return
            }
            guard version == 2 || version == 3 else { throw ToolsError.invalidArchive("Unsupported recovery journal version.") }
            var journal = try JSONDecoder().decode(Journal.self, from: bytes)
            try validateJournal(journal)
            if journal.phase != .committed && journal.phase != .rolledBack {
                guard try isAlreadyBefore(journal, settings: settings, root: root) else { throw ToolsError.rollbackFailed }
                journal.phase = .rolledBack
                try writeJournal(journal, to: file)
            }
            cleanup(journal, parent: parent)
        } catch { throw ToolsError.rollbackFailed }
    }

    private func rollback(_ journal: Journal, clientWrite: ClientWrite, pluginWrite: PluginWrite, receipt: SwapReceipt?,
                          settings: ToolsBackupSettingsAccess, root: URL, backup: URL) throws {
        let snapshot = try settings.snapshot()
        let keys = Set(journal.before.values.keys)
        let definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.key, $0) })
        for key in keys {
            guard let definition = definitions[key], !definition.isSecret, !snapshot.secretKeys.contains(key) else { throw ToolsError.rollbackFailed }
            if journal.before.storedKeys.contains(key), let value = journal.before.values[key] { try definition.validate(value) }
        }
        var restorePlugins = false
        // Validate both stores before beginning rollback. In particular, a native
        // target written before our swap must never become our rollback candidate.
        if let original = journal.originalFiles, let target = journal.targetFiles {
            let current = try directoryManifest(root)
            if current != original {
                guard pluginWrite == .confirmed, current == target, let receipt,
                      try directoryIdentity(root) == receipt.directory,
                      try directoryVersions(root) == receipt.files else { throw ToolsError.rollbackFailed }
                guard try directoryManifest(backup) == original else { throw ToolsError.rollbackFailed }
                restorePlugins = true
            }
        }
        guard clientWrite != .uncertain, pluginWrite != .swapAttempted else { throw ToolsError.rollbackFailed }
        if clientWrite == .applied && !keys.isEmpty {
            let alreadyBefore = try settings.readCurrent?().state(for: keys) == journal.before
            if !alreadyBefore {
            do {
                try settings.applyAtomically(journal.before.overrides, journal.before.resetting,
                    journal.target.expectedSnapshot(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys))
            } catch let error as ToolsBackupWriteFailure {
                guard case .rejected = error else { throw error }
                // No second setter disguised as a confirmation. A cached snapshot
                // is insufficient; absence of a fresh reader conservatively holds.
                guard try settings.readCurrent?().state(for: keys) == journal.before else { throw ToolsError.rollbackFailed }
            }
            }
            try fault(.afterClientRollback)
        }
        if restorePlugins, let receipt {
                #if canImport(Darwin) || canImport(Glibc)
                let replacement = try child("tools-settings-rollback-" + UUID().uuidString, root.deletingLastPathComponent())
                _ = try ToolsDirectoryDescriptor.open(root.deletingLastPathComponent()).createNewDirectory(replacement.lastPathComponent)
                defer { try? fileManager.removeItem(at: replacement) }
                _ = try copySettingsDirectory(backup, to: replacement)
                guard try directoryIdentity(root) == receipt.directory,
                      try directoryVersions(root) == receipt.files else { throw ToolsError.rollbackFailed }
                _ = try replaceDirectory(root, with: replacement)
                #else
                throw ToolsError.rollbackFailed
                #endif
        }
    }

    private func isAlreadyBefore(_ journal: Journal, settings: ToolsBackupSettingsAccess, root: URL) throws -> Bool {
        if !journal.before.values.isEmpty {
            guard let reader = settings.readCurrent, let current = try? reader(),
                  let state = try? current.state(for: Set(journal.before.values.keys)), state == journal.before else { return false }
        }
        if let original = journal.originalFiles {
            guard try directoryManifest(root) == original else { return false }
        }
        return true
    }

    private func validateJournal(_ journal: Journal) throws {
        _ = try ToolsBackupSettingsState(values: journal.before.values, storedKeys: journal.before.storedKeys)
        _ = try ToolsBackupSettingsState(values: journal.target.values, storedKeys: journal.target.storedKeys)
        guard Set(journal.before.values.keys) == Set(journal.target.values.keys),
              (journal.originalFiles == nil) == (journal.targetFiles == nil) else { throw ToolsError.rollbackFailed }
        for files in [journal.originalFiles, journal.targetFiles].compactMap({ $0 }) {
            guard files.count <= ToolsBackupPolicy.maximumPluginFiles else { throw ToolsError.sizeLimit }
            for (path, hash) in files {
                try ToolsBackupPolicy.validatePluginPath(path)
                guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ToolsError.rollbackFailed }
            }
        }
    }

    private func directoryManifest(_ directory: URL) throws -> [String: String] {
        try visitSettingsDirectory(directory) { _, bytes in ToolsSHA256.hex(bytes) }
    }

    @discardableResult private func copySettingsDirectory(_ source: URL, to destination: URL) throws -> [String: String] {
        try visitSettingsDirectory(source) { name, bytes in
            try ToolsBackupJournalIO.write(bytes, to: child(name, destination))
            return ToolsSHA256.hex(bytes)
        }
    }

    private func visitSettingsDirectory(_ directory: URL, file: (String, Data) throws -> String) throws -> [String: String] {
        #if canImport(Darwin) || canImport(Glibc)
        let source = try ToolsDirectoryDescriptor.open(directory)
        let files = try source.names(maximum: ToolsBackupPolicy.maximumPluginFiles)
        var total = 0, result: [String: String] = [:]
        var names = Set<String>()
        for name in files {
            try ToolsBackupPolicy.validatePluginPath(name)
            guard names.insert(name.lowercased()).inserted else { throw ToolsError.unsafePath }
            let maximum = min(ToolsBackupPolicy.maximumPluginFileBytes, ToolsBackupPolicy.maximumPayloadBytes - total)
            let input = try ToolsReadDescriptor(child(name, directory), maximumBytes: Int64(maximum), parent: source)
            let bytes = try input.readAll(maximumBytes: maximum)
            total += bytes.count
            guard total <= ToolsBackupPolicy.maximumPayloadBytes else { throw ToolsError.sizeLimit }
            result[name] = try file(name, bytes)
        }
        try source.verify()
        return result
        #else
        throw ToolsError.unavailable("Descriptor-bound settings access is unavailable on this platform.")
        #endif
    }

    private func directoryIdentity(_ url: URL) throws -> ToolsFileIdentity {
        #if canImport(Darwin) || canImport(Glibc)
        return try ToolsDirectoryDescriptor.open(url).identity
        #else
        throw ToolsError.unsafePath
        #endif
    }

    private func directoryVersions(_ url: URL) throws -> [String: ToolsFileMetadata] {
        #if canImport(Darwin) || canImport(Glibc)
        let directory = try ToolsDirectoryDescriptor.open(url)
        var result: [String: ToolsFileMetadata] = [:]
        for name in try directory.names(maximum: ToolsBackupPolicy.maximumPluginFiles) {
            try ToolsBackupPolicy.validatePluginPath(name)
            result[name] = ToolsFileMetadata(try directory.metadata(name))
        }
        try directory.verify()
        return result
        #else
        throw ToolsError.unsafePath
        #endif
    }

    private func replaceDirectory(_ root: URL, with replacement: URL) throws -> SwapReceipt {
        #if canImport(Darwin)
        guard root.deletingLastPathComponent().standardizedFileURL == replacement.deletingLastPathComponent().standardizedFileURL else { throw ToolsError.unsafePath }
        let parent = try ToolsDirectoryDescriptor.open(root.deletingLastPathComponent())
        let before = try directoryIdentity(root)
        let target = try directoryIdentity(replacement)
        let files = try directoryVersions(replacement)
        do {
            try parent.verify()
            let result = root.lastPathComponent.withCString { live in
                replacement.lastPathComponent.withCString { staged in
                    renameatx_np(parent.rawValue, live, parent.rawValue, staged, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0, ToolsFileIdentity(try parent.metadata(root.lastPathComponent)) == target,
                  ToolsFileIdentity(try parent.metadata(replacement.lastPathComponent)) == before,
                  try directoryVersions(root) == files else { throw ToolsError.rollbackFailed }
            try parent.synchronize()
            return SwapReceipt(directory: target, files: files)
        } catch { throw ToolsBackupWriteFailure.durability("The plugin settings replacement could not be confirmed durable.") }
        #else
        throw ToolsBackupWriteFailure.rejected("Atomic plugin-directory exchange requires Darwin.")
        #endif
    }

    private func isDurabilityFailure(_ error: Error) -> Bool {
        if case .durability? = error as? ToolsBackupWriteFailure { return true }
        return error is CocoaError || error is POSIXError
    }

    private func writeJournal(_ value: Journal, to file: URL) throws {
        try validateJournal(value)
        let bytes = try ToolsFileSafety.encode(value)
        guard bytes.count <= ToolsBackupPolicy.maximumPayloadBytes * 2 else { throw ToolsError.sizeLimit }
        try ToolsBackupJournalIO.write(bytes, to: file)
    }

    private func cleanup(_ journal: Journal, parent: URL) { cleanup(id: journal.transactionId, parent: parent) }
    private func cleanup(id: UUID, parent: URL) {
        do {
            for name in [backupName(id), stageName(id)] {
                let url = try child(name, parent)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            try ToolsBackupJournalIO.synchronizeDirectory(parent)
            let journal = try child("tools-settings-restore.json", parent)
            if fileManager.fileExists(atPath: journal.path) { try fileManager.removeItem(at: journal) }
            try ToolsBackupJournalIO.synchronizeDirectory(parent)
        } catch { /* A terminal journal is safe to retry; do not roll back committed data for cleanup debt. */ }
    }

    private func child(_ name: String, _ root: URL) throws -> URL { try ToolsFileSafety.checkedChild(name, root: root) }
    private func stageName(_ id: UUID) -> String { "tools-settings-stage-" + id.uuidString }
    private func backupName(_ id: UUID) -> String { "tools-settings-original-" + id.uuidString }
}
