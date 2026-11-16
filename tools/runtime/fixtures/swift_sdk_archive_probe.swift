import Foundation

private struct SDKArchiveFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

private func archiveCheck(_ condition: Bool, _ message: String) throws {
    if !condition { throw SDKArchiveFailure(description: message) }
}

private struct SDKArchiveReport: Encodable {
    let probe = "swift-sdk-owned-archives"
    let boundary = "Real Host/C/CPython Elyx SDK; local generated ZIP/wheel fixtures; no UIKit/network"
    var ok = false
    var phase = "initializing"
    var metadataZeroEntry = false
    var formatIds = false
    var stagedMetadataAndTrust = false
    var settings = false
    var reload = false
    var replacementModuleAndWheel = false
    var ownerCacheCleanup = false
    var requiresRejected = false
    var nativeBridge = false
    var cleanup = false
    var initializations = 0
    var finalizations = 0
    var snapshots: [String: PluginJSONValue] = [:]
    var traces: [SDKTLTrace] = []
    var unexpectedEffects: [String] = []
    var error: String?

    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Fourth child in the existing executable. The Host and recording forwarder
/// are reused as-is; no runtime method, backend or archive loader is replaced.
enum SDKArchiveNativeProbe {
    static func run(_ arguments: [String]) async -> Int32 {
        let reportURL = URL(fileURLWithPath: arguments[1])
        let work = URL(fileURLWithPath: arguments[7], isDirectory: true)
        let inputs = URL(fileURLWithPath: arguments[6], isDirectory: true)
        let services = NativeSDKFixtureServices(root: work.appendingPathComponent("native-storage", isDirectory: true))
        let engine = SDKTLObservedEngine(helper: arguments[8])
        var report = SDKArchiveReport()
        var host: PluginHost?
        var binding: NativeBridgeBinding?
        do {
            try report.write(reportURL)
            let plugins = try services.serviceStorage.pluginsDirectory()
            let configuration = PythonRuntimeConfiguration(programName: "exteraless-sdk-archive-probe", frameworkHome: arguments[2],
                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk", arguments[5] + "/vendor"],
                pluginRootDirectory: plugins.path, writeBytecode: false, installSignalHandlers: false,
                manifestPath: work.appendingPathComponent("manifest.json").path,
                executablePath: URL(fileURLWithPath: arguments[0]).standardizedFileURL.path)
            let current = try PluginHost(engine: engine, configuration: .init(runtime: configuration,
                interpreters: .init(maxInterpreters: 4, callTimeout: 5), storageDirectory: plugins),
                services: .init(messages: services, settings: services, ui: services))
            host = current
            let nativeBinding = NativeBridgeBinding(services: current.bridge)
            binding = nativeBinding
            try nativeBinding.install()
            try await current.start(safeMode: true)
            try archiveCheck(engine.apiVersion.hasPrefix("3.12.") && engine.snapshot.initializations == 1,
                             "archive child did not initialize the real CPython 3.12 once")

            func stored(_ id: String, _ key: String) throws -> PluginJSONValue {
                try services.serviceStorage.getSetting(pluginId: id, key: key, defaultValue: .null)
            }
            func loaded(_ id: String) throws -> PluginHost.CallbackOwner {
                guard let plugin = current.pluginList().first(where: { $0.id == id }), plugin.loaded,
                      let owner = current.callbackOwner(id: id) else {
                    throw SDKArchiveFailure(description: "real archive load failed: \(current.pluginList().first(where: { $0.id == id })?.loadError ?? id)")
                }
                return owner
            }
            func snapshot(_ owner: PluginHost.CallbackOwner, _ value: String) async throws -> [String: PluginJSONValue] {
                let handle = try engine.checks(owner.pluginId)
                let json = try await current.invokeCallbackResult(id: owner.pluginId, handle: handle, method: "snapshot",
                    argumentsJSON: PluginRuntimeScript.encodeJSON([value]), expectedOwner: owner)
                guard case let .object(result) = try NativeServiceWire.decode(json) else {
                    throw SDKArchiveFailure(description: "archive observer did not return its actual SDK state")
                }
                try archiveCheck(result["pluginId"] == .string(owner.pluginId) && result["ownerToken"] == .string(owner.wireToken),
                                 "archive observer/Host C epoch mismatch")
                return result
            }
            func path(_ record: [String: PluginJSONValue], _ key: String) throws -> String {
                guard case let .string(value)? = record[key] else { throw SDKArchiveFailure(description: "missing archive path: " + key) }
                return value
            }
            func inspectInstall(_ name: String, id: String, format: PluginFileFormat) async throws -> Plugin {
                let source = inputs.appendingPathComponent(name)
                var metadata = try await current.readPluginMetadata(sourceURL: source)
                try archiveCheck(metadata.id == id && metadata.fileFormat == format, "format-specific archive ID was changed")
                metadata.enabled = false
                // This is explicit native test consent. Host re-inspects its
                // staged bytes and commits this selection before owner startup.
                let installed = try await current.installPlugin(sourceURL: source, metadata: metadata,
                    selection: PluginPermissionRecord(level: .isolated, grants: []))
                guard let filename = installed.path else { throw SDKArchiveFailure(description: "Host omitted installed archive path") }
                try archiveCheck(!installed.loaded && !installed.enabled && installed.fileFormat == format,
                                 "disabled archive install executed an entry point")
                try archiveCheck(try Data(contentsOf: URL(fileURLWithPath: filename)) == Data(contentsOf: source),
                                 "Host installation did not retain exact archive bytes")
                let consent = current.permissionSnapshot(id: id)
                try archiveCheck(consent.record == PluginPermissionRecord(level: .isolated, grants: [])
                                 && consent.effective == [.ui], "actual native install consent differs")
                return installed
            }

            report.phase = "inspect-install-enable"
            let first = try await inspectInstall("owned.elyx", id: "7_archive", format: .elyx)
            try archiveCheck(try stored(first.id, "loads") == .null, "metadata or disabled install executed the plugin")
            let inspectors = engine.snapshot.records
            try archiveCheck(inspectors.count == 2 && inspectors.allSatisfy {
                $0.destroyed && $0.checks == nil && $0.observation?.sdkSource == nil && $0.observation?.pluginSource == nil
            }, "preview/staged metadata inspectors executed SDK entry code or leaked")
            report.metadataZeroEntry = true
            report.stagedMetadataAndTrust = true
            try await current.setPluginEnabled(id: first.id, true)
            let firstOwner = try loaded(first.id)
            let firstState = try await snapshot(firstOwner, "first")
            report.snapshots["first"] = .object(firstState)
            let rowsJSON = try await current.settingsJSON(id: first.id, account: 2, expectedOwner: firstOwner)
            let rows = try JSONDecoder().decode([[String: PluginJSONValue]].self, from: Data(rowsJSON.utf8))
            try archiveCheck(rows.map { $0["type"] } == [.string("header"), .string("switch")], "actual archive settings serializer did not run")
            try await current.updateSetting(id: first.id, key: "toggle", valueJSON: "false", expectedOwner: firstOwner, account: 2)
            try archiveCheck(try stored(first.id, "toggle") == .bool(false), "public Host settings update was lost")
            report.settings = true

            report.phase = "reload-and-replacement"
            try await current.reloadPlugin(id: first.id)
            let reloadedOwner = try loaded(first.id)
            let reloaded = try await snapshot(reloadedOwner, "first")
            try archiveCheck(reloadedOwner != firstOwner && reloadedOwner.wireToken != firstOwner.wireToken,
                             "reload reused its interpreter/module owner")
            try archiveCheck(try stored(first.id, "loads") == .integer(2) && stored(first.id, "unloads") == .integer(1),
                             "Host reload did not execute exactly one unload/load")
            try archiveCheck(!FileManager.default.fileExists(atPath: try path(firstState, "extractDir")), "reload retained old owner extraction")
            report.snapshots["reload"] = .object(reloaded)
            report.reload = true
            var replacement = try await current.readPluginMetadata(sourceURL: inputs.appendingPathComponent("owned-next.elyx"))
            replacement.enabled = true
            let replaced = try await current.installPlugin(sourceURL: inputs.appendingPathComponent("owned-next.elyx"), metadata: replacement,
                selection: PluginPermissionRecord(level: .isolated, grants: []))
            let replacementOwner = try loaded(first.id)
            let next = try await snapshot(replacementOwner, "later")
            try archiveCheck(replaced.id == first.id && replaced.path == first.path && replaced.version == "2.0",
                             "same-name native replacement did not publish inspected metadata")
            try archiveCheck(replacementOwner != reloadedOwner && next["archiveDigest"] != reloaded["archiveDigest"]
                             && next["moduleSource"] != reloaded["moduleSource"] && next["wheelSource"] != reloaded["wheelSource"],
                             "changed archive/module/same-name wheel used stale code")
            try archiveCheck(!FileManager.default.fileExists(atPath: try path(reloaded, "extractDir")), "replacement retained the retired extraction")
            try archiveCheck(try stored(first.id, "loads") == .integer(3) && stored(first.id, "unloads") == .integer(2)
                             && stored(first.id, "toggle") == .bool(false), "replacement lifecycle/settings were not preserved")
            report.snapshots["replacement"] = .object(next)
            report.replacementModuleAndWheel = true

            report.phase = "second-format-and-scoped-cleanup"
            let second = try await inspectInstall("literal.eaf", id: "_archive", format: .eaf)
            try await current.setPluginEnabled(id: second.id, true)
            let secondOwner = try loaded(second.id)
            let secondState = try await snapshot(secondOwner, "first")
            report.snapshots["literal"] = .object(secondState)
            report.formatIds = first.id == "7_archive" && second.id == "_archive"
            let cache = try services.serviceStorage.cacheDirectory(pluginId: second.id)
            let unrelated = cache.appendingPathComponent("keep-unrelated-cache.txt")
            try Data("owned unrelated cache".utf8).write(to: unrelated)
            try await current.uninstallPlugin(id: first.id)
            try archiveCheck(!FileManager.default.fileExists(atPath: try path(next, "extractDir"))
                             && FileManager.default.fileExists(atPath: try path(secondState, "extractDir")),
                             "uninstall cleanup crossed the other actual plugin owner")
            _ = try await snapshot(secondOwner, "first")
            try await current.uninstallPlugin(id: second.id)
            try archiveCheck(!FileManager.default.fileExists(atPath: try path(secondState, "extractDir"))
                             && FileManager.default.fileExists(atPath: unrelated.path), "archive cleanup removed unrelated cache or retained extraction")
            try archiveCheck(current.permissionSnapshot(id: second.id).record == nil, "uninstall retained native trust selection")
            report.ownerCacheCleanup = true

            report.phase = "requires-rejection"
            let neighbor = plugins.appendingPathComponent("neighbour.py")
            try Data("raise RuntimeError('owned neighbour must not execute')\n".utf8).write(to: neighbor)
            let rejected = try await inspectInstall("requires.elyx", id: first.id, format: .elyx)
            try await current.setPluginEnabled(id: rejected.id, true)
            guard let failed = current.pluginList().first(where: { $0.id == rejected.id }) else {
                throw SDKArchiveFailure(description: "requires fixture disappeared without a native result")
            }
            try archiveCheck(!failed.loaded && failed.loadError?.contains("cross-owner module provider") == true
                             && current.callbackOwner(id: failed.id) == nil, "archive requires was not rejected before entry")
            try archiveCheck(try stored(failed.id, "loads") == .integer(3), "requires rejection executed owned or neighbor entry code")
            report.requiresRejected = true
            try await current.uninstallPlugin(id: failed.id)
            try FileManager.default.removeItem(at: neighbor)
            await current.stop()
            nativeBinding.uninstall()
            let trace = engine.snapshot
            report.initializations = trace.initializations
            report.finalizations = trace.finalizations
            report.traces = trace.records
            report.unexpectedEffects = services.unexpectedEffects
            let owners = trace.records.filter { $0.observation?.pluginId != nil }
            try archiveCheck(trace.initializations == 1 && trace.finalizations == 1 && trace.records.count == 13 && owners.count == 5,
                             "archive child changed its single process/Host or inspector/owner lifetime")
            try archiveCheck(owners.allSatisfy { $0.observation?.bridgeBuiltin == true && $0.observation?.backendInstalled == true
                && $0.observation?.mockCalls == 0 && $0.observation?.legacyServiceCount == 0 }, "archive child bypassed the real C backend")
            report.nativeBridge = true
            try archiveCheck(trace.records.allSatisfy { $0.destroyed && $0.ownGIL && $0.observation?.handleCount == 0
                && $0.observation?.callbackLeases == 0 && $0.observation?.loadedPlugins.isEmpty == true }
                && current.pluginList().isEmpty && services.unexpectedEffects.isEmpty, "archive child leaked native/SDK state or performed an external effect")
            report.cleanup = true
            report.phase = "complete"
            report.ok = true
            try report.write(reportURL)
            print("EXTERALESS_SWIFT_SDK_ARCHIVE_PROBE_OK")
            return 0
        } catch {
            if let host { await host.stop() }
            binding?.uninstall()
            let trace = engine.snapshot
            report.initializations = trace.initializations
            report.finalizations = trace.finalizations
            report.traces = trace.records
            report.unexpectedEffects = services.unexpectedEffects
            report.error = String(describing: error)
            try? report.write(reportURL)
            return 1
        }
    }
}
