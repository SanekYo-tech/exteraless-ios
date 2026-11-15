import Foundation

/// Native per-plugin JSON settings and directories. The production root is
/// Application Support/exteraless; a test may inject a disposable root URL.
///
/// Layout: settings/<component>.json, files/<component>/, cache/<component>/,
/// plugins/. A component is the validated id plus its UTF-8 hex suffix, so ids
/// differing only in case remain isolated on case-insensitive iOS filesystems.
/// Only a missing settings file means an empty store. Corrupt/unreadable files
/// are reported and are never overwritten with a silent default.
public final class PluginServiceStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL?
    private let fileManager: FileManager
    private let maximumSettingsBytes = 1_048_576

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.root = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("exteraless", isDirectory: true)
    }

    public static func validatePluginId(_ pluginId: String) throws {
        guard (Plugin.isValidID(pluginId) || Plugin.isValidID(pluginId, format: .elyx)),
              !Plugin.isReservedID(pluginId) else {
            throw BridgeFailure.permission("Invalid plugin id for native storage: \(pluginId)")
        }
    }

    public func rootDirectory() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try directory([])
    }

    public func pluginsDirectory() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try directory(["plugins"])
    }

    public func settingsDirectory() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try directory(["settings"])
    }

    /// Resolve the settings location without creating any directory. Backup
    /// inspection/freeze and recovery must acquire their maintenance lease before
    /// performing filesystem mutations, including creating a missing root.
    public func settingsDirectoryURL() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let root, root.isFileURL else {
            throw BridgeFailure.storage("Application Support/exteraless is unavailable")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent("settings", isDirectory: true)
        try checkContained(target, in: base)
        return target
    }

    public func filesDirectory(pluginId: String) throws -> URL {
        try Self.validatePluginId(pluginId)
        lock.lock()
        defer { lock.unlock() }
        return try directory(["files", Self.component(pluginId)])
    }

    public func cacheDirectory(pluginId: String) throws -> URL {
        try Self.validatePluginId(pluginId)
        lock.lock()
        defer { lock.unlock() }
        return try directory(["cache", Self.component(pluginId)])
    }

    /// Capture before retiring a worker. The lease pins archive directory/file
    /// inodes so a delayed purge cannot discover a replacement generation by path.
    public func captureArchiveCache(pluginId: String) throws -> PluginArchiveCacheLease {
        try captureArchiveCache(pluginId: pluginId, hooks: .init())
    }

    func captureArchiveCache(pluginId: String, hooks: PluginArchiveFileHooks) throws -> PluginArchiveCacheLease {
        try Self.validatePluginId(pluginId)
        lock.lock(); defer { lock.unlock() }
        guard let root, root.isFileURL else {
            throw BridgeFailure.storage("Application Support/exteraless is unavailable")
        }
        return try PluginArchiveCacheLease.capture(root: root, component: Self.component(pluginId), hooks: hooks)
    }

    /// Synchronous convenience; asynchronous retirement uses captureArchiveCache
    /// before the await and purges that same lease afterwards.
    public func purgeArchiveCache(pluginId: String) throws {
        try captureArchiveCache(pluginId: pluginId).purge()
    }

    public func getSetting(pluginId: String, key: String, defaultValue: PluginJSONValue) throws -> PluginJSONValue {
        try Self.validatePluginId(pluginId)
        try validateKey(key)
        lock.lock()
        defer { lock.unlock() }
        return try readSettings(pluginId: pluginId)[key] ?? defaultValue
    }

    public func setSetting(pluginId: String, key: String, value: PluginJSONValue) throws {
        try Self.validatePluginId(pluginId)
        try validateKey(key)
        lock.lock()
        defer { lock.unlock() }
        var settings = try readSettings(pluginId: pluginId)
        settings[key] = value
        try writeSettings(settings, pluginId: pluginId)
    }

    /// Returns true iff a stored key was removed. JSON null is a stored value,
    /// distinct from a missing key, and does not implicitly remove the setting.
    @discardableResult
    public func removeSetting(pluginId: String, key: String) throws -> Bool {
        try Self.validatePluginId(pluginId)
        try validateKey(key)
        lock.lock()
        defer { lock.unlock() }
        var settings = try readSettings(pluginId: pluginId)
        guard settings.removeValue(forKey: key) != nil else { return false }
        try writeSettings(settings, pluginId: pluginId)
        return true
    }

    public func settingsSnapshot(pluginId: String) throws -> [String: PluginJSONValue] {
        try Self.validatePluginId(pluginId)
        lock.lock(); defer { lock.unlock() }
        return try readSettings(pluginId: pluginId)
    }

    /// Explicit replacement/restore, distinct from an implicit read fallback.
    /// All keys and the complete output are validated before atomic replacement.
    public func replaceSettings(pluginId: String, values: [String: PluginJSONValue]) throws {
        try Self.validatePluginId(pluginId)
        for key in values.keys { try validateKey(key) }
        lock.lock(); defer { lock.unlock() }
        try writeSettings(values, pluginId: pluginId)
    }

    public func updateSettings(pluginId: String, values: [String: PluginJSONValue]) throws {
        try Self.validatePluginId(pluginId)
        for key in values.keys { try validateKey(key) }
        lock.lock(); defer { lock.unlock() }
        var current = try readSettings(pluginId: pluginId)
        for (key, value) in values { current[key] = value }
        try writeSettings(current, pluginId: pluginId)
    }

    public func settingsJSON(pluginId: String) throws -> String {
        let values = try settingsSnapshot(pluginId: pluginId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(values), as: UTF8.self)
    }

    public func writeSettingsJSON(pluginId: String, json: String, replace: Bool) throws {
        let data = Data(json.utf8)
        guard data.count <= maximumSettingsBytes else {
            throw BridgeFailure.storage("Settings payload exceeds 1 MiB")
        }
        let values: [String: PluginJSONValue]
        do { values = try JSONDecoder().decode([String: PluginJSONValue].self, from: data) }
        catch { throw BridgeFailure.malformed("Settings payload must be a JSON object") }
        if replace { try replaceSettings(pluginId: pluginId, values: values) }
        else { try updateSettings(pluginId: pluginId, values: values) }
    }

    private func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 256, !key.contains("\0") else {
            throw BridgeFailure.malformed("Setting key must contain 1...256 UTF-8 bytes without NUL")
        }
    }

    static func component(_ pluginId: String) -> String {
        // Validated ids are ASCII; every permitted byte has exactly two hex digits.
        pluginId + "-" + pluginId.utf8.map { String($0, radix: 16) }.joined()
    }

    private func directory(_ components: [String]) throws -> URL {
        guard let root, root.isFileURL else {
            throw BridgeFailure.storage("Application Support/exteraless is unavailable")
        }
        do {
            let base = root.standardizedFileURL.resolvingSymlinksInPath()
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            let target = components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
            try checkContained(target, in: base)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try checkContained(target, in: base)
            return target
        } catch let failure as BridgeFailure {
            throw failure
        } catch {
            throw BridgeFailure.storage("Native service directory: \(error.localizedDescription)")
        }
    }

    private func checkContained(_ url: URL, in root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard path.starts(with: base), path == url.standardizedFileURL.pathComponents else {
            throw BridgeFailure.permission("Native service path is redirected by a symbolic link or escapes its owner directory")
        }
    }

    private func settingsURL(pluginId: String) throws -> URL {
        let directory = try self.directory(["settings"])
        let url = directory.appendingPathComponent(Self.component(pluginId)).appendingPathExtension("json")
        try checkContained(url, in: directory)
        return url
    }

    private func readSettings(pluginId: String) throws -> [String: PluginJSONValue] {
        let url = try settingsURL(pluginId: pluginId)
        let data: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(maximumSettingsBytes) {
                throw BridgeFailure.storage("Settings for \(pluginId) exceed 1 MiB")
            }
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return [:]
        } catch let failure as BridgeFailure {
            throw failure
        } catch {
            throw BridgeFailure.storage("Cannot read settings for \(pluginId): \(error.localizedDescription)")
        }
        guard data.count <= maximumSettingsBytes else {
            throw BridgeFailure.storage("Settings for \(pluginId) exceed 1 MiB")
        }
        do {
            return try JSONDecoder().decode([String: PluginJSONValue].self, from: data)
        } catch {
            throw BridgeFailure.storage("Invalid settings JSON for \(pluginId)")
        }
    }

    private func writeSettings(_ settings: [String: PluginJSONValue], pluginId: String) throws {
        let url = try settingsURL(pluginId: pluginId)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(settings)
            guard data.count <= maximumSettingsBytes else {
                throw BridgeFailure.storage("Settings for \(pluginId) exceed 1 MiB")
            }
            // Foundation replaces the destination atomically; no remove+move gap.
            try data.write(to: url, options: .atomic)
        } catch let failure as BridgeFailure {
            throw failure
        } catch {
            throw BridgeFailure.storage("Cannot write settings for \(pluginId): \(error.localizedDescription)")
        }
    }
}

