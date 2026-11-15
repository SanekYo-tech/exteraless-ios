import Foundation
import XCTest
@testable import ExteralessCore

private final class PillFixturePluginProvider: PillPluginProvider, @unchecked Sendable {
    let callbacks = PillTestBox<[@Sendable (PillModel) -> Void]>([])
    let requests = PillTestBox<[PillPluginRequest]>([])
    let actions = PillTestBox<[PillPluginAction]>([])
    let started = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)
    let acted = DispatchSemaphore(value: 0)
    func start(_ request: PillPluginRequest, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation {
        XCTAssertFalse(Thread.isMainThread)
        requests.update { $0.append(request) }; callbacks.update { $0.append(update) }; started.signal()
        return PillCancellation { [cancelled] in XCTAssertFalse(Thread.isMainThread); cancelled.signal() }
    }
    func perform(_ action: PillPluginAction, request: PillPluginRequest) {
        XCTAssertFalse(Thread.isMainThread)
        actions.update { $0.append(action) }; acted.signal()
    }
}

final class PillPluginRegistryTests: XCTestCase {
    func testOwnerUnloadStopsProviderAndRejectsOldGenerationSnapshots() throws {
        let registry = PillPluginRegistry()
        let provider = PillFixturePluginProvider()
        let owner = PillPluginOwner(pluginId: "own.fixture", generation: UUID())
        let descriptor = PillDescriptor(id: 10_001, title: "Fixture", symbol: "circle", interval: 5)
        let registration = try registry.register(owner: owner, descriptor: descriptor, provider: provider)
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let models = PillTestBox<[PillModel]>([])
        let subscription = registry.subscribe(.init(id: descriptor.id, scope: lease.scope), lease: lease) { model in models.update { $0.append(model) } }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        let value = PillModel(id: descriptor.id, title: "Fixture", value: "Actual fixture reading", source: "own.fixture")
        provider.callbacks.read()[0](value)
        XCTAssertEqual(models.read(), [value])
        registry.unregister(owner: owner)
        XCTAssertEqual(provider.cancelled.wait(timeout: .now() + 1), .success)
        provider.callbacks.read()[0](value)
        XCTAssertEqual(models.read().count, 1)
        XCTAssertTrue(registry.descriptors.isEmpty)
        subscription.cancel(); registration.cancel()
    }

    func testCallerLeaseDeinitCancelsEvenWhileRegistryRetainsRegistration() throws {
        let registry = PillPluginRegistry()
        let provider = PillFixturePluginProvider()
        let registration = try registry.register(owner: .init(pluginId: "own.fixture", generation: UUID()), descriptor: .init(id: 10_002, title: "Fixture", symbol: "circle", interval: 5), provider: provider)
        let lease = PillAccountLease(scope: .init(accountId: 7))
        var subscription: PillCancellation? = registry.subscribe(.init(id: 10_002, scope: lease.scope), lease: lease) { _ in }
        XCTAssertNotNil(subscription)
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        subscription = nil
        XCTAssertEqual(provider.cancelled.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(registry.descriptors.count, 1)
        registration.cancel()
    }

    func testDTOValidationAndActionsStayOffRenderThread() throws {
        let registry = PillPluginRegistry()
        let provider = PillFixturePluginProvider()
        let owner = PillPluginOwner(pluginId: "own.fixture", generation: UUID())
        XCTAssertThrowsError(try registry.register(owner: owner, descriptor: .init(id: 5, title: "Override cache", symbol: "circle", interval: 5), provider: provider))
        let registration = try registry.register(owner: owner, descriptor: .init(id: 10_003, title: "Fixture", symbol: "circle", interval: 5), provider: provider)
        let lease = PillAccountLease(scope: .init(accountId: 8))
        let models = PillTestBox<[PillModel]>([])
        let request = PillPluginRequest(id: 10_003, scope: lease.scope)
        let wrongScope = registry.subscribe(.init(id: 10_003, scope: .init(accountId: 99)), lease: lease) { _ in XCTFail("Mismatched account lease") }
        XCTAssertTrue(wrongScope.isCancelled)
        let subscription = registry.subscribe(request, lease: lease) { model in models.update { $0.append(model) } }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        provider.callbacks.read()[0](.init(id: 10_003, title: "Fixture", value: "Bad progress", source: "fixture", progress: .nan))
        provider.callbacks.read()[0](.init(id: 10_004, title: "Fixture", value: "Wrong id", source: "fixture"))
        XCTAssertTrue(models.read().isEmpty)
        registry.perform(.tap, request: request, lease: lease)
        XCTAssertEqual(provider.acted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(provider.actions.read(), [.tap])
        lease.invalidate()
        provider.callbacks.read()[0](.init(id: 10_003, title: "Fixture", value: "Retired account", source: "fixture"))
        XCTAssertTrue(models.read().isEmpty)
        subscription.cancel(); registration.cancel()
    }
}
