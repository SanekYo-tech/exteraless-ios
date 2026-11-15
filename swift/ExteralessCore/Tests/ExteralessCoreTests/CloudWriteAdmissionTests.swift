import Foundation
import XCTest
@testable import ExteralessCore

private final class CloudAdmissionIdentity { let recordId: Int64 = 42 }
private final class CloudAdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// These fixtures intentionally hold a synchronous writer behind a finite gate.
/// Keep that wait off Swift's cooperative executor on both Apple and Linux.
private func cloudAdmissionWorker(_ work: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue(label: "Exteraless.CloudAdmissionFixture").async {
            do {
                try work()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor final class CloudWriteAdmissionTests: XCTestCase {
    private func fixture() throws -> (ClientSettings, URL, CloudFixtureSecrets, ClientAPIFixtureStorage) {
        let file = try cloudTemporaryDirectory().appendingPathComponent("settings.json")
        let secrets = CloudFixtureSecrets()
        let vault = ClientAPIFixtureStorage()
        let settings = try ClientSettings(storageURL: file, secretStore: secrets)
        try settings.register(CloudFeatures.definitions + ClientAPIFeatures.definitions)
        return (settings, file, secrets, vault)
    }

    func testRetiredQueuedToggleHasNoBytesOrObserverEffects() async throws {
        let (settings, file, _, _) = try fixture()
        let owner = CloudAdmissionIdentity()
        let identity = ObjectIdentifier(owner)
        let admission = CloudWriteAdmission(contextIdentity: identity)
        let before = try Data(contentsOf: file)
        let events = CloudAdmissionCounter()
        let observation = settings.observe { _ in events.increment() }
        defer { observation.cancel() }
        let gate = DispatchSemaphore(value: 0)
        let queued = Task.detached {
            try await cloudAdmissionWorker {
                guard gate.wait(timeout: .now() + 1) == .success else { throw CloudError.timedOut }
                try admission.withAdmittedWrite(contextIdentity: identity) { try settings.applyPublic(["cloud.autoSync": .bool(true)]) }
            }
        }
        admission.revoke()
        gate.signal()
        do { try await queued.value; XCTFail("A retired writer must not run") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(events.value, 0)
        XCTAssertFalse(settings.bool("cloud.autoSync"))
        XCTAssertEqual(owner.recordId, 42)
    }

    func testRetiredQueuedAPIDraftSavePreservesKeychainTupleAndJournal() async throws {
        let (settings, file, secrets, secure) = try fixture()
        let configuration = ClientAPIConfigurationStore(settings: settings, settingsSecrets: secrets, vault: ClientAPIVault(storage: secure))
        try configuration.save(mode: .custom, apiId: 123, replacementHash: String(repeating: "a", count: 32), environment: .production)
        let before = try Data(contentsOf: file)
        let beforeHash = try secrets.data(for: "clientAPI.customAppHash")
        let beforeVault = secure.keys()
        let events = CloudAdmissionCounter()
        let observation = settings.observe { _ in events.increment() }
        defer { observation.cancel() }
        let owner = CloudAdmissionIdentity()
        let identity = ObjectIdentifier(owner)
        let admission = CloudWriteAdmission(contextIdentity: identity)
        let gate = DispatchSemaphore(value: 0)
        let queued = Task.detached {
            try await cloudAdmissionWorker {
                guard gate.wait(timeout: .now() + 1) == .success else { throw CloudError.timedOut }
                try admission.withAdmittedWrite(contextIdentity: identity) {
                    try configuration.save(mode: .custom, apiId: 456, replacementHash: String(repeating: "b", count: 32), environment: .production)
                }
            }
        }
        admission.revoke()
        gate.signal()
        do { try await queued.value; XCTFail("A retired API editor must not save") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try secrets.data(for: "clientAPI.customAppHash"), beforeHash)
        XCTAssertEqual(secure.keys(), beforeVault)
        XCTAssertEqual(events.value, 0)
        XCTAssertEqual(owner.recordId, 42)
    }

    func testAlreadyAdmittedWriteFinishesOnceWithoutHoldingRevocationLock() async throws {
        let (settings, _, _, _) = try fixture()
        let owner = CloudAdmissionIdentity()
        let identity = ObjectIdentifier(owner)
        let admission = CloudWriteAdmission(contextIdentity: identity)
        let gate = DispatchSemaphore(value: 0)
        let events = CloudAdmissionCounter()
        let observation = settings.observe { _ in events.increment() }
        defer { observation.cancel(); gate.signal() }
        let writer = Task.detached {
            try await cloudAdmissionWorker {
                try admission.withAdmittedWrite(contextIdentity: identity) {
                    guard gate.wait(timeout: .now() + 2) == .success else { throw CloudError.timedOut }
                    try settings.applyPublic(["cloud.autoSync": .bool(true)])
                }
            }
        }
        for _ in 0..<200 {
            if admission.hasAdmittedWrite { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(admission.hasAdmittedWrite)
        admission.revoke() // MainActor must not block on the worker's file transaction.
        gate.signal()
        try await writer.value
        XCTAssertTrue(settings.bool("cloud.autoSync"))
        XCTAssertEqual(events.value, 1)
        XCTAssertThrowsError(try admission.withAdmittedWrite(contextIdentity: identity) { try settings.applyPublic(["cloud.autoSync": .bool(false)]) })
        XCTAssertEqual(events.value, 1)
        XCTAssertEqual(owner.recordId, 42)
    }

    func testActualContextIdentityAndPreCancelledTaskCannotAdmitWriter() async throws {
        let first = CloudAdmissionIdentity(), second = CloudAdmissionIdentity()
        XCTAssertEqual(first.recordId, second.recordId)
        let admission = CloudWriteAdmission(contextIdentity: ObjectIdentifier(first))
        let effects = CloudAdmissionCounter()
        XCTAssertThrowsError(try admission.withAdmittedWrite(contextIdentity: ObjectIdentifier(second)) { effects.increment() })
        let identity = ObjectIdentifier(first)
        let task = Task { @MainActor in try await admission.perform(contextIdentity: identity) { effects.increment() } }
        task.cancel() // Same actor turn: the operation has not started.
        do { try await task.value; XCTFail("Pre-cancelled work must have no effect") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects.value, 0)
    }
}
