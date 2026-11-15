import Foundation
import XCTest
@testable import PluginHost

final class PluginEventIngressTests: XCTestCase {
    func testEveryIngressReservesBeforeActorHopAndAwaitingOverflowIsTyped() async throws {
        let queue = PluginEventQueue()
        let entered = OneShotResult<Void>()
        let release = PluginLifecycleSignal<Void>()
        let delivered = Recorder<PluginEvent>()
        addTeardownBlock { release.succeed(()); await queue.stop() }
        await queue.start(handler: { event in
            delivered.append(event)
            if case .appEvent = event {
                entered.succeed(())
                _ = try await release.wait(cancellable: false)
            }
            return .none
        }, limits: .init(dispatchTimeout: 2, maxQueueDepth: 2, maxQueueBytes: 4096))
        _ = await queue.submit(.appEvent(.init(name: "blocked")))
        _ = try await maintenanceTestWait(entered)
        XCTAssertTrue(queue.submitAsync(.preRequest(.init(requestName: "first", account: 0, requestJSON: "{}"))))
        XCTAssertFalse(queue.submitAsync(.postRequest(.init(requestName: "second", account: 0, responseJSON: "{}", errorMessage: nil))))
        XCTAssertFalse(queue.submitAsync(.update(.init(updateName: "unique-key", account: 0, updateJSON: "{}"))))
        XCTAssertFalse(queue.submitAsync(.updates(.init(containerName: "other-key", account: 1, updatesJSON: ["{}"]))))
        for event in [PluginEvent.sendMessage(.init(account: 0, paramsJSON: "{}")),
                      .createSettings(.init(pluginId: "alpha", account: 0))] {
            do { _ = try await queue.submitAwaiting(event); XCTFail("awaited work must share the same budget") }
            catch PluginHostError.eventQueueFull { }
        }
        let full = await queue.stats
        XCTAssertEqual(full.retainedCount, 2)
        XCTAssertEqual(full.droppedOverflow, 5)
        release.succeed(())
        let drained = await waitUntil({ await queue.stats.retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertEqual(delivered.count, 2)
        guard case .preRequest(let payload)? = delivered.values.last else { return XCTFail("unexpected retained event") }
        XCTAssertEqual(payload.requestName, "first")
    }

    func testCoalescedKeysAndBytesCannotBypassGlobalBudget() async throws {
        let queue = PluginEventQueue()
        let entered = OneShotResult<Void>()
        let release = PluginLifecycleSignal<Void>()
        let events = Recorder<PluginEvent>()
        addTeardownBlock { release.succeed(()); await queue.stop() }
        await queue.start(handler: { event in
            events.append(event)
            if case .appEvent = event { entered.succeed(()); _ = try await release.wait(cancellable: false) }
            return .none
        }, limits: .init(dispatchTimeout: 2, maxQueueDepth: 2, maxQueueBytes: 4096))
        _ = await queue.submit(.appEvent(.init(name: "hold")))
        _ = try await maintenanceTestWait(entered)
        XCTAssertTrue(queue.submitAsync(.update(.init(updateName: "one", account: 0, updateJSON: "{}"))))
        XCTAssertFalse(queue.submitAsync(.update(.init(updateName: "two", account: 0, updateJSON: "{}"))))
        XCTAssertFalse(queue.submitAsync(.updates(.init(containerName: "three", account: 1, updatesJSON: ["{}"]))))
        let retained = await queue.stats
        XCTAssertEqual(retained.retainedCount, 2)
        release.succeed(())
        let drained = await waitUntil({ await queue.stats.retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertEqual(events.count, 2)
        guard case .coalescedUpdates(_, let items)? = events.values.last else { return XCTFail("expected one retained coalesced item") }
        XCTAssertEqual(items.count, 1)
    }

    func testAggregateBytesBoundRequestsEvenBelowCountLimit() async throws {
        let queue = PluginEventQueue()
        let entered = OneShotResult<Void>()
        let release = PluginLifecycleSignal<Void>()
        addTeardownBlock { release.succeed(()); await queue.stop() }
        await queue.start(handler: { event in
            if case .appEvent = event { entered.succeed(()); _ = try await release.wait(cancellable: false) }
            return .none
        }, limits: .init(dispatchTimeout: 2, maxQueueDepth: 4, maxQueueBytes: 2048))
        _ = await queue.submit(.appEvent(.init(name: "hold")))
        _ = try await maintenanceTestWait(entered)
        XCTAssertTrue(queue.submitAsync(.preRequest(.init(requestName: "large", account: 0,
                                                         requestJSON: String(repeating: "x", count: 1400)))))
        XCTAssertFalse(queue.submitAsync(.postRequest(.init(requestName: "extra", account: 0,
            responseJSON: String(repeating: "y", count: 400), errorMessage: nil))))
        let retained = await queue.stats
        XCTAssertEqual(retained.retainedCount, 2)
        XCTAssertGreaterThan(retained.retainedBytes, 1500)
        XCTAssertLessThanOrEqual(retained.retainedBytes, 2048)
    }

    func testTimeoutStopAndRestartDoNotReleaseStillRetainedHandlerWork() async throws {
        let queue = PluginEventQueue()
        let entered = OneShotResult<Void>()
        let release = PluginLifecycleSignal<Void>()
        addTeardownBlock { release.succeed(()); await queue.stop() }
        await queue.start(handler: { _ in
            entered.succeed(())
            _ = try await release.wait(cancellable: false)
            return .none
        }, limits: .init(dispatchTimeout: 0.05, maxQueueDepth: 1, maxQueueBytes: 4096))
        let waiting = Task { try await queue.submitAwaiting(.preRequest(.init(requestName: "held", account: 0, requestJSON: "{}"))) }
        _ = try await maintenanceTestWait(entered)
        do { _ = try await waiting.value; XCTFail("expected deadline") }
        catch PluginHostError.timeout { }
        let timedOut = await queue.stats
        XCTAssertEqual(timedOut.retainedCount, 1)
        await queue.stop()
        await queue.start(handler: { _ in .none }, limits: .init(maxQueueDepth: 1, maxQueueBytes: 4096))
        XCTAssertFalse(queue.submitAsync(.appEvent(.init(name: "must-not-overcommit"))))
        release.succeed(())
        let drained = await waitUntil({ await queue.stats.retainedCount == 0 }, timeout: 1)
        XCTAssertTrue(drained)
        XCTAssertTrue(queue.submitAsync(.appEvent(.init(name: "new-generation"))))
    }
}
