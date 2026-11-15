import Foundation
import XCTest
@testable import PluginHost

final class MaintenanceTestEngine: CPythonEngine, @unchecked Sendable {
    struct Call: Sendable {
        let reference: InterpRef
        let source: String
        let threadName: String
    }
    struct Counts: Sendable {
        let initialized: Int
        let finalized: Int
        let created: Int64
        let destroyed: Int
        let live: Int
    }
    private let lock = NSLock()
    private var initializationCount = 0
    private var finalizationCount = 0
    private var nextID: Int64 = 0
    private var destructionCount = 0
    private var owners: [Int64: Thread] = [:]
    private var history: [Call] = []
    let onCreate: (@Sendable () throws -> Void)?
    let onDestroy: (@Sendable (InterpRef) throws -> Void)?
    let onScript: (@Sendable (InterpRef, String) throws -> String?)?

    init(onCreate: (@Sendable () throws -> Void)? = nil,
         onDestroy: (@Sendable (InterpRef) throws -> Void)? = nil,
         onScript: (@Sendable (InterpRef, String) throws -> String?)? = nil) {
        self.onCreate = onCreate
        self.onDestroy = onDestroy
        self.onScript = onScript
    }
    var apiVersion: String { "maintenance-fixture" }
    var isProcessInitialized: Bool { counts.initialized > counts.finalized }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        lock.lock(); initializationCount += 1; lock.unlock()
    }
    func finalizeProcess() throws { lock.lock(); finalizationCount += 1; lock.unlock() }
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        try onCreate?()
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        owners[nextID] = Thread.current
        return InterpRef(raw: nextID)
    }
    func destroyInterpreter(_ reference: InterpRef) throws {
        try checkOwner(reference)
        try onDestroy?(reference)
        lock.lock()
        owners[reference.raw] = nil
        destructionCount += 1
        lock.unlock()
    }
    private func checkOwner(_ reference: InterpRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard owners[reference.raw] === Thread.current else {
            throw PluginHostError.runtimeFailure("fixture left its owner thread")
        }
    }
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        try checkOwner(reference)
        record(Call(reference: reference, source: source, threadName: Thread.current.name ?? "unnamed"))
        if let value = try onScript?(reference, source) { return value }
        for method in ["load_json", "metadata_json"] {
            let prefix = "_exteraless_runtime.\(method)("
            if source.hasPrefix(prefix) {
                let arguments = "[" + String(source.dropFirst(prefix.count).dropLast()) + "]"
                let values = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                let id = URL(fileURLWithPath: values[0]).deletingPathExtension().lastPathComponent
                if method == "metadata_json" { return "{\"ok\":true,\"meta\":{\"id\":\"\(id)\"}}" }
                return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"app_event\":true},\"has_settings\":true}"
            }
        }
        if source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("create_settings") { return "[]" }
        return "null"
    }
    private func record(_ call: Call) { lock.lock(); history.append(call); lock.unlock() }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return history }
    var counts: Counts {
        lock.lock(); defer { lock.unlock() }
        return Counts(initialized: initializationCount, finalized: finalizationCount,
                      created: nextID, destroyed: destructionCount, live: owners.count)
    }
}

final class MaintenanceTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool
    init(_ value: Bool = true) { current = value }
    func set(_ value: Bool) { lock.lock(); current = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return current }
}

final class MaintenanceTestHostBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: PluginHost?
    func set(_ host: PluginHost) { lock.lock(); value = host; lock.unlock() }
    func get() -> PluginHost? { lock.lock(); defer { lock.unlock() }; return value }
}

func maintenanceTestWait<Value: Sendable>(_ result: OneShotResult<Value>) async throws -> Value {
    try await withDispatchTimeout(2) { try await result.awaitValue() }
}

func maintenanceTestBlock(_ gate: DispatchSemaphore) throws {
    guard gate.wait(timeout: .now() + 5) == .success else {
        throw PluginHostError.runtimeFailure("bounded fixture gate expired")
    }
}

struct MaintenanceTestFixture: Sendable {
    let host: PluginHost
    let engine: MaintenanceTestEngine
    let root: URL
    func source(_ id: String) -> URL { root.appendingPathComponent(id + ".plugin") }
}

class HostLifecycleTestCase: XCTestCase {
    func fixture(engine: MaintenanceTestEngine = MaintenanceTestEngine(),
                 callTimeout: TimeInterval = 2,
                 log: (@Sendable (String) -> Void)? = nil) throws -> MaintenanceTestFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for id in ["alpha", "beta"] {
            try Data("# data-only fake-engine fixture\n".utf8).write(to: root.appendingPathComponent(id + ".plugin"))
        }
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: callTimeout), queue: .init(dispatchTimeout: 2), storageDirectory: root),
            unsafePermissionsMode: true, log: log)
        addTeardownBlock {
            await host.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return MaintenanceTestFixture(host: host, engine: engine, root: root)
    }

    func load(_ fixture: MaintenanceTestFixture, _ id: String = "alpha", enabled: Bool = true) async throws {
        try await fixture.host.start(safeMode: true)
        let plugin = try await fixture.host.installPlugin(sourceURL: fixture.source(id), metadata: Plugin(id: id, enabled: enabled))
        XCTAssertEqual(plugin.loaded, enabled, plugin.loadError ?? "unexpected load state")
    }

    func maintenance(_ fixture: MaintenanceTestFixture, timeout: TimeInterval = 2) async throws -> PluginSettingsMaintenanceLease {
        let lease = try await fixture.host.beginSettingsMaintenance(timeout: timeout)
        addTeardownBlock { try? await lease.finish(resume: false) }
        return lease
    }
}
