import Foundation

/// Native install-editor draft. Declared permissions are displayed separately;
/// they never preselect a tier or a grant. Publishing the draft still goes through
/// Host's captured native authority and the durable consent transaction.
public struct PluginTrustSelection: Equatable, Sendable {
    public private(set) var level: PluginTrustLevel
    public private(set) var grants: Set<PluginPermission>

    public init(record: PluginPermissionRecord = PluginPermissionRecord()) {
        level = record.level
        grants = record.grants.filter { record.level.allows($0) }
    }

    public var record: PluginPermissionRecord {
        PluginPermissionRecord(level: level, grants: PluginPermission.requestable.filter { grants.contains($0) })
    }

    public mutating func selectLevel(_ value: PluginTrustLevel) {
        grants = grants.filter { value.allows($0) }
        level = value
    }

    public mutating func select(_ permission: PluginPermission, granted: Bool) throws {
        if permission == .ui { return }
        if granted {
            guard level.allows(permission) else { throw PluginPermissionStoreError.disallowedGrant(level, permission) }
            grants.insert(permission)
        } else { grants.remove(permission) }
    }
}
