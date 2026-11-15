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

private final class PillBurstPluginProvider: PillPluginProvider, @unchecked Sendable {
    let burst: [PillModel]
    let started = DispatchSemaphore(value: 0)
    let publish = PillTestBox<(@Sendable (PillModel) -> Void)?>(nil)
    init(_ burst: [PillModel]) { self.burst = burst }
    func start(_ request: PillPluginRequest, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation {
        XCTAssertFalse(Thread.isMainThread)
        self.publish.update { $0 = update }
        for model in self.burst { update(model) }
        self.started.signal()
        return PillCancellation()
    }
    func perform(_ action: PillPluginAction, request: PillPluginRequest) {}
}

/// Manual monotonic scheduler: proves the exact deadline without a wall-clock sleep or timing flake.
private final class PillDeliveryClock: @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let deadline: UInt64
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?
        init(deadline: UInt64, callback: @escaping @Sendable () -> Void) { self.deadline = deadline; self.callback = callback }
        var pending: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.callback != nil }
        func cancel() { self.lock.lock(); self.callback = nil; self.lock.unlock() }
        func run() {
            self.lock.lock(); let callback = self.callback; self.callback = nil; self.lock.unlock()
            callback?()
        }
    }
    private let lock = NSLock()
    private var time: UInt64 = 1_000_000_000
    private var jobs: [Job] = []
    private var scheduled = 0
    var now: UInt64 { self.lock.lock(); defer { self.lock.unlock() }; return self.time }
    var deadlines: [UInt64] { self.lock.lock(); defer { self.lock.unlock() }; return self.jobs.filter(\.pending).map(\.deadline).sorted() }
    var scheduleCount: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.scheduled }
    var timing: PillPluginDeliveryTiming {
        PillPluginDeliveryTiming(now: { self.now }, schedule: { deadline, callback in
            let job = Job(deadline: deadline, callback: callback)
            self.lock.lock(); self.jobs.append(job); self.scheduled += 1; self.lock.unlock()
            return PillCancellation { job.cancel() }
        })
    }
    func advance(by nanoseconds: UInt64) {
        self.lock.lock()
        self.time += nanoseconds
        let due = self.jobs.filter { $0.deadline <= self.time }
        self.jobs.removeAll { $0.deadline <= self.time }
        self.lock.unlock()
        for job in due.sorted(by: { $0.deadline < $1.deadline }) { job.run() }
    }
}

final class PillPluginRegistryTests: XCTestCase {
    private func model(_ phase: PillPhase, value: String? = nil) -> PillModel {
        PillModel(id: 10_010, title: "Native fixture", value: value ?? phase.rawValue, source: "native.fixture", phase: phase)
    }
    private func register(_ provider: PillBurstPluginProvider, registry: PillPluginRegistry, owner: PillPluginOwner) throws -> PillCancellation {
        try registry.register(owner: owner, descriptor: .init(id: 10_010, title: "Native fixture", symbol: "circle", interval: 5), provider: provider)
    }

