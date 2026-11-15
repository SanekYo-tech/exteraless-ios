import Foundation
import XCTest
@testable import PluginHooks

private final class TLAdmissionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ value: String) { self.lock.lock(); self.events.append(value); self.lock.unlock() }
    var values: [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.events }
}

final class PluginTLSubmissionOrderTests: XCTestCase {
    private func ticket(_ admission: PluginTLSubmissionOrder.Admission, file: StaticString = #filePath, line: UInt = #line) throws -> PluginTLSubmissionOrder.Ticket {
        if case let .reserved(value) = admission { return value }
        XCTFail("Expected ordered admission", file: file, line: line)
        throw NSError(domain: "TLAdmissionFixture", code: 1)
    }

    func testGateOffJoinsHeldPrivacyPrefixAndOtherAccountBypasses() throws {
        let order = PluginTLSubmissionOrder()
        let events = TLAdmissionEvents()
        let done = DispatchSemaphore(value: 0)
        let first = try ticket(order.reserveIfNeeded(accountRecordId: 1, transformsEnabled: true))
        let second = try ticket(order.reserveIfNeeded(accountRecordId: 1, transformsEnabled: false))
        order.ready(second) { events.add("B"); done.signal() }
        XCTAssertEqual(order.reserveIfNeeded(accountRecordId: 2, transformsEnabled: false), .bypass)
        events.add("other-account")
        XCTAssertEqual(done.wait(timeout: .now() + 0.02), .timedOut)
        order.ready(first) { events.add("A"); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.values, ["other-account", "A", "B"])
    }

    func testCancelledHeldPrefixReleasesGateOffFollowerWithoutAddingA() throws {
        let order = PluginTLSubmissionOrder()
        let events = TLAdmissionEvents()
        let done = DispatchSemaphore(value: 0)
        let first = try ticket(order.reserveIfNeeded(accountRecordId: 1, transformsEnabled: true))
        let second = try ticket(order.reserveIfNeeded(accountRecordId: 1, transformsEnabled: false))
        order.ready(second) { events.add("B"); done.signal() }
        order.cancel(first)
        order.ready(first) { events.add("cancelled-A") }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.values, ["B"])
    }

    func testHeadStaysReservedUntilActualAddReturns() throws {
        let order = PluginTLSubmissionOrder()
        let events = TLAdmissionEvents()
        let adding = DispatchSemaphore(value: 0)
        let releaseAdd = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { releaseAdd.signal() }
        let first = try ticket(order.reserveIfNeeded(accountRecordId: 1, transformsEnabled: true))
        order.ready(first) {
            adding.signal()
            guard releaseAdd.wait(timeout: .now() + 1) == .success else { XCTFail("bounded add fixture expired"); return }
            events.add("A")
        }
        XCTAssertEqual(adding.wait(timeout: .now() + 1), .success)
        let second = try ticket(order.reserveIfNeeded(accountRecordId: 1, transformsEnabled: false))
        order.ready(second) { events.add("B"); finished.signal() }
        releaseAdd.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.values, ["A", "B"])
    }
}
