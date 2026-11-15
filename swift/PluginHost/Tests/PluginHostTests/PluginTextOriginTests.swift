import Foundation
import XCTest
@testable import PluginHost

private final class TextOriginRecordingService: PluginUIService, PluginPlatformService, @unchecked Sendable {
    let serviceStorage = PluginServiceStorage(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-text-origin-fixture"))
    let serviceLogs = PluginServiceLogBuffer()
    let runtimeVersion = "text-origin-fixture"
    let requests = Recorder<PluginTextMessageRequest>()
    let platformSnapshot = PluginPlatformSnapshot(
        accounts: [PluginServiceAccount(index: 0, recordId: 41, userId: 42)], selectedAccountIndex: 0)

    func dp(_ value: Double) throws -> Double { throw BridgeFailure.unimplemented("unused fixture operation") }
    func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void) {}
    func constructUI(fqcn: String, arguments: [Any]) throws -> Int64 {
        throw BridgeFailure.unimplemented("unused fixture operation")
    }
    func sendMessage(_ request: PluginTextMessageRequest, lease: PluginNativeCallLease) throws -> String {
        try lease.check()
        requests.append(request)
        return "recorded-text-request"
    }
}

final class PluginTextOriginTests: HostLifecycleTestCase {
    private static func arguments(_ source: String, method: String) throws -> [String]? {
        let prefix = "_exteraless_runtime.\(method)("
        guard source.hasPrefix(prefix) else { return nil }
        return try JSONDecoder().decode([String].self, from: Data(("[" + String(source.dropFirst(prefix.count).dropLast()) + "]").utf8))
    }

