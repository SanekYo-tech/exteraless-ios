import Foundation
import XCTest
@testable import PluginHost

/// Own source fixture/FakeEngine only: no CPython, account, network or user plugin.
final class NativeServiceDispatcherTests: XCTestCase {
    func testBarrierConsumesActualDispatcherJSONAndReleaseStaysAfterInvocation() async throws {
        let directory = tempDirectory("native-service-result")
        let engine = FakeEngine()
        engine.scriptResponse = { source in
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                return "{\"metadata\":{\"id\":\"nativeServiceFixture\"},\"handles\":{},\"has_settings\":false}"
            }
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(") { return "false" }
            return "null"
        }
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: directory.appendingPathComponent("plugins").path), storageDirectory: directory))
        addTeardownBlock {
            await host.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try await host.start(safeMode: true)
        let source = directory.appendingPathComponent("native-service-fixture.plugin")
        try Data("# own FakeEngine fixture; never executed as a user plugin\n".utf8).write(to: source)
        let plugin = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "nativeServiceFixture"))
        XCTAssertTrue(plugin.loaded)
        let dispatcher = PluginCallbackDispatcher(host: host)
        let owner = try XCTUnwrap(dispatcher.captureOwner(plugin.id))
        let pool = NativeServiceLeasePool<PluginHost.CallbackOwner>()
        let lease = try pool.make(pluginId: plugin.id, owner: owner, handle: 11,
            isCurrent: { dispatcher.captureOwner($0.pluginId) == $0 },
            callback: { dispatcher.callback($0, $1, $2, $3) },
            resultCallback: NativeServiceCallbackTransport.result(using: dispatcher),
            release: { dispatcher.release($0, $1) })
        let result = OneShotResult<NativeServiceOpenDecision>()
        let barrier = NativeServiceOpenBarrier(steps: [try NativeServiceOpenStep(lease: lease, context: .object([:]))],
            fileCallback: false, callbackTimeoutMs: 1000, totalTimeoutMs: 1500) { result.succeed($0) }
        barrier.start()
        let decision = try await withDispatchTimeout(2) { try await result.awaitValue() }
        // dispatcher admitted true, Python JSON false: opening must continue.
        XCTAssertEqual(decision, .continueOpening)
        lease.close()
        let released = await waitUntil({ engine.scripts.contains { $0.hasPrefix("_exteraless_runtime.release_handles_json(") } }, timeout: 2)
        XCTAssertTrue(released)
        let work = engine.scripts.filter { $0.hasPrefix("_exteraless_runtime.invoke_handle_json(") || $0.hasPrefix("_exteraless_runtime.release_handles_json(") }
        XCTAssertEqual(work.count, 2)
        if work.count == 2 {
            XCTAssertTrue(work[0].hasPrefix("_exteraless_runtime.invoke_handle_json(11,"))
            XCTAssertTrue(work[1].contains("[11]"))
        }
        XCTAssertEqual(pool.count, 0)
    }
}
