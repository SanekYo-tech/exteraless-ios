import Foundation
import XCTest
@testable import NativeElyxModeRoot
@testable import PluginHost
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct ModeABAObservation: Sendable {
    let storedOn: Bool
    let diskOn: Bool
    let actorContinuationsHeld: Bool
    let oldScopeRetired: Bool
    let oldSessionRetired: Bool
    let oldRegistryRetired: Bool
    let pendingRequestRetired: Bool
    let oldCapabilityRejected: Bool
}

/// Observe the two ACTUAL atomic preference writes, outside the store lock.
/// Off's writer waits for on's durable publication. On captures its observations
/// before returning either writer to MainActor; no mode flag/result is supplied.
private final class ModeWriteHold: @unchecked Sendable {
    let offPersisted = OneShotResult<Void>()
    let bothPersisted = OneShotResult<ModeABAObservation>()
    private let releaseOff = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var capture: (@Sendable () throws -> ModeABAObservation)?
    private var writes: [Bool] = []
    func arm(_ body: @escaping @Sendable () throws -> ModeABAObservation) {
        lock.lock(); capture = body; writes = []; lock.unlock()
    }
    func finish() { lock.lock(); capture = nil; lock.unlock(); releaseOff.signal() }
    var observed: [Bool] { lock.lock(); defer { lock.unlock() }; return writes }
    func persisted(_ change: PluginManagerPreferenceChange) {
        guard case let .developer(on) = change else { return }
        lock.lock()
        let capture = self.capture
        if capture != nil { writes.append(on) }
        lock.unlock()
        guard let capture else { return }
        if !on {
            offPersisted.succeed(())
            if releaseOff.wait(timeout: .now() + 5) != .success {
                bothPersisted.fail(PluginHostError.timeout("second real preference write"))
            }
        } else {
            defer { finish() }
            do { bothPersisted.succeed(try capture()) }
            catch { bothPersisted.fail(PluginHostError.runtimeFailure(String(describing: error))) }
        }
    }
}

private final class ModeInvocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PluginElyxDeveloperInvocation?
    func set(_ value: PluginElyxDeveloperInvocation) { lock.lock(); self.value = value; lock.unlock() }
    var isCurrent: Bool { lock.lock(); let call = value; lock.unlock(); return call?.isCurrent() == true }
}

