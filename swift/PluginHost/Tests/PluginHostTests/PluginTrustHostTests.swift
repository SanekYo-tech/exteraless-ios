import Foundation
import XCTest
@testable import PluginHost

private final class TrustRetirementProvider: PluginBridgeExtension, @unchecked Sendable {
    let pool = NativeServiceLeasePool<PluginHost.CallbackOwner>()
    let operations = NativeServiceOperations<PluginHost.CallbackOwner>()
    let released = Recorder<Int64>()
    let cancelled = Recorder<String>()
    let changes = Recorder<String>()
    let dispatcher: PluginCallbackDispatcher

    init(dispatcher: PluginCallbackDispatcher) { self.dispatcher = dispatcher }
    func dispatch(requestJSON: String, pluginId: String) throws -> String? { nil }

    func make(owner: PluginHost.CallbackOwner, handle: Int64) throws -> NativeServiceCallbackLease<PluginHost.CallbackOwner> {
        let dispatcher = self.dispatcher
        let permission = dispatcher.permissionPredicate(owner.pluginId, requiring: [.files, .messagesRead])
        let released = self.released
        let retirement = NativeServiceReleaseTransport.acknowledged(dispatcher)
        return try pool.make(pluginId: owner.pluginId, owner: owner, handle: handle,
            isCurrent: { dispatcher.captureOwner($0.pluginId) == $0 && permission() },
            callback: NativeServiceCallbackTransport.callback(using: dispatcher),
            release: { _, _ in XCTFail("Use the production acknowledged FIFO release") },
            acknowledgedRelease: { owner, handles, completed in
                for handle in handles { released.append(handle) }
                retirement(owner, handles, completed)
            }, ownerWireToken: owner.wireToken)
    }

    func permissionsChanged(pluginId: String) {
        changes.append(pluginId)
        for ticket in operations.retirePermissions(pluginId: pluginId) { ticket.lease.close() }
        pool.retirePermissions(pluginId: pluginId)
    }

    func releaseInstances(pluginId: String) {
        for ticket in operations.takeAll(pluginId: pluginId) { ticket.lease.close() }
        pool.closeAll(pluginId: pluginId)
    }
}

