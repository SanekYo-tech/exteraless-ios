import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit
import XCTest
@testable import TelegramCore

/// Controlled signals and synthetic AccountRecord values. No Account/AccountManager,
/// production Keychain, logout, UNUserNotificationCenter, sound or vibration.
final class ExteralessPrivacyAdmissionReviewTests: XCTestCase {
    private let identity = PrivacyExtrasAccountIdentity(recordId: 81, userId: 82, testingEnvironment: false)

    private final class HiddenRevision: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        private var visible = true
        func read() -> UInt64? { lock.lock(); defer { lock.unlock() }; return visible ? value : nil }
        func hide() { lock.lock(); value += 1; visible = false; lock.unlock() }
    }

    private final class Revisions: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UInt32] = []
        func append(_ value: UInt32) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [UInt32] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func settings(_ root: URL) throws -> ClientSettings {
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("filters.json"), secretStore: AdmissionFixtureSecrets())
        try settings.register(PrivacyExtrasFeatures.definitions)
        return settings
    }

    private func message() -> Message {
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(83))
        return Message(stableId: 1, stableVersion: 0, id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 1, flags: [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: "block this text", attributes: [], media: [], peers: SimpleDictionary<PeerId, Peer>(), associatedMessages: SimpleDictionary<MessageId, Message>(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }

    private func delivery(batch: ExteralessNotificationMessageBatch, id: UUID, object: ObjectIdentifier, runtime: ExteralessFilteringRuntime, hidden: HiddenRevision) throws -> ExteralessAdmittedNotificationBatch {
        let revision = FilteringNotificationRevision(filtering: runtime.revision, hidden: try XCTUnwrap(hidden.read()))
        let state = FilteringNotificationAdmission(batchId: id, accountIdentity: identity, accountObject: object, revision: revision, currentRevision: {
            guard let value = hidden.read() else { return nil }
            return .init(filtering: runtime.revision, hidden: value)
        })
        var budget = FilteringWorkBudget(operations: 2_000)
        let policy = runtime.policy(identity)
        let visible: ExteralessNotificationMessageBatch = batch.compactMap { messages, group, notify, thread in
            let filtered = exteralessFilterNotificationMessages(policy: policy, messages: messages, budget: &budget)
            return filtered.isEmpty ? nil : (filtered, group, notify, thread)
        }
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(state.isCurrent(accountIdentity: identity, accountObject: object))
        return ExteralessAdmittedNotificationBatch(messages: visible, admission: ExteralessNotificationAdmission(state: state))
    }

    func testPR03SuspendedConsumerDropsFilterAndHiddenRevocationsBeforeAllEffects() throws {
        for hide in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("admission-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = try self.settings(root)
            try settings.set(.bool(true), for: "privacy.regexFiltersEnableInChats")
            let runtime = ExteralessFilteringRuntime(settings: settings)
            let hidden = HiddenRevision()
            let object = NSObject()
            let objectId = ObjectIdentifier(object)
            let source = ValuePipe<ExteralessNotificationMessageBatch>()
            let heldCompletion = ValuePipe<Void>()
            var effects: [FilteringNotificationEffect] = []
            var reachedConsumer = 0
            let stream = exteralessAdmittedNotificationStream(source: source.signal(), prepare: { batch, id in
                .single(try? self.delivery(batch: batch, id: id, object: objectId, runtime: runtime, hidden: hidden))
            }) |> mapToSignal { delivery in
                reachedConsumer += 1
                // Models the actual downstream EngineData/lock-state async hop.
                return heldCompletion.signal() |> take(1) |> map { _ -> Void in
                    for effect in [FilteringNotificationEffect.sound, .vibration, .enqueue] {
                        delivery.admission.state.performIfCurrent(accountIdentity: self.identity, accountObject: objectId, effect: effect) { effects.append(effect) }
                    }
                }
            }
            let disposable = stream.start()
            source.putNext([([message()], .root, true, nil)])
            XCTAssertEqual(reachedConsumer, 1)
            if hide { hidden.hide() }
            else {
                try runtime.setCollection("regexFiltersData", account: identity, value: FilteringConfiguration.value(for: [.init(id: "block", regex: "block")]))
                try settings.set(.bool(true), for: "privacy.regexFiltersEnabled")
                var budget = FilteringWorkBudget(operations: 2_000)
                XCTAssertTrue(exteralessFilterNotificationMessages(policy: runtime.policy(identity), messages: [message()], budget: &budget).isEmpty)
            }
            heldCompletion.putNext(())
            XCTAssertTrue(effects.isEmpty)
            disposable.dispose()
        }
    }

    func testPR03StreamSupersessionDisposalAndLateDuplicateCompletionAreRevoked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("admission-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ExteralessFilteringRuntime(settings: try settings(root))
        let hidden = HiddenRevision()
        let object = NSObject()
        let objectId = ObjectIdentifier(object)
        let source = ValuePipe<ExteralessNotificationMessageBatch>()
        var deliveries: [ExteralessAdmittedNotificationBatch] = []
        let disposable = exteralessAdmittedNotificationStream(source: source.signal(), prepare: { batch, id in
            .single(try? self.delivery(batch: batch, id: id, object: objectId, runtime: runtime, hidden: hidden))
        }).start(next: { deliveries.append($0) })
        source.putNext([([message()], .root, true, nil)])
        source.putNext([([message()], .root, true, nil)])
        guard deliveries.count == 2 else { disposable.dispose(); return XCTFail("Both filtered batches must reach the consumer") }
        var effects = 0
        XCTAssertFalse(deliveries[0].admission.state.performIfCurrent(accountIdentity: identity, accountObject: objectId, effect: .sound) { effects += 1 })
        XCTAssertTrue(deliveries[1].admission.state.performIfCurrent(accountIdentity: identity, accountObject: objectId, effect: .sound) { effects += 1 })
        XCTAssertFalse(deliveries[1].admission.state.performIfCurrent(accountIdentity: identity, accountObject: objectId, effect: .sound) { effects += 1 })
        disposable.dispose()
        XCTAssertFalse(deliveries[1].admission.state.performIfCurrent(accountIdentity: identity, accountObject: objectId, effect: .enqueue) { effects += 1 })
        XCTAssertEqual(effects, 1)
    }

    func testPR13RealNestedCollectionWriterPublishesAfterOutermostRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filter-lock-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ExteralessFilteringRuntime(settings: try settings(root))
        let identity = self.identity
        var initial = true
        var unlockedReads: [Bool] = []
        let disposable = runtime.changes.start(next: { _ in
            if initial { return }
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = runtime.policy(identity); _ = runtime.revision; read.signal() }
            unlockedReads.append(read.wait(timeout: .now() + 0.5) == .success)
        })
        defer { disposable.dispose() }
        initial = false
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(84))
        try runtime.setPeer(peer, account: identity, filtered: true)
        XCTAssertEqual(unlockedReads, [true])
        XCTAssertTrue(runtime.policy(identity).configuration.customFilteredUsers.contains(peer.toInt64()))
    }

    func testPR13ConcurrentRMWKeepsEveryPeerAndMonotonicRevisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filter-lock-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ExteralessFilteringRuntime(settings: try settings(root))
        let identity = self.identity
        let revisions = Revisions()
        let disposable = runtime.changes.start(next: { revisions.append($0) })
        defer { disposable.dispose() }
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                try runtime.setPeer(PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(Int64(90 + index))), account: identity, filtered: true)
            } catch { XCTFail("isolated collection mutation failed") }
        }
        let values = revisions.values
        XCTAssertEqual(runtime.policy(identity).configuration.customFilteredUsers.count, 8)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(UInt64(try XCTUnwrap(values.last)), runtime.revision)
    }

    private func record(id: Int64? = nil, user: Int64? = nil, environment: AccountEnvironment? = .production, backup: Bool = true) -> AccountRecord<TelegramAccountManagerTypes.Attribute> {
        var attributes: [TelegramAccountManagerTypes.Attribute] = []
        if let environment { attributes.append(.environment(AccountEnvironmentAttribute(environment: environment))) }
        if backup {
            let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(user ?? identity.userId))
            let data = AccountBackupData(masterDatacenterId: 2, peerId: peer.toInt64(), masterDatacenterKey: Data(repeating: 1, count: 32), masterDatacenterKeyId: 1, notificationEncryptionKeyId: nil, notificationEncryptionKey: nil, additionalDatacenterKeys: [:])
            attributes.append(.backupData(AccountBackupDataAttribute(data: data)))
        }
        return AccountRecord(id: AccountRecordId(rawValue: id ?? identity.recordId), attributes: attributes, temporarySessionId: 123)
    }

    func testPR12RejectedRecordHasNoLogoutTransitionOrAnyCleanupCallback() {
        let records: [AccountRecord<TelegramAccountManagerTypes.Attribute>?] = [nil, record(id: 999), record(user: 999), record(environment: .test), record(environment: nil), record(backup: false)]
        for record in records {
            let result = exteralessPanicRecordTransition(record: record, expected: identity)
            var effects: [String] = []
            exteralessWithAdmittedPanicIdentity(result.admission) { _ in effects += ["temporary", "private"] }
            exteralessWithAdmittedPanicIdentity(result.admission) { _ in effects.append("notifications") }
            XCTAssertNil(result.admission)
            XCTAssertTrue(result.record === record)
            XCTAssertTrue(effects.isEmpty)
        }
    }

    func testPR12OnlyTransactionAdmittedIdentityReachesInjectedEffects() {
        let original = record()
        let result = exteralessPanicRecordTransition(record: original, expected: identity)
        var effects: [PrivacyExtrasAccountIdentity] = []
        XCTAssertNotNil(result.admission)
        XCTAssertTrue(result.record?.attributes.contains(where: { if case .loggedOut = $0 { return true }; return false }) == true)
        exteralessWithAdmittedPanicIdentity(result.admission) { effects.append($0) } // temp/private stage
        exteralessWithAdmittedPanicIdentity(result.admission) { effects.append($0) } // main notification stage
        XCTAssertEqual(effects, [identity, identity])
        XCTAssertNil(result.record?.temporarySessionId)
        XCTAssertEqual(original.temporarySessionId, 123)
    }
}

private final class AdmissionFixtureSecrets: ClientSecretStore, @unchecked Sendable {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { XCTFail("Public filter fixture attempted a secret write") }
}