private final class ModeOwnedFD: @unchecked Sendable {
    let raw: Int32
    init(_ url: URL) throws {
        raw = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard raw >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    deinit { _ = close(raw) }
    func check() throws {
        guard fcntl(raw, F_GETFL) & O_ACCMODE == O_RDONLY else { throw PluginElyxDeveloperError.stale("own fixture FD retired") }
    }
}

private struct ModeHarness: Sendable {
    let root: URL
    let preferencesURL: URL
    let host: PluginHost
    let engine: MaintenanceTestEngine
    let store: PluginManagerPreferences
    let controller: NativeElyxModeRootFixture
    let owner: PluginHost.CallbackOwner
}

final class NativeElyxModeABATests: XCTestCase {
    @MainActor
    private func until(_ message: String, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PluginHostError.timeout(message) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    private func harness(start: Bool = true, hold: ModeWriteHold? = nil) async throws -> ModeHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-elyx-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hostBox = MaintenanceTestHostBox()
        // Python execution only is canned. The probe runs on the actual Host
        // inspector worker/TLS and reaches its installed BridgeServices registry.
        let engine = MaintenanceTestEngine(onScript: { _, source in
            let prefix = "__import__('exteraless_runtime._elyx_readiness', fromlist=['probe_json']).probe_json("
            guard source.hasPrefix(prefix) else { return nil }
            let nonce = try JSONDecoder().decode(String.self, from: Data(source.dropFirst(prefix.count).dropLast().utf8))
            guard case .inspection? = PluginElyxDeveloperDescriptorExecution.current, let host = hostBox.get() else {
                throw PluginHostError.internalInconsistency("missing actual Host inspector/TLS")
            }
            let payload = try PluginRuntimeScript.encodeJSON(["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "read_id": nonce])
            let call = try PluginRuntimeScript.encodeJSON(["op": "elyx_source", "operation": "check", "payload": payload,
                                                         "pluginId": "@elyx-inspection", "ownerToken": NSNull()])
            let raw = host.bridge.dispatchJSON(call, pluginId: "@elyx-inspection")
            let reply = try JSONDecoder().decode([String: PluginJSONValue].self, from: Data(raw.utf8))
            guard reply["error"] == .object(["kind": .string("Superseded"), "message": .string("native read ticket is unknown or released")]) else {
                throw PluginHostError.runtimeFailure("real native readiness challenge did not reject its unknown ticket")
            }
            return try PluginRuntimeScript.encodeJSON(["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI,
                "challenge": nonce, "gate": "builtin", "hooks": ["inspect", "manifest", "verifiedLoad"], "rejected": true])
        })
        let host = try PluginHost(engine: engine, configuration: .init(runtime: .init(pluginRootDirectory: root.appendingPathComponent("plugins").path),
            interpreters: .init(callTimeout: 2), storageDirectory: root))
        hostBox.set(host)
        try await host.start(safeMode: true)
        let source = root.appendingPathComponent("alpha.plugin")
        try Data("# owned data-only engine fixture\n".utf8).write(to: source)
        _ = try await host.installPlugin(sourceURL: source, metadata: Plugin(id: "alpha"),
            selection: PluginPermissionRecord(level: .trusted, grants: [.settings]))
        let owner = try XCTUnwrap(host.callbackOwner(id: "alpha"))
        XCTAssertTrue(host.permissions.has("alpha", .settings))
        let preferencesURL = root.appendingPathComponent("manager-presentation.json")
        let store = try PluginManagerPreferences(url: preferencesURL, legacyEngineEnabled: true,
                                                didPersist: { hold?.persisted($0) })
        let controller = NativeElyxModeRootFixture(host: host, store: store, root: root)
        addTeardownBlock {
            hold?.finish()
            await MainActor.run { controller.close() }
            await host.stop()
            try? FileManager.default.removeItem(at: root)
        }
        if start {
            try await controller.managerDeveloper(true) // Actual Root writer; no manual mode assignment.
            try await until("initial public Host activation") { controller.elyxDeveloperService?.isActive == true }
        }
        return ModeHarness(root: root, preferencesURL: preferencesURL, host: host, engine: engine, store: store, controller: controller, owner: owner)
    }

    @MainActor
    private func dispatch(_ provider: any PluginBridgeExtension, owner: PluginHost.CallbackOwner,
                          member: String, arguments: [PluginJSONValue] = []) async throws {
        let wire = try JSONEncoder().encode(PluginJSONValue.object(["op": .string("call"), "fqcn": .string("exteraless.ios.Runtime"),
            "member": .string(member), "args": .array(arguments), "ownerToken": .string(owner.wireToken), "pluginId": .string(owner.pluginId)]))
        let text = String(decoding: wire, as: UTF8.self)
        try await Task.detached {
            guard let output = try provider.dispatch(requestJSON: text, pluginId: owner.pluginId),
                  case let .object(reply) = try JSONDecoder().decode(PluginJSONValue.self, from: Data(output.utf8)),
                  reply["ok"] == .bool(true), case let .object(value)? = reply["value"], value["accepted"] == .bool(true) else {
                throw PluginHostError.runtimeFailure("actual native provider did not admit the fixture command")
            }
        }.value
    }

    private func disk(_ url: URL) throws -> PluginManagerPresentationState {
        try JSONDecoder().decode(PluginManagerPresentationState.self, from: Data(contentsOf: url))
    }

    @MainActor
    private func capability(_ h: ModeHarness) throws -> (descriptor: PluginElyxDeveloperDescriptor, consumer: PluginElyxDeveloperDescriptorConsumer) {
        let service = try XCTUnwrap(h.controller.elyxDeveloperService)
        let scope = try XCTUnwrap(h.controller.elyxDeveloperActivation)
        let url = h.root.appendingPathComponent("own-capability.elyx")
        let data = Data("owned read-only mode-ABA capability".utf8)
        try data.write(to: url)
        let held = try ModeOwnedFD(url)
        let current: @Sendable () throws -> Void = {
            try held.check()
            guard scope.isCurrent, service.isActive else { throw PluginElyxDeveloperError.stale("captured developer mode authority retired") }
        }
        let descriptor = try service.registry.issue(ElyxDescriptorBacking(descriptor: held.raw,
            claims: .init(purpose: .inspect, pluginId: "alpha", format: .elyx, owner: nil,
                          namespace: elyxNativeNonce(), version: elyxNativeNonce(), sha256: ElyxNativeSHA256.hex(data), byteCount: data.count),
            check: current, verify: current))
        let consumer = try descriptor.bindNativeInspection()
        try descriptor.checkCurrent() // Issued and unconsumed before off; not an already-replayed proof.
        return (descriptor, consumer)
    }

    @MainActor
    func testTwoRealNativeQueuesCommitOffOnBeforeEitherActorContinuation() async throws {
        let hold = ModeWriteHold()
        defer { hold.finish() }
        let h = try await harness(hold: hold)
        let oldScope = try XCTUnwrap(h.controller.elyxDeveloperActivation)
        let oldService = try XCTUnwrap(h.controller.elyxDeveloperService)
        let oldEpoch = try XCTUnwrap(oldService.readyReceipt).epoch
        let oldSession = try XCTUnwrap(h.controller.developerServer.session)
        let issued = try capability(h)
        let oldCapability = issued.descriptor
        let proof = oldCapability.descriptorJSON
        let counter = h.controller.completions
        let before = counter.value
        let invocation = ModeInvocationBox(), entered = OneShotResult<Void>(), resume = OneShotResult<Void>()
        defer { resume.succeed(()) }
        let authenticated = try PluginDeveloperProtocol.request(Data("{\"@\":\"elyx_ping\",\"#\":42,\"token\":\"own-mode-fixture\"}".utf8), token: "own-mode-fixture")
        let plan = try PluginElyxDeveloperIngress.capture(authenticated, host: h.host, account: 2, targets: { try h.host.elyxDeveloperTargets($0) })
        let pending = Task { @MainActor in
            await PluginElyxDeveloperIngress.run(plan, session: oldSession, files: nil,
                nativeCurrent: { oldScope.isCurrent && oldService.isActive && h.store.snapshot.developerMode }, execute: { call in
                    invocation.set(call); entered.succeed(())
                    try await resume.awaitValue()
                    return try await h.host.elyxDeveloper(call.request, targets: call.targets, account: call.account,
                        files: call.files, deadline: call.deadline, shouldExecute: call.isCurrent, publication: call.publication)
                }, actorCurrent: { oldScope.isCurrent })
        }
        _ = try await maintenanceTestWait(entered)
        XCTAssertTrue(invocation.isCurrent)
        hold.arm { [store = h.store, url = h.preferencesURL] in
            let disk = try JSONDecoder().decode(PluginManagerPresentationState.self, from: Data(contentsOf: url))
            return ModeABAObservation(storedOn: store.snapshot.developerMode, diskOn: disk.developerMode,
                actorContinuationsHeld: counter.value == before, oldScopeRetired: !oldScope.isCurrent,
                oldSessionRetired: !oldSession.isActive, oldRegistryRetired: !oldService.registry.metrics.accepting,
                pendingRequestRetired: !invocation.isCurrent, oldCapabilityRejected: (try? oldCapability.checkCurrent()) == nil)
        }
        try await dispatch(h.controller.developer, owner: h.owner, member: "requestDeveloperServerStop")
        _ = try await maintenanceTestWait(hold.offPersisted)
        XCTAssertFalse(h.store.snapshot.developerMode)
        XCTAssertFalse(try disk(h.preferencesURL).developerMode)
        XCTAssertEqual(counter.value, before)
        try await dispatch(h.controller.config, owner: h.owner, member: "setPluginConfig", arguments: [.string("developerMode"), .bool(true)])
        let observed = try await maintenanceTestWait(hold.bothPersisted)
        XCTAssertEqual(hold.observed, [false, true])
        XCTAssertTrue(observed.storedOn && observed.diskOn && observed.actorContinuationsHeld)
        XCTAssertTrue(observed.oldScopeRetired && observed.oldSessionRetired && observed.oldRegistryRetired)
        XCTAssertTrue(observed.pendingRequestRetired && observed.oldCapabilityRejected)
        resume.succeed(())
        let refused = await pending.value
        XCTAssertEqual(refused["ok"], .bool(false))
        XCTAssertEqual(refused["error_kind"], .string("Superseded"))
        try await until("fresh on authority and both actor continuations") {
            counter.value == before + 2 && h.controller.elyxDeveloperService?.isActive == true
        }
        let next = try XCTUnwrap(h.controller.elyxDeveloperService)
        XCTAssertNotEqual(next.registry.identifier, oldService.registry.identifier)
        XCTAssertNotEqual(try XCTUnwrap(next.readyReceipt).epoch, oldEpoch)
        XCTAssertNotEqual(h.controller.elyxDeveloperActivation?.id, oldScope.id)
        XCTAssertFalse(h.controller.developerServer.session === oldSession)
        XCTAssertEqual(h.controller.developerServer.sessionCount, 2)
        XCTAssertThrowsError(try oldService.registry.resolve(proof, purpose: .inspect, caller: issued.consumer))
        XCTAssertThrowsError(try next.registry.resolve(proof, purpose: .inspect, caller: issued.consumer))
        XCTAssertFalse(oldScope.isCurrent)
        XCTAssertFalse(oldSession.isActive)
        h.controller.close()
        await h.host.stop()
        XCTAssertEqual(h.engine.counts.initialized, 1)
        XCTAssertEqual(h.engine.counts.finalized, 1)
        XCTAssertEqual(h.engine.counts.live, 0)
    }

    @MainActor
    func testFailedOffWritePropagatesErrorAndRestartUsesFreshAuthority() async throws {
        let h = try await harness()
        let oldScope = try XCTUnwrap(h.controller.elyxDeveloperActivation)
        let oldService = try XCTUnwrap(h.controller.elyxDeveloperService)
        let oldEpoch = try XCTUnwrap(oldService.readyReceipt).epoch
        let oldSession = try XCTUnwrap(h.controller.developerServer.session)
        let oldCapability = try capability(h).descriptor
        let preserved = h.preferencesURL.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: h.preferencesURL, to: preserved)
        try FileManager.default.createDirectory(at: h.preferencesURL, withIntermediateDirectories: false)
        do { try await h.controller.managerDeveloper(false); XCTFail("failed durable write reported success") }
        catch { XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain) }
        XCTAssertTrue(h.store.snapshot.developerMode)
        XCTAssertTrue(try disk(preserved).developerMode)
        XCTAssertFalse(oldScope.isCurrent)
        XCTAssertFalse(oldSession.isActive)
        XCTAssertFalse(oldService.registry.metrics.accepting)
        XCTAssertThrowsError(try oldCapability.checkCurrent())
        XCTAssertNil(h.controller.developerServer.session)
        try FileManager.default.removeItem(at: h.preferencesURL)
        try FileManager.default.moveItem(at: preserved, to: h.preferencesURL)
        try await dispatch(h.controller.developer, owner: h.owner, member: "requestDeveloperServerStart")
        try await until("restart from truthful still-on stored state") { h.controller.elyxDeveloperService?.isActive == true }
        let next = try XCTUnwrap(h.controller.elyxDeveloperService)
        XCTAssertNotEqual(next.registry.identifier, oldService.registry.identifier)
        XCTAssertNotEqual(try XCTUnwrap(next.readyReceipt).epoch, oldEpoch)
        XCTAssertTrue(try disk(h.preferencesURL).developerMode)
        XCTAssertThrowsError(try oldCapability.checkCurrent())
        XCTAssertFalse(h.controller.developerServer.session === oldSession)
    }

