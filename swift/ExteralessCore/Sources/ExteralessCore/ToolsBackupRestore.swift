import Foundation

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

    public init(snapshot: @escaping @Sendable () throws -> ToolsBackupSettingsSnapshot,
                applyAtomically: @escaping @Sendable ([String: ClientSettingValue], Set<String>, ClientSettingsSnapshot) throws -> Void) {
        self.snapshot = snapshot
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

    private enum Phase: String, Codable { case prepared, pluginsApplied, clientPending, clientApplied, clientRejected, rolledBack, committed, needsRecovery }
    private enum ClientWrite: String, Codable { case notAttempted, rejected, applied, uncertain }
    private struct Journal: Codable {
        let version: Int
        let transactionId: UUID
        let before: ToolsBackupSettingsState
        let target: ToolsBackupSettingsState
        let originalFiles: [String: String]?
        let targetFiles: [String: String]?
        var phase: Phase
        var clientWrite: ClientWrite
    }
    private struct LegacyJournal: Decodable {
        let version: Int
        let transactionId: UUID
        let previousSettings: [String: ClientSettingValue]
        let includesPluginSettings: Bool
        let committed: Bool
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
        try ToolsBackupArchive.validatePayload(inspection.payload)
        let checked = try ToolsBackupArchive.inspection(inspection.payload, origin: inspection.origin,
                                                        definitions: snapshot.definitions, secretKeys: snapshot.secretKeys)
        let keys = Set(checked.settings.keys).union(checked.resetting)
        let before = try snapshot.state(for: keys)
        var targetValues = checked.settings
        for definition in snapshot.definitions where checked.resetting.contains(definition.key) {
            targetValues[definition.key] = definition.defaultValue
        }
        let target = try ToolsBackupSettingsState(values: targetValues, storedKeys: Set(checked.settings.keys))
        let root = plugins.directory.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        let id = UUID()
        let stage = try child(stageName(id), parent)
        let backup = try child(backupName(id), parent)
        let journalURL = try child("tools-settings-restore.json", parent)
        var originalFiles: [String: String]?
        var targetFiles: [String: String]?
        // Preparation cannot modify either live settings store.
        do {
            if !checked.payload.pluginSettings.isEmpty {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fileManager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                originalFiles = try copySettingsDirectory(root, to: stage)
                for entry in checked.payload.pluginSettings {
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
                try fileManager.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard try copySettingsDirectory(root, to: backup) == originalFiles else { throw ToolsBackupWriteFailure.rejected("Plugin settings changed while preparing the backup.") }
            }
        } catch {
            try? fileManager.removeItem(at: stage)
            try? fileManager.removeItem(at: backup)
            throw error
        }
        var journal = Journal(version: 2, transactionId: id, before: before, target: target,
                              originalFiles: originalFiles, targetFiles: targetFiles, phase: .prepared, clientWrite: .notAttempted)
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
                guard try directoryManifest(root) == originalFiles else { throw ToolsBackupWriteFailure.rejected("Plugin settings changed before commit.") }
                try replaceDirectory(root, with: stage)
                journal.phase = .pluginsApplied
                try writeJournal(journal, to: journalURL)
            }
            try fault(.beforeClientCommit)
            journal.phase = .clientPending
            journal.clientWrite = .uncertain
            try writeJournal(journal, to: journalURL)
            do {
                try settings.applyAtomically(checked.settings, checked.resetting,
                                             before.expectedSnapshot(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys))
            } catch let error as ToolsBackupWriteFailure {
                if case .rejected = error {
                    journal.clientWrite = .rejected
                    journal.phase = .clientRejected
                    try writeJournal(journal, to: journalURL)
                }
                throw error
            }
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
            if journal.clientWrite == .uncertain || isDurabilityFailure(error) {
                if journal.phase != .committed { journal.phase = .needsRecovery; try? writeJournal(journal, to: journalURL) }
                throw ToolsError.rollbackFailed
            }
            do {
                try fault(.beforeRollback)
                try rollback(journal, settings: settings, root: root, backup: backup)
                journal.phase = .rolledBack
                try writeJournal(journal, to: journalURL)
                cleanup(journal, parent: parent)
            } catch { throw ToolsError.rollbackFailed }
            throw error
        }
        cleanup(journal, parent: parent)
        return .init(settings: checked.settingCount, pluginFiles: checked.pluginFileCount)
    }

    /// Run under the maintenance lease BEFORE plugin admission/startup. Recovery
    /// writes use the journal's expected image, never a newly read native edit.
    public func recover(settings: ToolsBackupSettingsAccess, plugins: ToolsBackupPluginLocation) throws {
        lock.lock()
        defer { lock.unlock() }
        try ToolsBackupPolicy.validateLocation(plugins)
        try recoverLocked(settings: settings, plugins: plugins)
    }

    private func recoverLocked(settings: ToolsBackupSettingsAccess, plugins: ToolsBackupPluginLocation) throws {
        let root = plugins.directory.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        let file = try child("tools-settings-restore.json", parent)
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            let bytes = try ToolsFileSafety.read(file, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
            try ToolsFileSafety.checkJSON(bytes, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes * 2)
            struct Version: Decodable { let version: Int }
            let version = try JSONDecoder().decode(Version.self, from: bytes).version
            if version == 1 {
                let old = try JSONDecoder().decode(LegacyJournal.self, from: bytes)
                // An uncommitted v1 journal never recorded presence or the after
                // image. Guessing either would overwrite native edits/defaults.
                guard old.committed else { throw ToolsError.unavailable("Legacy recovery needs review: version 1 did not retain override presence or CAS state. Original files are retained.") }
                cleanup(id: old.transactionId, parent: parent)
                return
            }
            guard version == 2 else { throw ToolsError.invalidArchive("Unsupported recovery journal version.") }
            var journal = try JSONDecoder().decode(Journal.self, from: bytes)
            try validateJournal(journal)
            if journal.phase != .committed && journal.phase != .rolledBack {
                try rollback(journal, settings: settings, root: root, backup: child(backupName(journal.transactionId), parent))
                journal.phase = .rolledBack
                try writeJournal(journal, to: file)
            }
            cleanup(journal, parent: parent)
        } catch { throw ToolsError.rollbackFailed }
    }

    private func rollback(_ journal: Journal, settings: ToolsBackupSettingsAccess, root: URL, backup: URL) throws {
        let snapshot = try settings.snapshot()
        let keys = Set(journal.before.values.keys)
        let definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.key, $0) })
        for key in keys {
            guard let definition = definitions[key], !definition.isSecret, !snapshot.secretKeys.contains(key) else { throw ToolsError.rollbackFailed }
            if journal.before.storedKeys.contains(key), let value = journal.before.values[key] { try definition.validate(value) }
        }
        // A known pre-write rejection belongs to the native editor, not this
        // transaction. Leave its client values entirely alone.
        if journal.clientWrite == .applied || journal.clientWrite == .uncertain {
            do {
                try settings.applyAtomically(journal.before.overrides, journal.before.resetting,
                    journal.target.expectedSnapshot(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys))
            } catch let error as ToolsBackupWriteFailure {
                guard case .rejected = error else { throw error }
                // The forward write may never have committed. This second CAS is
                // only a same-state confirmation; it cannot overwrite another edit.
                try settings.applyAtomically(journal.before.overrides, journal.before.resetting,
                    journal.before.expectedSnapshot(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys))
            }
        }
        if let original = journal.originalFiles, let target = journal.targetFiles {
            let current = try directoryManifest(root)
            guard current == original || current == target else { throw ToolsError.rollbackFailed }
            guard try directoryManifest(backup) == original else { throw ToolsError.rollbackFailed }
            if current != original {
                let replacement = try child("tools-settings-rollback-" + UUID().uuidString, root.deletingLastPathComponent())
                try fileManager.createDirectory(at: replacement, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? fileManager.removeItem(at: replacement) }
                _ = try copySettingsDirectory(backup, to: replacement)
                try replaceDirectory(root, with: replacement)
            }
        }
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
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count <= ToolsBackupPolicy.maximumPluginFiles else { throw ToolsError.sizeLimit }
        var total = 0, result: [String: String] = [:]
        var names = Set<String>()
        for url in files {
            try ToolsBackupPolicy.validatePluginPath(url.lastPathComponent)
            guard names.insert(url.lastPathComponent.lowercased()).inserted else { throw ToolsError.unsafePath }
            let bytes = try ToolsFileSafety.read(child(url.lastPathComponent, directory), maximumBytes: ToolsBackupPolicy.maximumPluginFileBytes)
            total += bytes.count
            guard total <= ToolsBackupPolicy.maximumPayloadBytes else { throw ToolsError.sizeLimit }
            result[url.lastPathComponent] = try file(url.lastPathComponent, bytes)
        }
        return result
    }

    private func replaceDirectory(_ root: URL, with replacement: URL) throws {
        do {
            _ = try fileManager.replaceItemAt(root, withItemAt: replacement, backupItemName: nil, options: .usingNewMetadataOnly)
            try ToolsBackupJournalIO.synchronizeDirectory(root.deletingLastPathComponent())
        } catch { throw ToolsBackupWriteFailure.durability("The plugin settings replacement could not be confirmed durable.") }
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
