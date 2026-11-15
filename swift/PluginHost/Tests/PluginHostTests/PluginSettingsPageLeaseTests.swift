import Foundation
import XCTest
@testable import PluginHost

/// Actual Host/event/mailbox/retained-effect code with a canned CPythonEngine.
/// These tests prove native admission and cleanup ordering, not Python or UIKit.
final class PluginSettingsPageLeaseTests: HostLifecycleTestCase {
    private func arguments(_ source: String, method: String) throws -> [String]? {
        let prefix = "_exteraless_runtime._ui.\(method)("
        guard source.hasPrefix(prefix) else { return nil }
        return try JSONDecoder().decode([String].self, from: Data(("[" + String(source.dropFirst(prefix.count).dropLast()) + "]").utf8))
    }

    func testReadUsesCapturedBatchEffectGuardAndCloseReleasesExactlyOnce() async throws {
        let effects = Recorder<PluginNativeCallLease>()
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime._ui.read_settings_page_json(") {
                effects.append(PluginNativeCallLease(isCurrent: { true }))
                return "[]"
            }
            return nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let permit = MaintenanceTestFlag()
        let page = PluginSettingsPageLease(owner: owner, account: 7)
        let json = try await f.host.settingsJSON(id: "alpha", account: 7, expectedOwner: owner,
            shouldExecute: { permit.value }, page: page)
        XCTAssertEqual(json, "[]")
        XCTAssertTrue(page.wasRead)
        let effect = try XCTUnwrap(effects.values.first)
        XCTAssertTrue(effect.isCurrent)
        let call = try XCTUnwrap(engine.calls.first { $0.source.hasPrefix("_exteraless_runtime._ui.read_settings_page_json(") })
        let args = try XCTUnwrap(arguments(call.source, method: "read_settings_page_json"))
        XCTAssertEqual(args[0], page.id)
        XCTAssertEqual(try PluginRuntimeScript.jsonValue(args[1]) as? [String: Int], ["account": 7])
        XCTAssertFalse(call.source.contains(owner.wireToken))
        permit.set(false)
        XCTAssertFalse(effect.isCurrent)
        page.close(); page.close()
        let released = await waitUntil({ engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime._ui.release_settings_page_json(") } }, timeout: 1)
        XCTAssertTrue(released)
        let releases = engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime._ui.release_settings_page_json(") }
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.reference, call.reference)
    }

    func testCancelledReadAfterWorkerEntryReleasesAfterLateMaterialization() async throws {
        let entered = OneShotResult<Void>()
        let unblock = DispatchSemaphore(value: 0)
        let order = Recorder<String>()
        defer { unblock.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime._ui.read_settings_page_json(") {
                order.append("entered")
                entered.succeed(())
                try maintenanceTestBlock(unblock)
                order.append("materialized")
                return "[]"
            }
            if source.hasPrefix("_exteraless_runtime._ui.release_settings_page_json(") { order.append("released") }
            return nil
        })
        let f = try fixture(engine: engine, callTimeout: 10, queueLimits: .init(dispatchTimeout: 10))
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let page = PluginSettingsPageLease(owner: owner, account: 7)
        let read = Task { try await f.host.settingsJSON(id: "alpha", account: 7, expectedOwner: owner, page: page) }
        _ = try await maintenanceTestWait(entered)
        read.cancel()
        do { _ = try await read.value; XCTFail("cancelled read published a page") }
        catch is CancellationError { }
        XCTAssertFalse(page.isOpen)
        XCTAssertEqual(order.values, ["entered"])
        unblock.signal()
        let drained = await waitUntil({ order.values.last == "released" }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertEqual(order.values, ["entered", "materialized", "released"])
    }

    func testPageActionRechecksAccountGuardOnWorkerAndRetainsEffectRevocation() async throws {
        let entered = OneShotResult<Void>()
        let unblock = DispatchSemaphore(value: 0)
        let effects = Recorder<PluginNativeCallLease>()
        let ownerThreads = Recorder<Thread>()
        let workerChecks = Recorder<Bool>()
        defer { unblock.signal() }
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime._ui.read_settings_page_json(") { return "[]" }
            if source.hasPrefix("_exteraless_runtime.invoke_handle_json(77,") {
                ownerThreads.append(Thread.current)
                entered.succeed(())
                try maintenanceTestBlock(unblock)
            }
            if source.hasPrefix("_exteraless_runtime._ui.settings_page_event_json(") {
                effects.append(PluginNativeCallLease(isCurrent: { true }))
            }
            return nil
        })
        let f = try fixture(engine: engine, callTimeout: 10)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let page = PluginSettingsPageLease(owner: owner, account: 7)
        _ = try await f.host.settingsJSON(id: "alpha", account: 7, expectedOwner: owner, page: page)
        let blocker = Task { try await f.host.invokeCallback(id: "alpha", handle: 77, method: "run", expectedOwner: owner) }
        _ = try await maintenanceTestWait(entered)
        let account = MaintenanceTestFlag()
        let action = Task {
            try await PluginSettingsPageExecution.$current.withValue(page) {
                try await f.host.clickSetting(id: "alpha", callbackId: "cb_original_string", expectedOwner: owner,
                    account: 7, shouldExecute: {
                        if ownerThreads.values.contains(where: { $0 === Thread.current }) {
                            workerChecks.append(account.value)
                            return account.value
                        }
                        return true // An admission-only check cannot pass this test.
                    })
            }
        }
        account.set(false)
        unblock.signal()
        try await blocker.value
        do { try await action.value; XCTFail("stale account reached its callback") }
        catch PluginHostError.superseded { }
        XCTAssertTrue(effects.values.isEmpty)
        XCTAssertEqual(workerChecks.values, [false])
        account.set(true)
        try await PluginSettingsPageExecution.$current.withValue(page) {
            try await f.host.clickSetting(id: "alpha", callbackId: "cb_original_string", expectedOwner: owner,
                account: 7, shouldExecute: { account.value })
        }
        let effect = try XCTUnwrap(effects.values.first)
        XCTAssertTrue(effect.isCurrent)
        page.close()
        XCTAssertFalse(effect.isCurrent)
    }

    func testClosedOrReplacementOwnerPageCannotResolveFreshCallbackIDs() async throws {
        let engine = MaintenanceTestEngine(onScript: { _, source in
            source.hasPrefix("_exteraless_runtime._ui.read_settings_page_json(") ? "[]" : nil
        })
        let f = try fixture(engine: engine)
        try await load(f)
        let owner = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        let old = PluginSettingsPageLease(owner: owner, account: 7)
        _ = try await f.host.settingsJSON(id: "alpha", account: 7, expectedOwner: owner, page: old)
        try await f.host.reloadPlugin(id: "alpha")
        let replacement = try XCTUnwrap(f.host.callbackOwner(id: "alpha"))
        XCTAssertNotEqual(owner, replacement)
        do {
            try await PluginSettingsPageExecution.$current.withValue(old) {
                try await f.host.clickSetting(id: "alpha", callbackId: "cb_same_string", expectedOwner: replacement, account: 7)
            }
            XCTFail("page selected a replacement interpreter")
        } catch PluginHostError.superseded { }
        old.close()
        let fresh = PluginSettingsPageLease(owner: replacement, account: 7)
        _ = try await f.host.settingsJSON(id: "alpha", account: 7, expectedOwner: replacement, page: fresh)
        do {
            try await PluginSettingsPageExecution.$current.withValue(fresh) {
                try await f.host.updateSetting(id: "alpha", key: "same", valueJSON: "true", expectedOwner: replacement, account: 8)
            }
            XCTFail("page changed account")
        } catch PluginHostError.superseded { }
        XCTAssertFalse(engine.calls.contains { $0.source.hasPrefix("_exteraless_runtime._ui.settings_page_event_json(") })
        fresh.close()
    }
}
