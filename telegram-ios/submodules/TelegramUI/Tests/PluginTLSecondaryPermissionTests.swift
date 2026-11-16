import Foundation
import PluginHost
import TelegramCore
import XCTest
@testable import TelegramUI

private final class SecondaryTLBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

private final class SecondaryTLEngine: CPythonEngine, @unchecked Sendable {
    private let state = SecondaryTLBox<(Int64, [Int64: Thread])>((0, [:]))
    var apiVersion: String { "secondary-permission-canned" }
    var isProcessInitialized: Bool { true }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {}
    func finalizeProcess() throws {}
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        state.with { $0.0 += 1; $0.1[$0.0] = Thread.current; return InterpRef(raw: $0.0) }
    }
    func destroyInterpreter(_ reference: InterpRef) throws { _ = state.with { $0.1.removeValue(forKey: reference.raw) } }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        guard state.with({ $0.1[reference.raw] === Thread.current }) else { throw BridgeFailure.invalidHandle("Fixture left captured worker") }
        if source.hasPrefix("_exteraless_runtime.load_json(") {
            return "{\"metadata\":{\"id\":\"secondary\"},\"handles\":{\"app_event\":true},\"has_settings\":false}"
        }
        return "null"
    }
}

/// Actual sendMedia/editMedia/album dispatch, captured tickets, scheduled native
/// starts, the real preparation reader, and completion/release pressure. No
/// Account/Network or linked Python is created. Every wait is <= 2 seconds.
final class PluginTLSecondaryPermissionTests: XCTestCase {
    private struct State {
        var work: [@MainActor @Sendable () -> Void] = []
        var callbacks: [@Sendable () -> Bool] = []
        var callbackAttempts = 0
        var callbackAllowed = true
        var releaseAttempts = 0
        var releaseAllowed = true
        var released: [Int64] = []
        var accountLookups = 0
    }
    private struct Fixture: Sendable {
        let host: PluginHost
        let provider: PluginTLBridgeExtension
        let state: SecondaryTLBox<State>
        let root: URL
        let storage: PluginServiceStorage
        let own: URL
        let external: URL
        let owner: PluginHost.CallbackOwner
    }

