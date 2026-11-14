import Foundation
import XCTest
@testable import PluginHost

private final class LifecycleEngine: CPythonEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: Int64 = 0
    private var live = Set<Int64>()
    private var owners: [Int64: Thread] = [:]
    private var destroyed = 0
    let rejectDestruction: Bool
    let onCreate: (@Sendable () -> Void)?
    let creationGate: DispatchSemaphore?

    init(rejectDestruction: Bool = false, onCreate: (@Sendable () -> Void)? = nil,
         creationGate: DispatchSemaphore? = nil) {
        self.rejectDestruction = rejectDestruction
        self.onCreate = onCreate
        self.creationGate = creationGate
    }

    var apiVersion: String { "lifecycle-test" }
    var isProcessInitialized: Bool { true }
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {}
    func finalizeProcess() throws {}
    func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }

    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        onCreate?()
        if let creationGate, creationGate.wait(timeout: .now() + 5) == .timedOut {
            throw PluginHostError.runtimeFailure("test creation gate timed out")
        }
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        live.insert(nextID)
        owners[nextID] = Thread.current
        return InterpRef(raw: nextID)
    }

    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        if source == "bad-bootstrap" { throw PluginHostError.runtimeFailure("bootstrap failed") }
        return "None"
    }

    func destroyInterpreter(_ reference: InterpRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard Thread.current === owners[reference.raw] else {
            throw PluginHostError.runtimeFailure("cleanup must run on the creating worker")
        }
        if rejectDestruction { throw PluginHostError.runtimeFailure("native cleanup failed") }
        live.remove(reference.raw)
        owners[reference.raw] = nil
        destroyed += 1
    }

    var snapshot: (live: Int, destroyed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (live.count, destroyed)
    }
}

private func waitForLifecycleCreation(_ stream: AsyncStream<Void>) async throws {
    try await withDispatchTimeout(2) {
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        guard value != nil else {
            throw PluginHostError.runtimeFailure("creation signal closed before creation")
        }
    }
}