/// Actual Host mutation/admission + production callback transport and owner FIFO;
/// the engine is native-only test data. Every gate/wait/stop is bounded below 5 s.
final class PluginTrustHostTests: XCTestCase {
    private func fixture(engine: MaintenanceTestEngine = MaintenanceTestEngine(),
                         unblock: DispatchSemaphore? = nil) throws -> (PluginHost, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trust-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("alpha.plugin")
        try Data("# data-only native fake engine fixture\n".utf8).write(to: source)
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 4), storageDirectory: root, stopTimeout: 2), unsafePermissionsMode: false)
        addTeardownBlock {
            unblock?.signal()
            await host.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return (host, root, source)
    }

    func testHostCommitsDefaultBeforeLoadAndUsesActualInstallSelection() async throws {
        let box = MaintenanceTestHostBox()
        let observed = Recorder<PluginPermissionRecord>()
        let engine = MaintenanceTestEngine(onScript: { _, script in
            if script.hasPrefix("_exteraless_runtime.load_json("), let host = box.get(),
               let record = host.permissionSnapshot(id: "alpha").record { observed.append(record) }
            let prefix = "_exteraless_runtime.metadata_json("
            if script.hasPrefix(prefix) {
                let arguments = "[" + String(script.dropFirst(prefix.count).dropLast()) + "]"
                let paths = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                if let path = paths.first, ["elyx", "eaf"].contains(URL(fileURLWithPath: path).pathExtension) {
                    // Like the archive owner's fixture: JSON data, no ZIP/Python
                    // execution, through the real staged native metadata path.
                    let staged = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                    return try PluginRuntimeScript.encodeJSON(["meta": staged])
                }
            }
            return nil
        })
        let (host, root, source) = try fixture(engine: engine)
        box.set(host)
        try await host.start(safeMode: true)
        let metadata = Plugin(id: "alpha", permissions: ["network", "native", "hooks"], permissionsDeclared: true)
        _ = try await host.installPlugin(sourceURL: source, metadata: metadata)
        XCTAssertEqual(observed.values, [PluginPermissionRecord()])
        XCTAssertEqual(host.permissionSnapshot(id: "alpha").level, .isolated)
        XCTAssertEqual(try PluginStore(directory: root).loadPermissionRecords()["alpha"], PluginPermissionRecord())
        let owner = try XCTUnwrap(host.callbackOwner(id: "alpha"))
        func request(_ member: String, arguments: [PluginJSONValue]) throws -> PluginJSONValue {
            let json = try NativeServiceWire.json(.object([
                "op": .string("call"), "fqcn": .string(BridgeServices.runtimeClassName), "member": .string(member),
                "args": .array(arguments), "ownerToken": .string(owner.wireToken)
            ]))
            return try NativeServiceWire.decode(host.bridge.dispatchJSON(json, pluginId: "alpha"))
        }
        XCTAssertEqual(try request("getTrustLevel", arguments: []), .object(["ok": .bool(true), "value": .integer(0)]))
        for name in ["setTrustLevel", "setPluginTrustLevel", "setGrantedPermissions"] {
            guard case let .object(reply) = try request(name, arguments: [.integer(2)]) else { return XCTFail("Expected a bridge envelope") }
            XCTAssertEqual(reply["ok"], .bool(false), "The Python-facing bridge must have no consent setter")
        }
        XCTAssertEqual(host.permissionSnapshot(id: "alpha").record, PluginPermissionRecord())
        let selected = PluginPermissionRecord(level: .gated, grants: [.network])
        _ = try await host.installPlugin(sourceURL: source, metadata: metadata, selection: selected)
        XCTAssertEqual(observed.values.last, selected)
        XCTAssertEqual(host.permissions.effective("alpha"), [.ui, .network])
        _ = try await host.installPlugin(sourceURL: source, metadata: metadata)
        XCTAssertEqual(host.permissionSnapshot(id: "alpha").record, selected, "Source replacement must preserve existing consent")

        let archive = root.appendingPathComponent("selected.elyx")
        let stagedMetadata: [String: Any] = [
            "id": "_archive", "name": "Staged archive", "version": "2.0",
            "permissions": ["network", "native"]
        ]
        try JSONSerialization.data(withJSONObject: stagedMetadata).write(to: archive)
        let early = Plugin(id: "_archive", version: "stale preview", permissions: ["hooks"], enabled: false)
        let installed = try await host.installPlugin(sourceURL: archive, metadata: early)
        XCTAssertEqual(installed.fileFormat, .elyx)
        XCTAssertEqual(installed.version, "2.0")
        XCTAssertEqual(installed.permissions, ["network", "native"])
        XCTAssertEqual(host.permissionSnapshot(id: installed.id).record, PluginPermissionRecord())
        let replaced = try await host.installPlugin(sourceURL: archive, metadata: early, selection: selected)
        XCTAssertEqual(replaced.version, "2.0", "Trust integration must retain post-staging archive metadata")
        XCTAssertEqual(host.permissionSnapshot(id: replaced.id).record, selected)
        XCTAssertEqual(try PluginStore(directory: root).loadPlugins().first { $0.id == "_archive" }?.permissions, ["network", "native"])
    }

    func testHostLoweringRetiresNativeSignalAndQueuedBodiesStayRevokedAfterRegrant() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(9000,") {
                entered.succeed(())
                guard gate.wait(timeout: .now() + 4) == .success else { throw BridgeFailure.unavailable("Bounded trust test gate expired") }
            }
            return nil
        })
        let (host, _, source) = try fixture(engine: engine, unblock: gate)
        try await host.start(safeMode: true)
        _ = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "alpha"))
        try host.setGrantedPermissions(id: "alpha", permissions: [.files, .messagesRead], atLevel: .gated,
            expected: host.permissionSnapshot(id: "alpha"), shouldExecute: { true })
        let dispatcher = PluginCallbackDispatcher(host: host)
        let provider = TrustRetirementProvider(dispatcher: dispatcher)
        host.bridge.extensionProvider = CompositePluginBridgeExtension([provider])
        let owner = try XCTUnwrap(dispatcher.captureOwner("alpha"))
        let blocker = Task { try await host.invokeCallback(id: "alpha", handle: 9000, method: "run", expectedOwner: owner) }
        _ = try await withDispatchTimeout(2) { try await entered.awaitValue() }
        defer { gate.signal() }
        let retained = try provider.make(owner: owner, handle: 101)
        let ticket = try provider.operations.reserve(lease: retained, accountRecordId: 7, kind: "nativeObservePeer",
            timeoutMs: nil, expired: { _ in XCTFail("Persistent fixture unexpectedly timed out") })
        let cancelled = provider.cancelled
        provider.operations.bindCancellation(ticket) { cancelled.append(ticket.id) }
        XCTAssertTrue(retained.send(argumentsJSON: "[]"))
        let terminal = try provider.make(owner: owner, handle: 102)
        XCTAssertTrue(terminal.send(argumentsJSON: "[]", terminal: true))
        try host.setPluginTrustLevel(id: "alpha", level: .isolated)
        XCTAssertEqual(provider.changes.values, ["alpha"])
        XCTAssertEqual(provider.cancelled.values, [ticket.id])
        XCTAssertEqual(provider.operations.count, 0)
        XCTAssertFalse(retained.isOpen)
        // Regrant before the worker drains: a fresh Boolean permission lookup
        // would incorrectly execute both old bodies (including the terminal one).
        try host.setGrantedPermissions(id: "alpha", permissions: [.files, .messagesRead], atLevel: .trusted,
            expected: host.permissionSnapshot(id: "alpha"), shouldExecute: { true })
        gate.signal()
        _ = try await withDispatchTimeout(2) { try await blocker.value }
        let drained = await waitUntil({ dispatcher.outstandingWorkCount == 0 && provider.pool.count == 0 }, timeout: 2)
        XCTAssertTrue(drained)
        for handle in [101, 102] {
            XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.invoke_handle_json(\(handle),") })
            XCTAssertEqual(engine.calls.filter {
                $0.source.hasPrefix("_exteraless_runtime.release_handles_json(") && $0.source.contains("[\(handle)]")
            }.count, 1)
        }
        XCTAssertEqual(provider.released.values.sorted(), [101, 102])
    }

    func testFailedHostGrantOrUninstallDoesNotPublishConsentOrRemovePlugin() async throws {
        let (host, root, source) = try fixture()
        try await host.start(safeMode: true)
        let plugin = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "alpha"))
        try host.setGrantedPermissions(id: "alpha", permissions: [.network])
        let before = host.permissionSnapshot(id: "alpha")
        let file = root.appendingPathComponent("grants.json")
        let bytes = try Data(contentsOf: file)
        defer { try? bytes.write(to: file, options: .atomic) }
        try Data("{bad consent json".utf8).write(to: file)
        XCTAssertThrowsError(try host.setPluginTrustLevel(id: "alpha", level: .isolated))
        do { try await host.uninstallPlugin(id: "alpha"); XCTFail("Bad consent persistence must fail uninstall") }
        catch {}
        XCTAssertEqual(host.permissionSnapshot(id: "alpha"), before)
        XCTAssertTrue(host.pluginList().contains { $0.id == "alpha" && $0.loaded })
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(plugin.path)))
    }

    func testMetadataPersistenceFailureCannotReturnInstalledSuccess() async throws {
        let (host, root, source) = try fixture()
        try await host.start(safeMode: true)
        // Obstruct the model file itself, independently of the consent writer.
        // No permissions or system ACLs are changed by this fixture.
        let obstruction = root.appendingPathComponent("plugins.json", isDirectory: true)
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: obstruction.appendingPathComponent("occupied"))
        do {
            _ = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "alpha"))
            XCTFail("The public install result must propagate metadata persistence failure")
        } catch {}
        XCTAssertTrue(host.pluginList().isEmpty, "Uncommitted metadata must not be published or bootstrapped")
        XCTAssertEqual(try PluginStore(directory: root).loadPermissionRecords()["alpha"], PluginPermissionRecord(),
            "The earlier consent stage remains committed and isolated; it is never rolled back to old grants")
    }
}
