import Foundation
import XCTest
@testable import PluginHost
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class ElyxFilesBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
}

#if canImport(Darwin) || canImport(Glibc)
/// Filesystem operations, descriptor issuance and publication are production
/// implementations. The injected inspector reads fixture JSON from the actual
/// resolved fd; it stands for the separately joined SDK's full ZIP inspection.
private struct ElyxFilesRig: Sendable {
    let fixture: MaintenanceTestFixture
    let target: PluginElyxDeveloperTarget
    let registry: PluginElyxDeveloperDescriptorRegistry
    let readiness: ElyxFilesBox<PluginElyxDeveloperBridgeReadiness>
    let files: PluginElyxDeveloperFiles
    let diagnostics: ElyxFilesBox<[String]>
    var live: URL { URL(fileURLWithPath: target.plugin.path!) }
    var plugins: URL { live.deletingLastPathComponent() }
    var staging: URL { plugins.deletingLastPathComponent().appendingPathComponent(".elyx-developer-staging") }
}

private func elyxFileFixtureData(_ version: String, id: String = "7_archive") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": id, "name": "Owned FD fixture", "version": version], options: .sortedKeys)
}

private func elyxReadFixtureFD(_ fd: Int32) throws -> Data {
    var info = stat()
    guard fstat(fd, &info) == 0, UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
          fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY, info.st_size <= 1024 * 1024 else {
        throw PluginElyxDeveloperError.malformed("fixture received a non-readonly/unbounded fd")
    }
    var bytes = Data(count: Int(info.st_size))
    let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    guard count == bytes.count else { throw PluginHostError.runtimeFailure("fixture pread failed") }
    return bytes
}

private func elyxAwaitCancellable<Value: Sendable>(_ reply: OneShotResult<Value>) async throws -> Value {
    try await withTaskCancellationHandler(operation: {
        try await reply.awaitValue()
    }, onCancel: {
        reply.fail(CancellationError())
    })
}

final class PluginElyxDeveloperFilesTests: HostLifecycleTestCase {
    private typealias Inspect = @Sendable (PluginElyxDeveloperInspection, PluginElyxDeveloperResolvedDescriptor, Plugin) async throws -> Plugin

