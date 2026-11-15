import Foundation
import XCTest
@testable import ExteralessCore

final class FilteringNotificationAdmissionTests: XCTestCase {
    private let identity = PrivacyExtrasAccountIdentity(recordId: 71, userId: 72, testingEnvironment: false)
    private final class RevisionSource: @unchecked Sendable {
        private let lock = NSLock()
        private var filtering: UInt64 = 1
        private var hidden: UInt64 = 1
        private var allowed = true
        func read() -> FilteringNotificationRevision? { lock.lock(); defer { lock.unlock() }; return allowed ? .init(filtering: filtering, hidden: hidden) : nil }
        func changeFilters() { lock.lock(); filtering += 1; lock.unlock() }
        func setHidden(_ value: Bool) { lock.lock(); hidden += 1; allowed = !value; lock.unlock() }
    }
    private func admission(source: RevisionSource, object: ObjectIdentifier) throws -> FilteringNotificationAdmission {
        FilteringNotificationAdmission(batchId: UUID(), accountIdentity: identity, accountObject: object,
            revision: try XCTUnwrap(source.read()), currentRevision: { source.read() })
    }

    func testPR03PolicyChangesBetweenCaptureAndEffectsRevokeEveryStage() throws {
        let object = NSObject()
        for hide in [false, true] {
            let source = RevisionSource()
            let ticket = try admission(source: source, object: ObjectIdentifier(object))
            if hide { source.setHidden(true) } else { source.changeFilters() }
            var effects: [FilteringNotificationEffect] = []
            for effect in [FilteringNotificationEffect.sound, .vibration, .enqueue] {
                XCTAssertFalse(ticket.performIfCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(object), effect: effect) { effects.append(effect) })
            }
            XCTAssertTrue(effects.isEmpty)
        }
    }

    func testPR03HideUnhideAndFilterABACannotRefreshAnOldAdmission() throws {
        let object = NSObject()
        let source = RevisionSource()
        let ticket = try admission(source: source, object: ObjectIdentifier(object))
        source.setHidden(true); source.setHidden(false)
        XCTAssertFalse(ticket.isCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(object)))
        let second = try admission(source: source, object: ObjectIdentifier(object))
        source.changeFilters(); source.changeFilters()
        XCTAssertFalse(second.isCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(object)))
    }

    func testPR03EachImmediateEffectIsOnceOnlyAndCancellationStopsTheRest() throws {
        let object = NSObject()
        let source = RevisionSource()
        let ticket = try admission(source: source, object: ObjectIdentifier(object))
        var effects: [FilteringNotificationEffect] = []
        for effect in [FilteringNotificationEffect.sound, .vibration, .enqueue] {
            XCTAssertTrue(ticket.performIfCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(object), effect: effect) { effects.append(effect) })
            XCTAssertFalse(ticket.performIfCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(object), effect: effect) { effects.append(effect) })
        }
        XCTAssertEqual(effects, [.sound, .vibration, .enqueue])
        let cancelled = try admission(source: source, object: ObjectIdentifier(object))
        cancelled.cancel()
        XCTAssertFalse(cancelled.performIfCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(object), effect: .enqueue) { XCTFail("cancelled alert") })
    }

    func testPR03ReceiverRecordUserEnvironmentAndObjectAreAllBound() throws {
        let object = NSObject(), replacement = NSObject()
        for wrongIdentity in [PrivacyExtrasAccountIdentity(recordId: 99, userId: 72, testingEnvironment: false), .init(recordId: 71, userId: 99, testingEnvironment: false), .init(recordId: 71, userId: 72, testingEnvironment: true)] {
            let ticket = try admission(source: RevisionSource(), object: ObjectIdentifier(object))
            XCTAssertFalse(ticket.performIfCurrent(accountIdentity: wrongIdentity, accountObject: ObjectIdentifier(object), effect: .enqueue) { XCTFail("cross-identity alert") })
        }
        let ticket = try admission(source: RevisionSource(), object: ObjectIdentifier(object))
        XCTAssertFalse(ticket.performIfCurrent(accountIdentity: identity, accountObject: ObjectIdentifier(replacement), effect: .sound) { XCTFail("retired Account object") })
    }
}
