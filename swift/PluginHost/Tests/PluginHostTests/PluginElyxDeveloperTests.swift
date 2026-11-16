import Foundation
import XCTest
@testable import PluginHost

// Independent Python zipfile ZIP_STORED bytes, generated from six owned files.
private let elyxZIP = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwvAoB+OwAAADsAAAALAAAAcmVmbWFwLmpzb257Im1haW4iOiJtYWluLnB5IiwibWV0YWluZm8iOiJtZXRhLmpzb24iLCJhc3NldHMiOiJhc3NldHMifVBLAwQUAAAAAAAAACFcBX5/kSoAAAAqAAAACQAAAG1ldGEuanNvbnsiaWQiOiJlbHl4Rml4dHVyZSIsIm5hbWUiOiJFbHl4IGZpeHR1cmUifVBLAwQUAAAAAAAAACFcLwFHHkEAAABBAAAABwAAAG1haW4ucHlmcm9tIGJhc2VfcGx1Z2luIGltcG9ydCBCYXNlUGx1Z2luCmNsYXNzIFByb2JlKEJhc2VQbHVnaW4pOiBwYXNzClBLAwQUAAAAAAAAACFc5dRdPwMAAAADAAAABwAAAG9sZC50eHRvbGRQSwMEFAAAAAAAAAAhXB4lGx8EAAAABAAAAAwAAABkaXIvaXRlbS50eHRpdGVtUEsDBBQAAAAAAAAAIVyGphA2BQAAAAUAAAAQAAAAYXNzZXRzL2hlbGxvLnR4dGhlbGxvUEsBAhQAFAAAAAAAAAAhXC8CgH47AAAAOwAAAAsAAAAAAAAAAAAAAIABAAAAAHJlZm1hcC5qc29uUEsBAhQAFAAAAAAAAAAhXAV+f5EqAAAAKgAAAAkAAAAAAAAAAAAAAIABZAAAAG1ldGEuanNvblBLAQIUABQAAAAAAAAAIVwvAUceQQAAAEEAAAAHAAAAAAAAAAAAAACAAbUAAABtYWluLnB5UEsBAhQAFAAAAAAAAAAhXOXUXT8DAAAAAwAAAAcAAAAAAAAAAAAAAIABGwEAAG9sZC50eHRQSwECFAAUAAAAAAAAACFcHiUbHwQAAAAEAAAADAAAAAAAAAAAAAAAgAFDAQAAZGlyL2l0ZW0udHh0UEsBAhQAFAAAAAAAAAAhXIamEDYFAAAABQAAABAAAAAAAAAAAAAAAIABcQEAAGFzc2V0cy9oZWxsby50eHRQSwUGAAAAAAYABgBSAQAApAEAAAAA")!

/// Native file-authority CONTRACT RECORDER, not an FD implementation. It only
/// changes memory. Live file tests must use the archive owner's reviewed provider.
private final class ElyxFileRecorder: PluginElyxDeveloperFileAuthority, PluginElyxDeveloperSource, PluginElyxDeveloperPrepared, @unchecked Sendable {
    let archiveBytes = elyxZIP
    let sha256 = String(repeating: "a", count: 64)
    let metadata: Plugin
    let valid = MaintenanceTestFlag()
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    private var candidate: Data?
    private let onPublish: @Sendable () throws -> Void

    init(_ plugin: Plugin, onPublish: @escaping @Sendable () throws -> Void = {}) { metadata = plugin; self.onPublish = onPublish }
    var operations: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    var preparedBytes: Data? { lock.lock(); defer { lock.unlock() }; return candidate }
    func open(_ target: PluginElyxDeveloperTarget) throws -> any PluginElyxDeveloperSource {
        try checkCurrent()
        lock.lock(); counts[0] += 1; lock.unlock()
        return self
    }
    func checkCurrent() throws { if !valid.value { throw PluginElyxDeveloperError.stale("fixture source/namespace changed") } }
    func prepare(_ bytes: Data, shouldExecute: @escaping @Sendable () -> Bool) async throws -> any PluginElyxDeveloperPrepared {
        guard shouldExecute() else { throw PluginElyxDeveloperError.stale("fixture staging refused") }
        try checkCurrent()
        recordCandidate(bytes)
        return self
    }
    private func recordCandidate(_ value: Data) { lock.lock(); counts[1] += 1; candidate = value; lock.unlock() }
    func checkBeforePublication() throws { try checkCurrent() }
    func publish(shouldExecute: @escaping @Sendable () -> Bool) throws {
        guard shouldExecute() else { throw PluginElyxDeveloperError.stale("fixture publication refused") }
        try checkCurrent()
        lock.lock(); counts[2] += 1; lock.unlock()
        try onPublish()
    }
    func checkPublished() throws { try checkCurrent() }
    func loadSource(owner: PluginHost.CallbackOwner) throws -> any PluginElyxDeveloperDescriptorLease {
        throw PluginElyxDeveloperError.unavailable("recorder does not implement the production verified-load FD ABI")
    }
}

