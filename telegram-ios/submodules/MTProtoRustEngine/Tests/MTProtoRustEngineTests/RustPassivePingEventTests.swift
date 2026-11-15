import Foundation
import MTProtoEngineFFI
import TelegramCore
import XCTest
@testable import MTProtoRustEngine

/// Decodes the real FFI event layout, then drives the same event projection used
/// in RustNetworkSession's switch. No engine, account, socket or ping is started.
final class RustPassivePingEventTests: XCTestCase {
    private func event(_ kind: MTEventKind, rtt: Double = 0, flags: UInt32 = 0) -> RustEngineEvent {
        var raw = MTEvent()
        raw.kind = kind; raw.value1 = rtt; raw.flags = flags
        return withUnsafePointer(to: &raw) { RustEngineEvent($0) }
    }

    func testFFIEvent17Value1KeepsNativeRTTAndReceiptTime() throws {
        let time = Date(timeIntervalSince1970: 1000)
        var state = RustPassivePingState()
        let pong = event(MTEventKindPong, rtt: 0.0125)
        XCTAssertEqual(pong.rawKind, 17)
        XCTAssertEqual(pong.value1, 0.0125)
        // The first answered-state event can follow the matched pong.
        state.consume(pong, isMain: true, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time))
        state.consume(event(MTEventKindConnectionState, flags: 3), isMain: true, active: true, receivedAt: time)
        let sample = try XCTUnwrap(state.snapshot(now: time.addingTimeInterval(10)))
        XCTAssertEqual(sample.roundTripSeconds, 0.0125)
        XCTAssertEqual(sample.sampledAt, time)
        XCTAssertEqual(state.snapshot(now: time.addingTimeInterval(120)), sample)
        XCTAssertNil(state.snapshot(now: time.addingTimeInterval(121)))
        XCTAssertNil(state.snapshot(now: time.addingTimeInterval(-1)))
    }

    func testNonMainInvalidAndNonPongEventsCannotPublishRTT() {
        let time = Date(timeIntervalSince1970: 1000)
        var state = RustPassivePingState()
        state.consume(event(MTEventKindConnectionState, flags: 3), isMain: true, active: true, receivedAt: time)
        state.consume(event(MTEventKindCompleted, rtt: 0.001), isMain: true, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time), "RPC completion is not a ping RTT")
        for value in [0.0, -1, .nan, .infinity, Double.greatestFiniteMagnitude] {
            state.consume(event(MTEventKindPong, rtt: value), isMain: true, active: true, receivedAt: time)
            XCTAssertNil(state.snapshot(now: time))
        }
        state.consume(event(MTEventKindConnectionState, flags: 3), isMain: false, active: true, receivedAt: time)
        state.consume(event(MTEventKindPong, rtt: 0.01), isMain: false, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time))
    }

    func testPauseDropAndNonAnsweredClearThePreviousConnectionSample() {
        let time = Date(timeIntervalSince1970: 1000)
        var state = RustPassivePingState()
        func seed(_ state: inout RustPassivePingState) {
            state.consume(event(MTEventKindConnectionState, flags: 3), isMain: true, active: true, receivedAt: time)
            state.consume(event(MTEventKindPong, rtt: 0.01), isMain: true, active: true, receivedAt: time)
            XCTAssertNotNil(state.snapshot(now: time))
        }
        seed(&state)
        state.invalidate() // same operation as applied pause / drain / reset
        state.consume(event(MTEventKindPong, rtt: 0.02), isMain: true, active: false, receivedAt: time)
        state.consume(event(MTEventKindConnectionState, flags: 3), isMain: true, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time), "resume cannot revive the pre-pause reading")
        seed(&state)
        state.consume(event(MTEventKindConnectionDropped), isMain: true, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time))
        seed(&state)
        // Connected, but still updating context without a bound key: not answered.
        state.consume(event(MTEventKindConnectionState, flags: 7), isMain: true, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time))
        seed(&state)
        state.consume(event(MTEventKindClosed), isMain: true, active: true, receivedAt: time)
        XCTAssertNil(state.snapshot(now: time))
    }
}
