import Foundation

public struct PluginManagerPresentationState: Codable, Equatable, Sendable {
    public var engineEnabled = false
    public var safeMode = false
    public var compactView = false
    public var developerMode = false
    public var pinned: Set<String> = []
    public var warningMuted: Set<String> = []

    public init() {}

    public var permitsPluginExecution: Bool { self.engineEnabled && !self.safeMode }

    private enum CodingKeys: String, CodingKey { case engineEnabled, safeMode, compactView, developerMode, pinned, warningMuted }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing native manager files predate the master switch and ran the
        // engine automatically. Preserve that installation's behavior on upgrade.
        self.engineEnabled = try values.decodeIfPresent(Bool.self, forKey: .engineEnabled) ?? true
        self.safeMode = try values.decodeIfPresent(Bool.self, forKey: .safeMode) ?? false
        self.compactView = try values.decodeIfPresent(Bool.self, forKey: .compactView) ?? false
        self.developerMode = try values.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        self.pinned = try values.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        self.warningMuted = try values.decodeIfPresent(Set<String>.self, forKey: .warningMuted) ?? []
    }

    public func precedes(id leftId: String, title leftTitle: String, id rightId: String, title rightTitle: String) -> Bool {
        let leftPinned = self.pinned.contains(leftId)
        let rightPinned = self.pinned.contains(rightId)
        if leftPinned != rightPinned { return leftPinned }
        let order = leftTitle.compare(rightTitle, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return order == .orderedSame ? leftId < rightId : order == .orderedAscending
    }
}

enum PluginManagerPreferenceChange: Sendable {
    case engine(Bool), safeMode(Bool), compact(Bool), developer(Bool), pinned(String, Bool), warningMuted(String, Bool), remove(String)
    case pinnedSet(wanted: Set<String>, installed: Set<String>)
}

/// Manager presentation state is separate from plugin-owned setting JSON. Writes
/// publish only after atomic persistence succeeds; fixtures inject a temp URL.
final class PluginManagerPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var state = PluginManagerPresentationState()

    init(url: URL, legacyEngineEnabled: Bool = false) throws {
        self.url = url
        self.state.engineEnabled = legacyEngineEnabled
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 128 * 1024 else { throw PluginUIFailure.malformed("Plugin manager preferences exceed 128 KiB") }
            self.state = try JSONDecoder().decode(PluginManagerPresentationState.self, from: Data(contentsOf: url))
            try Self.validate(self.state)
        } else {
            // Persist the first-install/upgrade decision once. Disabling the last
            // plugin later must not silently turn off an upgraded master switch.
            try JSONEncoder().encode(self.state).write(to: url, options: .atomic)
        }
    }

    var snapshot: PluginManagerPresentationState {
        self.lock.lock(); defer { self.lock.unlock() }; return self.state
    }

    func apply(_ change: PluginManagerPreferenceChange, isCurrent: () -> Bool = { true }) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        var next = self.state
        switch change {
        case let .engine(value): next.engineEnabled = value
        case let .safeMode(value): next.safeMode = value
        case let .compact(value): next.compactView = value
        case let .developer(value): next.developerMode = value
        case let .pinned(id, value):
            if value { next.pinned.insert(id) } else { next.pinned.remove(id) }
        case let .pinnedSet(wanted, installed):
            next.pinned.subtract(installed)
            next.pinned.formUnion(wanted.intersection(installed))
        case let .warningMuted(id, value):
            if value { next.warningMuted.insert(id) } else { next.warningMuted.remove(id) }
        case let .remove(id): next.pinned.remove(id); next.warningMuted.remove(id)
        }
        try Self.validate(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 128 * 1024 else { throw PluginUIFailure.malformed("Plugin manager preferences exceed 128 KiB") }
        // One admission point for the complete atomic write, including a whole
        // pinned-set update. No later per-plugin writes can outlive revocation.
        guard isCurrent() else { throw PluginUIFailure.invalidHandle("Plugin config writer authority expired") }
        try data.write(to: self.url, options: .atomic)
        self.state = next
    }

    private static func validate(_ state: PluginManagerPresentationState) throws {
        guard state.pinned.count <= 4096, state.warningMuted.count <= 4096 else { throw PluginUIFailure.malformed("Plugin manager preference count exceeded") }
        for id in state.pinned.union(state.warningMuted) {
            guard (2...32).contains(id.utf8.count), let first = id.utf8.first,
                  (65...90).contains(first) || (97...122).contains(first), id.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }) else { throw PluginUIFailure.malformed("Invalid plugin manager preference id") }
        }
    }
}

public struct PluginManagerControls {
    public let snapshot: () -> PluginManagerPresentationState?
    public let compact: (Bool) async throws -> Void
    public let developer: (Bool) async throws -> Void
    public let pin: (String, Bool) async throws -> Void
    public let muteWarning: (String, Bool) async throws -> Void
    public let reload: (String) async throws -> Void
    public let developerConnection: () -> PluginDeveloperConnectionState
    public let engine: (Bool) async throws -> Void
    public let safeMode: (Bool) async throws -> Void
    public let recovery: () -> PluginRuntimeRecoverySnapshot?
    public let acknowledgeRecovery: () async throws -> Void

    public init(snapshot: @escaping () -> PluginManagerPresentationState?, compact: @escaping (Bool) async throws -> Void,
                developer: @escaping (Bool) async throws -> Void, pin: @escaping (String, Bool) async throws -> Void,
                muteWarning: @escaping (String, Bool) async throws -> Void, reload: @escaping (String) async throws -> Void,
                engine: @escaping (Bool) async throws -> Void, safeMode: @escaping (Bool) async throws -> Void,
                recovery: @escaping () -> PluginRuntimeRecoverySnapshot?, acknowledgeRecovery: @escaping () async throws -> Void,
                developerConnection: @escaping () -> PluginDeveloperConnectionState = { .init(status: "Unavailable", token: nil) }) {
        self.snapshot = snapshot; self.compact = compact; self.developer = developer
        self.pin = pin; self.muteWarning = muteWarning; self.reload = reload
        self.developerConnection = developerConnection
        self.engine = engine; self.safeMode = safeMode
        self.recovery = recovery; self.acknowledgeRecovery = acknowledgeRecovery
    }
}
