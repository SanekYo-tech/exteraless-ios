import Foundation

public struct PluginRuntimeRecoverySnapshot: Equatable, Sendable {
    public let earlyUncleanStarts: Int
    public let notice: String?
}

/// Native process recovery uses an early-start journal, not a fabricated Java
/// uncaught-exception count. A healthy/backgrounded launch clears it; three
/// consecutive unclean, unattributed starts request real Host safe-mode startup.
final class PluginRuntimeRecovery: @unchecked Sendable {
    private struct State: Codable, Equatable {
        var armed = false
        var earlyUncleanStarts = 0
        var autoSafeMode = false
        var requestedAutomaticSafeMode = false
        var crashedPlugin: String?

        init() {}
        private enum CodingKeys: String, CodingKey { case armed, earlyUncleanStarts, autoSafeMode, requestedAutomaticSafeMode, crashedPlugin }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.armed = try values.decodeIfPresent(Bool.self, forKey: .armed) ?? false
            self.earlyUncleanStarts = try values.decodeIfPresent(Int.self, forKey: .earlyUncleanStarts) ?? 0
            self.autoSafeMode = try values.decodeIfPresent(Bool.self, forKey: .autoSafeMode) ?? false
            self.requestedAutomaticSafeMode = try values.decodeIfPresent(Bool.self, forKey: .requestedAutomaticSafeMode) ?? false
            self.crashedPlugin = try values.decodeIfPresent(String.self, forKey: .crashedPlugin)
        }
    }
    private let lock = NSLock()
    private let url: URL
    private var state = State()

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 else { throw PluginUIFailure.malformed("Runtime recovery journal is oversized") }
            self.state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard (0...3).contains(self.state.earlyUncleanStarts), (self.state.crashedPlugin?.utf8.count ?? 0) <= 128 else { throw PluginUIFailure.malformed("Invalid runtime recovery state") }
        }
    }

    var snapshot: PluginRuntimeRecoverySnapshot {
        self.lock.lock(); defer { self.lock.unlock() }
        var notices: [String] = []
        if self.state.autoSafeMode { notices.append("Safe mode was enabled after three unclean early runtime starts.") }
        if let id = self.state.crashedPlugin { notices.append("Plugin \(id) was disabled by native crash recovery.") }
        return PluginRuntimeRecoverySnapshot(earlyUncleanStarts: self.state.earlyUncleanStarts, notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }

    /// Called once, immediately before this process's native Host startup.
    func beginStart(safeMode: Bool, hasAttributedPluginMarker: Bool) throws -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        var next = self.state
        if safeMode {
            if next.requestedAutomaticSafeMode { next.autoSafeMode = true }
            next.requestedAutomaticSafeMode = false
            next.armed = false
            next.earlyUncleanStarts = 0
        } else if !next.requestedAutomaticSafeMode {
            if hasAttributedPluginMarker { next.earlyUncleanStarts = 0 }
            else if next.armed { next.earlyUncleanStarts = min(3, next.earlyUncleanStarts + 1) }
            if next.earlyUncleanStarts >= 3 {
                next.requestedAutomaticSafeMode = true
                next.earlyUncleanStarts = 0
                next.armed = false
            } else { next.armed = true }
        }
        try self.save(next)
        return next.requestedAutomaticSafeMode
    }

    /// Called only after the manager's actual safe-mode startup policy persisted.
    /// A failed write leaves the request pending for the next native launch.
    func confirmAutomaticSafeMode() throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.state.requestedAutomaticSafeMode else { return }
        var next = self.state
        next.requestedAutomaticSafeMode = false
        next.autoSafeMode = true
        try self.save(next)
    }

    static func attributedPlugin(marker: URL, knownPlugins: Set<String>) -> String? {
        guard let size = try? marker.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...128).contains(size),
              let data = try? Data(contentsOf: marker), data.count <= 128,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              knownPlugins.contains(value) else { return nil }
        return value
    }

    func markHealthy() throws {
        self.lock.lock(); defer { self.lock.unlock() }
        var next = self.state
        next.armed = false
        next.earlyUncleanStarts = 0
        try self.save(next)
    }

    func recordDisabledPlugin(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128 else { throw PluginUIFailure.malformed("Invalid recovered plugin id") }
        self.lock.lock(); defer { self.lock.unlock() }
        var next = self.state
        next.crashedPlugin = id
        try self.save(next)
    }

    func acknowledgeNotice() throws {
        self.lock.lock(); defer { self.lock.unlock() }
        var next = self.state
        next.autoSafeMode = false
        next.crashedPlugin = nil
        try self.save(next)
    }

    private func save(_ value: State) throws {
        guard value != self.state else { return }
        try JSONEncoder().encode(value).write(to: self.url, options: .atomic)
        self.state = value
    }
}
