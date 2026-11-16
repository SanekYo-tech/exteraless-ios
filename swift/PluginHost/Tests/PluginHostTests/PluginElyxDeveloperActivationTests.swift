import Foundation
import XCTest
@testable import PluginHost

#if canImport(Darwin) || canImport(Glibc)
/// Only Python execution is a recorder here. Host creates its real fresh worker,
/// installs actual TLS and dispatches the challenge through the installed native
/// BridgeServices/registry. The separate fifth child proves the built-in C gate.
private final class ElyxActivationRecorder: @unchecked Sendable {
    enum Mode: Equatable, Sendable { case observed, counterfeit, wrongIdentity, repeated }
    let host = MaintenanceTestHostBox()
    private let lock = NSLock()
    private var mode = Mode.observed
    private var barrier: (@Sendable () throws -> Void)?

    func select(_ value: Mode) { lock.lock(); mode = value; lock.unlock() }
    func blockOnce(_ body: @escaping @Sendable () throws -> Void) { lock.lock(); barrier = body; lock.unlock() }
    private func take() -> (Mode, (@Sendable () throws -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        defer { barrier = nil }
        return (mode, barrier)
    }

    func script(_ source: String) throws -> String? {
        let prefix = "__import__('exteraless_runtime._elyx_readiness', fromlist=['probe_json']).probe_json("
        guard source.hasPrefix(prefix) else { return nil }
        let nonce = try JSONDecoder().decode(String.self, from: Data(source.dropFirst(prefix.count).dropLast().utf8))
        let (mode, barrier) = take()
        XCTAssertFalse(Thread.isMainThread)
        guard case .inspection? = PluginElyxDeveloperDescriptorExecution.current else {
            throw PluginHostError.internalInconsistency("Host omitted actual inspector TLS")
        }
        try barrier?()
        if mode != .counterfeit {
            let host = try XCTUnwrap(host.get())
            let id = mode == .wrongIdentity ? "ownedWrongIdentity" : "@elyx-inspection"
            let payload = try PluginRuntimeScript.encodeJSON(["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI, "read_id": nonce])
            let request = try PluginRuntimeScript.encodeJSON(["op": "elyx_source", "operation": "check", "payload": payload,
                                                              "pluginId": id, "ownerToken": NSNull()])
            for _ in 0..<(mode == .repeated ? 2 : 1) {
                let output = host.bridge.dispatchJSON(request, pluginId: id)
                let value = try JSONDecoder().decode([String: PluginJSONValue].self, from: Data(output.utf8))
                XCTAssertEqual(value["ok"], .bool(false))
                if mode == .observed {
                    XCTAssertEqual(value["error"], .object(["kind": .string("Superseded"),
                        "message": .string("native read ticket is unknown or released")]))
                }
            }
        }
        return try PluginRuntimeScript.encodeJSON(["abi": PluginElyxDeveloperDescriptorRegistry.sourceABI,
            "challenge": nonce, "gate": "builtin", "hooks": ["inspect", "manifest", "verifiedLoad"], "rejected": true])
    }
}

final class PluginElyxDeveloperActivationTests: HostLifecycleTestCase {
    private func activeFixture(_ observer: ElyxActivationRecorder) async throws -> MaintenanceTestFixture {
        let engine = MaintenanceTestEngine(onScript: { _, source in try observer.script(source) })
        let fixture = try fixture(engine: engine)
        observer.host.set(fixture.host)
        try await fixture.host.start(safeMode: true)
        return fixture
    }

    func testPublicActivationRejectsPythonOnlyWrongIdentityAndRepeatedReceiptsThenRetries() async throws {
        let observer = ElyxActivationRecorder()
        let fixture = try await activeFixture(observer)
        let scope = PluginElyxDeveloperActivationScope()
        for mode in [ElyxActivationRecorder.Mode.counterfeit, .wrongIdentity, .repeated] {
            observer.select(mode)
            do {
                _ = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
                XCTFail("fabricated or incorrectly bound readiness was accepted")
            } catch { XCTAssertTrue(String(describing: error).contains("did not prove")) }
            XCTAssertEqual(fixture.engine.counts.live, 0)
        }
        observer.select(.observed)
        let service = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        XCTAssertEqual(service.probeAttempts, 4)
        XCTAssertEqual(service.registry.metrics.challengesObserved, 3) // repeated witness (2), then genuine single observation (1)
        XCTAssertEqual(service.readyReceipt?.epoch, fixture.host.bridge.elyxSourceDispatcherBindingEpoch)
        XCTAssertNoThrow(try service.fileAuthority())
        XCTAssertEqual(fixture.engine.counts.created, 4)
        XCTAssertEqual(fixture.engine.counts.destroyed, 4)
        XCTAssertFalse(fixture.engine.calls.contains { $0.source.contains("_exteraless_runtime.configure(") || $0.source.contains("load_json(") })
        XCTAssertEqual(service.registry.metrics.capabilities, 0)
        XCTAssertEqual(service.registry.metrics.readTickets, 0)
    }

    func testConcurrentPublicActivationUsesOneWorkerAndOneProvider() async throws {
        let observer = ElyxActivationRecorder()
        let fixture = try await activeFixture(observer)
        let scope = PluginElyxDeveloperActivationScope()
        let entered = OneShotResult<Void>(), gate = DispatchSemaphore(value: 0)
        observer.blockOnce { entered.succeed(()); try maintenanceTestBlock(gate) }
        defer { gate.signal() }
        let first = Task { try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent }) }
        _ = try await maintenanceTestWait(entered)
        let second = Task { try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent }) }
        gate.signal()
        let a = try await first.value, b = try await second.value
        XCTAssertTrue(a === b)
        XCTAssertTrue(try a.fileAuthority() === b.fileAuthority())
        XCTAssertEqual(a.probeAttempts, 1)
        XCTAssertEqual(a.registry.metrics.challengesObserved, 1)
        XCTAssertEqual(fixture.engine.counts.created, 1)
    }

    func testFileConstructionFailureRetainsDataAndRetriesWithFreshReadiness() async throws {
        let observer = ElyxActivationRecorder()
        let fixture = try await activeFixture(observer)
        let scope = PluginElyxDeveloperActivationScope()
        let staging = fixture.root.appendingPathComponent(".elyx-developer-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let marker = staging.appendingPathComponent("owned-recovery-marker")
        try Data("must retain".utf8).write(to: marker)
        do {
            _ = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
            XCTFail("nonempty staging was silently adopted")
        } catch { XCTAssertTrue(String(describing: error).contains("recovery")) }
        XCTAssertEqual(try Data(contentsOf: marker), Data("must retain".utf8))
        try FileManager.default.removeItem(at: marker) // Fixture owner explicitly clears its own marker.
        let ready = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        XCTAssertEqual(ready.probeAttempts, 2)
        XCTAssertEqual(ready.registry.metrics.challengesObserved, 2)
        XCTAssertNotNil(ready.readyReceipt)
        XCTAssertEqual(fixture.engine.counts.created, 2)
        XCTAssertEqual(fixture.engine.counts.destroyed, 2)
    }

    func testOldQueuedScopeCannotReplaceOrRemoveNewActivation() async throws {
        let observer = ElyxActivationRecorder()
        let fixture = try await activeFixture(observer)
        let oldScope = PluginElyxDeveloperActivationScope(), nextScope = PluginElyxDeveloperActivationScope()
        let entered = OneShotResult<Void>(), gate = DispatchSemaphore(value: 0)
        observer.blockOnce { entered.succeed(()); try maintenanceTestBlock(gate) }
        defer { gate.signal() }
        let delayed = Task { try await fixture.host.activateElyxDeveloper(scope: oldScope.id, isCurrent: { oldScope.isCurrent }) }
        _ = try await maintenanceTestWait(entered)
        oldScope.invalidate()
        let replacement = try await fixture.host.activateElyxDeveloper(scope: nextScope.id, isCurrent: { nextScope.isCurrent })
        let epoch = fixture.host.bridge.elyxSourceDispatcherBindingEpoch
        gate.signal()
        do { _ = try await delayed.value; XCTFail("retired activation delivered a provider") } catch { }
        do {
            _ = try await fixture.host.activateElyxDeveloper(scope: oldScope.id, isCurrent: { oldScope.isCurrent })
            XCTFail("queued obsolete scope displaced current activation")
        } catch { }
        fixture.host.deactivateElyxDeveloper(scope: oldScope.id)
        XCTAssertTrue(replacement.isActive)
        XCTAssertEqual(fixture.host.bridge.elyxSourceDispatcherBindingEpoch, epoch)
        XCTAssertEqual(replacement.registry.metrics.challengesObserved, 1)
        XCTAssertEqual(fixture.engine.counts.live, 0)
    }

    func testDispatcherABAInvalidatesReadinessAndOldInvalidationCannotRemoveReplacement() async throws {
        let observer = ElyxActivationRecorder()
        let fixture = try await activeFixture(observer)
        let scope = PluginElyxDeveloperActivationScope()
        let old = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        let oldDispatcher = try XCTUnwrap(fixture.host.bridge.elyxSourceDispatcher)
        fixture.host.bridge.elyxSourceDispatcher = nil
        fixture.host.bridge.elyxSourceDispatcher = oldDispatcher
        let restoredEpoch = fixture.host.bridge.elyxSourceDispatcherBindingEpoch
        XCTAssertFalse(old.isActive)
        XCTAssertThrowsError(try old.fileAuthority())
        old.invalidate()
        XCTAssertEqual(fixture.host.bridge.elyxSourceDispatcherBindingEpoch, restoredEpoch)
        XCTAssertNotNil(fixture.host.bridge.elyxSourceDispatcher)
        let next = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        XCTAssertNotEqual(next.registry.identifier, old.registry.identifier)
        XCTAssertNotEqual(next.readyReceipt?.epoch, restoredEpoch)
        XCTAssertFalse(old.registry.metrics.accepting)
        XCTAssertEqual(next.registry.metrics.challengesObserved, 1)
    }

    func testMaintenanceAndHostSwapRevokeOnlyTheirOwnService() async throws {
        let observer = ElyxActivationRecorder(), nextObserver = ElyxActivationRecorder()
        let fixture = try await activeFixture(observer), other = try await activeFixture(nextObserver)
        let scope = PluginElyxDeveloperActivationScope()
        let first = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        let second = try await other.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        let lease = try await fixture.host.beginSettingsMaintenance()
        XCTAssertFalse(first.isActive)
        XCTAssertFalse(first.registry.metrics.accepting)
        XCTAssertEqual(first.fileAuthorityCount, 0)
        XCTAssertTrue(second.isActive)
        XCTAssertNil(fixture.host.bridge.elyxSourceDispatcher)
        try await lease.finish(resume: true)
        let resumed = try await fixture.host.activateElyxDeveloper(scope: scope.id, isCurrent: { scope.isCurrent })
        XCTAssertNotEqual(first.registry.identifier, resumed.registry.identifier)
        await fixture.host.stop()
        XCTAssertFalse(resumed.isActive)
        XCTAssertEqual(resumed.fileAuthorityCount, 0)
        XCTAssertTrue(second.isActive)
        XCTAssertEqual(fixture.engine.counts.initialized, 1)
        XCTAssertEqual(fixture.engine.counts.finalized, 1)
    }
}
#endif
