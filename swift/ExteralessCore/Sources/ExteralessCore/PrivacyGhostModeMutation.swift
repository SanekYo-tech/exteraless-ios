import Foundation

/// The shared synchronous ghost toggle. Call on the owning settings worker.
public enum PrivacyGhostModeMutation {
    /// Uses one cache generation for direction, locked fields and disk CAS. A caller
    /// may supply the snapshot captured before its final context/operation check.
    /// Returns this successful batch's projected state, not a later observer edit;
    /// when every field is locked, the policy remains active without changing it.
    @discardableResult
    public static func toggle(in settings: ClientSettings, expectedBefore: ClientSettingsSnapshot? = nil) throws -> Bool {
        let before = expectedBefore ?? settings.readSnapshot()
        let policy = PrivacyPolicy(values: before.values)
        var values = policy.ghostModeChanges(enabled: !policy.ghostModeActive)
        var resets = Set<String>()
        for field in PrivacyFeatures.ghostFields {
            let key = "privacy." + field
            // Guard every value and lock, including dependencies the policy keeps.
            // A no-op reset protects absence; writing a default would create an override.
            for dependency in [key, key + "Locked"] where values[dependency] == nil {
                if before.storedKeys.contains(dependency), let value = before.values[dependency] {
                    values[dependency] = value
                } else {
                    resets.insert(dependency)
                }
            }
        }
        let projected = PrivacyPolicy(values: before.values.merging(values) { _, value in value })
        try settings.applyPublic(values, resetting: resets, expected: before)
        return projected.ghostModeActive
    }
}
