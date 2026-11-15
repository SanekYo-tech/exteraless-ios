import Foundation
import XCTest
@testable import PluginHost

private final class ExtensionFixture: PluginBridgeExtension, @unchecked Sendable {
    let exportedMethods: [String: Set<String>]
    let received = Recorder<String>()
    let released = Recorder<String>()
    let handle: @Sendable (String, String) throws -> String?
    let cleanup: @Sendable (String) -> Void

    init(methods: [String: Set<String>] = [:],
         handle: @escaping @Sendable (String, String) throws -> String?,
         cleanup: @escaping @Sendable (String) -> Void = { _ in }) {
        self.exportedMethods = methods
        self.handle = handle
        self.cleanup = cleanup
    }
    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        received.append(pluginId)
        return try handle(requestJSON, pluginId)
    }
    func releaseInstances(pluginId: String) {
        released.append(pluginId)
        cleanup(pluginId)
    }
}

final class PluginBridgeExtensionTests: XCTestCase {
    private let request = "{\"op\":\"call\",\"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"extraOperation\",\"args\":[],\"pluginId\":\"forged\"}"

    func testExtensionsReceiveValidatedNativeIdentityAndPreserveNull() throws {
        let provider = ExtensionFixture(handle: { json, owner in
            let object = try JSONDecoder().decode(PluginJSONValue.self, from: Data(json.utf8))
            guard case .object(let fields) = object, fields["pluginId"] == .string(owner) else {
                throw BridgeFailure.permission("untrusted owner")
            }
            return try PluginBridgeJSON.success(.null)
        })
        let bridge = BridgeServices()
        bridge.extensionProvider = provider
        let reply = try JSONDecoder().decode(PluginJSONValue.self, from: Data(bridge.dispatchJSON(request, pluginId: "owner").utf8))
        XCTAssertEqual(reply, .object(["ok": .bool(true), "value": .null]))
        XCTAssertEqual(provider.received.values, ["owner"])
    }

    func testMalformedRequestNeverReachesAnExtension() {
        let provider = ExtensionFixture(handle: { _, _ in try PluginBridgeJSON.success(.bool(true)) })
        let bridge = BridgeServices()
        bridge.extensionProvider = provider
        let reply = bridge.dispatchJSON("{\"op\":\"invented\",\"fqcn\":\"exteraless.ios.Runtime\"}", pluginId: "owner")
        XCTAssertTrue(reply.contains("MalformedRequest"))
        XCTAssertTrue(provider.received.values.isEmpty)
    }

    func testCanonicalNativeEnvelopeRetainsOriginalNumericTokens() throws {
        let captured = Recorder<String>()
        let provider = ExtensionFixture(handle: { json, _ in
            captured.append(json)
            return try PluginBridgeJSON.success(.null)
        })
        let bridge = BridgeServices()
        bridge.extensionProvider = provider
        let input = "{\"op\":\"call\", \"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"getClientSetting\",\"pluginId\":\"owner\",\"args\":[\"unknown\",18446744073709551615]}"
        let reply = try JSONDecoder().decode(PluginJSONValue.self, from: Data(bridge.dispatchJSON(input, pluginId: "owner").utf8))
        XCTAssertEqual(reply, .object(["ok": .bool(true), "value": .null]))
        XCTAssertEqual(captured.values, [input])
    }

    func testInstalledExtensionDiscoveryDoesNotDispatchOrAdvertiseAbsentMethods() throws {
        let first = ExtensionFixture(methods: ["exteraless.ios.Runtime": ["uiPresent"]], handle: { _, _ in
            throw BridgeFailure.malformed("Discovery must not enter the side-effecting dispatcher")
        })
        let second = ExtensionFixture(methods: ["exteraless.ios.Runtime": ["tlRequest"]], handle: { _, _ in nil })
        let bridge = BridgeServices()
        bridge.extensionProvider = CompositePluginBridgeExtension([first, second])
        func kind(_ member: String) throws -> PluginJSONValue {
            let json = "{\"op\":\"member_kind\",\"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"\(member)\"}"
            return try JSONDecoder().decode(PluginJSONValue.self, from: Data(bridge.dispatchJSON(json, pluginId: "owner").utf8))
        }
        XCTAssertEqual(try kind("uiPresent"), .object(["ok": .bool(true), "value": .string("method")]))
        XCTAssertEqual(try kind("tlRequest"), .object(["ok": .bool(true), "value": .string("method")]))
        XCTAssertEqual(try kind("madeUpNativeAPI"), .object(["ok": .bool(true), "value": .string("unknown")]))
        XCTAssertTrue(first.received.values.isEmpty)
        XCTAssertTrue(second.received.values.isEmpty)
        bridge.extensionProvider = nil
        XCTAssertEqual(try kind("uiPresent"), .object(["ok": .bool(true), "value": .string("unknown")]))
    }

