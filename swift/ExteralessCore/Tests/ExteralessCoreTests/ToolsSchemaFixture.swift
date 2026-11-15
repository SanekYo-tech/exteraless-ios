import Foundation
@testable import ExteralessCore

/// A self-owned native declarative authority for file fixtures, not a promise about
/// Python create_settings(). Its nonescaping pin is the production protocol seam.
final class ToolsSchemaFixture: ToolsPluginSchemaValidity, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var current: [String: ToolsPluginSchemaEvidence]
    private var drained = true

    init(_ current: [String: ToolsPluginSchemaEvidence]) { self.current = current }
    func set(_ file: String, _ evidence: ToolsPluginSchemaEvidence?) {
        lock.lock(); current[file] = evidence; lock.unlock()
    }
    func setDrained(_ value: Bool) { lock.lock(); drained = value; lock.unlock() }
    func withCurrent<T>(evidence: [String: ToolsPluginSchemaEvidence], use: ToolsPluginSchemaUse, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if case .restore = use, !drained { throw ToolsError.invalidArchive("Fixture maintenance has not drained") }
        guard evidence.allSatisfy({ current[$0.key] == $0.value }) else { throw ToolsError.invalidArchive("Fixture evidence revoked") }
        let result = try body()
        if case .export = use {
            guard evidence.allSatisfy({ current[$0.key] == $0.value }) else { throw ToolsError.invalidArchive("Fixture evidence changed during read") }
        }
        return result
    }

    private struct Row: Encodable { let type = "input"; let key: String; let backup_exportable = true }
    static func location(directory: URL, fields: [String: Set<String>]) throws -> ToolsBackupPluginLocation {
        var schemas: [String: ToolsPluginSettingsSchema] = [:]
        var evidence: [String: ToolsPluginSchemaEvidence] = [:]
        for (name, keys) in fields {
            let json = try ToolsFileSafety.encode(keys.sorted().map { Row(key: $0) })
            let source = directory.deletingLastPathComponent().appendingPathComponent("fixture-schema-" + UUID().uuidString + ".json")
            try json.write(to: source)
            let file = directory.appendingPathComponent(name)
            let digest = FileManager.default.fileExists(atPath: file.path) ? ToolsSHA256.hex(try ToolsFileSafety.read(file, maximumBytes: 1_024 * 1_024)) : nil
            schemas[name] = try ToolsPluginSchemaCache.decode(json)
            evidence[name] = .init(accountId: 1, owner: "fixture-native-owner", sourceURL: source,
                sourceSHA256: ToolsSHA256.hex(json), settingsRevision: 1, settingsSHA256: digest,
                schemaSHA256: ToolsSHA256.hex(json), guarantee: .nativeImmutable)
        }
        return .init(directory: directory, exportableFields: fields, schemas: schemas, evidence: evidence,
                     validity: ToolsSchemaFixture(evidence))
    }
}
