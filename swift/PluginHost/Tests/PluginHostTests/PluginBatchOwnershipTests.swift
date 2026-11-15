import Foundation
import XCTest
@testable import PluginHost

final class PluginBatchOwnershipTests: HostLifecycleTestCase {
    func testTimeoutRevokesOnlyItsBatchAndRetainsRunningWorkerCredit() async throws {
        let betaEntered = OneShotResult<Void>()
        let gammaEntered = OneShotResult<Void>()
        let betaGate = DispatchSemaphore(value: 0)
        let gammaGate = DispatchSemaphore(value: 0)
        defer { betaGate.signal(); gammaGate.signal() }
        let effects = Recorder<PluginNativeCallLease>()
        let independentEffects = Recorder<PluginNativeCallLease>()
        let names = ["alpha", "beta", "gamma", "delta"]
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                let id = names[Int(reference.raw - 1)]
                return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"app_event\":\(id != "gamma")},\"has_settings\":false}"
            }
            if reference.raw == 3, source.hasPrefix("_exteraless_runtime.invoke_handle_json(99,") {
                independentEffects.append(PluginNativeCallLease(isCurrent: { true }))
                gammaEntered.succeed(())
                try maintenanceTestBlock(gammaGate)
            }
            if source.hasPrefix("_exteraless_runtime.dispatch_json("), source.contains("timeout_case") {
                if reference.raw == 1 { effects.append(PluginNativeCallLease(isCurrent: { true })) }
                if reference.raw == 2 { betaEntered.succeed(()); try maintenanceTestBlock(betaGate) }
            }
            return nil
        })
        let f = try fixture(engine: engine, queueLimits: .init(dispatchTimeout: 0.25, maxQueueDepth: 2, maxQueueBytes: 4096))
        for id in names {
            if !FileManager.default.fileExists(atPath: f.source(id).path) { try Data("# own fixture".utf8).write(to: f.source(id)) }
            try await load(f, id)
        }
        let gamma = try XCTUnwrap(f.host.callbackOwner(id: "gamma"))
        let unrelated = Task { try await f.host.invokeCallbackResult(id: "gamma", handle: 99, method: "run", expectedOwner: gamma) }
        _ = try await maintenanceTestWait(gammaEntered)
        let event = Task { try await f.host.deliverAppEvent("timeout_case") }
        _ = try await maintenanceTestWait(betaEntered)
        do { try await event.value; XCTFail("expected batch timeout") }
        catch PluginHostError.timeout { }
        XCTAssertTrue(f.host.pluginList().first(where: { $0.id == "gamma" })?.loaded == true)
        XCTAssertFalse(f.host.pluginList().first(where: { $0.id == "gamma" })?.notResponding ?? true)
        XCTAssertEqual(effects.count, 1)
        XCTAssertFalse(try XCTUnwrap(effects.values.first).isCurrent) // A completed before B timed out.
        XCTAssertTrue(try XCTUnwrap(independentEffects.values.first).isCurrent)
        XCTAssertFalse(engine.calls.contains { $0.reference.raw == 4 && $0.source.contains("timeout_case") })
        let retained = await f.host.events.queueStatistics()
        XCTAssertEqual(retained.retainedCount, 1) // B still retains the native job/payload.
        gammaGate.signal()
        _ = try await unrelated.value
        try await f.host.deliverAppEvent("fresh_case")
        XCTAssertTrue(engine.calls.contains { $0.reference.raw == 4 && $0.source.contains("fresh_case") })
        betaGate.signal()
        let drained = await waitUntil({ await f.host.events.queueStatistics().retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
    }

    func testAwaitedSendCancellationRevokesQueuedFanoutAndDeferredEffects() async throws {
        let entered = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let effects = Recorder<PluginNativeCallLease>()
        let names = ["alpha", "beta", "delta"]
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                return "{\"metadata\":{\"id\":\"\(names[Int(reference.raw - 1)])\"},\"handles\":{\"send_message\":true},\"has_settings\":false}"
            }
            if source.hasPrefix("_exteraless_runtime.dispatch_json(") {
                if reference.raw == 1 { effects.append(PluginNativeCallLease(isCurrent: { true })) }
                if reference.raw == 2 { entered.succeed(()); try maintenanceTestBlock(gate) }
                return "{\"strategy\":\"DEFAULT\"}"
            }
            return nil
        })
        let f = try fixture(engine: engine)
        for id in names {
            if !FileManager.default.fileExists(atPath: f.source(id).path) { try Data("# own fixture".utf8).write(to: f.source(id)) }
            try await load(f, id)
        }
        let permitted = MaintenanceTestFlag()
        let waiting = Task {
            try await f.host.events.preSendMessageResult(.init(account: 0, paramsJSON: "{\"text\":\"fixture\"}"),
                                                       shouldExecute: { permitted.value })
        }
        _ = try await maintenanceTestWait(entered)
        permitted.set(false)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("expected cancelled send") }
        catch is CancellationError { }
        XCTAssertFalse(try XCTUnwrap(effects.values.first).isCurrent)
        gate.signal()
        let drained = await waitUntil({ await f.host.events.queueStatistics().retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertFalse(engine.calls.contains { $0.reference.raw == 3 && $0.source.hasPrefix("_exteraless_runtime.dispatch_json(") })
        XCTAssertFalse(f.host.pluginList().contains { $0.notResponding })
    }
}