    private func rig(hooks: PluginElyxDeveloperFileHooks = .init(),
                     consume: Bool = true, wireInspection: Bool = false, inspect: Inspect? = nil) async throws -> ElyxFilesRig {
        let engine = MaintenanceTestEngine(onScript: { _, source in
            for method in ["metadata_json", "load_json"] {
                let prefix = "_exteraless_runtime.\(method)("
                if source.hasPrefix(prefix) {
                    let arguments = "[" + source.dropFirst(prefix.count).dropLast() + "]"
                    let paths = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: paths[0])))
                    if method == "metadata_json" { return try PluginRuntimeScript.encodeJSON(metadata) }
                    return try PluginRuntimeScript.encodeJSON(["metadata": metadata, "handles": [:], "has_settings": false])
                }
            }
            return nil
        })
        let fixture = try fixture(engine: engine)
        let host = fixture.host
        try await host.start(safeMode: true)
        let input = fixture.root.appendingPathComponent("input.eaf")
        try elyxFileFixtureData("1.0").write(to: input)
        let installed = try await host.installPlugin(sourceURL: input, metadata: Plugin(id: "7_archive", fileFormat: .eaf))
        let owner = try XCTUnwrap(host.callbackOwner(id: installed.id))
        let target = try PluginElyxDeveloperTarget(plugin: installed, owner: owner, consent: host.permissionSnapshot(id: installed.id))
        let registry = PluginElyxDeveloperDescriptorRegistry()
        let readiness = ElyxFilesBox(PluginElyxDeveloperBridgeReadiness(abi: 1, registry: registry.identifier,
            epoch: UUID(), hooks: Set(PluginElyxDeveloperBridgeReadiness.Hook.allCases)))
        let diagnostics = ElyxFilesBox<[String]>([])
        let bridge = PluginElyxDeveloperDescriptorBridge(readiness: { readiness.get() }, inspect: { call in
            if !consume { return Plugin(id: target.plugin.id, fileFormat: call.format) }
            let consumer = try call.descriptor.bindNativeInspection()
            if wireInspection {
                PluginElyxDeveloperDescriptorExecution.install(consumer, isCurrent: call.isCurrent)
                defer { PluginElyxDeveloperDescriptorExecution.install(nil) }
                func wire(_ operation: String, _ payload: [String: Any]) throws -> [String: Any] {
                    let request = try PluginRuntimeScript.encodeJSON(["op": "elyx_source", "operation": operation,
                        "payload": try PluginRuntimeScript.encodeJSON(payload), "pluginId": "@elyx-inspection", "ownerToken": NSNull()])
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(registry.dispatch(requestJSON: request,
                        immutablePluginId: "@elyx-inspection", immutableOwnerToken: nil).utf8)) as? [String: Any])
                }
                let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.descriptor.descriptorJSON.utf8)) as? [String: Any])
                XCTAssertTrue(proof["owner_token"] is NSNull)
                let claim = try wire("claim", proof)
                XCTAssertEqual(claim["ok"] as? Bool, true)
                let claimed = try XCTUnwrap(claim["value"] as? [String: Any])
                XCTAssertEqual(Set(claimed.keys), Set(["abi", "read_id", "descriptor", "read_only", "load_reader_abi"]))
                XCTAssertEqual(try wire("claim", proof)["ok"] as? Bool, false)
                let ticket: [String: Any] = ["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "read_id": claimed["read_id"]!]
                let read = try wire("read", ticket.merging(["offset": 0, "count": 65536]) { _, new in new })
                let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap((read["value"] as? [String: Any])?["data_base64"] as? String)))
                XCTAssertEqual(try wire("check", ticket)["ok"] as? Bool, true)
                XCTAssertEqual((try wire("release", ticket)["value"] as? [String: Any])?["released"] as? Bool, true)
                return try PluginRuntimeScript.metadata(String(decoding: data, as: UTF8.self), format: call.format)
            }
            let resolved: PluginElyxDeveloperResolvedDescriptor = try {
                PluginElyxDeveloperDescriptorExecution.install(consumer)
                defer { PluginElyxDeveloperDescriptorExecution.install(nil) }
                XCTAssertThrowsError(try registry.resolveFromBridge(call.descriptor.descriptorJSON, purpose: .inspect,
                                                                    pluginId: "exteralessMetadataInspector", ownerToken: nil))
                return try registry.resolveFromBridge(call.descriptor.descriptorJSON, purpose: .inspect, pluginId: "@elyx-inspection", ownerToken: nil)
            }()
            let data = try resolved.read(offset: 0, count: 65536)
            XCTAssertEqual(ElyxNativeSHA256.hex(data), resolved.claims.sha256)
            let metadata = try PluginRuntimeScript.metadata(String(decoding: data, as: UTF8.self), format: call.format)
            if let inspect { return try await inspect(call, resolved, metadata) }
            return metadata
        }, currentOwner: { host.callbackOwner(id: $0.pluginId) == $0 })
        let files = try PluginElyxDeveloperFiles(pluginsDirectory: URL(fileURLWithPath: host.configuration.runtime.pluginRootDirectory),
            registry: registry, bridge: bridge, currentTarget: { target in
                host.callbackOwner(id: target.plugin.id) == target.owner
                    && host.permissionSnapshot(id: target.plugin.id) == target.consent
                    && host.pluginList().contains { target.matches($0) }
            }, currentConsent: { host.permissionSnapshot(id: $0.plugin.id) == $0.consent },
            diagnostic: { text in diagnostics.set(diagnostics.get() + [text]) }, hooks: hooks)
        return ElyxFilesRig(fixture: fixture, target: target, registry: registry, readiness: readiness, files: files, diagnostics: diagnostics)
    }

    private func children(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }

    private func sourceCall(_ rig: ElyxFilesRig, _ operation: String, _ payload: [String: Any],
                            pluginId: String? = nil, ownerToken: String? = nil) throws -> [String: Any] {
        let id = pluginId ?? rig.target.owner.pluginId
        let token = ownerToken ?? rig.target.owner.wireToken
        let text = try PluginRuntimeScript.encodeJSON(["op": "elyx_source", "operation": operation,
            "payload": try PluginRuntimeScript.encodeJSON(payload), "pluginId": id, "ownerToken": token])
        let result = rig.registry.dispatch(requestJSON: text, immutablePluginId: id, immutableOwnerToken: token)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(ElyxNativeSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ElyxNativeSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ElyxNativeSHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testRealStagingPublicationAndNewOwnerDescriptor() async throws {
        let rig = try await rig()
        let before = try Data(contentsOf: rig.live)
        let candidate = try elyxFileFixtureData("2.0")
        let source = try rig.files.open(rig.target)
        XCTAssertEqual(source.archiveBytes, before)
        XCTAssertEqual(source.sha256, ElyxNativeSHA256.hex(before))
        let prepared = try await source.prepare(candidate, shouldExecute: { true })
        XCTAssertEqual(try Data(contentsOf: rig.live), before)
        XCTAssertEqual(prepared.metadata.id, rig.target.plugin.id)
        XCTAssertEqual(prepared.metadata.fileFormat, .eaf)
        XCTAssertEqual(prepared.metadata.version, "2.0")
        try prepared.checkBeforePublication()
        try prepared.publish(shouldExecute: { true })
        try prepared.checkPublished()
        XCTAssertThrowsError(try prepared.publish(shouldExecute: { true }))
        try prepared.checkPublished() // duplicate publication cannot corrupt its receipt
        XCTAssertEqual(try Data(contentsOf: rig.live), candidate)
        XCTAssertThrowsError(try source.checkCurrent())
        XCTAssertThrowsError(try prepared.loadSource(owner: rig.target.owner))
        // Existing Host really creates a different owner. Its engine is a canned
        // metadata engine; verified Python code execution is a separate fixture.
        try await rig.fixture.host.reloadPlugin(id: rig.target.plugin.id)
        let owner = try XCTUnwrap(rig.fixture.host.callbackOwner(id: rig.target.plugin.id))
        XCTAssertNotEqual(owner, rig.target.owner)
        let lease = try prepared.loadSource(owner: owner)
        XCTAssertThrowsError(try rig.registry.resolveCurrent(lease.descriptorJSON, purpose: .load))
        XCTAssertThrowsError(try rig.registry.resolve(lease.descriptorJSON, purpose: .load, caller: .owner(rig.target.owner)))
        PluginElyxDeveloperDescriptorExecution.install(.owner(owner))
        defer { PluginElyxDeveloperDescriptorExecution.install(nil) }
        XCTAssertThrowsError(try rig.registry.resolveFromBridge(lease.descriptorJSON, purpose: .load,
                                                               pluginId: owner.pluginId, ownerToken: "forged"))
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lease.descriptorJSON.utf8)) as? [String: Any])
        forged["fd"] = 0
        forged["sha256"] = prepared.sha256
        let forgedJSON = String(decoding: try JSONSerialization.data(withJSONObject: forged), as: UTF8.self)
        XCTAssertThrowsError(try rig.registry.resolveFromBridge(forgedJSON, purpose: .load,
                                                               pluginId: owner.pluginId, ownerToken: owner.wireToken))
        let resolved = try rig.registry.resolveFromBridge(lease.descriptorJSON, purpose: .load,
                                                         pluginId: owner.pluginId, ownerToken: owner.wireToken)
        XCTAssertEqual(resolved.claims.owner, owner)
        XCTAssertEqual(try resolved.read(offset: 0, count: 65536), candidate)
        XCTAssertThrowsError(try rig.registry.resolve(lease.descriptorJSON, purpose: .load, caller: .owner(owner)))
        XCTAssertEqual(rig.fixture.host.permissionSnapshot(id: rig.target.plugin.id), rig.target.consent)
    }

    func testForgedFdDigestPurposeAndInspectionContextNeverAuthorize() async throws {
        let rig = try await rig(inspect: { call, resolved, metadata in
            let registry = PluginElyxDeveloperDescriptorRegistry()
            XCTAssertThrowsError(try registry.resolve(call.descriptor.descriptorJSON, purpose: .inspect,
                                                       caller: .inspection(registry.makeInspectionContext())))
            var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.descriptor.descriptorJSON.utf8)) as? [String: Any])
            forged["fd"] = resolved.nativeDescriptorForTesting
            forged["sha256"] = resolved.claims.sha256
            XCTAssertFalse(PluginElyxDeveloperDescriptorExecution.current != nil)
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: forged), as: UTF8.self)
            XCTAssertThrowsError(try registry.resolveCurrent(wire, purpose: .inspect))
            return metadata
        })
        let source = try rig.files.open(rig.target)
        _ = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        XCTAssertEqual(rig.registry.outstandingCount, 0)
    }

    func testInspectorCannotReturnSuccessWithoutNativeResolution() async throws {
        let rig = try await rig(consume: false)
        let source = try rig.files.open(rig.target)
        let original = try Data(contentsOf: rig.live)
        do {
            _ = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
            XCTFail("inspector skipped the native verifier")
        } catch { XCTAssertTrue(String(describing: error).contains("did not consume")) }
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
        XCTAssertEqual(try children(rig.staging), [])
        XCTAssertEqual(rig.registry.outstandingCount, 0)
    }

    func testBridgeReadinessAndMetadataFailurePrecedePublication() async throws {
        let rig = try await rig()
        let source = try rig.files.open(rig.target)
        let original = try Data(contentsOf: rig.live)
        let current = rig.readiness.get()
        rig.readiness.set(.init(abi: 1, registry: current.registry, epoch: UUID(), hooks: [.manifest, .inspect]))
        do { _ = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true }); XCTFail("missing verified-load hook accepted") }
        catch { XCTAssertTrue(String(describing: error).contains("hooks")) }
        XCTAssertEqual(try children(rig.staging), [])
        rig.readiness.set(current)
        do { _ = try await source.prepare(elyxFileFixtureData("2.0", id: "differentArchive"), shouldExecute: { true }); XCTFail("identity change accepted") }
        catch { XCTAssertTrue(String(describing: error).contains("ID/format/engine")) }
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
        XCTAssertEqual(try children(rig.staging), [])
    }

    func testSameDigestReplacementAndNamespaceABAInvalidateCapture() async throws {
        let rig = try await rig()
        let original = try Data(contentsOf: rig.live)
        let source = try rig.files.open(rig.target)
        try original.write(to: rig.live, options: .atomic)
        XCTAssertEqual(ElyxNativeSHA256.hex(try Data(contentsOf: rig.live)), source.sha256)
        XCTAssertThrowsError(try source.checkCurrent())
        let next = try rig.files.open(rig.target)
        let moved = rig.plugins.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: rig.plugins, to: moved)
        try FileManager.default.moveItem(at: moved, to: rig.plugins)
        XCTAssertThrowsError(try next.checkCurrent())
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
    }

    func testSymlinkAndParentSwapCannotRedirectReadsOrWrites() async throws {
        let rig = try await rig(hooks: .init { point, file in
            if case .sourceCaptured = point {
                let parent = file.deletingLastPathComponent()
                let outside = parent.deletingLastPathComponent().appendingPathComponent("outside")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try Data("untouched".utf8).write(to: outside.appendingPathComponent(file.lastPathComponent))
                try FileManager.default.moveItem(at: parent, to: parent.appendingPathExtension("old"))
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            }
        })
        XCTAssertThrowsError(try rig.files.open(rig.target))
        let outside = rig.fixture.root.appendingPathComponent("outside").appendingPathComponent(rig.live.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        XCTAssertEqual(try children(rig.staging), [])
    }

    func testCandidateReplacementBeforeInspectionIsRetainedNotUnlinked() async throws {
        let replaced = ElyxFilesBox<URL?>(nil)
        let rig = try await rig(hooks: .init { point, file in
            if case .candidateSealed = point {
                try FileManager.default.removeItem(at: file)
                try Data("replacement must survive".utf8).write(to: file)
                replaced.set(file)
            }
        })
        let source = try rig.files.open(rig.target)
        let original = try Data(contentsOf: rig.live)
        do { _ = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true }); XCTFail("stage swap accepted") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replaced.get())), Data("replacement must survive".utf8))
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
        XCTAssertFalse(rig.diagnostics.get().isEmpty)
        do { _ = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true }); XCTFail("cleanup debt allowed unbounded staging") }
        catch { XCTAssertTrue(String(describing: error).contains("recovery")) }
    }

    func testRevocationAtAtomicExchangeRollsBackCapturedInodes() async throws {
        let allowed = MaintenanceTestFlag()
        let rig = try await rig(hooks: .init { point, _ in if case .afterExchange = point { allowed.set(false) } })
        let original = try Data(contentsOf: rig.live)
        let source = try rig.files.open(rig.target)
        let prepared = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        do { try prepared.publish(shouldExecute: { allowed.value }); XCTFail("retired publication succeeded") }
        catch let error as PluginElyxDeveloperPublicationFailure {
            XCTAssertEqual(error.outcome, .rolledBack)
            XCTAssertEqual(error.sourceChanged, false)
            let response = PluginElyxDeveloperError.response(error, request: nil)
            XCTAssertEqual(response["publication_outcome"], .string("rolledBack"))
            XCTAssertEqual(response["source_changed"], .bool(false))
        }
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
        XCTAssertThrowsError(try prepared.checkPublished())
        XCTAssertThrowsError(try source.checkCurrent(), "rollback must not revive an old operation version")
    }

    func testParentSwapAfterExchangeRollsBackOnlyHeldNamespace() async throws {
        let rig = try await rig(hooks: .init { point, file in
            if case .afterExchange = point {
                let parent = file.deletingLastPathComponent()
                try FileManager.default.moveItem(at: parent, to: parent.appendingPathExtension("old"))
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try Data("new namespace".utf8).write(to: file)
            }
        })
        let original = try Data(contentsOf: rig.live)
        let source = try rig.files.open(rig.target)
        let prepared = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        XCTAssertThrowsError(try prepared.publish(shouldExecute: { true })) { error in
            XCTAssertEqual((error as? PluginElyxDeveloperPublicationFailure)?.outcome, .rolledBack)
        }
        XCTAssertEqual(try Data(contentsOf: rig.live), Data("new namespace".utf8))
        XCTAssertEqual(try Data(contentsOf: rig.plugins.appendingPathExtension("old").appendingPathComponent(rig.live.lastPathComponent)), original)
    }

    func testUnrecoverableRacingSlotAndPostCommitFailureReportTruthfully() async throws {
        let raced = try await rig(hooks: .init { point, file in
            if case .afterExchange = point { try Data("racing third inode".utf8).write(to: file, options: .atomic) }
        })
        let source = try raced.files.open(raced.target)
        let prepared = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        XCTAssertThrowsError(try prepared.publish(shouldExecute: { true })) { error in
            let failure = error as? PluginElyxDeveloperPublicationFailure
            XCTAssertEqual(failure?.outcome, .recoveryRequired)
            XCTAssertNil(failure?.sourceChanged)
            let response = PluginElyxDeveloperError.response(error, request: nil)
            XCTAssertEqual(response["publication_outcome"], .string("recoveryRequired"))
            XCTAssertEqual(response["source_changed"], .null)
        }
        XCTAssertEqual(try Data(contentsOf: raced.live), Data("racing third inode".utf8))
        let committed = try await rig(hooks: .init { point, _ in
            if case .committed = point { throw POSIXError(.EIO) }
        })
        let current = try committed.files.open(committed.target)
        let bytes = try elyxFileFixtureData("2.0")
        let next = try await current.prepare(bytes, shouldExecute: { true })
        XCTAssertThrowsError(try next.publish(shouldExecute: { true })) { error in
            let failure = error as? PluginElyxDeveloperPublicationFailure
            XCTAssertEqual(failure?.outcome, .committed)
            XCTAssertEqual(failure?.sourceChanged, true)
        }
        XCTAssertEqual(try Data(contentsOf: committed.live), bytes)
        XCTAssertThrowsError(try next.checkPublished())
    }

    func testCancelledWaiterRetainsActualInspectorFDThroughCompletion() async throws {
        let entered = OneShotResult<Int32>()
        let finish = OneShotResult<Void>()
        defer { finish.succeed(()) }
        let finished = OneShotResult<Void>()
        let rig = try await rig(inspect: { call, resolved, metadata in
            let descriptor = resolved.nativeDescriptorForTesting
            let reply = OneShotResult<Plugin>()
            // Model the existing native mailbox's retained execution callback,
            // which outlives a cancelled async waiter. No Python threads involved.
            Task.detached { [call, resolved] in
                entered.succeed(descriptor)
                _ = try? await finish.awaitValue()
                XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFL), 0)
                withExtendedLifetime(call.descriptor) {}
                withExtendedLifetime(resolved) {}
                reply.succeed(metadata)
                finished.succeed(())
            }
            return try await elyxAwaitCancellable(reply)
        })
        let source = try rig.files.open(rig.target)
        let task = Task { try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true }) }
        let fd = try await maintenanceTestWait(entered)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled prepare returned a candidate") } catch { }
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFL), 0, "cancelled waiter recycled the live native reader's fd")
        XCTAssertEqual(rig.registry.outstandingCount, 1)
        finish.succeed(())
        _ = try await maintenanceTestWait(finished)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while try (rig.registry.outstandingCount != 0 || !children(rig.staging).isEmpty), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(rig.registry.outstandingCount, 0)
        XCTAssertEqual(try children(rig.staging), [])
    }

    func testCandidateSurvivesOldArchiveCachePurge() async throws {
        let rig = try await rig()
        let component = PluginServiceStorage.component(rig.target.plugin.id)
        let cache = rig.fixture.root.appendingPathComponent("cache/\(component)/elyx/\(String(repeating: "a", count: 64))/\(String(repeating: "b", count: 64))-\(String(repeating: "c", count: 32))/contents")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("old cache".utf8).write(to: cache.appendingPathComponent("old.py"))
        let purge = try PluginArchiveCacheLease.capture(root: rig.fixture.root, component: component, hooks: .init())
        let source = try rig.files.open(rig.target)
        let prepared = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        try purge.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try prepared.checkBeforePublication()
        XCTAssertEqual(try children(rig.staging).count, 1)
    }

    func testCancelledLoadWaiterCannotRecycleRetainedDescriptor() async throws {
        let rig = try await rig()
        let source = try rig.files.open(rig.target)
        let candidate = try elyxFileFixtureData("2.0")
        let prepared = try await source.prepare(candidate, shouldExecute: { true })
        try prepared.publish(shouldExecute: { true })
        try await rig.fixture.host.reloadPlugin(id: rig.target.plugin.id)
        let owner = try XCTUnwrap(rig.fixture.host.callbackOwner(id: rig.target.plugin.id))
        var lease: (any PluginElyxDeveloperDescriptorLease)? = try prepared.loadSource(owner: owner)
        var resolved: PluginElyxDeveloperResolvedDescriptor? = try rig.registry.resolve(lease!.descriptorJSON, purpose: .load, caller: .owner(owner))
        let fd = resolved!.nativeDescriptorForTesting
        let entered = OneShotResult<Void>(), finish = OneShotResult<Void>(), finished = OneShotResult<Void>()
        defer { finish.succeed(()) }
        let reply = OneShotResult<Void>()
        Task.detached { [held = lease!, result = resolved!] in
            entered.succeed(())
            _ = try? await finish.awaitValue()
            XCTAssertEqual(try elyxReadFixtureFD(fd), candidate)
            withExtendedLifetime(held) {}
            withExtendedLifetime(result) {}
            reply.succeed(())
            finished.succeed(())
        }
        lease = nil; resolved = nil
        let waiter = Task { try await elyxAwaitCancellable(reply) }
        _ = try await maintenanceTestWait(entered)
        waiter.cancel()
        do { try await waiter.value; XCTFail("cancelled load waiter succeeded") } catch { }
        try await rig.fixture.host.setPluginEnabled(id: rig.target.plugin.id, false)
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFL), 0)
        XCTAssertEqual(rig.registry.outstandingCount, 1)
        finish.succeed(())
        _ = try await maintenanceTestWait(finished)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while rig.registry.outstandingCount != 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(rig.registry.outstandingCount, 0)
    }

    func testConsentRetirementDuringInspectionDoesNotPublish() async throws {
        let host = MaintenanceTestHostBox()
        let rig = try await rig(inspect: { _, resolved, metadata in
            try host.get()?.setPluginTrustLevel(id: resolved.claims.pluginId, level: .trusted)
            return metadata
        })
        host.set(rig.fixture.host)
        let original = try Data(contentsOf: rig.live)
        let source = try rig.files.open(rig.target)
        do { _ = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true }); XCTFail("retired consent accepted") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
        XCTAssertEqual(try children(rig.staging), [])
    }

    func testSourcesAndStagesHaveIndependentFiniteBudgets() async throws {
        let rig = try await rig()
        var sources: [any PluginElyxDeveloperSource] = []
        for _ in 0..<8 { sources.append(try rig.files.open(rig.target)) }
        XCTAssertThrowsError(try rig.files.open(rig.target)) { error in
            XCTAssertTrue(String(describing: error).contains("source capacity"))
        }
        var candidates: [any PluginElyxDeveloperPrepared] = []
        for _ in 0..<8 { candidates.append(try await sources[0].prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })) }
        do { _ = try await sources[0].prepare(elyxFileFixtureData("2.0"), shouldExecute: { true }); XCTFail("unbounded stage capacity") }
        catch { XCTAssertTrue(String(describing: error).contains("staging capacity")) }
        XCTAssertEqual(try children(rig.staging).count, 8)
        candidates.removeAll()
        XCTAssertEqual(try children(rig.staging), [])
        sources.removeAll()
        _ = try rig.files.open(rig.target)
    }

    func testPreparedCandidateCannotSurviveBridgeEpochReplacement() async throws {
        let rig = try await rig()
        let source = try rig.files.open(rig.target)
        let original = try Data(contentsOf: rig.live)
        let candidate = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        let old = rig.readiness.get()
        rig.readiness.set(.init(abi: old.abi, registry: old.registry, epoch: UUID(), hooks: old.hooks))
        XCTAssertThrowsError(try candidate.checkBeforePublication())
        XCTAssertThrowsError(try candidate.publish(shouldExecute: { true }))
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
    }

    func testV1ManifestChunkCheckReleaseExactShapesAndNoRawFD() async throws {
        let rig = try await rig()
        let source = try rig.files.open(rig.target)
        PluginElyxDeveloperDescriptorExecution.install(.owner(rig.target.owner))
        defer { PluginElyxDeveloperDescriptorExecution.install(nil); withExtendedLifetime(source) {} }
        let claim = try sourceCall(rig, "manifest", ["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "expected_source_sha256": source.sha256])
        XCTAssertEqual(claim["ok"] as? Bool, true)
        let value = try XCTUnwrap(claim["value"] as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["abi", "read_id", "descriptor", "read_only", "load_reader_abi"]))
        XCTAssertEqual(value["read_only"] as? Bool, true)
        XCTAssertEqual(value["load_reader_abi"] as? Int, 1)
        let proof = try XCTUnwrap(value["descriptor"] as? [String: Any])
        XCTAssertEqual(Set(proof.keys), Set(["abi", "schema", "capability", "purpose", "plugin_id", "owner_token", "format",
            "source_sha256", "byte_length", "source_namespace", "source_nonce"]))
        XCTAssertEqual(proof["purpose"] as? String, "manifest")
        XCTAssertEqual(proof["owner_token"] as? String, rig.target.owner.wireToken)
        XCTAssertNil(proof["fd"])
        for key in ["capability", "source_sha256", "source_namespace", "source_nonce"] {
            let hex = try XCTUnwrap(proof[key] as? String)
            XCTAssertEqual(hex.count, 64)
            XCTAssertTrue(hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
        let id = try XCTUnwrap(value["read_id"] as? String)
        let ticket: [String: Any] = ["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "read_id": id]
        let read = try sourceCall(rig, "read", ticket.merging(["offset": 0, "count": 65536]) { _, new in new })
        let chunk = try XCTUnwrap(read["value"] as? [String: Any])
        XCTAssertEqual(Set(chunk.keys), Set(["offset", "data_base64"]))
        XCTAssertEqual(chunk["offset"] as? Int, 0)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(chunk["data_base64"] as? String)), source.archiveBytes)
        let check = try sourceCall(rig, "check", ticket)
        let checked = try XCTUnwrap(check["value"] as? [String: Any])
        XCTAssertEqual(Set(checked.keys), Set(["read_id", "descriptor", "current"]))
        XCTAssertEqual(checked["current"] as? Bool, true)
        let invalidRanges: [[String: Any]] = [["offset": true, "count": 1], ["offset": 0, "count": 65537], ["offset": -1, "count": 1]]
        for invalid in invalidRanges {
            XCTAssertEqual(try sourceCall(rig, "read", ticket.merging(invalid) { _, new in new })["ok"] as? Bool, false)
        }
        XCTAssertEqual(try sourceCall(rig, "release", ticket, ownerToken: "different-owner")["ok"] as? Bool, false)
        let released = try sourceCall(rig, "release", ticket)
        XCTAssertEqual((released["value"] as? [String: Any])?["released"] as? Bool, true)
        XCTAssertEqual((try sourceCall(rig, "release", ticket)["value"] as? [String: Any])?["released"] as? Bool, false)
        XCTAssertEqual(try sourceCall(rig, "read", ticket.merging(["offset": 0, "count": 1]) { _, new in new })["ok"] as? Bool, false)
        XCTAssertEqual(rig.registry.outstandingReadCount, 0)
    }

    func testV1InspectionClaimUsesExactProofAndChunkTransport() async throws {
        let rig = try await rig(wireInspection: true)
        let source = try rig.files.open(rig.target)
        let candidate = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        XCTAssertEqual(candidate.metadata.version, "2.0")
        XCTAssertEqual(rig.registry.outstandingReadCount, 0)
        XCTAssertEqual(rig.registry.outstandingCount, 0)
        try candidate.checkBeforePublication()
    }

    func testManifestRejectsAmbiguousReceiptsAndActualFinishReclaimsTickets() async throws {
        let rig = try await rig()
        let first = try rig.files.open(rig.target)
        var second: (any PluginElyxDeveloperSource)? = try rig.files.open(rig.target)
        PluginElyxDeveloperDescriptorExecution.install(.owner(rig.target.owner))
        let request: [String: Any] = ["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "expected_source_sha256": first.sha256]
        let ambiguous = try sourceCall(rig, "manifest", request)
        XCTAssertEqual(ambiguous["ok"] as? Bool, false)
        XCTAssertTrue(String(describing: ambiguous["error"]).contains("ambiguous"))
        withExtendedLifetime(second) {}
        second = nil
        let claimed = try sourceCall(rig, "manifest", request)
        XCTAssertEqual(claimed["ok"] as? Bool, true)
        XCTAssertEqual(rig.registry.outstandingReadCount, 1)
        // No Python release: actual native invocation completion still retires
        // the reader, capability and its held FD/source receipt.
        PluginElyxDeveloperDescriptorExecution.install(nil)
        XCTAssertEqual(rig.registry.outstandingReadCount, 0)
        XCTAssertEqual(rig.registry.outstandingCount, 0)
        withExtendedLifetime(first) {}
    }

    func testManifestReadRefusesSourceReplacementAndAllowsRetiringRelease() async throws {
        let rig = try await rig()
        let source = try rig.files.open(rig.target)
        PluginElyxDeveloperDescriptorExecution.install(.owner(rig.target.owner))
        defer { PluginElyxDeveloperDescriptorExecution.install(nil); withExtendedLifetime(source) {} }
        let claimed = try sourceCall(rig, "manifest", ["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "expected_source_sha256": source.sha256])
        let id = try XCTUnwrap((claimed["value"] as? [String: Any])?["read_id"] as? String)
        let ticket: [String: Any] = ["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "read_id": id]
        try source.archiveBytes.write(to: rig.live, options: .atomic)
        XCTAssertEqual(try sourceCall(rig, "check", ticket)["ok"] as? Bool, false)
        XCTAssertEqual(try sourceCall(rig, "read", ticket.merging(["offset": 0, "count": 1]) { _, new in new })["ok"] as? Bool, false)
        XCTAssertEqual((try sourceCall(rig, "release", ticket)["value"] as? [String: Any])?["released"] as? Bool, true)
    }

    func testStolenStageBeforeCleanupRetainsCandidateAndClosesAdmission() async throws {
        let stolen = ElyxFilesBox<URL?>(nil)
        let rig = try await rig(hooks: .init { point, directory in
            if case .beforeCleanup = point {
                let destination = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("stolen-stage")
                try FileManager.default.moveItem(at: directory, to: destination)
                stolen.set(destination)
            }
        })
        let source = try rig.files.open(rig.target)
        let bytes = try elyxFileFixtureData("2.0")
        var prepared: (any PluginElyxDeveloperPrepared)? = try await source.prepare(bytes, shouldExecute: { true })
        withExtendedLifetime(prepared) {}
        prepared = nil
        let file = try XCTUnwrap(stolen.get()).appendingPathComponent("candidate.eaf")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(rig.diagnostics.get().isEmpty)
        do { _ = try await source.prepare(bytes, shouldExecute: { true }); XCTFail("lost namespace admitted another stage") }
        catch { XCTAssertTrue(String(describing: error).contains("recovery")) }
    }

    func testStageStolenAfterCleanupLookupIsNotRenamedOrDeleted() async throws {
        let stolen = ElyxFilesBox<URL?>(nil)
        let rig = try await rig(hooks: .init { point, file in
            if case .cleanupLookup = point, stolen.get() == nil, file.lastPathComponent == "candidate.eaf" {
                let directory = file.deletingLastPathComponent()
                let destination = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("stolen-after-lookup")
                try FileManager.default.moveItem(at: directory, to: destination)
                stolen.set(destination)
            }
        })
        let source = try rig.files.open(rig.target)
        let bytes = try elyxFileFixtureData("2.0")
        var prepared: (any PluginElyxDeveloperPrepared)? = try await source.prepare(bytes, shouldExecute: { true })
        withExtendedLifetime(prepared) {}; prepared = nil
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stolen.get()).appendingPathComponent("candidate.eaf")), bytes)
        XCTAssertFalse(rig.diagnostics.get().isEmpty)
        do { _ = try await source.prepare(bytes, shouldExecute: { true }); XCTFail("lookup-race debt allowed another stage") }
        catch { XCTAssertTrue(String(describing: error).contains("recovery")) }
    }

    func testFailedInitializationCleanupDoesNotDeleteStolenNamespace() async throws {
        let stolen = ElyxFilesBox<URL?>(nil)
        let rig = try await rig(hooks: .init { point, file in
            if case .candidateSealed = point {
                let directory = file.deletingLastPathComponent()
                let destination = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("stolen-init")
                try FileManager.default.moveItem(at: directory, to: destination)
                stolen.set(destination)
            }
        })
        let source = try rig.files.open(rig.target)
        let bytes = try elyxFileFixtureData("2.0")
        do { _ = try await source.prepare(bytes, shouldExecute: { true }); XCTFail("stolen initialization succeeded") } catch { }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stolen.get()).appendingPathComponent("candidate.eaf")), bytes)
        XCTAssertFalse(rig.diagnostics.get().isEmpty)
        do { _ = try await source.prepare(bytes, shouldExecute: { true }); XCTFail("initialization debt allowed another write") }
        catch { XCTAssertTrue(String(describing: error).contains("recovery")) }
    }

    func testCleanupRejectsStageABAAtBothHookBoundaries() async throws {
        for afterLookup in [false, true] {
            let candidate = ElyxFilesBox<URL?>(nil)
            let moved = MaintenanceTestFlag(false)
            let rig = try await rig(hooks: .init { point, url in
                let selected: Bool
                switch point {
                case .beforeCleanup: selected = !afterLookup
                case .cleanupLookup: selected = afterLookup && url.lastPathComponent == "candidate.eaf"
                default: selected = false
                }
                if selected, !moved.value {
                    moved.set(true)
                    let directory = afterLookup ? url.deletingLastPathComponent() : url
                    let stolen = directory.appendingPathExtension("stolen")
                    try FileManager.default.moveItem(at: directory, to: stolen)
                    try FileManager.default.moveItem(at: stolen, to: directory)
                    candidate.set(directory.appendingPathComponent("candidate.eaf"))
                }
            })
            let source = try rig.files.open(rig.target)
            let bytes = try elyxFileFixtureData("2.0")
            var prepared: (any PluginElyxDeveloperPrepared)? = try await source.prepare(bytes, shouldExecute: { true })
            withExtendedLifetime(prepared) {}; prepared = nil
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(candidate.get())), bytes)
            XCTAssertFalse(rig.diagnostics.get().isEmpty)
            do { _ = try await source.prepare(bytes, shouldExecute: { true }); XCTFail("stage ABA restored cleanup authority") }
            catch { XCTAssertTrue(String(describing: error).contains("recovery")) }
        }
    }

    func testFailedInitializationWithIntactCustodyReclaimsAndPermitsRetry() async throws {
        let fail = MaintenanceTestFlag()
        let rig = try await rig(hooks: .init { point, _ in
            if case .candidateSealed = point, fail.value { fail.set(false); throw POSIXError(.EIO) }
        })
        let source = try rig.files.open(rig.target)
        let bytes = try elyxFileFixtureData("2.0")
        do { _ = try await source.prepare(bytes, shouldExecute: { true }); XCTFail("fixture seal fault did not run") } catch { }
        XCTAssertEqual(try children(rig.staging), [])
        XCTAssertEqual(rig.files.activity.snapshot.stages, 0)
        XCTAssertEqual(rig.diagnostics.get(), [])
        var prepared: (any PluginElyxDeveloperPrepared)? = try await source.prepare(bytes, shouldExecute: { true })
        XCTAssertEqual(rig.files.activity.snapshot.stages, 1)
        withExtendedLifetime(prepared) {}; prepared = nil
        XCTAssertEqual(try children(rig.staging), [])
        XCTAssertEqual(rig.files.activity.snapshot.stages, 0)
        XCTAssertEqual(rig.diagnostics.get(), [])
    }

    func testRefusedPublicationHasStructuredZeroWriteOutcome() async throws {
        let exchanges = ElyxFilesBox(0)
        let rig = try await rig(hooks: .init { point, _ in
            if case .beforeExchange = point { exchanges.set(exchanges.get() + 1) }
        })
        let original = try Data(contentsOf: rig.live)
        let source = try rig.files.open(rig.target)
        let prepared = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        XCTAssertThrowsError(try prepared.publish(shouldExecute: { false })) { error in
            let response = PluginElyxDeveloperError.response(error, request: nil)
            XCTAssertEqual(response["publication_outcome"], .string("refused"))
            XCTAssertEqual(response["source_changed"], .bool(false))
            XCTAssertEqual(response["reloaded"], .bool(false))
            XCTAssertEqual(response["error_kind"], .string("Superseded"))
        }
        XCTAssertEqual(exchanges.get(), 0)
        XCTAssertEqual(try Data(contentsOf: rig.live), original)
        XCTAssertEqual(rig.fixture.host.callbackOwner(id: rig.target.plugin.id), rig.target.owner)
    }

    func testDirectorySyncErrorKeepsStructuredCommittedOutcome() async throws {
        let calls = ElyxFilesBox(0)
        let rig = try await rig(hooks: .init(directorySync: { fd in
            calls.set(calls.get() + 1)
            if calls.get() == 2 {
                // Fault at the directory-sync boundary: real fsync reports EBADF.
                // The underlying exchanged files and namespace stay untouched.
                XCTAssertEqual(fsync(-1), -1)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }))
        let source = try rig.files.open(rig.target)
        let bytes = try elyxFileFixtureData("2.0")
        let prepared = try await source.prepare(bytes, shouldExecute: { true })
        let request = try PluginElyxDeveloperRequest(json: "{\"@\":\"elyx_changes\",\"plugin_id\":\"7_archive\",\"changes\":[]}")
        do { try prepared.publish(shouldExecute: { true }); XCTFail("directory-sync failure reported success") }
        catch {
            let response = PluginElyxDeveloperError.response(error, request: request)
            XCTAssertEqual(response["publication_outcome"], .string("committed"))
            XCTAssertEqual(response["source_changed"], .bool(true))
            XCTAssertEqual(response["reloaded"], .bool(false))
        }
        XCTAssertEqual(try Data(contentsOf: rig.live), bytes)
        XCTAssertEqual(calls.get(), 2)
    }

    func testRegistryRetirementRevokesReaderButRetainsItsRealFDThroughCompletion() async throws {
        let rig = try await rig()
        let source = try rig.files.open(rig.target)
        let prepared = try await source.prepare(elyxFileFixtureData("2.0"), shouldExecute: { true })
        try prepared.publish(shouldExecute: { true })
        try await rig.fixture.host.reloadPlugin(id: rig.target.plugin.id)
        let owner = try XCTUnwrap(rig.fixture.host.callbackOwner(id: rig.target.plugin.id))
        var lease: (any PluginElyxDeveloperDescriptorLease)? = try prepared.loadSource(owner: owner)
        var reader: PluginElyxDeveloperResolvedDescriptor? = try rig.registry.resolve(lease!.descriptorJSON, purpose: .load, caller: .owner(owner))
        let fd = try XCTUnwrap(reader).nativeDescriptorForTesting
        rig.registry.invalidate()
        XCTAssertThrowsError(try lease?.checkCurrent())
        XCTAssertThrowsError(try reader?.read(offset: 0, count: 1))
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFL), 0)
        lease = nil
        XCTAssertEqual(rig.registry.outstandingCount, 0)
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFL), 0, "lease retirement closed a reader still held by execution")
        withExtendedLifetime(reader) {}; reader = nil
        XCTAssertEqual(fcntl(fd, F_GETFL), -1)
        XCTAssertEqual(errno, EBADF)
    }
}
#endif