    func testSynchronousLoadingReadyUsesOneTrailingDeliveryAt250Milliseconds() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.ready)])
        let registration = try self.register(provider, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[(PillModel, UInt64)]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append((model, clock.now)) } }
        defer { token.cancel(); registration.cancel() }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(received.read().map { $0.0.phase }, [.loading])
        XCTAssertEqual(clock.deadlines, [1_250_000_000])
        clock.advance(by: 249_999_999)
        XCTAssertEqual(received.read().count, 1)
        clock.advance(by: 1)
        XCTAssertEqual(received.read().map { $0.0.phase }, [.loading, .ready])
        XCTAssertEqual(received.read().map { $0.1 }, [1_000_000_000, 1_250_000_000])
        XCTAssertTrue(clock.deadlines.isEmpty)
    }

    func testSynchronousLoadingFailureEndsLoadingWithoutAnotherProviderEvent() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.failed)])
        let registration = try self.register(provider, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[PillPhase]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.phase) } }
        defer { token.cancel(); registration.cancel() }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        clock.advance(by: 250_000_000)
        XCTAssertEqual(received.read(), [.loading, .failed])
        XCTAssertEqual(clock.scheduleCount, 1)
    }

    func testLiveSchedulerDeliversCachedReadyAfterSynchronousStart() throws {
        let registry = PillPluginRegistry()
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.ready)])
        let registration = try self.register(provider, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let ready = self.expectation(description: "Default utility scheduler delivered trailing ready")
        let received = PillTestBox<[PillPhase]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in
            received.update { $0.append(model.phase) }
            if model.phase == .ready { ready.fulfill() }
        }
        defer { token.cancel(); registration.cancel() }
        self.wait(for: [ready], timeout: 1)
        XCTAssertEqual(received.read(), [.loading, .ready])
    }

    func testTerminalBurstsCoalesceLatestWithoutBypassingFourHertz() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.ready), self.model(.failed, value: "last")])
        let registration = try self.register(provider, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[String]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.value) } }
        defer { token.cancel(); registration.cancel() }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clock.scheduleCount, 1)
        clock.advance(by: 250_000_000)
        XCTAssertEqual(received.read(), ["loading", "last"])
        for index in 0..<32 { provider.publish.read()?(self.model(index.isMultiple(of: 2) ? .ready : .failed, value: String(index))) }
        XCTAssertEqual(received.read().count, 2)
        XCTAssertEqual(clock.deadlines, [1_500_000_000])
        XCTAssertEqual(clock.scheduleCount, 2)
        clock.advance(by: 250_000_000)
        XCTAssertEqual(received.read(), ["loading", "last", "31"])
    }

    func testCancellationBeforeTrailingRemovesPendingModelAndTimer() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.ready)])
        let registration = try self.register(provider, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        defer { registration.cancel() }
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[PillPhase]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.phase) } }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        token.cancel()
        XCTAssertTrue(clock.deadlines.isEmpty)
        clock.advance(by: 250_000_000)
        provider.publish.read()?(self.model(.failed))
        XCTAssertEqual(received.read(), [.loading])
        XCTAssertTrue(clock.deadlines.isEmpty)
    }

    func testOwnerUnloadBeforeTrailingNeverPublishesTerminalModel() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let owner = PillPluginOwner(pluginId: "fixture", generation: UUID())
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.ready)])
        let registration = try self.register(provider, registry: registry, owner: owner)
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[PillPhase]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.phase) } }
        defer { token.cancel(); registration.cancel() }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        registry.unregister(owner: owner)
        XCTAssertTrue(clock.deadlines.isEmpty)
        clock.advance(by: 250_000_000)
        XCTAssertEqual(received.read(), [.loading])
    }

    func testSameIdReplacementCannotDeliverPreviousOwnersTrailingModel() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let oldOwner = PillPluginOwner(pluginId: "fixture", generation: UUID())
        let old = PillBurstPluginProvider([self.model(.loading, value: "old loading"), self.model(.ready, value: "old ready")])
        let oldRegistration = try self.register(old, registry: registry, owner: oldOwner)
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[String]>([])
        let first = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.value) } }
        XCTAssertEqual(old.started.wait(timeout: .now() + 1), .success)
        registry.unregister(owner: oldOwner)
        let new = PillBurstPluginProvider([self.model(.loading, value: "new loading"), self.model(.ready, value: "new ready")])
        let newRegistration = try self.register(new, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        let second = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.value) } }
        defer { first.cancel(); second.cancel(); oldRegistration.cancel(); newRegistration.cancel() }
        XCTAssertEqual(new.started.wait(timeout: .now() + 1), .success)
        clock.advance(by: 250_000_000)
        old.publish.read()?(self.model(.failed, value: "old late error"))
        XCTAssertEqual(received.read(), ["old loading", "new loading", "new ready"])
        XCTAssertEqual(clock.scheduleCount, 2)
    }

    func testAccountRetirementSuppressesPendingTrailingDelivery() throws {
        let clock = PillDeliveryClock()
        let registry = PillPluginRegistry(deliveryTiming: clock.timing)
        let provider = PillBurstPluginProvider([self.model(.loading), self.model(.ready)])
        let registration = try self.register(provider, registry: registry, owner: .init(pluginId: "fixture", generation: UUID()))
        let lease = PillAccountLease(scope: .init(accountId: 4))
        let received = PillTestBox<[PillPhase]>([])
        let token = registry.subscribe(.init(id: 10_010, scope: lease.scope), lease: lease) { model in received.update { $0.append(model.phase) } }
        defer { token.cancel(); registration.cancel() }
        XCTAssertEqual(provider.started.wait(timeout: .now() + 1), .success)
        lease.invalidate()
        clock.advance(by: 250_000_000)
        XCTAssertEqual(received.read(), [.loading])
        XCTAssertTrue(clock.deadlines.isEmpty)
    }

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
