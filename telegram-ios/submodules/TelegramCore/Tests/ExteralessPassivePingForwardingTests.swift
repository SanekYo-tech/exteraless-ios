import Foundation
import MtProtoKit
import SwiftSignalKit
import XCTest
@testable import TelegramCore

private final class PassivePingFixtureRequests: NetworkEngineRequestService {
    func add(_ request: NetworkEngineRequest) -> Disposable {
        XCTFail("A passive RTT read must never submit a request")
        return EmptyDisposable
    }
}

private final class PassivePingFixtureSession: NetworkEngineSession, ExteralessPillPassivePingSource {
    let datacenterId = 2
    let requestService: NetworkEngineRequestService = PassivePingFixtureRequests()
    private(set) var replies: [(ExteralessPillPassivePingSample?) -> Void] = []
    private var drops: [(NetworkEngineConnectionDrop) -> Void] = []
    func exteralessPillPassivePingSnapshot(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void) { replies.append(reply) }
    func observeConnectionDrops(_ observer: @escaping (NetworkEngineConnectionDrop) -> Void) { drops.append(observer) }
    func drop() { for observer in drops { observer(.init(reason: "fixture", answered: true, age: 1)) } }
    func setPaused(_ paused: Bool) {}
    func setOnline(_ online: Bool) {}
    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {}
    func stop() {}
    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) { completion() }
}

private final class PassivePingFixtureEngine: NetworkEngine {
    let kind: NetworkEngineKind
    let session: PassivePingFixtureSession
    init(kind: NetworkEngineKind, session: PassivePingFixtureSession = PassivePingFixtureSession()) { self.kind = kind; self.session = session }
    func makeSession(datacenterId: Int, role: NetworkEngineSessionRole, usageCalculationInfo: MTNetworkUsageCalculationInfo?, delegate: NetworkEngineSessionDelegate?) -> NetworkEngineSession { session }
}

/// Exercises the real Recording and Switching wrappers with delayed/duplicate
/// inner replies. Telemetry is memory-only; no live network or active pinger.
final class ExteralessPassivePingForwardingTests: XCTestCase {
    private func telemetry() -> NetworkTelemetry {
        NetworkTelemetry(directory: nil, layer: 1, app: "fixture", system: "fixture", variant: nil)
    }
    private func sample(age: TimeInterval = 0) -> ExteralessPillPassivePingSample {
        ExteralessPillPassivePingSample(roundTripSeconds: 0.025, sampledAt: Date().addingTimeInterval(-age))!
    }

    func testRecordingForwardsOnceWithoutRefreshingTheTimestamp() throws {
        let inner = PassivePingFixtureEngine(kind: .rust)
        let recording = RecordingNetworkEngine(engine: inner, telemetry: telemetry())
        let session = recording.makeSession(datacenterId: 2, role: .main, usageCalculationInfo: nil, delegate: nil)
        defer { session.stop() }
        let source = try XCTUnwrap(session as? ExteralessPillPassivePingSource)
        let reading = sample(age: 1)
        var replies: [ExteralessPillPassivePingSample?] = []
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        XCTAssertEqual(inner.session.replies.count, 1)
        inner.session.replies[0](reading)
        inner.session.replies[0](sample()) // deliberately misbehaving duplicate
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0], reading)
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        inner.session.replies[1](sample(age: 121))
        XCTAssertEqual(replies.count, 2); XCTAssertNil(replies[1])
    }

    func testRecordingRejectsWorkerPauseDropAndRetiredReplies() throws {
        let inner = PassivePingFixtureEngine(kind: .rust)
        let recording = RecordingNetworkEngine(engine: inner, telemetry: telemetry())
        let worker = recording.makeSession(datacenterId: 2, role: .worker(masterDatacenterId: 2, isMedia: false, isCdn: false), usageCalculationInfo: nil, delegate: nil)
        let workerSource = try XCTUnwrap(worker as? ExteralessPillPassivePingSource)
        var workerReplied = false
        workerSource.exteralessPillPassivePingSnapshot { XCTAssertNil($0); workerReplied = true }
        XCTAssertTrue(workerReplied); XCTAssertTrue(inner.session.replies.isEmpty)

        let session = recording.makeSession(datacenterId: 2, role: .main, usageCalculationInfo: nil, delegate: nil)
        let source = try XCTUnwrap(session as? ExteralessPillPassivePingSource)
        var replies: [ExteralessPillPassivePingSample?] = []
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        session.setPaused(true); session.setPaused(false)
        inner.session.replies[0](sample())
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        inner.session.drop(); inner.session.replies[1](sample())
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        session.stop(); inner.session.replies[2](sample())
        XCTAssertEqual(replies.count, 3)
        XCTAssertTrue(replies.allSatisfy { $0 == nil })
        worker.stop()
    }

    func testRecordingOverSwitchingDiscardsLateOldEngineReply() throws {
        let old = PassivePingFixtureEngine(kind: .rust), new = PassivePingFixtureEngine(kind: .mtProtoKit)
        let switching = SwitchingNetworkEngine(engine: old)
        let recording = RecordingNetworkEngine(engine: switching, telemetry: telemetry())
        let session = recording.makeSession(datacenterId: 2, role: .main, usageCalculationInfo: nil, delegate: nil)
        defer { session.stop() }
        session.setPaused(false)
        let source = try XCTUnwrap(session as? ExteralessPillPassivePingSource)
        var replies: [ExteralessPillPassivePingSample?] = []
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        XCTAssertEqual(old.session.replies.count, 1)
        XCTAssertTrue(switching.switchEngine(to: .mtProtoKit, drainTimeout: 0, makeEngine: { new }))
        old.session.replies[0](sample()); old.session.replies[0](sample())
        XCTAssertEqual(replies.count, 1); XCTAssertNil(replies[0])
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        let reading = sample()
        new.session.replies[0](reading)
        XCTAssertEqual(replies.count, 2); XCTAssertEqual(replies[1], reading)
    }

    func testSwitchingPauseResumeDropStopAndRepeatedSessionIdentityInvalidateRead() throws {
        let sameSession = PassivePingFixtureSession()
        let first = PassivePingFixtureEngine(kind: .rust, session: sameSession)
        let switching = SwitchingNetworkEngine(engine: first)
        let session = switching.makeSession(datacenterId: 2, role: .main, usageCalculationInfo: nil, delegate: nil)
        session.setPaused(false)
        let source = try XCTUnwrap(session as? ExteralessPillPassivePingSource)
        var replies: [ExteralessPillPassivePingSample?] = []
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        session.setPaused(true); session.setPaused(false); sameSession.replies[0](sample())
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        sameSession.drop(); sameSession.replies[1](sample())
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        // Identity alone would accept this; the engine-generation check must reject it.
        let reused = PassivePingFixtureEngine(kind: .mtProtoKit, session: sameSession)
        XCTAssertTrue(switching.switchEngine(to: .mtProtoKit, drainTimeout: 0, makeEngine: { reused }))
        sameSession.replies[2](sample())
        source.exteralessPillPassivePingSnapshot { replies.append($0) }
        session.stop(); sameSession.replies[3](sample())
        XCTAssertEqual(replies.count, 4); XCTAssertTrue(replies.allSatisfy { $0 == nil })
    }
}