    @MainActor
    func testRejectedPermissionAuthorityAndContextCannotRetireCurrentDeveloperService() async throws {
        let h = try await harness()
        let scope = try XCTUnwrap(h.controller.elyxDeveloperActivation)
        let service = try XCTUnwrap(h.controller.elyxDeveloperService)
        let session = try XCTUnwrap(h.controller.developerServer.session)
        let original = try Data(contentsOf: h.preferencesURL)
        let completions = h.controller.completions.value
        let callbacks = PluginCallbackDispatcher(host: h.host)
        let authority = PluginConfigAuthority(isCurrent: callbacks.permissionPredicate("alpha", requiring: [.settings]))
        try h.host.setGrantedPermissions(id: "alpha", permissions: [])
        do { try await dispatch(h.controller.developer, owner: h.owner, member: "requestDeveloperServerStop"); XCTFail("ungranted caller was admitted") }
        catch { XCTAssertEqual((error as? BridgeFailure)?.kind, "SecurityError") }
        try h.host.setGrantedPermissions(id: "alpha", permissions: [.settings])
        XCTAssertTrue(h.host.permissions.has("alpha", .settings))
        XCTAssertFalse(authority.isCurrent())
        do { try await h.controller.managerDeveloper(false, authority: authority); XCTFail("retired Root authority was admitted") }
        catch {
            guard let failure = error as? PluginHostError, case .superseded = failure else { return XCTFail("expected typed Superseded") }
        }
        let context = h.controller.currentContext
        h.controller.currentContext = nil
        do { try await h.controller.managerDeveloper(false); XCTFail("Root without context was admitted") }
        catch { XCTAssertEqual(error as? PluginHostError, .notRunning) }
        h.controller.currentContext = context
        XCTAssertTrue(scope.isCurrent && session.isActive && service.isActive)
        XCTAssertTrue(h.controller.developerServer.session === session)
        XCTAssertEqual(h.controller.completions.value, completions)
        XCTAssertEqual(try Data(contentsOf: h.preferencesURL), original)
    }

