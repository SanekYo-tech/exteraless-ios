import Foundation
import XCTest
@testable import PluginHost

private final class MarkerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    let entered = [OneShotResult<Void>(), OneShotResult<Void>()]
    let release = [PluginLifecycleSignal<Void>(), PluginLifecycleSignal<Void>()]
    private func next() -> Int { lock.lock(); defer { lock.unlock() }; let value = index; index += 1; return value }
    func sleep() async throws {
        let value = next()
        guard value < release.count else { throw PluginHostError.runtimeFailure("unexpected marker timer") }
        entered[value].succeed(())
        _ = try await release[value].wait(cancellable: false)
    }
}

final class PluginWatchdogMarkerTests: XCTestCase {
    func testCancelledTimerAndStaleActorClearCannotDeleteNextMarker() async throws {
        let directory = tempDirectory("marker-generation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker")
        let clock = MarkerClock()
        defer { clock.release.forEach { $0.succeed(()) } }
        let watchdog = PluginWatchdog(markerURL: marker, persistURL: directory.appendingPathComponent("watchdog.json"),
                                       markerSleep: { _ in try await clock.sleep() })
        let a = await watchdog.noteRiskyOperation("alpha")
        await watchdog.scheduleMarkerClear(a)
        let captured = await watchdog.markerIdentity
        let pendingA = await watchdog.markerClearTask
        let oldTimer = try XCTUnwrap(pendingA)
        _ = try await maintenanceTestWait(clock.entered[0])
        let b = await watchdog.noteRiskyOperation("beta")
        clock.release[0].succeed(())
        await oldTimer.value
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "beta")
        await watchdog.clearMarkerIfCurrent(generation: captured.generation, marker: "alpha")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "beta")
        await watchdog.scheduleMarkerClear(b)
        let pendingB = await watchdog.markerClearTask
        let newTimer = try XCTUnwrap(pendingB)
        _ = try await maintenanceTestWait(clock.entered[1])
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "beta")
        clock.release[1].succeed(())
        await newTimer.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await watchdog.stop()
    }

    func testOverlappingRiskyLoadsKeepMarkerUntilLastOwnedExit() async throws {
        let directory = tempDirectory("marker-overlap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker")
        let clock = MarkerClock()
        defer { clock.release.forEach { $0.succeed(()) } }
        let watchdog = PluginWatchdog(markerURL: marker, persistURL: directory.appendingPathComponent("watchdog.json"),
                                       markerSleep: { _ in try await clock.sleep() })
        let a = await watchdog.noteRiskyOperation("alpha")
        let b = await watchdog.noteRiskyOperation("beta")
        await watchdog.scheduleMarkerClear(a)
        let timerWhileBIsLoading = await watchdog.markerClearTask
        XCTAssertNil(timerWhileBIsLoading)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "beta")
        await watchdog.scheduleMarkerClear(a) // Late duplicate exit owns nothing.
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "beta")
        await watchdog.scheduleMarkerClear(b)
        let timer = await watchdog.markerClearTask
        let last = try XCTUnwrap(timer)
        _ = try await maintenanceTestWait(clock.entered[0])
        clock.release[0].succeed(())
        await last.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await watchdog.stop()
    }
}