public struct PluginServiceLogEntry: Identifiable, Sendable {
    public enum Level: String, Sendable { case info, warning, error }
    public let id: UInt64
    public let timestamp: Date
    public let pluginId: String
    public let level: Level
    public let message: String
}

/// Bounded in-memory log. Readers receive an immutable oldest-first copy; neither
/// a UI observer nor a Python callback runs while the buffer's lock is held.
public final class PluginServiceLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let maximumMessageBytes: Int
    private var buffer: [PluginServiceLogEntry?]
    private var count = 0
    private var next = 0
    private var sequence: UInt64 = 0

    public init(capacity: Int = 512, maximumMessageBytes: Int = 4096) {
        self.capacity = max(1, capacity)
        self.maximumMessageBytes = max(1, maximumMessageBytes)
        self.buffer = Array(repeating: nil, count: max(1, capacity))
    }

    public func append(pluginId: String, level: PluginServiceLogEntry.Level = .info, message: String) {
        // A Character may contain arbitrarily many combining scalars. Bound bytes,
        // then drop an incomplete trailing scalar rather than growing a replacement.
        var bytes = Array(message.utf8.prefix(maximumMessageBytes))
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        let bounded = String(bytes: bytes, encoding: .utf8) ?? ""
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        buffer[next] = PluginServiceLogEntry(id: sequence, timestamp: Date(), pluginId: pluginId,
                                             level: level, message: bounded)
        next = (next + 1) % capacity
        count = min(count + 1, capacity)
    }

    public var entries: [PluginServiceLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let start = count == capacity ? next : 0
        return (0..<count).compactMap { buffer[(start + $0) % capacity] }
    }

    public func entries(pluginId: String) -> [PluginServiceLogEntry] {
        entries.filter { $0.pluginId == pluginId }
    }
}