    @MainActor
    func testAlreadyOffAndCoalescedOnControlsPreserveCurrentAuthority() async throws {
        let h = try await harness(start: false)
        try await h.controller.managerDeveloper(false)
        XCTAssertFalse(h.store.snapshot.developerMode)
        XCTAssertFalse(try disk(h.preferencesURL).developerMode)
        XCTAssertNil(h.controller.elyxDeveloperActivation)
        XCTAssertNil(h.controller.elyxDeveloperService)
        XCTAssertNil(h.controller.developerServer.session)
        try await h.controller.managerDeveloper(true)
        try await until("first on activation") { h.controller.elyxDeveloperService?.isActive == true }
        let service = try XCTUnwrap(h.controller.elyxDeveloperService)
        let scope = try XCTUnwrap(h.controller.elyxDeveloperActivation)
        let session = try XCTUnwrap(h.controller.developerServer.session)
        let starts = h.controller.developerServer.startCount, completions = h.controller.completions.value
        let consent = h.host.permissionSnapshot(id: "alpha")
        try await dispatch(h.controller.config, owner: h.owner, member: "setPluginConfig", arguments: [.string("developerMode"), .bool(true)])
        try await dispatch(h.controller.developer, owner: h.owner, member: "requestDeveloperServerStart")
        try await until("coalesced on controls") {
            h.controller.developerServer.startCount == starts + 2 && h.controller.completions.value == completions + 1
        }
        XCTAssertTrue(h.controller.elyxDeveloperService === service)
        XCTAssertEqual(h.controller.elyxDeveloperActivation?.id, scope.id)
        XCTAssertTrue(h.controller.developerServer.session === session)
        XCTAssertEqual(h.controller.developerServer.sessionCount, 1)
        XCTAssertEqual(service.probeAttempts, 1)
        XCTAssertEqual(h.host.permissionSnapshot(id: "alpha"), consent)
        XCTAssertTrue(h.store.snapshot.engineEnabled)
        XCTAssertFalse(h.store.snapshot.safeMode)
        XCTAssertTrue(try disk(h.preferencesURL).developerMode)
    }
}