final class PluginElyxDeveloperTests: HostLifecycleTestCase {
    private func owner() async throws -> (MaintenanceTestFixture, PluginElyxDeveloperTarget) {
        let engine = MaintenanceTestEngine(onScript: { _, source in
            if source.hasPrefix("_exteraless_runtime.metadata_json(") {
                return "{\"id\":\"elyxFixture\",\"name\":\"Owned fixture\",\"version\":\"1.0\"}"
            }
            if source.hasPrefix("_exteraless_runtime.load_json(") {
                return "{\"metadata\":{\"id\":\"elyxFixture\",\"name\":\"Owned fixture\",\"version\":\"1.0\"},\"handles\":{},\"has_settings\":false}"
            }
            let manifest = "_exteraless_runtime._elyx_developer.manifest_json("
            if source.hasPrefix(manifest) {
                let values = try JSONDecoder().decode([String].self, from: Data(("[" + source.dropFirst(manifest.count).dropLast() + "]").utf8))
                return try PluginRuntimeScript.encodeJSON(["ok": true, "source_digest": values[2], "files": [:]])
            }
            return nil
        })
        let fixture = try fixture(engine: engine)
        try await fixture.host.start(safeMode: true)
        let file = fixture.root.appendingPathComponent("owned.elyx")
        try elyxZIP.write(to: file)
        let plugin = try await fixture.host.installPlugin(sourceURL: file, metadata: Plugin(id: "elyxFixture", fileFormat: .elyx))
        let captured = try XCTUnwrap(fixture.host.callbackOwner(id: plugin.id))
        return (fixture, try PluginElyxDeveloperTarget(plugin: plugin, owner: captured, consent: fixture.host.permissionSnapshot(id: plugin.id)))
    }

    private func request(_ name: String, _ params: [String: Any] = [:]) throws -> PluginElyxDeveloperRequest {
        try PluginElyxDeveloperRequest(json: PluginRuntimeScript.encodeJSON(params.merging(["@": name]) { _, new in new }))
    }

    private func workerReply(_ target: PluginElyxDeveloperTarget, digest: String? = nil) throws -> String {
        if let digest {
            return try PluginRuntimeScript.encodeJSON(["ok": true, "source_digest": digest,
                "files": ["main.py": String(repeating: "b", count: 64), "old.txt": String(repeating: "c", count: 64)]])
        }
        return try PluginRuntimeScript.encodeJSON(["ok": true, "version": "1.0.0", "plugin": ["id": target.plugin.id, "version": "1.0"]])
    }