    private static func send(_ bridge: BridgeServices, pluginId: String, token: String?, forgedOrigin: Bool = false) throws -> [String: Any] {
        var request: [String: Any] = ["op": "call", "fqcn": BridgeServices.runtimeClassName,
            "member": "sendMessage", "args": [42, "child", 0]]
        if let token { request["ownerToken"] = token }
        if forgedOrigin {
            request["originPluginIds"] = ["beta"]
            request["originRootId"] = "untrusted-root"
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = bridge.dispatchJSON(json, pluginId: pluginId)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func payload(_ origin: PluginTLInvocationOrigin? = nil) -> PluginTLHostPayload {
        PluginTLHostPayload(kind: .preRequest, account: 0, name: "TL_messages_sendMessage",
            canonicalName: "messages.sendMessage", valueJSON: "{}", metadataJSON: "{}", errorJSON: nil,
            canCancel: true, originPluginIds: origin?.pluginIds ?? [], originRootId: origin?.rootId,
            normalize: { $0 }, shouldExecute: { true })
    }

    func testLegacyTextBridgeKeepsAncestryAcrossNativeHopAndSkipsOnlyItsAncestor() async throws {
        let services = TextOriginRecordingService()
        let bridge = BridgeServices(ui: services)
        let hostBox = MaintenanceTestHostBox()
        let owners = Recorder<(InterpRef, String)>()
        let hooks = Recorder<String>()
        let accepted = Recorder<Bool>()
        let emitChild = MaintenanceTestFlag()
        let engine = MaintenanceTestEngine(onScript: { reference, source in
            if let args = try Self.arguments(source, method: "load_json") {
                let id = URL(fileURLWithPath: args[0]).deletingPathExtension().lastPathComponent
                owners.append((reference, id))
                return "{\"metadata\":{\"id\":\"\(id)\"},\"handles\":{\"pre_request\":true},\"has_settings\":false}"
            }
            if source.hasPrefix("_exteraless_runtime.hook_priority_json(") { return "0" }
            guard let args = try Self.arguments(source, method: "dispatch_json"), args[0] == "pre_request_hook",
                  let id = owners.values.first(where: { $0.0.raw == reference.raw })?.1 else { return nil }
            hooks.append(id)
            if id == "alpha", emitChild.value {
                emitChild.set(false)
                guard let owner = hostBox.get()?.callbackOwner(id: id) else { throw PluginHostError.notRunning }
                // Models the synchronous C reverse call while Host's real mailbox
                // has installed this hook's thread-local scope.
                let reply = try Self.send(bridge, pluginId: id, token: owner.wireToken)
                accepted.append(reply["ok"] as? Bool == true)
            }
            return "{\"strategy\":\"DEFAULT\"}"
        })
        let fixture = try self.fixture(engine: engine)
        hostBox.set(fixture.host)
        try await load(fixture, "alpha")
        try await load(fixture, "beta")
        _ = try await fixture.host.events.transformTL(payload())
        XCTAssertEqual(accepted.values, [true])
        let captured = try XCTUnwrap(services.requests.values.first?.origin)
        XCTAssertEqual(captured.pluginIds, ["alpha"])

        // Native preparation happens after the hook returns, on a different Task.
        let forwarded = await Task.detached { services.requests.values.first }.value
        XCTAssertEqual(forwarded?.origin, captured)
        _ = try await fixture.host.events.transformTL(payload(forwarded?.origin))
        XCTAssertEqual(hooks.values, ["alpha", "beta", "beta"])

        let owner = try XCTUnwrap(fixture.host.callbackOwner(id: "alpha"))
        let ordinary = try Self.send(bridge, pluginId: "alpha", token: owner.wireToken, forgedOrigin: true)
        XCTAssertEqual(ordinary["ok"] as? Bool, true)
        XCTAssertNil(services.requests.values.last?.origin)
        _ = try await fixture.host.events.transformTL(payload(services.requests.values.last?.origin))
        XCTAssertEqual(hooks.values, ["alpha", "beta", "beta", "alpha", "beta"])
    }

    private func withScope<T>(owner: PluginHost.CallbackOwner, origin: PluginTLInvocationOrigin,
                              _ body: (PluginTLInvocationScope) throws -> T) rethrows -> T {
        let registry = PluginTLOriginRegistry()
        let scope = PluginTLInvocationScope(owner: owner, origin: origin, registry: registry)
        PluginTLNativeOrigin.install(scope)
        defer { scope.close(); PluginTLNativeOrigin.install(nil) }
        return try withExtendedLifetime(registry) { try body(scope) }
    }

    func testLegacyTextCannotReplaceNativeAncestryOrBorrowAnotherOwnersScope() async throws {
        let fixture = try self.fixture()
        try await load(fixture)
        let owner = try XCTUnwrap(fixture.host.callbackOwner(id: "alpha"))
        let services = TextOriginRecordingService()
        let bridge = BridgeServices(ui: services)
        let origin = try PluginTLInvocationOrigin(rootId: "native-root", pluginIds: ["alpha"])
        try withScope(owner: owner, origin: origin) { _ in
            let valid = try Self.send(bridge, pluginId: "alpha", token: owner.wireToken, forgedOrigin: true)
            XCTAssertEqual(valid["ok"] as? Bool, true)
            XCTAssertEqual(services.requests.values.first?.origin, origin)
            for (id, token) in [("alpha", "different-epoch"), ("beta", owner.wireToken)] {
                let rejected = try Self.send(bridge, pluginId: id, token: token)
                XCTAssertEqual(rejected["ok"] as? Bool, false)
            }
            XCTAssertEqual(services.requests.count, 1)
        }
    }

    func testExpiredAndDepthLimitedHookTextIsRejectedBeforeNativeScheduling() async throws {
        let fixture = try self.fixture()
        try await load(fixture)
        let owner = try XCTUnwrap(fixture.host.callbackOwner(id: "alpha"))
        let services = TextOriginRecordingService()
        let bridge = BridgeServices(ui: services)
        let origin = try PluginTLInvocationOrigin(rootId: "native-root", pluginIds: ["alpha"])
        try withScope(owner: owner, origin: origin) { scope in
            scope.close()
            XCTAssertEqual(try Self.send(bridge, pluginId: "alpha", token: owner.wireToken)["ok"] as? Bool, false)
        }
        let limited = try PluginTLInvocationOrigin(rootId: "native-root", pluginIds: ["alpha"] + (0 ..< 31).map { "ancestor\($0)" })
        try withScope(owner: owner, origin: limited) { _ in
            XCTAssertEqual(try Self.send(bridge, pluginId: "alpha", token: owner.wireToken)["ok"] as? Bool, false)
        }
        XCTAssertEqual(services.requests.count, 0)
    }
}
