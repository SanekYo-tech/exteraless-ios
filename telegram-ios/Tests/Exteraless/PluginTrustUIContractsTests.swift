import Foundation
import PluginHost
import XCTest

/// Shipping editor draft and native UI lease contracts. These do not claim
/// recorded UIKit appearance, an account, a Python engine or a network provider.
final class PluginTrustUIContractsTests: XCTestCase {
    func testInstallDraftStartsAtZeroAndOnlyActualSelectionGrantsPermissions() throws {
        var draft = PluginTrustSelection()
        XCTAssertEqual(draft.record, PluginPermissionRecord())
        XCTAssertThrowsError(try draft.select(.network, granted: true))
        draft.selectLevel(.gated)
        XCTAssertTrue(draft.grants.isEmpty)
        try draft.select(.network, granted: true)
        XCTAssertThrowsError(try draft.select(.hooks, granted: true))
        draft.selectLevel(.trusted)
        XCTAssertEqual(draft.grants, [.network])
        try draft.select(.hooks, granted: true)
        draft.selectLevel(.gated)
        draft.selectLevel(.trusted)
        XCTAssertEqual(draft.grants, [.network])
        draft.selectLevel(.isolated)
        draft.selectLevel(.trusted)
        XCTAssertTrue(draft.grants.isEmpty)
    }

    func testPermissionLowerRetiresShareAndItsQueuedBodyButKeepsUICleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trust-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try PluginStore(directory: root)
        let permissions = PermissionsModel()
        try permissions.setConsent("alpha", level: .gated, permissions: [.intents], to: disk)
        let current = permissions.futurePredicate("alpha", requiring: [.ui, .intents])
        typealias Store = PluginUILeaseStore<String>
        var limits = Store.Limits()
        limits.terminalHistory = 0 // The captured predicate must outlive history.
        let ui = Store(limits: limits)
        _ = ui.replaceScope(accountRecordId: 7)
        let callbacks = try PluginUICallback.map(.object([
            "action": .object(["__handle__": .integer(101)]),
            "closed": .object(["__handle__": .integer(102)])
        ]))
        let entry = try ui.accept(pluginId: "alpha", owner: "owner:1",
            content: .presentation(PluginUIModel(kind: .share, value: .object(["text": .string("fixture")]))),
            callbacks: callbacks, permissionIsCurrent: current)
        _ = try ui.accept(pluginId: "alpha", owner: "owner:1",
            content: .presentation(PluginUIModel(kind: .alert, value: .object([:]))), callbacks: [:])
        XCTAssertNotNil(ui.beginPresentation(id: entry.state.id))
        _ = ui.observeVisibility(id: entry.state.id, visible: true)
        let queued = try XCTUnwrap(ui.action(id: entry.state.id, revision: 0, scope: entry.state.scope,
            name: "action", payload: [:], dismissReason: "completed").delivery)
        XCTAssertTrue(queued.permissionIsCurrent())
        try permissions.setLevel("alpha", .isolated, to: disk)
        let retired = ui.retirePermissions(pluginId: "alpha")
        XCTAssertEqual(retired.count, 1)
        XCTAssertEqual(ui.liveCount, 1, "UI-only presentations remain allowed")
        try permissions.setConsent("alpha", level: .gated, permissions: [.intents], to: disk)
        XCTAssertFalse(queued.permissionIsCurrent(), "A retained old body must not recover after regrant")
        let closed = try XCTUnwrap(retired.first?.deliveries.first {
            $0.arguments.array?.first?.object?["event"] == .string("closed")
        })
        XCTAssertTrue(closed.permissionIsCurrent(), "Closing bookkeeping still uses the captured owner FIFO")
        XCTAssertEqual(retired.first?.handles, [101, 102])
    }
}
