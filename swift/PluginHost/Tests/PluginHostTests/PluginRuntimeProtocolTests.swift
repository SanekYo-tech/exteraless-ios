import Foundation
import XCTest
@testable import PluginHost

final class PluginRuntimeProtocolTests: XCTestCase {
    private func payload(_ script: String) throws -> [String: Any] {
        let prefix = "_exteraless_runtime.dispatch_json("
        XCTAssertTrue(script.hasPrefix(prefix))
        let arguments = "[" + String(script.dropFirst(prefix.count).dropLast()) + "]"
        let decoded = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
        return try XCTUnwrap(PluginRuntimeScript.jsonValue(decoded[1]) as? [String: Any])
    }

    func testEventPayloadRemainsJSONData() throws {
        let data = try payload(PluginScriptBuilder.dispatch(for: .sendMessage(SendMessagePayload(
            account: 2, paramsJSON: "{\"text\":\"quote'\\n雪\",\"flag\":false,\"optional\":null}"))))
        let params = try XCTUnwrap(data["params"] as? [String: Any])
        XCTAssertEqual(params["text"] as? String, "quote'\n雪")
        XCTAssertEqual(params["flag"] as? Bool, false)
        XCTAssertTrue(params["optional"] is NSNull)
    }

    func testCoalescedContainersAreNotDropped() throws {
        let event = PluginEvent.coalescedUpdates(CoalesceKey(account: 1, container: "updates"), [
            .update(UpdatePayload(updateName: "one", account: 1, updateJSON: "{\"id\":1}")),
            .updates(UpdatesPayload(containerName: "batch", account: 1, updatesJSON: ["{\"id\":2}", "{\"id\":3}"])),
        ])
        let script = try PluginScriptBuilder.dispatch(for: event)
        XCTAssertTrue(script.hasPrefix("["))
        XCTAssertTrue(script.hasSuffix("]"))
        XCTAssertTrue(script.contains("\"on_update_hook\""))
        XCTAssertTrue(script.contains("\"on_updates_hook\""))
        XCTAssertTrue(script.contains("\\\"id\\\":3"))
    }

    func testMetadataUsesSDKSnakeCaseFields() throws {
        let plugin = try PluginRuntimeScript.metadata("""
        {"ok":true,"meta":{"id":"metadataTest","name":"Test","app_version":">=13","sdk_version":"1","permissions_declared":true,"permissions":["messages.read"]}}
        """)
        XCTAssertEqual(plugin.appVersion, ">=13")
        XCTAssertEqual(plugin.sdkVersion, "1")
        XCTAssertTrue(plugin.permissionsDeclared)
    }

    func testLoadResultMustMatchInstalledIdentity() throws {
        XCTAssertThrowsError(try PluginRuntimeScript.applyLoadResult(
            "{\"metadata\":{\"id\":\"other\"},\"handles\":{},\"has_settings\":false}",
            to: Plugin(id: "installed")))
    }

    func testModifyCarriesItsPayloadAndRejectsMissingReplacement() throws {
        let result = try PluginRuntimeScript.sendResult("{\"strategy\":\"MODIFY\",\"params\":{\"text\":\"changed\"}}")
        XCTAssertEqual(result.strategy, .modify)
        XCTAssertEqual(try PluginRuntimeScript.jsonValue(try XCTUnwrap(result.paramsJSON)) as? [String: String],
                       ["text": "changed"])
        XCTAssertThrowsError(try PluginRuntimeScript.sendResult("{\"strategy\":\"MODIFY\",\"params\":null}"))
    }

    func testHostRestoresPersistedPluginMetadata() throws {
        let directory = tempDirectory("restored")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PluginStore(directory: directory)
        try store.savePlugins([Plugin(id: "savedPlugin", enabled: false)])
        let host = try PluginHost(engine: FakeEngine(), configuration: .init(storageDirectory: directory))
        XCTAssertEqual(host.pluginList().map(\.id), ["savedPlugin"])
        XCTAssertEqual(host.pluginList().first?.loaded, false)
        XCTAssertEqual(host.pluginList().first?.enabled, false)
    }

    func testSparseSendPatchesPreserveIdentityAndEarlierPluginEdits() throws {
        let first = try PluginRuntimeScript.applyingSendResult(
            "{\"strategy\":\"MODIFY\",\"params\":{\"text\":\"first edit\"}}",
            to: "{\"peerId\":9007199254740993,\"text\":\"original\",\"silent\":false}")
        let second = try PluginRuntimeScript.applyingSendResult(
            "{\"strategy\":\"MODIFY_FINAL\",\"params\":{\"silent\":true}}",
            to: XCTUnwrap(first.paramsJSON))
        let params = try XCTUnwrap(PluginRuntimeScript.jsonValue(XCTUnwrap(second.paramsJSON)) as? [String: Any])
        XCTAssertEqual(params["peerId"] as? Int64, 9_007_199_254_740_993)
        XCTAssertEqual(params["text"] as? String, "first edit")
        XCTAssertEqual(params["silent"] as? Bool, true)
        XCTAssertEqual(second.strategy, .modifyFinal)
    }

    func testScalarModifyCannotReplaceAnEntireSendSnapshot() throws {
        XCTAssertThrowsError(try PluginRuntimeScript.applyingSendResult(
            "{\"strategy\":\"MODIFY\",\"params\":42}", to: "{\"text\":\"original\"}"))
    }
}