private func expectLifecycleNotRunning<T: Sendable>(
    file: StaticString = #filePath, line: UInt = #line,
    _ operation: @escaping @Sendable () async throws -> T
) async {
    do {
        _ = try await withDispatchTimeout(2, operation)
        XCTFail("expected notRunning after terminal stop", file: file, line: line)
    } catch PluginHostError.notRunning {
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

final class SubinterpreterLifecycleTests: XCTestCase {
    func testBootstrapFailureDestroysCreatedInterpreter() async {
        let engine = LifecycleEngine()
        let manager = SubinterpreterManager(engine: engine)
        do {
            _ = try await manager.createInterpreter(for: "bad", bootstrapScript: "bad-bootstrap")
            XCTFail("bootstrap failure must propagate")
        } catch {}
        let active = await manager.activeCount
        let canFinalize = await manager.canFinalizeProcess
        let stats = await manager.stats
        XCTAssertEqual(active, 0)
        XCTAssertTrue(canFinalize)
        XCTAssertEqual(engine.snapshot.live, 0)
        XCTAssertEqual(engine.snapshot.destroyed, 1)
        XCTAssertEqual(stats.created, 1)
        XCTAssertEqual(stats.destroyed, 1)
    }

    func testFailedBootstrapCleanupRetainsPoolSlotAndBlocksFinalization() async {
        let engine = LifecycleEngine(rejectDestruction: true)
        let manager = SubinterpreterManager(engine: engine, limits: PythonInterpreterLimits(maxInterpreters: 1))
        do {
            _ = try await manager.createInterpreter(for: "bad", bootstrapScript: "bad-bootstrap")
            XCTFail("bootstrap failure must propagate")
        } catch {}
        let abandoned = await manager.abandonedCount
        let canFinalize = await manager.canFinalizeProcess
        XCTAssertEqual(abandoned, 1)
        XCTAssertFalse(canFinalize)
        XCTAssertEqual(engine.snapshot.live, 1)
        do {
            _ = try await manager.createInterpreter(for: "overflow", bootstrapScript: "")
            XCTFail("leaked native interpreter must still count toward the limit")
        } catch PluginHostError.interpreterLimitReached(1) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFailedDestructionIsRetainedAsAbandoned() async throws {
        let engine = LifecycleEngine(rejectDestruction: true)
        let manager = SubinterpreterManager(engine: engine)
        let handle = try await manager.createInterpreter(for: "plugin", bootstrapScript: "")
        await manager.destroy(handle)
        let abandoned = await manager.abandonedCount
        let canFinalize = await manager.canFinalizeProcess
        let stats = await manager.stats
        XCTAssertEqual(abandoned, 1)
        XCTAssertFalse(canFinalize)
        XCTAssertEqual(stats.destroyed, 0)
        XCTAssertEqual(engine.snapshot.live, 1)
    }

    func testPendingCreationReservesCapacityAndPreventsFinalization() async throws {
        let (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); signal.finish() }
        let engine = LifecycleEngine(onCreate: { signal.yield(()) }, creationGate: gate)
        let manager = SubinterpreterManager(engine: engine, limits: PythonInterpreterLimits(maxInterpreters: 1))
        let first = Task { try await manager.createInterpreter(for: "first", bootstrapScript: "") }
        try await waitForLifecycleCreation(stream)
        let canFinalize = await manager.canFinalizeProcess
        XCTAssertFalse(canFinalize)
        do {
            _ = try await manager.createInterpreter(for: "second", bootstrapScript: "")
            XCTFail("pending creation must reserve the only slot")
        } catch PluginHostError.interpreterLimitReached(1) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        gate.signal()
        let handle = try await first.value
        await manager.destroy(handle)
        let settled = await manager.canFinalizeProcess
        XCTAssertTrue(settled)
        XCTAssertEqual(engine.snapshot.destroyed, 1)
    }

    func testStopDuringPendingCreationCleansUpOnWorkerAndIsTerminal() async throws {
        let (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); signal.finish() }
        let engine = LifecycleEngine(onCreate: { signal.yield(()) }, creationGate: gate)
        let manager = SubinterpreterManager(engine: engine, limits: PythonInterpreterLimits(maxInterpreters: 1))
        let first = Task { try await manager.createInterpreter(for: "pending", bootstrapScript: "") }
        try await waitForLifecycleCreation(stream)

        // Stop must finish before the creation gate is released (its timeout is 5s).
        try await withDispatchTimeout(2) { await manager.destroyAll() }
        let canFinalizeWhilePending = await manager.canFinalizeProcess
        XCTAssertFalse(canFinalizeWhilePending)
        await expectLifecycleNotRunning {
            try await manager.createInterpreter(for: "during-stop", bootstrapScript: "")
        }

        gate.signal()
        await expectLifecycleNotRunning { try await first.value }
        let active = await manager.activeCount
        let canFinalize = await manager.canFinalizeProcess
        let stats = await manager.stats
        XCTAssertEqual(active, 0)
        XCTAssertTrue(canFinalize)
        XCTAssertEqual(engine.snapshot.live, 0)
        XCTAssertEqual(engine.snapshot.destroyed, 1)
        XCTAssertEqual(stats.created, 1)
        XCTAssertEqual(stats.destroyed, 1)
        XCTAssertEqual(stats.abandoned, 0)
        await expectLifecycleNotRunning {
            try await manager.createInterpreter(for: "after-stop", bootstrapScript: "")
        }
    }

    func testLateCreationCleanupFailureRemainsAbandonedAfterStop() async throws {
        let (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); signal.finish() }
        let engine = LifecycleEngine(rejectDestruction: true,
                                     onCreate: { signal.yield(()) }, creationGate: gate)
        let manager = SubinterpreterManager(engine: engine, limits: PythonInterpreterLimits(maxInterpreters: 1))
        let first = Task { try await manager.createInterpreter(for: "pending", bootstrapScript: "") }
        try await waitForLifecycleCreation(stream)
        try await withDispatchTimeout(2) { await manager.destroyAll() }

        gate.signal()
        await expectLifecycleNotRunning { try await first.value }
        let active = await manager.activeCount
        let abandoned = await manager.abandonedCount
        let canFinalize = await manager.canFinalizeProcess
        let stats = await manager.stats
        XCTAssertEqual(active, 1)
        XCTAssertEqual(abandoned, 1)
        XCTAssertFalse(canFinalize)
        XCTAssertEqual(engine.snapshot.live, 1)
        XCTAssertEqual(stats.created, 1)
        XCTAssertEqual(stats.destroyed, 0)
        XCTAssertEqual(stats.abandoned, 1)
        await expectLifecycleNotRunning {
            try await manager.createInterpreter(for: "after-stop", bootstrapScript: "")
        }
    }

    func testHostStopDuringInstallDoesNotPublishLateLoadedPlugin() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHost-late-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("empty.plugin")
        try Data("# empty\n".utf8).write(to: source)

        let (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); signal.finish() }
        let engine = LifecycleEngine(onCreate: { signal.yield(()) }, creationGate: gate)
        let host = try PluginHost(engine: engine, configuration: PluginHost.Configuration(
            runtime: PythonRuntimeConfiguration(
                pluginRootDirectory: directory.appendingPathComponent("plugins").path),
            storageDirectory: directory))
        try await withDispatchTimeout(2) { try await host.start(safeMode: true) }
        XCTAssertTrue(host.isRunning)
        let installation = Task {
            try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "lateInstall"))
        }
        try await waitForLifecycleCreation(stream)

        try await withDispatchTimeout(2) { await host.stop() }
        XCTAssertFalse(host.isRunning)
        XCTAssertTrue(host.events.subscribers.isIdle)
        gate.signal()
        let installed = try await withDispatchTimeout(2) { try await installation.value }
        XCTAssertFalse(installed.loaded)
        let stored = try XCTUnwrap(host.pluginList().first { $0.id == "lateInstall" })
        XCTAssertFalse(stored.loaded)
        XCTAssertTrue(host.events.subscribers.isIdle)
        XCTAssertEqual(engine.snapshot.live, 0)
        XCTAssertEqual(engine.snapshot.destroyed, 1)

        // Even stale metadata carrying loaded=true cannot republish a plugin.
        let stale = try await withDispatchTimeout(2) {
            try await host.installPlugin(
                sourceURL: source, metadata: Plugin(id: "staleMetadata", enabled: false, loaded: true))
        }
        XCTAssertFalse(stale.loaded)
        host.updatePluginFlags(id: "staleMetadata", hasSettings: true)
        XCTAssertFalse(host.pluginList().contains { $0.loaded })
        XCTAssertTrue(host.events.subscribers.isIdle)
        await expectLifecycleNotRunning { try await host.start(safeMode: true) }
        XCTAssertFalse(host.isRunning)
    }
}