    func testOriginalCommandShapesAndRefusedParameters() throws {
        XCTAssertEqual(try request("elyx_ping").kind, .ping)
        XCTAssertEqual(try request("get_elyx_plugins").kind, .list)
        XCTAssertEqual(try request("elyx_compare_folder", ["plugin_id": "7_archive"]).hashes, [:])
        XCTAssertEqual(try request("elyx_compare_folder", ["plugin_id": "7_archive", "hashes": NSNull()]).hashes, [:])
        XCTAssertTrue(try request("elyx_changes", ["plugin_id": "_archive", "changes": [["#": "created", "path": "empty", "content": NSNull()]]]).changes[0].content.isEmpty)
        let parsed = try request("elyx_changes", ["plugin_id": "_archive", "changes": [
            ["#": "created", "path": "folder", "is_directory": true],
            ["type": "modified", "path": "folder\\file.txt", "content": "aGk="],
            ["#": "moved", "path": "folder", "dest_path": "next"],
            ["#": "deleted", "path": "next/file.txt"],
        ]])
        XCTAssertEqual(parsed.changes.count, 4)
        XCTAssertEqual(parsed.changes[1].path, "folder/file.txt")
        XCTAssertEqual(parsed.changes[1].content, Data("hi".utf8))
        for path in ["../main.py", "/root", "x/../y", "x//y", "C:/root", "x\0y", "CON", "x."] {
            XCTAssertThrowsError(try request("elyx_changes", ["plugin_id": "_archive", "changes": [["#": "deleted", "path": path]]]))
        }
        XCTAssertThrowsError(try request("elyx_unknown"))
        XCTAssertThrowsError(try request("elyx_ping", ["token": "must-already-be-stripped"]))
        XCTAssertThrowsError(try request("elyx_changes", ["plugin_id": "_archive", "changes": [["#": "modified", "type": "deleted", "path": "x"]]]))
        XCTAssertThrowsError(try request("elyx_changes", ["plugin_id": "_archive", "changes": [["#": "modified", "path": "x", "content": "%%%"]]]))
        XCTAssertThrowsError(try request("elyx_changes", ["plugin_id": "_archive", "changes": Array(repeating: ["#": "deleted", "path": "x"], count: 129)]))
    }

    func testNativeZIPChangesKeepUnchangedBodiesAndRejectCollisions() throws {
        let command = try request("elyx_changes", ["plugin_id": "elyxFixture", "changes": [
            ["#": "modified", "path": "assets/hello.txt", "content": "bmV3"],
            ["#": "created", "path": "fresh/item.txt", "content": "aGk="],
            ["#": "moved", "path": "dir", "dest_path": "renamed"],
            ["#": "deleted", "path": "old.txt"],
        ]])
        let candidate = try PluginElyxArchiveCandidate.applying(command.changes, to: elyxZIP)
        let values = try storedBodies(candidate)
        let original = try storedBodies(elyxZIP)
        XCTAssertEqual(values["main.py"], original["main.py"])
        XCTAssertEqual(values["meta.json"], original["meta.json"])
        XCTAssertEqual(values["assets/hello.txt"], Data("new".utf8))
        XCTAssertEqual(values["fresh/item.txt"], Data("hi".utf8))
        XCTAssertEqual(values["renamed/item.txt"], Data("item".utf8))
        XCTAssertNil(values["old.txt"])
        XCTAssertNil(values["dir/item.txt"])
        for change in [
            ["#": "created", "path": "MAIN.py", "content": ""],
            ["#": "modified", "path": "dir", "content": ""],
            ["#": "moved", "path": "dir", "dest_path": "dir/child"],
            ["#": "moved", "path": "missing", "dest_path": "new"],
            ["#": "created", "path": "native.so", "content": ""],
            ["#": "created", "path": "blob.txt", "content": "TVpmb3JiaWRkZW4="],
        ] {
            let invalid = try request("elyx_changes", ["plugin_id": "elyxFixture", "changes": [change]])
            XCTAssertThrowsError(try PluginElyxArchiveCandidate.applying(invalid.changes, to: elyxZIP))
        }
    }

