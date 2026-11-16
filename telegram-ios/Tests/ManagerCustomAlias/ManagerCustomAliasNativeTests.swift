import Foundation
import TelegramPresentationData
import UIKit
import XCTest

// Only label localization is fixture-provided. The selected sources compile the
// actual PluginUIWidgetView/Container, cells, models, resources and page gates.
// No substitute renderer, AccountContext or interpreter is provided here.
func pluginText(_ key: String, _ fallback: String) -> String { fallback }

final class ManagerCustomAliasNativeTests: XCTestCase {
    private let rows = """
    [{"type":"text","row_id":"parent","text":"Nested","link_alias":"parent_alias","sub_page":[
      {"type":"switch","row_id":"toggle","key":"enabled","link_alias":"known_alias","text":"Enabled","value":true},
      {"type":"custom","row_id":"custom","link_alias":"custom_alias","widget_json":"{\\"type\\":\\"text\\",\\"id\\":\\"native-widget\\",\\"text\\":\\"Portable\\"}"}
    ]}]
    """

    private func model(_ json: String) throws -> PluginUIWidget {
        var count = 0
        return try PluginUIWidget.parse(PluginUIJSON.decode(json), fallbackId: "root", count: &count)
    }

    @MainActor private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { self.descendants($0, of: type) }
    }

    func testOriginalAliasAndKeyResolveSameNestedNativeRow() throws {
        let document = try PluginSettingsDocument.decode(self.rows)
        let expected = PluginSettingsTarget(pagePath: ["parent"], rowId: "toggle")
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: "known_alias", in: document), expected)
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: "enabled", in: document), expected)
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: nil, in: document), .init(pagePath: [], rowId: nil))
        let custom = try XCTUnwrap(document[0].subPage?[1])
        XCTAssertEqual(custom.kind, .custom)
        XCTAssertEqual(try self.model(XCTUnwrap(custom.widgetJSON)).kind, .text)
    }

    func testDuplicateUnknownTooLongAndUnicodeAliasesAreTyped() throws {
        let document = try PluginSettingsDocument.decode(self.rows)
        for (target, expected) in [("Unknown", PluginSettingsTargetError.unknown), ("", .invalid), (String(repeating: "é", count: 129), .tooLong)] {
            XCTAssertThrowsError(try PluginSettingsDocument.resolve(target: target, in: document)) { error in
                XCTAssertEqual(error as? PluginSettingsTargetError, expected)
            }
        }
        let duplicate = try PluginSettingsDocument.decode("[{\"type\":\"text\",\"row_id\":\"one\",\"link_alias\":\"dup\"},{\"type\":\"text\",\"row_id\":\"two\",\"key\":\"dup\"}]")
        XCTAssertThrowsError(try PluginSettingsDocument.resolve(target: "dup", in: duplicate)) { error in
            XCTAssertEqual(error as? PluginSettingsTargetError, .ambiguous)
        }
        let unicode = try PluginSettingsDocument.decode("[{\"type\":\"text\",\"row_id\":\"one\",\"link_alias\":\"é\"},{\"type\":\"text\",\"row_id\":\"two\",\"link_alias\":\"e\\u0301\"}]")
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: "é", in: unicode).rowId, "one")
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: "e\u{301}", in: unicode).rowId, "two")
        let refreshed = try PluginSettingsDocument.decode("[{\"type\":\"text\",\"row_id\":\"new\",\"link_alias\":\"known_alias\"}]")
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: "known_alias", in: refreshed).rowId, "new")
        XCTAssertEqual(try PluginSettingsDocument.resolve(target: "known_alias", in: document).rowId, "toggle")
    }

    @MainActor func testActualNestedTextFieldEmitsBoundedWidgetArgumentsAndRejectsOldPage() throws {
        let root = try self.model("""
        {"type":"column","id":"root","children":[
          {"type":"input","id":"draft","text":"Draft","value":"before","max_length":32,"callback":"cw_read1_input"},
          {"type":"text","id":"action","text":"Tap","callback":"cw_read1_tap","long_callback_id":"cw_read1_long"}
        ]}
        """)
        let route = PluginUIManagerWidgetRoute(rowId: "sdk-custom", root: root)
        let gate = PluginUISettingsPageGate()
        gate.beginAppearance(); gate.setVisible(true); gate.publish()
        let read = try gate.captureRead()
        let permit = try gate.capture()
        let account = PluginUISettingsAccountGate()
        account.replace(recordId: 42, index: 7)
        let token = try XCTUnwrap(account.snapshot)
        var events: [(String, String)] = []
        let cell = PluginUIManagerCustomCell(style: .default, reuseIdentifier: nil)
        try cell.configure(model: root, data: defaultPresentationData(), enabled: true, values: [:], change: { widget, value in
            guard read.isCurrent, permit.isCurrent, account.permits(token), let event = try? route.event(widget: widget, name: "change", value: value) else { return false }
            events.append(event)
            return true
        }, select: { _, _ in XCTFail("input must not present selector") }, activated: { widget, long in
            if permit.isCurrent, let event = try? route.event(widget: widget, name: long ? "longAction" : "action") { events.append(event) }
        }, layoutChanged: {})
        cell.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        cell.layoutIfNeeded()
        let field = try XCTUnwrap(self.descendants(cell, of: UITextField.self).first)
        field.text = "edited 🙂"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, "cw_read1_input")
        let event = try PluginUIJSON.decode(events[0].1).object
        XCTAssertEqual(event?["rowId"], .string("sdk-custom"))
        XCTAssertEqual(event?["widgetId"], .string("draft"))
        XCTAssertEqual(event?["value"], .string("edited 🙂"))
        gate.invalidate(); gate.publish() // new rendered revision does not revive this cell
        field.text = "stale"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(field.text, "edited 🙂")
        let disabled = try self.model("{\"type\":\"column\",\"id\":\"disabled\",\"enabled\":false,\"children\":[{\"type\":\"text\",\"id\":\"child\",\"callback\":\"cw_child\"}]}")
        XCTAssertThrowsError(try PluginUIManagerWidgetRoute(rowId: "disabled-row", root: disabled).event(widget: disabled.children[0], name: "action"))
        account.replace(recordId: 42, index: 7) // A -> replacement A is a new lifetime
        XCTAssertFalse(account.permits(token))
        read.cancel()
        XCTAssertFalse(read.isCurrent)
        gate.close()
    }

    @MainActor func testNativeResourcesAndWidgetBoundsFailExplicitly() throws {
        let badImage = try self.model("{\"type\":\"image\",\"id\":\"missing\",\"image\":\"sf:__owned_nonexistent_symbol__\"}")
        XCTAssertThrowsError(try PluginUIWidgetView(model: badImage, data: defaultPresentationData(), change: { _, _ in false },
            select: { _, _ in }, activated: { _, _ in }, layoutChanged: {})) { error in
            XCTAssertEqual((error as? PluginUIFailure)?.kind, "ResourceUnavailable")
        }
        let children = (0..<512).map { "{\"type\":\"text\",\"id\":\"child\($0)\"}" }.joined(separator: ",")
        XCTAssertThrowsError(try self.model("{\"type\":\"column\",\"id\":\"root\",\"children\":[\(children)]}"))
        var nested = "{\"type\":\"text\",\"id\":\"leaf\"}"
        for index in 0..<9 { nested = "{\"type\":\"column\",\"id\":\"level\(index)\",\"children\":[\(nested)]}" }
        XCTAssertThrowsError(try self.model(nested))
        XCTAssertThrowsError(try PluginSettingsDocument.decode("[" + Array(repeating: "{\"type\":\"text\"}", count: 1001).joined(separator: ",") + "]"))
    }

    @MainActor func testResolvedTargetFocusNeedsCurrentNativePermissionAndExistingRow() throws {
        // Requires the coordinator's targetRowId validation hunk. A wire recorder
        // accepting an unknown field is deliberately insufficient for this test.
        let raw = try PluginUIJSON.decode("{\"rows\":[{\"type\":\"text\",\"id\":\"target\",\"text\":\"Target\"}],\"pagePath\":[],\"targetRowId\":\"target\"}")
        let model = try PluginUIModel(kind: .settings, value: raw)
        let widget = try PluginUIWidgetView(model: model.rows[0], data: defaultPresentationData(), change: { _, _ in false },
            select: { _, _ in }, activated: { _, _ in }, layoutChanged: {})
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        controller.view.addSubview(scroll)
        scroll.contentSize = CGSize(width: 320, height: 1200)
        widget.frame = CGRect(x: 0, y: 900, width: 320, height: 80)
        scroll.addSubview(widget)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let focus = PluginUISettingsTargetFocus()
        focus.reveal(model: model, revision: 1, pagePath: [], scrollView: scroll, widgets: [widget], permitted: false)
        XCTAssertEqual(scroll.contentOffset.y, 0)
        focus.reveal(model: model, revision: 1, pagePath: [], scrollView: scroll, widgets: [widget], permitted: true)
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertThrowsError(try model.applying(.object(["targetRowId": .string("unknown")])))
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PluginUIFailure.unavailable("Owned FIFO fixture exceeded two seconds") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor func testRootCustomWaitsBehindBothAcceptedInlineValues() async throws {
        let fifo = PluginUIManagerEventFIFO()
        let held = MCAHeldOperation()
        let page = PluginUISettingsPageGate()
        page.beginAppearance(); page.setVisible(true); page.publish()
        let first = try page.capture(), second = try page.capture(), root = try page.capture()
        defer { held.release(); fifo.close(); page.close() }
        var value = "initial"
        var order: [String] = []
        _ = try fifo.enqueue(bytes: 20, isCurrent: { first.isCurrent }, cancel: { first.cancel() }, operation: {
            value = "a"; order.append("E1")
            await held.wait()
        })
        try await self.waitFor { held.entered }
        _ = try fifo.enqueue(bytes: 21, isCurrent: { second.isCurrent }, cancel: { second.cancel() }, operation: {
            value = "ab"; order.append("E2")
        })
        let result = try fifo.enqueue(bytes: 30, isCurrent: { root.isCurrent }, cancel: { root.cancel() }, operation: {
            order.append("R:\(value)")
        })
        XCTAssertEqual(order, ["E1"])
        XCTAssertEqual(fifo.retainedCount, 3)
        XCTAssertEqual(fifo.retainedBytes, 71)
        held.release()
        try await self.waitFor { fifo.retainedCount == 0 }
        try await result.value()
        XCTAssertEqual(order, ["E1", "E2", "R:ab"])
        XCTAssertEqual(fifo.retainedBytes, 0)
    }

    @MainActor func testRefreshDisposalDropsPendingRootAndKeepsInFlightCredit() async throws {
        let fifo = PluginUIManagerEventFIFO()
        let held = MCAHeldOperation()
        let page = PluginUISettingsPageGate()
        page.beginAppearance(); page.setVisible(true); page.publish()
        let first = try page.capture(), root = try page.capture()
        defer { held.release(); fifo.close(); page.close() }
        var calls = 0
        _ = try fifo.enqueue(bytes: 64, isCurrent: { first.isCurrent }, cancel: { first.cancel() }, operation: { await held.wait() })
        try await self.waitFor { held.entered }
        let result = try fifo.enqueue(bytes: 40, isCurrent: { root.isCurrent }, cancel: { root.cancel() }, operation: { calls += 1 })
        page.invalidate(); page.publish() // a replacement revision cannot revive R
        fifo.close()
        XCTAssertEqual(fifo.retainedCount, 1)
        XCTAssertEqual(fifo.retainedBytes, 64)
        do { try await result.value(); XCTFail("disposed root action completed") } catch is CancellationError { }
        XCTAssertThrowsError(try fifo.enqueue(bytes: 1, isCurrent: { true }, cancel: {}, operation: {}))
        held.release()
        try await self.waitFor { fifo.retainedCount == 0 }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(fifo.retainedBytes, 0)
    }

    @MainActor func testFIFOCountAndBytesIncludeTheHeldOperation() async throws {
        for byteLimited in [false, true] {
            let fifo = PluginUIManagerEventFIFO()
            let held = MCAHeldOperation()
            defer { held.release(); fifo.close() }
            let bytes = byteLimited ? 512 * 1024 : 16
            _ = try fifo.enqueue(bytes: bytes, isCurrent: { true }, cancel: {}, operation: { await held.wait() })
            try await self.waitFor { held.entered }
            if !byteLimited {
                for _ in 0..<127 { _ = try fifo.enqueue(bytes: 1, isCurrent: { true }, cancel: {}, operation: {}) }
            }
            XCTAssertEqual(fifo.retainedCount, byteLimited ? 1 : 128)
            XCTAssertThrowsError(try fifo.enqueue(bytes: 1, isCurrent: { true }, cancel: {}, operation: {}))
            fifo.close()
            XCTAssertEqual(fifo.retainedCount, 1)
            XCTAssertEqual(fifo.retainedBytes, bytes)
            held.release()
            try await self.waitFor { fifo.retainedCount == 0 }
        }
    }

    @MainActor func testInlineCallbackErrorDoesNotInventValueRollbackOrLetRootOvertake() async throws {
        let fifo = PluginUIManagerEventFIFO()
        defer { fifo.close() }
        var value = "initial"
        var errors = 0
        var rootValue: String?
        _ = try fifo.enqueue(bytes: 20, isCurrent: { true }, cancel: {}, operation: {
            value = "a" // matches the SDK write-before-callback contract
            throw PluginUIFailure.unavailable("owned inline callback failure")
        }, failed: { _ in errors += 1 })
        _ = try fifo.enqueue(bytes: 21, isCurrent: { true }, cancel: {}, operation: {
            XCTAssertEqual(value, "a")
            value = "ab"
        })
        let root = try fifo.enqueue(bytes: 30, isCurrent: { true }, cancel: {}, operation: { rootValue = value })
        try await self.waitFor { fifo.retainedCount == 0 }
        try await root.value()
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(rootValue, "ab")
    }

    private func snapshotModel(_ snapshot: String) throws -> PluginUIModel {
        try PluginUIModel(kind: .settings, value: .object([
            "settingsSnapshotId": .string(snapshot),
            "rows": .array([.object(["type": .string("switch"), "id": .string("row"),
                "key": .string("known_key"), "text": .string("Enabled"), "value": .bool(false)])])]))
    }

    private func updateRequest(from: String, to: String, handle: Int64 = 3) -> PluginUIJSON {
        .object(["previousSnapshotId": .string(from), "snapshotId": .string(to),
                 "completion": .object(["__handle__": .integer(handle)])])
    }

    func testNativeCommitACKAndReleasePrecedeS2EventsUnderBackpressure() throws {
        let store = PluginUILeaseStore<String>()
        _ = store.replaceScope(accountRecordId: 42)
        let s1 = UUID().uuidString, s2 = UUID().uuidString
        let model = try self.snapshotModel(s1)
        let entry = try store.accept(pluginId: "owned", owner: "owner-1", content: .presentation(model), callbacks: [
            "change": try PluginUICallback(.object(["__handle__": .integer(1)])),
            "closed": try PluginUICallback(.object(["__handle__": .integer(2)]))])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let patch = PluginUIJSON.object(["settingsSnapshotId": .string(s2)])
        let update = try store.reserveSettingsUpdate(id: entry.state.id, pluginId: "owned", owner: "owner-1", patch: patch,
            request: self.updateRequest(from: s1, to: s2), expectedScope: entry.state.scope, admission: {})
        let old = try XCTUnwrap(store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "change",
            payload: ["key": .string("known_key"), "value": .bool(true), "_uiSettingsSnapshot": .string("spoof")]).delivery)
        let oldMetadata = try XCTUnwrap(old.arguments.array?.first?.object)
        XCTAssertEqual(oldMetadata["_uiSettingsSnapshot"], .string(s1))
        XCTAssertTrue(store.permitsCallback(pluginId: "owned", metadata: oldMetadata))
        _ = try store.update(id: entry.state.id, pluginId: "owned", patch: patch, expectedScope: entry.state.scope, settingsUpdateId: update.id)
        XCTAssertFalse(store.permitsCallback(pluginId: "owned", metadata: oldMetadata))
        let retirement = try XCTUnwrap(store.finishSettingsUpdate(id: entry.state.id, updateId: update.id))
        XCTAssertEqual(retirement.deliveries.first?.arguments.array?.first?.object?["committed"], .bool(true))
        let admission = MCAAdmission()
        let trace = MCATrace()
        let queue = PluginUIReleaseQueue<String>(isCurrent: { _ in true }, callback: { _ in
            guard admission.allowed else { return false }
            trace.append("ack"); return true
        }, release: { _, handles in
            XCTAssertEqual(handles, [3]); trace.append("release"); return true
        }, completed: { store.completeRetirement(id: $0.id, owner: $0.owner) })
        queue.retire(retirement)
        XCTAssertTrue(trace.values.isEmpty)
        XCTAssertFalse(store.action(id: entry.state.id, revision: 1, scope: entry.state.scope, name: "change", payload: [:]).accepted)
        admission.open()
        queue.retryPending()
        XCTAssertEqual(trace.values, ["ack", "release"])
        let fresh = try XCTUnwrap(store.action(id: entry.state.id, revision: 1, scope: entry.state.scope, name: "change", payload: [:]).delivery)
        XCTAssertEqual(fresh.arguments.array?.first?.object?["_uiSettingsSnapshot"], .string(s2))
    }

    func testRejectedNativeUpdatePreservesS1AndCapturedPermissionPredicate() throws {
        let store = PluginUILeaseStore<String>()
        _ = store.replaceScope(accountRecordId: 42)
        let permission = MCAAdmission(initiallyAllowed: true)
        let s1 = UUID().uuidString, s2 = UUID().uuidString
        let model = try self.snapshotModel(s1)
        let entry = try store.accept(pluginId: "owned", owner: "owner-1", content: .presentation(model), callbacks: [:],
            permissionIsCurrent: { permission.allowed })
        let patch = PluginUIJSON.object(["settingsSnapshotId": .string(s2)])
        let ticket = try store.reserveSettingsUpdate(id: entry.state.id, pluginId: "owned", owner: "owner-1", patch: patch,
            request: self.updateRequest(from: s1, to: s2), expectedScope: entry.state.scope, admission: {})
        XCTAssertThrowsError(try store.update(id: entry.state.id, pluginId: "owned", patch: patch, settingsUpdateId: ticket.id,
            admission: { throw PluginUIFailure.invalidHandle("cancelled before commit") }))
        let rejected = try XCTUnwrap(store.finishSettingsUpdate(id: entry.state.id, updateId: ticket.id,
            failure: .invalidHandle("cancelled before commit")))
        let current = try store.entry(id: entry.state.id, pluginId: "owned")
        XCTAssertEqual(current.content, .presentation(model))
        XCTAssertEqual(current.state.revision, 0)
        let ack = try XCTUnwrap(rejected.deliveries.first)
        XCTAssertEqual(ack.arguments.array?.first?.object?["committed"], .bool(false))
        XCTAssertTrue(ack.permissionIsCurrent())
        permission.revoke()
        let replacementGrant = MCAAdmission(initiallyAllowed: true)
        XCTAssertTrue(replacementGrant.allowed)
        XCTAssertFalse(ack.permissionIsCurrent(), "ACK must retain the old predicate, not recapture a regrant")
        store.completeRetirement(id: rejected.id, owner: rejected.owner)
        XCTAssertNil(store.entry(id: entry.state.id)?.settingsUpdate)
    }

    func testPageRetirementOwnsPendingCompletionButDoesNotReleaseSettledOneTwice() throws {
        for settled in [false, true] {
            let store = PluginUILeaseStore<String>()
            _ = store.replaceScope(accountRecordId: 42)
            let s1 = UUID().uuidString, s2 = UUID().uuidString
            let entry = try store.accept(pluginId: "owned", owner: "owner-1", content: .presentation(self.snapshotModel(s1)), callbacks: [
                "closed": try PluginUICallback(.object(["__handle__": .integer(2)]))])
            let ticket = try store.reserveSettingsUpdate(id: entry.state.id, pluginId: "owned", owner: "owner-1",
                patch: .object(["settingsSnapshotId": .string(s2)]), request: self.updateRequest(from: s1, to: s2), expectedScope: entry.state.scope, admission: {})
            let ack = settled ? store.finishSettingsUpdate(id: entry.state.id, updateId: ticket.id) : nil
            let retired = try XCTUnwrap(store.finish(id: entry.state.id, notify: false))
            XCTAssertEqual(Set(retired.handles + (ack?.handles ?? [])), [2, 3])
            XCTAssertEqual(retired.handles.count + (ack?.handles.count ?? 0), 2)
            XCTAssertNil(store.finishSettingsUpdate(id: entry.state.id, updateId: ticket.id))
        }
    }
}

@MainActor private final class MCAHeldOperation {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; self.entered = true }
    }
    func release() { let continuation = self.continuation; self.continuation = nil; continuation?.resume() }
}

private final class MCAAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(initiallyAllowed: Bool = false) { self.value = initiallyAllowed }
    var allowed: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.value }
    func open() { self.lock.lock(); self.value = true; self.lock.unlock() }
    func revoke() { self.lock.lock(); self.value = false; self.lock.unlock() }
}

private final class MCATrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { self.lock.lock(); self.storage.append(value); self.lock.unlock() }
    var values: [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
}
