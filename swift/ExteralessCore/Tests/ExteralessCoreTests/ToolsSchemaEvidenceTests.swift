import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsSchemaEvidenceTests: XCTestCase {
    private let s1 = Data("[{\"type\":\"switch\",\"key\":\"mode\"},{\"type\":\"slider\",\"key\":\"value\",\"min\":0,\"max\":100}]".utf8)
    private let s2 = Data("[{\"type\":\"switch\",\"key\":\"mode\"}]".utf8)

    private struct Fixture {
        let directory: URL
        let file: URL
        let source: URL
        func evidence(_ schema: Data, revision: UInt64 = 1, owner: String = "owner-a",
                      account: Int64 = 1, guarantee: ToolsPluginSchemaEvidence.Guarantee = .nativeImmutable) throws -> ToolsPluginSchemaEvidence {
            .init(accountId: account, owner: owner, sourceURL: source,
                  sourceSHA256: ToolsSHA256.hex(try ToolsFileSafety.read(source, maximumBytes: 1_024)),
                  settingsRevision: revision, settingsSHA256: ToolsSHA256.hex(try ToolsFileSafety.read(file, maximumBytes: 1_024)),
                  schemaSHA256: ToolsSHA256.hex(schema), guarantee: guarantee)
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-schema-evidence-" + UUID().uuidString)
        let directory = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json"), file = directory.appendingPathComponent("fixture.json")
        try Data("native declarative fixture; no Python execution API".utf8).write(to: source)
        try Data("{\"mode\":false,\"value\":75}".utf8).write(to: file)
        return Fixture(directory: directory, file: file, source: source)
    }
    private func export(_ location: ToolsBackupPluginLocation, hooks: ToolsFileOperationHooks = .init()) throws -> ToolsBackupInspection {
        try ToolsBackupArchive.inspect(ToolsBackupArchive.export(settings: [:], definitions: [], appVersion: "fixture", plugins: location, fileHooks: hooks), definitions: [])
    }

    func testHNS01S1ValuesWriteS2WithinSameOwnerRevokesCapturedPermission() throws {
        let f = try fixture(), cache = ToolsPluginSchemaCache()
        let first = try f.evidence(s1)
        let authority = ToolsSchemaFixture(["fixture.json": first])
        try cache.record(fileName: "fixture.json", owner: "owner-a", cachedNativeSettingsJSON: s1, evidence: first)
        let captured = try cache.location(directory: f.directory, activeOwners: ["fixture.json": "owner-a"], validity: authority)
        XCTAssertEqual(try export(captured).payload.pluginSettings.first?.values["value"], .integer(75))
        try Data("{\"mode\":true,\"value\":75}".utf8).write(to: f.file)
        let second = try f.evidence(s2, revision: 2)
        authority.set("fixture.json", second)
        try cache.record(fileName: "fixture.json", owner: "owner-a", cachedNativeSettingsJSON: s2, evidence: second)
        XCTAssertThrowsError(try export(captured))
        let current = try cache.location(directory: f.directory, activeOwners: ["fixture.json": "owner-a"], validity: authority)
        let values = try XCTUnwrap(export(current).payload.pluginSettings.first?.values)
        XCTAssertEqual(values, ["mode": .bool(true)])
    }

    func testHNS01UnloadWriteAfterFreezeFailsPostDrainSnapshotCheck() throws {
        let f = try fixture(), cache = ToolsPluginSchemaCache()
        let evidence = try f.evidence(s1)
        let authority = ToolsSchemaFixture(["fixture.json": evidence])
        authority.setDrained(false)
        try cache.record(fileName: "fixture.json", owner: "owner-a", cachedNativeSettingsJSON: s1, evidence: evidence)
        let frozen = try cache.location(directory: f.directory, activeOwners: ["fixture.json": "owner-a"], validity: authority)
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(.init(createdAt: "2026-11-15T00:00:00Z", appVersion: "fixture", clientSettings: [:],
            pluginSettings: [.init(path: "fixture.json", values: ["value": .integer(50)])])), definitions: [])
        let access = ToolsBackupSettingsAccess(snapshot: { .init(definitions: [], values: [:], storedKeys: []) }, applyAtomically: { _, _, _ in XCTFail("Rejected schema cannot reach client commit") })
        XCTAssertThrowsError(try ToolsBackupRestorer().restore(imported, settings: access, plugins: frozen))
        let changed = Data("{\"mode\":true,\"value\":5}".utf8)
        try changed.write(to: f.file) // Actual unload-side file write, even if a producer forgot to update its counter.
        authority.setDrained(true)
        XCTAssertThrowsError(try ToolsBackupRestorer().restore(imported, settings: access, plugins: frozen))
        XCTAssertEqual(try Data(contentsOf: f.file), changed)
    }

    func testHNS01SourceOwnerAccountAndCacheRevocationBetweenLocationAndRead() throws {
        let f = try fixture(), cache = ToolsPluginSchemaCache()
        let evidence = try f.evidence(s1)
        let authority = ToolsSchemaFixture(["fixture.json": evidence])
        try cache.record(fileName: "fixture.json", owner: "owner-a", cachedNativeSettingsJSON: s1, evidence: evidence)
        let location = try cache.location(directory: f.directory, activeOwners: ["fixture.json": "owner-a"], validity: authority)
        authority.set("fixture.json", try f.evidence(s1, owner: "owner-b"))
        XCTAssertThrowsError(try export(location))
        authority.set("fixture.json", try f.evidence(s1, account: 2))
        XCTAssertThrowsError(try export(location))
        authority.set("fixture.json", evidence)
        let source = f.source
        let hooks = ToolsFileOperationHooks { point, _ in
            if case .afterSourceMetadata = point { try Data("replacement source".utf8).write(to: source) }
        }
        XCTAssertThrowsError(try export(location, hooks: hooks))
        cache.invalidate(fileName: "fixture.json")
        XCTAssertThrowsError(try export(location))
    }

    func testHNS01ArbitraryDynamicSchemasAndBareAllowlistsDoNotAuthorizeBackup() throws {
        let f = try fixture(), cache = ToolsPluginSchemaCache()
        let evidence = try f.evidence(s1, guarantee: .unprovenDynamic)
        let authority = ToolsSchemaFixture(["fixture.json": evidence])
        try cache.record(fileName: "fixture.json", owner: "owner-a", cachedNativeSettingsJSON: s1, evidence: evidence)
        let location = try cache.location(directory: f.directory, activeOwners: ["fixture.json": "owner-a"], validity: authority)
        XCTAssertTrue(location.exportableFields.isEmpty)
        XCTAssertEqual(try export(location).pluginFileCount, 0)
        XCTAssertThrowsError(try export(.init(directory: f.directory, exportableFields: ["fixture.json": ["mode"]])))
        XCTAssertEqual(try Data(contentsOf: f.file), Data("{\"mode\":false,\"value\":75}".utf8))
    }
}
