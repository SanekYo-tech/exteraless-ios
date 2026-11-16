import Foundation
import PluginHost
import XCTest
@testable import TelegramUI

private final class ElyxIngressFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func clear() { lock.lock(); value = false; lock.unlock() }
    var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class PluginElyxDeveloperProtocolTests: XCTestCase {
    func testAuthenticationPrecedesElyxCommandParsing() throws {
        let token = "own-fixture-native-session"
        for command in ["elyx_ping", "get_elyx_plugins", "elyx_compare_folder", "elyx_changes"] {
            let unauthenticated = Data("{\"@\":\"\(command)\",\"#\":9}".utf8)
            XCTAssertThrowsError(try PluginDeveloperProtocol.request(unauthenticated, token: token))
            let authenticated = Data("{\"@\":\"\(command)\",\"#\":9,\"token\":\"\(token)\"}".utf8)
            var request = try PluginDeveloperProtocol.request(authenticated, token: token)
            XCTAssertEqual(request.removeValue(forKey: "token"), .string(token))
            XCTAssertEqual(request.removeValue(forKey: "#"), .integer(9))
            if command == "elyx_compare_folder" || command == "elyx_changes" {
                request["plugin_id"] = .string("7_archive")
                if command == "elyx_changes" { request["changes"] = .array([]) }
            }
            let parsed = try PluginElyxDeveloperRequest(json: PluginUIJSON.object(request).encoded())
            XCTAssertEqual(parsed.kind.rawValue, command)
        }
    }

    func testNativeResponseDoesNotTurnFailedReloadIntoSuccess() throws {
        let value = PluginDeveloperProtocol.response(id: .integer(42), value: ["ok": .bool(false),
            "reloaded": .bool(false), "errors": .array([.string("source version retired")]), "#": .integer(0)])
        XCTAssertEqual(value.object?["ok"], .bool(false))
        XCTAssertEqual(value.object?["reloaded"], .bool(false))
        XCTAssertEqual(value.object?["#"], .integer(42))
    }

    func testSessionRevocationAndUnknownCommandsStayExplicit() throws {
        let session = PluginDeveloperSession()
        XCTAssertTrue(session.isActive)
        session.cancel()
        XCTAssertFalse(session.isActive)
        XCTAssertThrowsError(try PluginElyxDeveloperRequest(json: "{\"@\":\"elyx_execute\"}")) { error in
            let response = PluginElyxDeveloperError.response(error, request: nil)
            XCTAssertEqual(response["ok"], .bool(false))
            XCTAssertEqual(response["error_kind"], .string("Unimplemented"))
        }
    }

    @MainActor
    private func plan() throws -> PluginElyxDeveloperIngress.Plan {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("elyx-ingress-\(UUID().uuidString)")
        let host = try PluginHost(engine: UnboundCPythonEngine(), configuration: .init(storageDirectory: root))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let token = "own-authenticated-ingress-fixture"
        let wire = Data("{\"@\":\"elyx_changes\",\"plugin_id\":\"7_archive\",\"changes\":[],\"#\":42,\"token\":\"\(token)\"}".utf8)
        let request = try PluginDeveloperProtocol.request(wire, token: token)
        // Actual pure ingress; execution below is an explicit native invocation
        // recorder. The Host is deliberately unstarted and cannot enter Python.
        return try PluginElyxDeveloperIngress.capture(request, host: host, account: 2, targets: { _ in [] })
    }

    @MainActor
    func testActualIngressPreservesAllPublicationFailureOutcomesAndOriginalEnvelope() async throws {
        for (outcome, changed) in [(PluginElyxDeveloperPublicationFailure.Outcome.refused, PluginUIJSON.bool(false)),
                                   (.rolledBack, .bool(false)), (.committed, .bool(true)), (.recoveryRequired, .null)] {
            let plan = try plan()
            let original = BridgeFailure.storage("owned directory durability failure")
            let failure = PluginElyxDeveloperPublicationFailure(outcome: outcome, detail: original.description, underlying: original)
            let result = await PluginElyxDeveloperIngress.run(plan, session: PluginDeveloperSession(), files: nil,
                nativeCurrent: { true }, execute: { call in
                    XCTAssertEqual(call.account, 2)
                    XCTAssertEqual(call.request.pluginId, "7_archive")
                    throw failure
                }, actorCurrent: { true })
            let value = try XCTUnwrap(PluginDeveloperProtocol.response(id: .integer(42), value: result).object)
            XCTAssertEqual(value["#"], .integer(42))
            XCTAssertEqual(value["ok"], .bool(false))
            XCTAssertEqual(value["plugin_id"], .string("7_archive"))
            XCTAssertEqual(value["reloaded"], .bool(false))
            XCTAssertEqual(value["error_kind"], .string("StorageError"))
            XCTAssertEqual(value["error"], .string(failure.description))
            XCTAssertEqual(value["errors"], .array([.string(failure.description)]))
            XCTAssertEqual(value["publication_outcome"], .string(outcome.rawValue))
            XCTAssertEqual(value["source_changed"], changed)
            XCTAssertNil(value["token"])
        }
    }

    @MainActor
    func testActualIngressLateSessionAndActorGuardsKeepSuccessfulPublication() async throws {
        for retireSession in [true, false] {
            let plan = try plan(), session = PluginDeveloperSession(), actor = ElyxIngressFlag()
            let result = await PluginElyxDeveloperIngress.run(plan, session: session, files: nil,
                nativeCurrent: { true }, execute: { call in
                    call.publication?.record(.committed)
                    if retireSession { session.cancel() } else { actor.clear() }
                    return ["ok": .bool(true), "plugin_id": .string("7_archive"), "reloaded": .bool(true),
                            "errors": .array([]), "publication_outcome": .string("committed"), "source_changed": .bool(true)]
                }, actorCurrent: { actor.current })
            let value = try XCTUnwrap(PluginDeveloperProtocol.response(id: .integer(42), value: result).object)
            XCTAssertEqual(value["ok"], .bool(false))
            XCTAssertEqual(value["reloaded"], .bool(false))
            XCTAssertEqual(value["publication_outcome"], .string("committed"))
            XCTAssertEqual(value["source_changed"], .bool(true))
            XCTAssertEqual(value["error_kind"], .string("Superseded"))
            XCTAssertEqual(value["#"], .integer(42))
        }
    }

    @MainActor
    func testActualIngressPostPublishPersistenceOrLoadErrorKeepsKnownState() async throws {
        for boundary in ["persistInstalledPlugin", "verified load", "final owner after read"] {
            let plan = try plan()
            let original = PluginElyxDeveloperError.stale("owned \(boundary) failure")
            let result = await PluginElyxDeveloperIngress.run(plan, session: PluginDeveloperSession(), files: nil,
                nativeCurrent: { true }, execute: { call in
                    call.publication?.record(.committed)
                    throw original
                }, actorCurrent: { true })
            XCTAssertEqual(result["publication_outcome"], .string("committed"))
            XCTAssertEqual(result["source_changed"], .bool(true))
            XCTAssertEqual(result["error_kind"], .string(original.kind))
            XCTAssertEqual(result["error"], .string(original.description))
            XCTAssertEqual(result["errors"], .array([.string(original.description)]))
            XCTAssertEqual(result["plugin_id"], .string("7_archive"))
            XCTAssertEqual(result["reloaded"], .bool(false))
        }
    }

    @MainActor
    func testActualIngressPreAdmissionRefusalNeverExecutesAndReportsZeroWrite() async throws {
        let plan = try plan(), session = PluginDeveloperSession(), untouched = ElyxIngressFlag()
        session.cancel()
        let result = await PluginElyxDeveloperIngress.run(plan, session: session, files: nil,
            nativeCurrent: { true }, execute: { _ in untouched.clear(); return [:] }, actorCurrent: { true })
        XCTAssertTrue(untouched.current)
        XCTAssertEqual(result["publication_outcome"], .string("refused"))
        XCTAssertEqual(result["source_changed"], .bool(false))
        XCTAssertEqual(result["reloaded"], .bool(false))
    }
}
