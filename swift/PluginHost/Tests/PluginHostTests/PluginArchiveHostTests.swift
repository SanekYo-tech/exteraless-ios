import Foundation
import XCTest
@testable import PluginHost

// This engine reads fixture JSON, not ZIP: these tests exercise the real native
// copy/replace/model/owner lifecycle. test_ios_elyx_archives.py supplies real,
// owned ZIPs and a generator for the linked-CPython Mac fixture handoff.
private func archiveFixtureReply(_ source: String) throws -> String? {
    for method in ["metadata_json", "load_json"] {
        let prefix = "_exteraless_runtime.\(method)("
        guard source.hasPrefix(prefix) else { continue }
        let args = "[" + String(source.dropFirst(prefix.count).dropLast()) + "]"
        let paths = try JSONDecoder().decode([String].self, from: Data(args.utf8))
        let data = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        let meta = try JSONSerialization.jsonObject(with: data)
        if method == "metadata_json" { return try PluginRuntimeScript.encodeJSON(["meta": meta]) }
        return try PluginRuntimeScript.encodeJSON(["metadata": meta, "handles": ["app_event": true], "has_settings": false])
    }
    return nil
}

final class PluginArchiveHostTests: HostLifecycleTestCase {
    private func archiveSource(_ fixture: MaintenanceTestFixture, name: String = "input.elyx",
                               id: String = "7_archive", version: String = "1.0") throws -> URL {
        let url = fixture.root.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: ["id": id, "name": "Owned archive", "version": version]).write(to: url)
        return url
    }

    private func engine() -> MaintenanceTestEngine {
        MaintenanceTestEngine(onScript: { _, source in try archiveFixtureReply(source) })
    }

    func testElyxRequiresObjectDecodesToNativeSlotsAndPersists() throws {
        let plugin = try PluginRuntimeScript.metadata("""
        {"ok":true,"meta":{"id":"_archive","name":"Owned","requires":{
          "99":{"min_version":"2.1","url":"https://example.invalid/metadata-only.eaf"},
          "_lib":{"min_version":null,"url":null}},"permissions_declared":true}}
        """, format: .eaf)
        XCTAssertEqual(plugin.fileFormat, .eaf)
        XCTAssertEqual(plugin.requires["99"], ["2.1", "https://example.invalid/metadata-only.eaf"])
        XCTAssertEqual(plugin.requires["_lib"], [nil, nil])
        let persisted = try JSONDecoder().decode(Plugin.self, from: JSONEncoder().encode(plugin))
        XCTAssertEqual(persisted, plugin)
        let legacy = try JSONDecoder().decode(Plugin.self, from: Data("{\"id\":\"_archive\",\"path\":\"/plugins/input.eaf\"}".utf8))
        XCTAssertEqual(legacy.fileFormat, .eaf)
        XCTAssertThrowsError(try PluginRuntimeScript.metadata("{\"id\":\"_archive\"}"))
        XCTAssertThrowsError(try PluginRuntimeScript.metadata("{\"id\":\"_archive\",\"requires\":{\"ab\":{\"min_version\":false}}}", format: .elyx))
    }

    func testIDValidationIsFormatSpecificWithoutRenaming() throws {
        for id in ["12", "_p", "__", "os", String(repeating: "a", count: 32)] {
            XCTAssertTrue(Plugin.isValidID(id, format: .elyx))
            XCTAssertEqual(try PluginRuntimeScript.metadata("{\"id\":\"\(id)\"}", format: .elyx).id, id)
            XCTAssertNoThrow(try PluginServiceStorage.validatePluginId(id))
        }
        XCTAssertFalse(Plugin.isValidID("12"))
        XCTAssertTrue(Plugin.isValidID("a-b", format: .source))
        for id in ["a", "a-b", "a.b", "../a", "éé", String(repeating: "a", count: 33)] {
            XCTAssertFalse(Plugin.isValidID(id, format: .elyx))
        }
        XCTAssertThrowsError(try PluginRuntimeScript.metadata("{\"id\":\"exteralessMetadataInspector\"}", format: .elyx)) { error in
            XCTAssertTrue(String(describing: error).contains("reserved"))
        }
    }

    func testArchiveReloadRefreshesMetadataAndPreservesNativeInstallationState() throws {
        let installed = Plugin(id: "_archive", version: "1.0", path: "/plugins/owned.eaf", fileFormat: .eaf, enabled: false)
        let loaded = try PluginRuntimeScript.applyLoadResult("""
        {"metadata":{"id":"_archive","name":"Changed","version":"2.0","requires":{"ab":{"min_version":null,"url":null}}},
         "handles":{"app_event":true},"has_settings":true}
        """, to: installed)
        XCTAssertEqual(loaded.version, "2.0")
        XCTAssertEqual(loaded.requires["ab"], [nil, nil])
        XCTAssertEqual(loaded.path, installed.path)
        XCTAssertEqual(loaded.fileFormat, .eaf)
        XCTAssertFalse(loaded.enabled)
        XCTAssertTrue(loaded.loaded)
    }

    func testInstallEnableReloadAndUninstallKeepEafAndOneProcessRuntime() async throws {
        let fixture = try fixture(engine: engine())
        let host = fixture.host
        try await host.start(safeMode: true)
        let source = try archiveSource(fixture, name: "input.EAF", id: "_archive")
        var metadata = try await host.readPluginMetadata(sourceURL: source)
        metadata.enabled = false
        let installed = try await host.installPlugin(sourceURL: source, metadata: metadata)
        let path = try XCTUnwrap(installed.path)
        XCTAssertEqual(installed.fileFormat, .eaf)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "eaf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), try Data(contentsOf: source))
        XCTAssertFalse(installed.loaded)
        XCTAssertEqual(fixture.engine.counts.live, 0) // inspectors are already destroyed
        let inspections = fixture.engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.metadata_json(") }.count
        XCTAssertEqual(inspections, 2) // picker preview plus exact native-staged bytes
        try await host.setPluginEnabled(id: installed.id, true)
        try await host.reloadPlugin(id: installed.id)
        XCTAssertTrue(host.pluginList().first?.loaded == true)
        XCTAssertEqual(fixture.engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.metadata_json(") }.count, inspections)
        XCTAssertEqual(fixture.engine.counts.initialized, 1)
        XCTAssertEqual(fixture.engine.counts.finalized, 0)
        XCTAssertTrue(fixture.engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.load_json(") }.allSatisfy { $0.source.contains(".eaf") })
        let saved = try PluginStore(directory: fixture.root).loadPlugins()
        XCTAssertEqual(saved.first?.fileFormat, .eaf)
        let storage = PluginServiceStorage(rootDirectory: fixture.root)
        let cache = try storage.cacheDirectory(pluginId: installed.id)
        let archiveCache = cache.appendingPathComponent("elyx/" + String(repeating: "a", count: 64) + "/"
            + String(repeating: "b", count: 64) + "-" + String(repeating: "c", count: 32), isDirectory: true)
        try FileManager.default.createDirectory(at: archiveCache, withIntermediateDirectories: true)
        let unrelated = cache.appendingPathComponent("keep.txt")
        try Data("user cache".utf8).write(to: unrelated)
        try await host.uninstallPlugin(id: installed.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("elyx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(host.pluginList().isEmpty)
        XCTAssertEqual(fixture.engine.counts.live, 0)
    }

    func testFormatReplacementRemovesPriorNativeFileAndKeepsArchiveBytes() async throws {
        let fixture = try fixture(engine: engine())
        try await fixture.host.start(safeMode: true)
        let first = try archiveSource(fixture, id: "archiveProbe")
        let old = try await fixture.host.installPlugin(sourceURL: first, metadata: Plugin(id: "archiveProbe", enabled: false))
        let next = try archiveSource(fixture, name: "replacement.eaf", id: old.id, version: "2.0")
        let fresh = try await fixture.host.installPlugin(sourceURL: next, metadata: Plugin(id: old.id, enabled: false))
        XCTAssertEqual(fresh.fileFormat, .eaf)
        XCTAssertEqual(fresh.version, "2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(old.path)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(fresh.path))), try Data(contentsOf: next))
        let source = try archiveSource(fixture, name: "source.plugin", id: old.id)
        let plain = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: old.id, enabled: false))
        XCTAssertEqual(plain.fileFormat, .source)
        XCTAssertTrue(try XCTUnwrap(plain.path).hasSuffix(".plugin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fresh.path)))
    }

    func testCaseDistinctArchiveIDsHaveDifferentNativePaths() async throws {
        let fixture = try fixture(engine: engine())
        try await fixture.host.start(safeMode: true)
        var paths: [String] = []
        for (name, id) in [("upper.elyx", "Case"), ("lower.elyx", "case")] {
            let source = try archiveSource(fixture, name: name, id: id)
            let installed = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: id, enabled: false))
            paths.append(try XCTUnwrap(installed.path).lowercased())
        }
        XCTAssertNotEqual(paths[0], paths[1])
        XCTAssertEqual(Set(fixture.host.pluginList().map(\.id)), ["Case", "case"])
    }

    func testChangedStagedIdentityCannotRetireCurrentOwner() async throws {
        let fixture = try fixture(engine: engine())
        try await fixture.host.start(safeMode: true)
        let source = try archiveSource(fixture)
        let old = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: "7_archive"))
        let owner = try XCTUnwrap(fixture.host.callbackOwner(id: old.id))
        let bad = try archiveSource(fixture, name: "changed.elyx", id: "otherID")
        do {
            _ = try await fixture.host.installPlugin(sourceURL: bad, metadata: Plugin(id: old.id))
            XCTFail("staged archive changed its ID")
        } catch PluginHostError.invalidPlugin { }
        XCTAssertEqual(fixture.host.callbackOwner(id: old.id), owner)
        XCTAssertEqual(fixture.host.pluginList().first?.path, old.path)
        XCTAssertTrue(fixture.host.pluginList().first?.loaded == true)
    }

    func testUninstallReservationCannotPurgeReplacementArchiveResources() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        let firstUnload = MaintenanceTestFlag()
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source == "_exteraless_runtime.unload()", firstUnload.value {
                firstUnload.set(false)
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return try archiveFixtureReply(source)
        })
        let fixture = try fixture(engine: engine)
        try await fixture.host.start(safeMode: true)
        let source = try archiveSource(fixture)
        let old = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: "7_archive"))
        let oldOwner = try XCTUnwrap(fixture.host.callbackOwner(id: old.id))
        let uninstall = Task { try await fixture.host.uninstallPlugin(id: old.id) }
        _ = try await maintenanceTestWait(entered)
        do {
            _ = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: old.id))
            XCTFail("replacement must wait until archive cleanup has completed")
        } catch PluginHostError.runtimeFailure { }
        gate.signal()
        try await uninstall.value
        let fresh = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: old.id))
        let cache = try PluginServiceStorage(rootDirectory: fixture.root).cacheDirectory(pluginId: old.id)
        let marker = cache.appendingPathComponent("elyx/replacement-owner/replacement-digest/keep.txt")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: marker)
        do {
            try await fixture.host.invokeCallback(id: old.id, handle: 1, method: "run", expectedOwner: oldOwner)
            XCTFail("old owner cannot enter replacement cleanup")
        } catch PluginHostError.superseded { }
        XCTAssertTrue(fresh.loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOversizedArchiveCopyIsBoundedBeforeInspectorEntry() async throws {
        let fixture = try fixture(engine: engine())
        try await fixture.host.start(safeMode: true)
        let source = fixture.root.appendingPathComponent("large.elyx")
        try Data().write(to: source)
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: 32 * 1024 * 1024 + 1)
        try file.close()
        do {
            _ = try await fixture.host.installPlugin(sourceURL: source, metadata: Plugin(id: "7_archive"))
            XCTFail("native copy must enforce the compressed size budget")
        } catch PluginHostError.invalidPlugin(let reason) {
            XCTAssertTrue(reason.contains("32 MiB"))
        }
        XCTAssertEqual(fixture.engine.counts.created, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.host.configuration.runtime.pluginRootDirectory)
        XCTAssertTrue(files.isEmpty)
    }

    #if canImport(Darwin) || canImport(Glibc)
    func testUninstallPurgeCapturesBeforeItsUnloadingAwait() async throws {
        let published = MaintenanceTestFlag(false)
        let markers = Recorder<URL>()
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source == "_exteraless_runtime.unload()", !published.value,
               let marker = markers.values.first {
                published.set(true)
                try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("later generation".utf8).write(to: marker)
            }
            return try archiveFixtureReply(source)
        })
        let fixture = try fixture(engine: engine)
        try await fixture.host.start(safeMode: true)
        let input = try archiveSource(fixture)
        _ = try await fixture.host.installPlugin(sourceURL: input, metadata: Plugin(id: "7_archive"))
        let cache = try PluginServiceStorage(rootDirectory: fixture.root).cacheDirectory(pluginId: "7_archive")
        let owner = cache.appendingPathComponent("elyx/" + String(repeating: "a", count: 64))
        let old = owner.appendingPathComponent(String(repeating: "b", count: 64) + "-" + String(repeating: "c", count: 32))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: old.appendingPathComponent("old.txt"))
        let marker = owner.appendingPathComponent(String(repeating: "d", count: 64) + "-" + String(repeating: "e", count: 32) + "/keep.txt")
        markers.append(marker)
        try await fixture.host.uninstallPlugin(id: "7_archive")
        XCTAssertTrue(published.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("later generation".utf8))
    }
    #endif

    func testArchiveBootstrapKeepsNeighbourFilesOutOfInspectorAndOwnerImports() {
        let config = PythonRuntimeConfiguration(compatibilityDirectories: ["/python", "/python/sdk", "/python/vendor", "/plugins"],
                                                pluginRootDirectory: "/plugins")
        XCTAssertFalse(config.metadataBootstrapScript().contains("\"/plugins\""))
        let script = config.bootstrapScript(interpreterPluginId: "12", fileFormat: .elyx)
        XCTAssertTrue(script.contains("plugin_format=\"elyx\""))
        let imports = script.components(separatedBy: "\n").first { $0.hasPrefix("sys.path[:0]") }
        XCTAssertFalse(imports?.contains("\"/plugins\"") ?? true)
    }

    #if !os(Windows)
    func testNativeArchivePurgeRejectsSymlinkedParent() throws {
        let fixture = try fixture(engine: engine())
        let storage = PluginServiceStorage(rootDirectory: fixture.root)
        let cache = try storage.cacheDirectory(pluginId: "_archive")
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("elyx"), withDestinationURL: outside)
        XCTAssertThrowsError(try storage.purgeArchiveCache(pluginId: "_archive"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
    #endif
}