    func testCompositeFallthroughAndMalformedProviderReply() {
        let first = ExtensionFixture(handle: { _, _ in nil })
        let second = ExtensionFixture(handle: { _, _ in "{\"ok\":true}" })
        let bridge = BridgeServices()
        bridge.extensionProvider = CompositePluginBridgeExtension([first, second])
        XCTAssertTrue(bridge.dispatchJSON(request, pluginId: "owner").contains("omitted value"))
        XCTAssertEqual(first.received.values, ["owner"])
        XCTAssertEqual(second.received.values, ["owner"])
        bridge.extensionProvider = first
        XCTAssertTrue(bridge.dispatchJSON(request, pluginId: "owner").contains("\"ok\":false"))
    }

    func testProviderCleanupCanReenterBridgeOutsideItsLock() async throws {
        let bridge = BridgeServices()
        let provider = ExtensionFixture(handle: { _, _ in nil }, cleanup: { _ in
            _ = bridge.liveInstanceCount
            _ = bridge.onCallback
        })
        bridge.extensionProvider = provider
        let finished = OneShotResult<Void>()
        DispatchQueue.global().async {
            bridge.releaseInstances(pluginId: "owner")
            finished.succeed(())
        }
        _ = try await withDispatchTimeout(2) { try await finished.awaitValue() }
        XCTAssertEqual(provider.released.values, ["owner"])
        bridge.extensionProvider = nil // Break the fixture-only closure cycle.
    }

    func testCallbackLeaseReleaseFollowsQueuedInvocation() async throws {
        let directory = tempDirectory("extension-callbacks")
        let engine = FakeEngine()
        engine.scriptResponse = { source in
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                return "{\"metadata\":{\"id\":\"callbackOwner\"},\"handles\":{},\"has_settings\":false}"
            }
            return "null"
        }
        let host = try PluginHost(engine: engine, configuration: .init(
            runtime: .init(pluginRootDirectory: directory.appendingPathComponent("plugins").path),
            storageDirectory: directory))
        addTeardownBlock {
            await host.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try await host.start(safeMode: true)
        let source = directory.appendingPathComponent("fixture.plugin")
        try Data("# fake-engine fixture".utf8).write(to: source)
        let installed = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "callbackOwner"))
        XCTAssertTrue(installed.loaded)
        let dispatcher = PluginCallbackDispatcher(host: host)
        let owner = try XCTUnwrap(dispatcher.captureOwner("callbackOwner"))
        for handle in Int64(1)...Int64(16) {
            XCTAssertTrue(dispatcher.callback(owner, handle, "run", "[]"))
            dispatcher.release(owner, [handle])
        }
        let completed = await waitUntil({ engine.scripts.filter { $0.hasPrefix("_exteraless_runtime.release_handles_json(") }.count == 16 }, timeout: 3)
        XCTAssertTrue(completed)
        let work = engine.scripts.filter { $0.hasPrefix("_exteraless_runtime.invoke_handle_json(") || $0.hasPrefix("_exteraless_runtime.release_handles_json(") }
        XCTAssertEqual(work.count, 32)
        if work.count == 32 {
            for index in 0..<16 {
                XCTAssertTrue(work[index * 2].hasPrefix("_exteraless_runtime.invoke_handle_json(\(index + 1),"))
                XCTAssertTrue(work[index * 2 + 1].contains("[\(index + 1)]"))
            }
        }
        try await host.reloadPlugin(id: "callbackOwner")
        XCTAssertFalse(dispatcher.callback(owner, 1, "run", "[]"))
        do {
            try await host.releaseCallbackHandles([1], expectedOwner: owner)
            XCTFail("retired leases must not enter a new interpreter")
        } catch PluginHostError.superseded {
        }
    }
}
