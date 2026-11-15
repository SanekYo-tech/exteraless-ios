import Foundation
import XCTest
@testable import PluginHost

final class PluginSettingsExecutionTests: HostLifecycleTestCase {
    func testQueuedChangeAndClickRecheckPageScopeOnWorker() async throws {
        let entered = OneShotResult<Void>()
        let changeAdmitted = OneShotResult<Void>()
        let clickAdmitted = OneShotResult<Void>()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(55,") {
                entered.succeed(())
                try maintenanceTestBlock(gate)
            }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let prior = Task { try await f.host.invokeCallback(id: "alpha", handle: 55, method: "run", expectedOwner: owner) }
        _ = try await maintenanceTestWait(entered)
        let current = MaintenanceTestFlag()
        let workerChecks = Recorder<String>()
        let change = Task {
            try await f.host.updateSetting(id: "alpha", key: "mode", valueJSON: "true", expectedOwner: owner, account: 7,
                shouldExecute: {
                    changeAdmitted.succeed(())
                    if let name = Thread.current.name, name.hasPrefix("plugin-") { workerChecks.append(name) }
                    return current.value
                })
        }
        let click = Task {
            try await f.host.clickSetting(id: "alpha", callbackId: "row", expectedOwner: owner, account: 7,
                shouldExecute: {
                    clickAdmitted.succeed(())
                    if let name = Thread.current.name, name.hasPrefix("plugin-") { workerChecks.append(name) }
                    return current.value
                })
        }
        _ = try await maintenanceTestWait(changeAdmitted)
        _ = try await maintenanceTestWait(clickAdmitted)
        current.set(false) // account/revision revoked after admission, before worker entry
        gate.signal()
        try await prior.value
        for task in [change, click] {
            do { try await task.value; XCTFail("expired settings action must be skipped") }
            catch PluginHostError.superseded { }
        }
        XCTAssertEqual(workerChecks.count, 2)
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.setting_changed_json(") })
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime.setting_click_json(") })
    }

    func testExpectedOwnerCannotRetargetAndCapturedAccountIsAnSDKArgument() async throws {
        let f = try fixture()
        try await load(f)
        let old = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        try await f.host.reloadPlugin(id: "alpha")
        do {
            try await f.host.updateSetting(id: "alpha", key: "k", valueJSON: "false", expectedOwner: old, account: 3)
            XCTFail("reload between page validation and Host admission must reject")
        } catch PluginHostError.superseded { }
        do {
            try await f.host.clickSetting(id: "alpha", callbackId: "old", expectedOwner: old, account: 3)
            XCTFail("old page callback must not enter the replacement")
        } catch PluginHostError.superseded { }
        let fresh = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        try await f.host.updateSetting(id: "alpha", key: "k", valueJSON: "false", expectedOwner: fresh, account: 3)
        try await f.host.clickSetting(id: "alpha", callbackId: "row", expectedOwner: fresh, account: 3)
        try await f.host.clickSetting(id: "alpha", callbackId: "legacy")
        let scripts = f.engine.calls.map(\.source)
        XCTAssertTrue(scripts.contains("_exteraless_runtime.setting_changed_json(\"k\", \"false\", 3)"))
        XCTAssertTrue(scripts.contains("_exteraless_runtime.setting_click_json(\"row\", 3)"))
        XCTAssertTrue(scripts.contains("_exteraless_runtime.setting_click_json(\"legacy\")"))
        XCTAssertFalse(scripts.contains { $0.contains("setting_click_json(\"old\"") })
    }
}
