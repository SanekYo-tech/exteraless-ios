import Foundation

/// Capture once before scheduling; the returned predicate is checked again at
/// native admission and owner-worker execution. It does not capture an owner.
public typealias PluginPermissionAdmission = @Sendable (String, Set<PluginPermission>) -> (@Sendable () -> Bool)

/// Native consent policy from PluginTrustLevel.java. A level is a ceiling, not
/// a grant and not a claim that an Android/JVM/native-code mechanism is available.
public enum PluginTrustLevel: Int, Codable, CaseIterable, Hashable, Sendable {
    case isolated = 0
    case gated = 1
    case trusted = 2

    public static let `default`: PluginTrustLevel = .isolated

    public var name: String {
        switch self {
        case .isolated: return "Isolated"
        case .gated: return "Gated"
        case .trusted: return "Trusted"
        }
    }

    /// The global, explicitly selected native unsafe mode overrides the cap, as
    /// PluginTrustLevel.allows / PluginPermissions.has do in the original.
    public func allows(_ permission: PluginPermission, unsafeMode: Bool = false) -> Bool {
        if permission == .ui || unsafeMode { return true }
        switch self {
        case .isolated: return false
        case .gated: return !permission.isDangerous
        case .trusted: return true
        }
    }

    /// Only actual raw consent is migration evidence. Metadata requests and
    /// unsafe mode must never raise a migrated level.
    public static func migrating(rawGrants: [PluginPermission]) -> PluginTrustLevel {
        if rawGrants.contains(where: \.isDangerous) { return .trusted }
        return rawGrants.contains(where: { $0 != .ui }) ? .gated : .isolated
    }
}

/// The indivisible durable consent record. Raw grants are deliberately distinct
/// from effective grants: even a stale/mismatched disk record remains capped.
public struct PluginPermissionRecord: Hashable, Sendable {
    public let level: PluginTrustLevel
    public let grants: Set<PluginPermission>

    public init(level: PluginTrustLevel = .default, grants: [PluginPermission] = []) {
        self.level = level
        self.grants = Set(grants).subtracting([.ui])
    }

    public var orderedGrants: [PluginPermission] {
        PluginPermission.requestable.filter { grants.contains($0) }
    }

    public func effective(unsafeMode: Bool = false) -> Set<PluginPermission> {
        if unsafeMode { return Set(PluginPermission.allCases) }
        return Set(grants.filter { level.allows($0) }).union([.ui])
    }

    /// Prune at the OLD ceiling too, so upgrading a mismatched old record cannot
    /// turn a previously capped raw bit into fresh consent. Unsafe mode never
    /// prevents the durable pruning performed by an explicit level change.
    func changingLevel(to next: PluginTrustLevel) -> PluginPermissionRecord {
        PluginPermissionRecord(level: next, grants: orderedGrants.filter {
            level.allows($0) && next.allows($0)
        })
    }
}

/// One locked read for UI and admission. UI switches display stored consent;
/// `effective` includes the cap and global override from this same snapshot.
public struct PluginPermissionSnapshot: Equatable, Sendable {
    public let record: PluginPermissionRecord?
    public let unsafeMode: Bool
    /// In-process native-editor revision. It is never plugin metadata or stored
    /// consent. An A -> B -> A edit must not revive an old pending UI action.
    public let revision: UUID?

    public init(record: PluginPermissionRecord?, unsafeMode: Bool, revision: UUID? = nil) {
        self.record = record
        self.unsafeMode = unsafeMode
        self.revision = revision
    }

    public var level: PluginTrustLevel { record?.level ?? .default }
    public var grants: Set<PluginPermission> { record?.grants ?? [] }
    public var effective: Set<PluginPermission> {
        (record ?? PluginPermissionRecord()).effective(unsafeMode: unsafeMode)
    }

    public func allows(_ permission: PluginPermission) -> Bool {
        level.allows(permission, unsafeMode: unsafeMode)
    }
}

public enum PluginPermissionStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidFormat(String)
    case unsupportedVersion(Int)
    case disallowedGrant(PluginTrustLevel, PluginPermission)
    case authorityExpired

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason): return "Plugin consent storage: \(reason)"
        case .unsupportedVersion(let version): return "Unsupported plugin consent storage version: \(version)"
        case let .disallowedGrant(level, permission):
            return "\(level.name) does not allow granting \(permission.rawValue)"
        case .authorityExpired: return "Plugin consent operation belongs to an expired native authority"
        }
    }
}
