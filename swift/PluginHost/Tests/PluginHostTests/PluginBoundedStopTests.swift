import Foundation
import XCTest
@testable import PluginHost

private final class StopCleanupRecorder: PluginBridgeExtension, @unchecked Sendable {
    let releases = Recorder<String>()
    func dispatch(requestJSON: String, pluginId: String) throws -> String? { nil }
    func releaseInstances(pluginId: String) { releases.append(pluginId) }
}

final class PluginBoundedStopTests: HostLifecycleTestCase {
    func testStopAfterDestructionTimeoutRetiresProvidersWithoutLosingEvidence() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onDestroy: { reference in
            if reference.raw == 1 { entered.succeed(()); try maintenanceTestBlock(gate) }
        })
        let f = try fixture(engine: engine, stopTimeout: 0.1)
        try await load(f)
        try await load(f, "beta")
        let cleanup = StopCleanupRecorder()
        f.host.bridge.extensionProvider = cleanup
        let preparing = Task { try await f.host.beginSettingsMaintenance(timeout: 0.25) }
        _ = try await maintenanceTestWait(entered)
        do {
            let unexpected = try await preparing.value
            addTeardownBlock { try? await unexpected.finish(resume: false) }
            XCTFail("held destructor cannot produce a maintenance lease")
        } catch PluginHostError.timeout { }
        try await withDispatchTimeout(1) { await f.host.stop() }
        XCTAssertFalse(f.host.isRunning)
        XCTAssertNil(f.host.callbackOwner(id: "alpha"))
        XCTAssertEqual(engine.counts.finalized, 0)
        XCTAssertEqual(Set(cleanup.releases.values), Set(["alpha", "beta"]))
        let healthyRetired = await waitUntil({ engine.counts.destroyed == 1 }, timeout: 1)
        XCTAssertTrue(healthyRetired)
        XCTAssertEqual(engine.counts.live, 1)
        gate.signal()
        let oldExited = await waitUntil({ engine.counts.destroyed == 2 }, timeout: 1)
        XCTAssertTrue(oldExited)
        await f.host.stop()
        XCTAssertEqual(engine.counts.finalized, 0) // Late exit does not restart/finalize the terminal runtime.
        XCTAssertFalse(f.host.pluginList().contains { $0.loaded })
    }
}
