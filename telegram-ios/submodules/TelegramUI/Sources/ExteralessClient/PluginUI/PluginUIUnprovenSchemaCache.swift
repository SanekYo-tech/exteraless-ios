import ExteralessCore
import Foundation

/// Current SDK create_settings() is freely stateful. Its JSON is useful for
/// display/diagnostics but cannot prove immutable backup permissions, even when
/// source, account, settings bytes and interpreter epoch happen to match.
///
/// This producer deliberately has no API for minting nativeImmutable evidence.
/// A future enforced declarative schema must use a separate producer with the
/// full ToolsPluginSchemaValidity pin from tools-schema-evidence-contract.md.
final class PluginUIUnprovenSchemaCache: @unchecked Sendable {
    private let cache = ToolsPluginSchemaCache()

    func recordDynamic(fileName: String, owner: String, cachedNativeSettingsJSON: Data) throws {
        try self.cache.record(fileName: fileName, owner: owner,
            cachedNativeSettingsJSON: cachedNativeSettingsJSON, evidence: nil)
    }

    func location(directory: URL, activeOwners: [String: String]) throws -> ToolsBackupPluginLocation {
        // Core performs actual read/apply enforcement as well as filtering at
        // location creation. No owner-only pin, fabricated revision or Bool proof.
        return try self.cache.location(directory: directory, activeOwners: activeOwners, validity: nil)
    }

    func invalidate(fileName: String) { self.cache.invalidate(fileName: fileName) }
    func clear() { self.cache.clear() }
}
