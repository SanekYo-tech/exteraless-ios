import Foundation

/// A versioned wrapper in the EXISTING grants.json. Its lock covers read/modify/
/// replace; no operation ever writes grants and their ceiling separately.
final class PluginPermissionStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    // Internal fault/admission seam; it runs before the commit, never after it.
    private let beforeCommit: (@Sendable () throws -> Void)?

    init(url: URL, beforeCommit: (@Sendable () throws -> Void)? = nil) {
        self.url = url
        self.beforeCommit = beforeCommit
    }

    func load() throws -> [String: PluginPermissionRecord] {
        try update { _ in }
    }

    /// The predicate may read the PermissionsModel/owner/account snapshots. It
    /// must be lock-only and must not mutate storage or reenter this transaction.
    func update(isCurrent: @Sendable () -> Bool = { true },
                _ change: (inout [String: PluginPermissionRecord]) throws -> Void) throws -> [String: PluginPermissionRecord] {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try read()
        var next = loaded.records
        try change(&next)
        if loaded.needsMigration || next != loaded.records {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(records: next))
            try beforeCommit?()
            guard isCurrent() else { throw PluginPermissionStoreError.authorityExpired }
            // Foundation stages in the same directory and atomically renames.
            // Do not remove the previous file first or swallow an I/O error.
            try data.write(to: url, options: .atomic)
        } else {
            guard isCurrent() else { throw PluginPermissionStoreError.authorityExpired }
        }
        // Nothing throwable, cancellable, or authority-dependent after commit.
        return next
    }

    private func read() throws -> (records: [String: PluginPermissionRecord], needsMigration: Bool) {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PluginPermissionStoreError.invalidFormat("grants.json must be a regular file")
            }
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            // Absence is the only empty-store case. Bad JSON, denied access,
            // directories, symlinks and unknown schema versions are errors.
            let parent = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            guard parent[.type] as? FileAttributeType == .typeDirectory else {
                throw PluginPermissionStoreError.invalidFormat("consent directory is unavailable")
            }
            return ([:], false)
        }
        let decoder = JSONDecoder()
        // The legacy shape is disjoint from the wrapper's integer version.
        // Unknown legacy permission strings were ignored by the original reader.
        if let legacy = try? decoder.decode([String: [String]].self, from: data) {
            return (legacy.mapValues { raw in
                let grants = PluginPermission.sanitize(rawKeys: raw)
                return PluginPermissionRecord(level: .migrating(rawGrants: grants), grants: grants)
            }, true)
        }
        let document = try decoder.decode(Document.self, from: data)
        return (document.records.mapValues(\.record), document.records.values.contains(where: \.needsMigration))
    }

    private struct Key: CodingKey, Hashable {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static let version = Key(stringValue: "version")
        static let records = Key(stringValue: "records")
        static let level = Key(stringValue: "level")
        static let grants = Key(stringValue: "grants")
    }

    private struct DiskRecord: Codable {
        let record: PluginPermissionRecord
        let needsMigration: Bool

        init(_ record: PluginPermissionRecord) {
            self.record = record
            self.needsMigration = false
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            guard Set(values.allKeys).isSubset(of: [.level, .grants]) else {
                throw PluginPermissionStoreError.invalidFormat("unknown consent record field")
            }
            let grants = try values.decode([PluginPermission].self, forKey: .grants)
            // Missing is legacy; an explicit null/wrong type/invalid enum is not.
            needsMigration = !values.contains(.level)
            let level: PluginTrustLevel
            if needsMigration { level = .migrating(rawGrants: grants) }
            else { level = try values.decode(PluginTrustLevel.self, forKey: .level) }
            record = PluginPermissionRecord(level: level, grants: grants)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Key.self)
            try values.encode(record.level, forKey: .level)
            try values.encode(record.orderedGrants, forKey: .grants)
        }
    }

    private struct Document: Codable {
        let records: [String: DiskRecord]

        init(records: [String: PluginPermissionRecord]) { self.records = records.mapValues(DiskRecord.init) }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            guard Set(values.allKeys) == [.version, .records] else {
                throw PluginPermissionStoreError.invalidFormat("expected version and records")
            }
            let version = try values.decode(Int.self, forKey: .version)
            guard version == 1 else { throw PluginPermissionStoreError.unsupportedVersion(version) }
            records = try values.decode([String: DiskRecord].self, forKey: .records)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Key.self)
            try values.encode(1, forKey: .version)
            try values.encode(records, forKey: .records)
        }
    }
}
