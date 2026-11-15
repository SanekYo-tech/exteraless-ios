import Foundation
import XCTest

final class NativeUIContractsTests: XCTestCase {
    private typealias Store = PluginUILeaseStore<String>

    private func callback(_ value: Int64) throws -> PluginUICallback {
        try PluginUICallback(.object(["__handle__": .integer(value)]))
    }

    private func model() throws -> PluginUIModel {
        try PluginUIModel(kind: .alert, value: .object([:]))
    }

    func testNativeHandlePreservesInt64AndRejectsNonHandles() throws {
        XCTAssertEqual(try callback(9_007_199_254_740_993).handle, 9_007_199_254_740_993)
        for value in ["{\"__handle__\":0}", "{\"__handle__\":-1}", "{\"__handle__\":true}", "{\"__handle__\":1.5}"] {
            XCTAssertThrowsError(try PluginUICallback(PluginUIJSON.decode(value)))
        }
    }

    func testAcceptanceDoesNotInventAppearanceAndTerminalReleaseIsUnique() throws {
        let store = Store()
        _ = store.replaceScope(accountRecordId: 42)
        let lease = try store.accept(pluginId: "p", owner: "generation-one", content: .presentation(model()),
                                     callbacks: ["show": callback(1), "closed": callback(2)])
        XCTAssertFalse(lease.state.isPresented)
        XCTAssertFalse(try XCTUnwrap(store.beginPresentation(id: lease.state.id)).state.isPresented)
        XCTAssertNotNil(store.observeVisibility(id: lease.state.id, visible: true))
        XCTAssertNil(store.observeVisibility(id: lease.state.id, visible: true))
        let retired = try XCTUnwrap(store.finish(id: lease.state.id))
        XCTAssertEqual(Set(retired.handles), Set([Int64(1), Int64(2)]))
        XCTAssertNil(store.finish(id: lease.state.id))
    }

    func testAccountAndRenderedRevisionCannotRetargetAnOldButton() throws {
        let store = Store()
        _ = store.replaceScope(accountRecordId: 42)
        let lease = try store.accept(pluginId: "p", owner: "generation-one", content: .presentation(model()),
                                     callbacks: ["positive": callback(3)])
        _ = store.beginPresentation(id: lease.state.id)
        _ = store.observeVisibility(id: lease.state.id, visible: true)
        _ = try store.update(id: lease.state.id, pluginId: "p", patch: .object(["title": .string("new")]))
        XCTAssertFalse(store.action(id: lease.state.id, revision: 0, scope: lease.state.scope,
                                    name: "positive", payload: [:]).accepted)
        _ = store.replaceScope(accountRecordId: 43)
        _ = store.replaceScope(accountRecordId: 42)
        XCTAssertNotEqual(store.currentScope, lease.state.scope)
        XCTAssertFalse(store.action(id: lease.state.id, revision: 1, scope: lease.state.scope,
                                    name: "positive", payload: [:]).accepted)
    }

    func testCallbackHandlesCannotBeReusedAcrossLiveLeases() throws {
        let store = Store()
        _ = store.replaceScope(accountRecordId: 42)
        _ = try store.accept(pluginId: "p", owner: "g", content: .presentation(model()),
                             callbacks: ["positive": callback(4)])
        XCTAssertThrowsError(try store.accept(pluginId: "p", owner: "g", content: .presentation(model()),
                                              callbacks: ["negative": callback(4)]))
        XCTAssertNoThrow(try store.accept(pluginId: "other", owner: "other-g", content: .presentation(model()),
                                          callbacks: ["negative": callback(4)]))
    }
}