    private func fixture(files: Bool) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tl-secondary-\(UUID().uuidString)")
        let storage = PluginServiceStorage(rootDirectory: root)
        let own = try storage.filesDirectory(pluginId: "secondary").appendingPathComponent("own.bin")
        let external = root.appendingPathComponent("external.bin")
        try Data([1, 2, 3, 4]).write(to: own)
        try Data([5, 6, 7, 8]).write(to: external)
        let host = try PluginHost(engine: SecondaryTLEngine(), configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 2), storageDirectory: root, stopTimeout: 1))
        let state = SecondaryTLBox(State())
        let provider = PluginTLBridgeExtension(storage: storage, hasPermission: { host.permissions.has($0, $1) },
            captureOwner: { host.callbackOwner(id: $0) }, callback: { _, _, _, _, predicate in
                state.with { value in
                    value.callbackAttempts += 1
                    guard value.callbackAllowed else { return false }
                    value.callbacks.append(predicate)
                    return true
                }
            }, release: { _, handles in
                state.with { value in
                    value.releaseAttempts += 1
                    guard value.releaseAllowed else { return false }
                    value.released += handles
                    return true
                }
            }, accountLookup: { _ in 7 }, resolveAccount: { _ in
                state.with { $0.accountLookups += 1 }; return nil
            }, diagnostic: { _ in }, scheduleStart: { work in state.with { $0.work.append(work) } },
            permissionAdmission: { host.permissions.futurePredicate($0, requiring: $1) })
        host.bridge.extensionProvider = provider
        addTeardownBlock {
            state.with { $0.callbackAllowed = true; $0.releaseAllowed = true; $0.work.removeAll() }
            host.bridge.extensionProvider = nil
            provider.releaseInstances(pluginId: "secondary")
            await host.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await host.start(safeMode: true)
        let source = root.appendingPathComponent("secondary.plugin")
        try Data("# canned native fixture; no Python execution\n".utf8).write(to: source)
        _ = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "secondary"))
        try host.setGrantedPermissions(id: "secondary", permissions: files ? [.messagesSend, .files] : [.messagesSend])
        return Fixture(host: host, provider: provider, state: state, root: root, storage: storage,
            own: own, external: external, owner: try XCTUnwrap(host.callbackOwner(id: "secondary")))
    }

    private func model(_ fixture: Fixture, variant: String, external: Bool) -> [String: Any] {
        var value: [String: Any] = ["schemaVersion": 1, "account": 0, "peer": ["type": "user", "id": 1], "timeoutMs": 5000]
        if variant == "album" {
            value["kind"] = "album"
            value["items"] = [["kind": "document", "path": fixture.own.path],
                              ["kind": "document", "path": (external ? fixture.external : fixture.own).path]]
        } else {
            value["kind"] = "document"
            value["path"] = (external ? fixture.external : fixture.own).path
        }
        if variant == "edit" { value["message"] = ["id": 1, "namespace": 0] }
        return value
    }

    private func dispatch(_ f: Fixture, variant: String, external: Bool, handle: Int64 = 17) throws -> [String: Any] {
        let request: [String: Any] = ["op": "call", "fqcn": "exteraless.ios.Runtime", "ownerToken": f.owner.wireToken,
            "member": variant == "edit" ? "editMedia" : "sendMedia", "args": [model(f, variant: variant, external: external), ["__handle__": handle]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply = try XCTUnwrap(f.provider.dispatch(requestJSON: json, pluginId: "secondary"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func wait(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(predicate(), "Bounded native continuation did not drain")
    }

    func testAllExternalMediaShapesDenyBeforeQueueWithoutFiles() async throws {
        let f = try await fixture(files: false)
        for variant in ["document", "edit", "album"] {
            XCTAssertEqual(try dispatch(f, variant: variant, external: true)["ok"] as? Bool, false, variant)
        }
        XCTAssertEqual(f.provider.registry.count, 0)
        XCTAssertTrue(f.state.with { $0.work.isEmpty && $0.callbacks.isEmpty && $0.released.isEmpty })
        try f.host.setGrantedPermissions(id: "secondary", permissions: [.messagesSend, .files])
        XCTAssertTrue(f.state.with { $0.work.isEmpty }, "Later grants must not publish a previously denied request")
    }

    func testHeldExternalMediaCannotReadStartOrDeliverAfterFilesRegrant() async throws {
        for variant in ["document", "edit", "album"] {
            let f = try await fixture(files: true)
            XCTAssertEqual(try dispatch(f, variant: variant, external: true)["ok"] as? Bool, true)
            let ticket = try XCTUnwrap(f.provider.registry.runningTickets.first)
            let cancelled = f.provider.nativeCancellation(ticket)
            XCTAssertFalse(cancelled())
            f.state.with { $0.releaseAllowed = false }
            try f.host.setGrantedPermissions(id: "secondary", permissions: [.messagesSend])
            try f.host.setGrantedPermissions(id: "secondary", permissions: [.messagesSend, .files])
            XCTAssertFalse(ticket.permitsExecution)
            XCTAssertTrue(cancelled())
            let source = try PluginResourcePath(path: f.external.path, allowedRoots: [f.storage.filesDirectory(pluginId: "secondary"), f.storage.cacheDirectory(pluginId: "secondary")])
            try FileManager.default.removeItem(at: f.external)
            do {
                _ = try await PluginTLMediaPreparation().prepare(model: PluginTLMediaModel(model(f, variant: "document", external: true)),
                    source: source, cacheDirectory: f.storage.cacheDirectory(pluginId: "secondary"),
                    isActive: { !cancelled() }, bindCancellation: { _ in })
                XCTFail("Revoked preparation read an external file")
            } catch is CancellationError {} // Must reject before even inspecting the now-absent file.
            let pending = f.state.with { value -> [@MainActor @Sendable () -> Void] in
                let work = value.work; value.work.removeAll(); return work
            }
            for job in pending { await job() } // The real startMedia/startAlbum/startEditMedia consumer.
            try await wait { f.state.with { $0.releaseAttempts > 0 } }
            XCTAssertEqual(f.state.with { $0.accountLookups }, 0)
            XCTAssertTrue(f.state.with { $0.callbacks.isEmpty && $0.released.isEmpty })
            XCTAssertTrue(f.provider.registry.completionPending(ticket), "False release must retain its original ticket")
            f.state.with { $0.releaseAllowed = true }
            try await wait { f.provider.registry.count == 0 }
            XCTAssertEqual(f.state.with { $0.released }, [17])
        }
    }

    func testOwnRootMediaKeepsNarrowPermissionAndActualReaderCompletion() async throws {
        let f = try await fixture(files: true)
        XCTAssertEqual(try dispatch(f, variant: "document", external: false)["ok"] as? Bool, true)
        let ticket = try XCTUnwrap(f.provider.registry.runningTickets.first)
        let cancelled = f.provider.nativeCancellation(ticket)
        try f.host.setGrantedPermissions(id: "secondary", permissions: [.messagesSend])
        XCTAssertTrue(ticket.permitsExecution)
        let resource = try PluginResourcePath(path: f.own.path, allowedRoots: [f.storage.filesDirectory(pluginId: "secondary"), f.storage.cacheDirectory(pluginId: "secondary")])
        let prepared = try await PluginTLMediaPreparation().prepare(model: PluginTLMediaModel(model(f, variant: "document", external: false)),
            source: resource, cacheDirectory: f.storage.cacheDirectory(pluginId: "secondary"),
            isActive: { !cancelled() }, bindCancellation: { _ in })
        XCTAssertEqual(prepared.data, Data([1, 2, 3, 4]))
        f.state.with { $0.callbackAllowed = false }
        f.provider.finish(ticket, response: .object(["status": .string("fixture")]))
        try await wait { f.state.with { $0.callbackAttempts > 0 } }
        XCTAssertTrue(f.provider.registry.completionPending(ticket))
        XCTAssertTrue(f.state.with { $0.released.isEmpty })
        f.state.with { $0.callbackAllowed = true }
        try await wait { f.provider.registry.count == 0 }
        XCTAssertEqual(f.state.with { $0.released }, [17])
        XCTAssertTrue(try XCTUnwrap(f.state.with { $0.callbacks.first })())
    }
}
