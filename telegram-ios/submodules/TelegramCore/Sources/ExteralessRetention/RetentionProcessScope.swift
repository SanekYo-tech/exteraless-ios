import ExteralessCore
import Foundation

public enum ExteralessRetentionProcessRole: Equatable, Sendable {
    case mainApplication
    case notificationService
    case shareExtension
}

/// A successful configure/reload + complete registration must precede this snapshot.
/// In particular an extension's unregistered values are NOT the user's default policy.
public struct ExteralessRetentionProcessConfiguration: Equatable, Sendable {
    public let role: ExteralessRetentionProcessRole
    public let policy: RetentionPolicy
    public let durabilityRootURL: URL

    public init(role: ExteralessRetentionProcessRole, snapshot: ClientSettingsSnapshot, durabilityRootURL: URL) throws {
        let keys = RetentionFeatures.keys
        guard snapshot.lastError == nil, keys.isSubset(of: Set(snapshot.definitions.map(\.key))),
              keys.isSubset(of: Set(snapshot.values.keys)), keys.isDisjoint(with: snapshot.secretKeys),
              durabilityRootURL.isFileURL else { throw ExteralessRetentionError.unavailable }
        for definition in RetentionFeatures.definitions {
            guard let value = snapshot.values[definition.key] else { throw ExteralessRetentionError.unavailable }
            _ = try definition.validatedValue(value)
        }
        self.role = role
        self.policy = RetentionPolicy(values: snapshot.values)
        self.durabilityRootURL = durabilityRootURL.standardizedFileURL
    }

    var performsMaintenance: Bool { self.role == .mainApplication }
}

/// Every environment transition, including failure after a settings commit, has a version.
/// Versions belong to one process environment and increase for both available and unavailable.
public struct ExteralessRetentionConfigurationState: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case available(ExteralessRetentionProcessConfiguration)
        case unavailable
    }
    public let version: UInt64
    public let availability: Availability

    public init(version: UInt64, availability: Availability) {
        self.version = version
        self.availability = availability
    }
}