    func testMissingFDAuthorityFailsBeforeReadStageOrPublication() async throws {
        let (_, target) = try await owner()
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": []])
        do {
            _ = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: nil, current: { _ in true },
                installedCurrent: { _, _ in true }, session: { true }, read: { _, _ in throw PluginHostError.internalInconsistency("unexpected read") },
                ping: { throw PluginHostError.internalInconsistency("unexpected ping") },
                publish: { _, _, _ in throw PluginHostError.internalInconsistency("unexpected publication") })
            XCTFail("missing authority was accepted")
        } catch let error as PluginElyxDeveloperOperationFailure {
            XCTAssertEqual(error.kind, "ServiceUnavailable")
            XCTAssertTrue(error.message.contains("FD-backed"))
            XCTAssertEqual(error.outcome, .refused)
        }
    }

    func testCapturedOwnerReplacementInvalidatesList() async throws {
        let (fixture, target) = try await owner()
        let host = fixture.host
        let response = try workerReply(target)
        do {
            _ = try await PluginElyxDeveloperTransaction.run(request("get_elyx_plugins"), targets: [target], files: nil,
                current: { host.callbackOwner(id: $0.plugin.id) == $0.owner }, installedCurrent: { _, _ in true }, session: { true },
                read: { _, _ in try await host.reloadPlugin(id: target.plugin.id); return response }, ping: { response },
                publish: { _, _, _ in throw PluginHostError.internalInconsistency("unexpected publication") })
            XCTFail("list escaped its captured owner")
        } catch let error as PluginElyxDeveloperError { XCTAssertEqual(error.kind, "Superseded") }
        XCTAssertNotEqual(host.callbackOwner(id: target.plugin.id), target.owner)
    }

    func testCompareUsesVerifiedSourceHashesAndRechecksSourceVersion() async throws {
        let (_, target) = try await owner()
        let files = ElyxFileRecorder(target.plugin)
        let command = try request("elyx_compare_folder", ["plugin_id": target.plugin.id,
            "hashes": ["main.py": String(repeating: "b", count: 64), "new.txt": String(repeating: "d", count: 64)]])
        let response = try workerReply(target, digest: files.sha256)
        let value = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: files, current: { _ in true },
            installedCurrent: { _, _ in true }, session: { true }, read: { _, _ in response }, ping: { response },
            publish: { _, _, _ in throw PluginHostError.internalInconsistency("compare cannot publish") })
        XCTAssertEqual(value["created_or_modified"], .array([.string("new.txt")]))
        XCTAssertEqual(value["deleted"], .array([.string("old.txt")]))
        XCTAssertEqual(files.operations, [1, 0, 0])
        do {
            _ = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: files, current: { _ in true },
                installedCurrent: { _, _ in true }, session: { true }, read: { _, _ in files.valid.set(false); return response }, ping: { response },
                publish: { _, _, _ in throw PluginHostError.internalInconsistency("compare cannot publish") })
            XCTFail("compare escaped changed source version")
        } catch let error as PluginElyxDeveloperError { XCTAssertEqual(error.kind, "Superseded") }
        XCTAssertEqual(files.operations, [2, 0, 0])
    }

    func testRetiredSessionOrConsentCannotStageChanges() async throws {
        let (fixture, target) = try await owner()
        let host = fixture.host
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": []])
        for revokeConsent in [false, true] {
            let files = ElyxFileRecorder(target.plugin)
            let session = MaintenanceTestFlag()
            let response = try workerReply(target, digest: files.sha256)
            do {
                _ = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: files,
                    current: { host.permissionSnapshot(id: $0.plugin.id) == $0.consent }, installedCurrent: { _, _ in true },
                    session: { session.value }, read: { _, _ in
                        if revokeConsent { try host.setPluginTrustLevel(id: target.plugin.id, level: .trusted) }
                        else { session.set(false) }
                        return response
                    }, ping: { response }, publish: { _, _, _ in throw PluginHostError.internalInconsistency("retired command cannot publish") })
                XCTFail("retired change command staged bytes")
            } catch let error as PluginElyxDeveloperOperationFailure {
                XCTAssertEqual(error.kind, "Superseded")
                XCTAssertEqual(PluginElyxDeveloperError.response(error, request: command)["source_changed"], .bool(false))
            }
            XCTAssertEqual(files.operations, [1, 0, 0])
        }
    }

    func testReloadedTrueRequiresAnActualNewHostOwner() async throws {
        let (fixture, target) = try await owner()
        let host = fixture.host
        let files = ElyxFileRecorder(target.plugin)
        let response = try workerReply(target, digest: files.sha256)
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": [["#": "modified", "path": "old.txt", "content": "bmV3"]]])
        let value = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: files,
            current: { host.callbackOwner(id: $0.plugin.id) == $0.owner },
            installedCurrent: { result, consent in host.callbackOwner(id: result.plugin.id) == result.owner && host.permissionSnapshot(id: result.plugin.id) == consent },
            session: { true }, read: { _, _ in response }, ping: { response }, publish: { _, _, prepared in
                try prepared.publish(shouldExecute: { true }) // in-memory recorder, no source file write
                try await host.reloadPlugin(id: target.plugin.id) // actual Host lifecycle, canned metadata engine
                let plugin = host.pluginList().first { $0.id == target.plugin.id }!
                return PluginElyxDeveloperInstalled(plugin: plugin, owner: host.callbackOwner(id: plugin.id))
            })
        XCTAssertEqual(value["ok"], .bool(true))
        XCTAssertEqual(value["reloaded"], .bool(true))
        XCTAssertEqual(files.operations, [1, 1, 1])
        XCTAssertEqual(try storedBodies(XCTUnwrap(files.preparedBytes))["old.txt"], Data("new".utf8))
        XCTAssertEqual(host.pluginList().first?.path, target.plugin.path)
        XCTAssertEqual(host.pluginList().first?.fileFormat, .elyx)
        XCTAssertNotEqual(host.callbackOwner(id: target.plugin.id), target.owner)
    }

    func testPublicationFailureKeepsEveryTypedOutcomeAtTransactionBoundary() async throws {
        let (_, target) = try await owner()
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": []])
        for (outcome, changed) in [(PluginElyxDeveloperPublicationFailure.Outcome.refused, PluginJSONValue.bool(false)),
                                   (.rolledBack, .bool(false)), (.committed, .bool(true)), (.recoveryRequired, .null)] {
            let files = ElyxFileRecorder(target.plugin)
            let response = try workerReply(target, digest: files.sha256)
            let cause = PluginElyxDeveloperError.stale("owned publication witness")
            let failure = PluginElyxDeveloperPublicationFailure(outcome: outcome, detail: cause.description, underlying: cause)
            do {
                _ = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: files,
                    current: { _ in true }, installedCurrent: { _, _ in true }, session: { true },
                    read: { _, _ in response }, ping: { response }, publish: { _, _, _ in throw failure })
                XCTFail("publication failure returned success")
            } catch {
                let value = PluginElyxDeveloperError.response(error, request: command)
                XCTAssertEqual(value["error_kind"], .string(cause.kind))
                XCTAssertEqual(value["error"], .string(failure.description))
                XCTAssertEqual(value["errors"], .array([.string(failure.description)]))
                XCTAssertEqual(value["plugin_id"], .string(target.plugin.id))
                XCTAssertEqual(value["publication_outcome"], .string(outcome.rawValue))
                XCTAssertEqual(value["source_changed"], changed)
                XCTAssertEqual(value["reloaded"], .bool(false))
            }
        }
    }

    func testPostPublicationSessionOwnerModelAndSourceGuardsCannotReportNoWrite() async throws {
        let (_, target) = try await owner()
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": []])
        for boundary in ["session", "owner", "model", "source"] {
            let files = ElyxFileRecorder(target.plugin)
            let session = MaintenanceTestFlag()
            let response = try workerReply(target, digest: files.sha256)
            do {
                _ = try await PluginElyxDeveloperTransaction.run(command, targets: [target], files: files,
                    current: { _ in true }, installedCurrent: { _, _ in boundary != "owner" }, session: { session.value },
                    read: { _, _ in response }, ping: { response }, publish: { _, _, prepared in
                        try prepared.publish(shouldExecute: { true })
                        if boundary == "session" { session.set(false) }
                        if boundary == "source" { files.valid.set(false) }
                        var plugin = target.plugin
                        if boundary == "model" { plugin.enabled.toggle() }
                        return PluginElyxDeveloperInstalled(plugin: plugin, owner: target.owner)
                    })
                XCTFail("late \(boundary) guard accepted a receipt")
            } catch {
                let value = PluginElyxDeveloperError.response(error, request: command)
                XCTAssertEqual(value["publication_outcome"], .string("committed"), boundary)
                XCTAssertEqual(value["source_changed"], .bool(true), boundary)
                XCTAssertEqual(value["error_kind"], .string("Superseded"), boundary)
                XCTAssertEqual(value["reloaded"], .bool(false), boundary)
            }
            XCTAssertEqual(files.operations, [1, 1, 1])
        }
    }

    func testActualHostPersistenceFailureAfterPublicationKeepsCommit() async throws {
        let (fixture, target) = try await owner()
        let store = fixture.root.appendingPathComponent("plugins.json")
        let files = ElyxFileRecorder(target.plugin, onPublish: {
            // Fault the real throwing persistInstalledPlugin write AFTER the
            // Host has retired the old owner and the native recorder published.
            try FileManager.default.removeItem(at: store)
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        })
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": []])
        do {
            _ = try await fixture.host.elyxDeveloper(command, targets: [target], account: 2, files: files,
                deadline: ProcessInfo.processInfo.systemUptime + 5, shouldExecute: { true })
            XCTFail("model persistence failure returned success")
        } catch {
            let value = PluginElyxDeveloperError.response(error, request: command)
            XCTAssertEqual(value["publication_outcome"], .string("committed"))
            XCTAssertEqual(value["source_changed"], .bool(true))
            XCTAssertEqual(value["reloaded"], .bool(false))
            XCTAssertFalse(String(describing: value).contains(fixture.root.path))
        }
        XCTAssertEqual(files.operations, [1, 1, 1])
        XCTAssertNil(fixture.host.callbackOwner(id: target.plugin.id))
        XCTAssertEqual(fixture.engine.calls.filter { $0.source.hasPrefix("_exteraless_runtime.load_json(") }.count, 1)
    }

    func testActualHostVerifiedLoadFailureKeepsOriginalTypeAndCommit() async throws {
        let (fixture, target) = try await owner()
        let files = ElyxFileRecorder(target.plugin)
        let command = try request("elyx_changes", ["plugin_id": target.plugin.id, "changes": []])
        do {
            _ = try await fixture.host.elyxDeveloper(command, targets: [target], account: 2, files: files,
                deadline: ProcessInfo.processInfo.systemUptime + 5, shouldExecute: { true })
            XCTFail("recorder unexpectedly supplied a verified-load descriptor")
        } catch {
            let value = PluginElyxDeveloperError.response(error, request: command)
            XCTAssertEqual(value["publication_outcome"], .string("committed"))
            XCTAssertEqual(value["source_changed"], .bool(true))
            XCTAssertEqual(value["error_kind"], .string("ServiceUnavailable"))
            XCTAssertEqual(value["reloaded"], .bool(false))
            XCTAssertTrue((error as? PluginElyxDeveloperOperationFailure)?.message.contains("recorder does not implement") == true)
        }
        XCTAssertEqual(files.operations, [1, 1, 1])
        XCTAssertNil(fixture.host.callbackOwner(id: target.plugin.id))
        XCTAssertEqual(fixture.engine.counts.live, 0)
    }

    func testFailureWireRetainsOriginalFieldsButRedactsNativeProofsAndPaths() throws {
        let command = try request("elyx_changes", ["plugin_id": "elyxFixture", "changes": []])
        let failure = PluginElyxDeveloperError.stale("owned safe message")
        let original = PluginElyxDeveloperError.response(failure, request: command)
        XCTAssertEqual(original["error"], .string(failure.description))
        XCTAssertEqual(original["errors"], .array([.string(failure.description)]))
        XCTAssertEqual(original["error_kind"], .string(failure.kind))
        let proof = String(repeating: "b", count: 64), epoch = UUID().uuidString
        let unsafe = PluginElyxDeveloperError.stale("failed '/private/owned path/candidate.elyx' \(proof) \(epoch)")
        let response = PluginElyxDeveloperError.response(unsafe, request: command)
        let wire = try PluginRuntimeScript.encodeJSON(response.mapValues(\.jsonObject))
        for secret in ["/private/", "owned path", "candidate.elyx", proof, epoch] { XCTAssertFalse(wire.contains(secret)) }
        XCTAssertEqual(response["publication_outcome"], .string("refused"))
        XCTAssertEqual(response["source_changed"], .bool(false))
    }

    /// Independent minimal reader for stored-fixture bodies, not a ZIP writer or
    /// a copy of the mutation implementation. Production tests additionally feed
    /// the native candidate to Python's zipfile/CRC/static archive validator.
    private func storedBodies(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func number(_ at: Int, _ width: Int) throws -> Int {
            guard at + width <= bytes.count else { throw PluginElyxDeveloperError.malformed("truncated test ZIP") }
            return (0..<width).reduce(0) { $0 | Int(bytes[at + $1]) << ($1 * 8) }
        }
        var cursor = 0, result: [String: Data] = [:]
        while try number(cursor, 4) == 0x04034b50 {
            XCTAssertEqual(try number(cursor + 8, 2), 0)
            let size = try number(cursor + 18, 4), name = try number(cursor + 26, 2), extra = try number(cursor + 28, 2)
            let path = String(decoding: bytes[(cursor + 30)..<(cursor + 30 + name)], as: UTF8.self)
            let start = cursor + 30 + name + extra
            guard start + size <= bytes.count else { throw PluginElyxDeveloperError.malformed("truncated test body") }
            result[path] = Data(bytes[start..<(start + size)])
            cursor = start + size
        }
        return result
    }
}
