import Foundation
import XCTest
@testable import ExteralessCore

final class HiddenAccountRemediationTests: XCTestCase {
    private let a = PrivacyExtrasAccountIdentity(recordId: 101, userId: 201, testingEnvironment: false)
    private let b = PrivacyExtrasAccountIdentity(recordId: 102, userId: 202, testingEnvironment: false)

    private final class Recorder: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: [UInt64] = []
        func record(_ revision: UInt64) { mutex.lock(); stored.append(revision); mutex.unlock() }
        var values: [UInt64] { mutex.lock(); defer { mutex.unlock() }; return stored }
    }

    private final class PublicationReference: @unchecked Sendable {
        // Assigned once before any test publication; the callback owns no state lock.
        weak var value: HiddenAccountPresentationLock!
    }

    func testCNestedStateMutationPublishesAfterOutermostUnlockAndAllowsAnotherThread() {
        let reference = PublicationReference()
        let recorder = Recorder()
        let publication = HiddenAccountPresentationLock { revision in
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                reference.value.lock()
                recorder.record(revision)
                reference.value.unlock()
                completed.signal()
            }
            // A wrong nested-unlock publication fails within this bound, rather
            // than hanging the fixture on the other thread's state read.
            XCTAssertEqual(completed.wait(timeout: .now() + 0.5), .success)
        }
        reference.value = publication
        publication.lock()
        publication.lock()
        publication.invalidatePresentations()
        publication.unlock()
        XCTAssertEqual(recorder.values, [])
        publication.invalidatePresentations()
        XCTAssertEqual(recorder.values, [])
        publication.unlock()
        XCTAssertEqual(recorder.values, [2])
    }

    func testCReentrantPublicationsDrainInOrderWithoutRecursionOrRevisionRewind() {
        let reference = PublicationReference()
        let recorder = Recorder()
        let publication = HiddenAccountPresentationLock { revision in
            recorder.record(revision)
            if revision == 1 { reference.value.invalidatePresentations() }
        }
        reference.value = publication
        publication.invalidatePresentations()
        XCTAssertEqual(recorder.values, [1, 2])
        DispatchQueue.concurrentPerform(iterations: 24) { _ in publication.invalidatePresentations() }
        let values = recorder.values
        XCTAssertEqual(values.last, 26)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertLessThanOrEqual(values.count, 26)
    }

    func testCSameAccountRevealAndFailedFinishInvalidateWithoutAConfigurationUpdate() throws {
        let recorder = Recorder()
        let publication = HiddenAccountPresentationLock { recorder.record($0) }
        let policy = HiddenAccountPolicy(presentationChanged: { publication.invalidatePresentations() })
        let config = HiddenAccountConfiguration(accounts: [b: .init(hasPasscode: true, hidden: true)], revision: 40)
        publication.lock()
        policy.update(configuration: config, accounts: [a, b], current: b, foreground: true, locked: true, available: true)
        publication.unlock()
        let previous = recorder.values.last!
        let attempt = try XCTUnwrap(policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
        let authorization = try XCTUnwrap(policy.authorize(.accountCode(b), attempt: attempt, now: 1))
        XCTAssertNotNil(policy.consume(authorization, now: 2))
        XCTAssertTrue(policy.canSelect(b))
        XCTAssertGreaterThan(try XCTUnwrap(recorder.values.last), previous)
        let consumedRevision = recorder.values.last!
        // No raw account-list or private-configuration update accompanies failure.
        XCTAssertFalse(policy.finishUnlock(authorization, now: 16))
        XCTAssertFalse(policy.canSelect(b))
        XCTAssertGreaterThan(try XCTUnwrap(recorder.values.last), consumedRevision)
    }

    func testCPresentationInvalidationAndExpectedSwitchDoNotRetireTheOpaqueGrant() throws {
        let recorder = Recorder()
        let publication = HiddenAccountPresentationLock { recorder.record($0) }
        let policy = HiddenAccountPolicy(presentationChanged: { publication.invalidatePresentations() })
        let objectA = NSObject(), objectB = NSObject()
        let entries = [HiddenAccountSnapshot.Entry(identity: a, object: ObjectIdentifier(objectA)), .init(identity: b, object: ObjectIdentifier(objectB))]
        var snapshot = HiddenAccountSnapshot()
        XCTAssertFalse(snapshot.update(entries))
        let config = HiddenAccountConfiguration(accounts: [b: .init(hasPasscode: true, hidden: true)], revision: 40)
        policy.update(configuration: config, accounts: snapshot.identities, current: a, foreground: true, locked: true, available: true)
        let attempt = try XCTUnwrap(policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
        let authorization = try XCTUnwrap(policy.authorize(.accountCode(b), attempt: attempt, now: 1))
        XCTAssertNotNil(policy.consume(authorization, now: 2))
        publication.invalidatePresentations()
        // This is the exact replacement detector used by the native Account update.
        XCTAssertFalse(snapshot.update(entries))
        policy.update(configuration: config, accounts: snapshot.identities, current: b, foreground: true, locked: true, available: true)
        XCTAssertTrue(policy.canSelect(b))
        XCTAssertTrue(policy.finishUnlock(authorization, now: 3))
        policy.update(configuration: config, accounts: snapshot.identities, current: b, foreground: true, locked: false, available: true)
        XCTAssertTrue(policy.canUse(b))
    }

    func testCActualObjectReplacementRetiresPendingPanicAndConsumedUnlock() throws {
        let objectA = NSObject(), oldB = NSObject(), replacementB = NSObject()
        let old = [HiddenAccountSnapshot.Entry(identity: a, object: ObjectIdentifier(objectA)), .init(identity: b, object: ObjectIdentifier(oldB))]
        let replacement = [HiddenAccountSnapshot.Entry(identity: a, object: ObjectIdentifier(objectA)), .init(identity: b, object: ObjectIdentifier(replacementB))]
        for proof in [HiddenAccountAuthentication.panicCode, .accountCode(b)] {
            var snapshot = HiddenAccountSnapshot()
            XCTAssertFalse(snapshot.update(old))
            let policy = HiddenAccountPolicy()
            let config = HiddenAccountConfiguration(accounts: [b: .init(hasPasscode: true, hidden: true)], panicConfigured: true)
            policy.update(configuration: config, accounts: snapshot.identities, current: b, foreground: true, locked: true, available: true)
            let attempt = try XCTUnwrap(policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
            let authorization = try XCTUnwrap(policy.authorize(proof, attempt: attempt, now: 1))
            if case .accountCode = proof { XCTAssertNotNil(policy.consume(authorization, now: 2)) }
            let replaced = snapshot.update(replacement)
            XCTAssertTrue(replaced)
            if replaced { policy.cancel(nil) }
            policy.update(configuration: config, accounts: snapshot.identities, current: b, foreground: true, locked: true, available: true)
            XCTAssertNil(policy.consume(authorization, now: 3))
            XCTAssertFalse(policy.finishUnlock(authorization, now: 3))
            XCTAssertFalse(policy.canUse(b))
            // No executor/effect factory is used: these are synthetic identities.
        }
    }

    func testCStaleCancellationCannotRetireAReplacementAttempt() throws {
        let policy = HiddenAccountPolicy()
        let config = HiddenAccountConfiguration(accounts: [b: .init(hasPasscode: true, hidden: true)])
        policy.update(configuration: config, accounts: [a, b], current: a, foreground: true, locked: true, available: true)
        let old = try XCTUnwrap(policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
        let oldAuthorization = try XCTUnwrap(policy.authorize(.accountCode(b), attempt: old, now: 0.5))
        let current = try XCTUnwrap(policy.beginAttempt(now: 1, explicitPasscodeEntry: true))
        policy.cancel(old)
        let authorization = try XCTUnwrap(policy.authorize(.accountCode(b), attempt: current, now: 2))
        XCTAssertNotNil(policy.consume(authorization, now: 3))
        policy.cancel(old)
        XCTAssertFalse(policy.finishUnlock(oldAuthorization, now: 3.5))
        XCTAssertTrue(policy.canSelect(b))
        XCTAssertTrue(policy.finishUnlock(authorization, now: 4))
    }

    func testDLoadingStoredCodesRequiresRoutingButConfirmedEmptyDoesNot() {
        for panic in [false, true] {
            for keys in [Set<String>(), Set([b.storageKey])] {
                var snapshot = HiddenAccountSnapshot()
                XCTAssertFalse(snapshot.hasAccountSnapshot)
                XCTAssertEqual(snapshot.requiresUnlockRouting(available: true, panicConfigured: panic, accountCodeKeys: keys), panic || !keys.isEmpty)
                snapshot.confirmEmpty()
                XCTAssertTrue(snapshot.hasAccountSnapshot)
                XCTAssertFalse(snapshot.requiresUnlockRouting(available: true, panicConfigured: panic, accountCodeKeys: keys))
                XCTAssertTrue(snapshot.requiresUnlockRouting(available: false, panicConfigured: panic, accountCodeKeys: keys))
            }
        }
    }

    func testDRealSnapshotUsesOnlyItsActiveIdentitiesAndNeverFabricatesAnAttempt() {
        let objectA = NSObject(), objectB = NSObject()
        var snapshot = HiddenAccountSnapshot()
        snapshot.update([.init(identity: a, object: ObjectIdentifier(objectA))])
        XCTAssertFalse(snapshot.requiresUnlockRouting(available: true, panicConfigured: false, accountCodeKeys: [b.storageKey]))
        snapshot.update([.init(identity: a, object: ObjectIdentifier(objectA)), .init(identity: b, object: ObjectIdentifier(objectB))])
        XCTAssertTrue(snapshot.requiresUnlockRouting(available: true, panicConfigured: false, accountCodeKeys: [b.storageKey]))
        snapshot.update([]) // a real empty emission is also confirmation
        XCTAssertTrue(snapshot.hasAccountSnapshot)
        XCTAssertFalse(snapshot.requiresUnlockRouting(available: true, panicConfigured: true, accountCodeKeys: [b.storageKey]))
        let policy = HiddenAccountPolicy()
        policy.update(configuration: .init(panicConfigured: true), accounts: snapshot.identities, current: nil, foreground: true, locked: true, available: true)
        XCTAssertNil(policy.beginAttempt(now: 1, explicitPasscodeEntry: true))
        XCTAssertNil(policy.beginAttempt(now: 1, explicitPasscodeEntry: false))
    }
}
