import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit
import XCTest
@testable import TelegramCore

/// Synthetic messages/identity tokens and an injected secret store only. None of
/// these fixtures creates an Account, authenticates against Keychain, or logs out.
final class ExteralessPrivacyExtrasRemediationTests: XCTestCase {
    private let a = PrivacyExtrasAccountIdentity(recordId: 31, userId: 41, testingEnvironment: false)
    private let b = PrivacyExtrasAccountIdentity(recordId: 32, userId: 42, testingEnvironment: false)

    private final class Secrets: ClientSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func set(_ data: Data?, for key: String) throws { lock.lock(); values[key] = data; lock.unlock() }
        var snapshot: [String: Data] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private final class StorageProbe {
        let secrets = Secrets()
        var roots: [URL?] = []
        var scopes: [String?] = []
        var first = true
    }

    private func fixture(basePath: String, accountCodes: [PrivacyExtrasAccountIdentity], panic: Bool, probe: StorageProbe) -> ExteralessHiddenAccounts {
        return ExteralessHiddenAccounts(makeStorage: { url, _, scope, root in
            XCTAssertEqual(url, URL(fileURLWithPath: basePath, isDirectory: true).appendingPathComponent("exteraless/privacy-extras-private.json"))
            probe.roots.append(root); probe.scopes.append(scope)
            let settings = try ClientSettings(storageURL: url, secretStore: probe.secrets, durabilityRootURL: root)
            try settings.register(PrivacyExtrasFeatures.privateDefinitions)
            if probe.first {
                probe.first = false
                // Valid verifier shape, not a real user's PIN or credential.
                let code: ClientSettingValue = .object([
                    "kind": .string("digits4"),
                    "salt": .string(Data(repeating: 1, count: 16).base64EncodedString()),
                    "hash": .string(Data(repeating: 2, count: 32).base64EncodedString())
                ])
                try settings.set(.object(Dictionary(uniqueKeysWithValues: accountCodes.map { ($0.storageKey, code) })), for: "privacy.passcodeHash")
                try settings.set(.object(Dictionary(uniqueKeysWithValues: accountCodes.map { ($0.storageKey, .bool(true)) })), for: "privacy.accountHidden")
                if panic { try settings.set(code, for: "privacy.panicPasscode") }
            }
            return settings
        })
    }

    private func message(id: Int32, namespace: Int32 = Namespaces.Message.Cloud, thread: Int64? = nil, group: Int64? = nil, text: String) -> Message {
        let peer = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(44))
        return Message(stableId: UInt32(id), stableVersion: 0, id: MessageId(peerId: peer, namespace: namespace, id: id), globallyUniqueId: nil, groupingKey: group, groupInfo: nil, threadId: thread, timestamp: id, flags: [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: text, attributes: [], media: [], peers: SimpleDictionary<PeerId, Peer>(), associatedMessages: SimpleDictionary<MessageId, Message>(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }

    @MainActor
    func testAActualWaitDoesNotFinishAtRawPrimaryBeforeInstalledRoot() throws {
        let primary = ValuePromise<PrivacyExtrasAccountIdentity?>(a, ignoreRepeated: true)
        let foreground = ValuePromise(true, ignoreRepeated: true)
        let rootReady = ValuePromise(false, ignoreRepeated: true)
        let policy = HiddenAccountPolicy()
        let configuration = HiddenAccountConfiguration(accounts: [b: .init(hasPasscode: true, hidden: true)])
        policy.update(configuration: configuration, accounts: [a, b], current: a, foreground: true, locked: true, available: true)
        let attempt = try XCTUnwrap(policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
        let authorization = try XCTUnwrap(policy.authorize(.accountCode(b), attempt: attempt, now: 1))
        XCTAssertNotNil(policy.consume(authorization, now: 2))
        var finished: [Bool] = []
        let disposable = exteralessAwaitHiddenAccountPresentation(identity: b, primary: primary.get(), foreground: foreground.get(), rootReady: rootReady.get()).start(next: {
            finished.append($0 && policy.finishUnlock(authorization, now: 3))
        })
        defer { disposable.dispose() }
        policy.update(configuration: configuration, accounts: [a, b], current: b, foreground: true, locked: true, available: true)
        primary.set(b)
        XCTAssertTrue(finished.isEmpty)
        XCTAssertFalse(policy.canUse(b))
        rootReady.set(true)
        XCTAssertEqual(finished, [true])
        rootReady.set(false); rootReady.set(true)
        XCTAssertEqual(finished, [true])
    }

    @MainActor
    func testAReadyStateCannotReviveRetiredAuthorizationAndBackgroundFailsClosed() throws {
        let primary = ValuePromise<PrivacyExtrasAccountIdentity?>(b, ignoreRepeated: true)
        let foreground = ValuePromise(true, ignoreRepeated: true)
        let ready = ValuePromise(false, ignoreRepeated: true)
        let policy = HiddenAccountPolicy()
        policy.update(configuration: .init(accounts: [b: .init(hasPasscode: true, hidden: true)]), accounts: [a, b], current: b, foreground: true, locked: true, available: true)
        let attempt = try XCTUnwrap(policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
        let authorization = try XCTUnwrap(policy.authorize(.accountCode(b), attempt: attempt, now: 1))
        XCTAssertNotNil(policy.consume(authorization, now: 2))
        var finished: [Bool] = []
        let disposable = exteralessAwaitHiddenAccountPresentation(identity: b, primary: primary.get(), foreground: foreground.get(), rootReady: ready.get()).start(next: {
            finished.append($0 && policy.finishUnlock(authorization, now: 3))
        })
        policy.cancel(attempt)
        ready.set(true)
        XCTAssertEqual(finished, [false])
        disposable.dispose()

        var background: [Bool] = []
        ready.set(false)
        let second = exteralessAwaitHiddenAccountPresentation(identity: b, primary: primary.get(), foreground: foreground.get(), rootReady: ready.get()).start(next: { background.append($0) })
        foreground.set(false); ready.set(true)
        XCTAssertEqual(background, [false])
        second.dispose()
    }

    @MainActor
    func testAWaitTimeoutAndDisposalDoNotCompleteLateOnReadiness() {
        let primary = ValuePromise<PrivacyExtrasAccountIdentity?>(b, ignoreRepeated: true)
        let ready = ValuePromise(false, ignoreRepeated: true)
        let timedOut = expectation(description: "root readiness deadline")
        var results: [Bool] = []
        let signal = exteralessAwaitHiddenAccountPresentationImpl(identity: b, primary: primary.get(), foreground: .single(true), rootReady: ready.get(), timeoutSeconds: 0.05)
        let disposable = signal.start(next: { results.append($0); timedOut.fulfill() })
        var cancelledValues: [Bool] = []
        let cancelled = signal.start(next: { cancelledValues.append($0) })
        cancelled.dispose()
        wait(for: [timedOut], timeout: 1.0)
        ready.set(true)
        XCTAssertEqual(results, [false])
        XCTAssertTrue(cancelledValues.isEmpty)
        disposable.dispose()
    }

    func testBBothNativeNotificationConsumersRejectIncompleteActualEvaluation() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "reverse", regex: "safe$", reversed: true)]
        let policy = FilteringPolicy(account: a, configuration: configuration)
        let input = message(id: 1, text: "not safe yet")
        var serviceBudget = FilteringWorkBudget(operations: 1)
        let decision = exteralessNotificationMessageDecision(policy: policy, message: input, group: [], budget: &serviceBudget)
        XCTAssertEqual(decision, .awaitMessage)
        XCTAssertEqual(serviceBudget.remaining, 0)
        let gate = ExteralessPrivacyExtrasNotificationGate(currentGeneration: { 1 }, accountAllowsNotifications: { _ in true })
        gate.bind(account: a)
        gate.update(decision, generation: 1)
        XCTAssertFalse(gate.canPresent) // actual content generator guard, before title/sound/attachments
        var appBudget = FilteringWorkBudget(operations: 1)
        XCTAssertTrue(exteralessFilterNotificationMessages(policy: policy, messages: [input], budget: &appBudget).isEmpty)
        XCTAssertEqual(appBudget.remaining, 0)
    }

    func testBActualAlbumScopeIncludesMessageNamespaceAndThread() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "block", regex: "block")]
        let policy = FilteringPolicy(account: a, configuration: configuration)
        let cloud = message(id: 1, thread: 7, group: 8, text: "clean")
        let local = message(id: 2, namespace: Namespaces.Message.Local, thread: 7, group: 8, text: "block")
        let otherThread = message(id: 3, thread: 9, group: 8, text: "block")
        let inputs = [cloud, local, otherThread]
        XCTAssertEqual(exteralessFilteringAlbum(message: cloud, messages: inputs).map(\.id), [cloud.id])
        var budget = FilteringWorkBudget(operations: 2_000)
        XCTAssertEqual(exteralessFilterNotificationMessages(policy: policy, messages: inputs, budget: &budget).map(\.id), [cloud.id])
    }

    func testCNativeChangesPublishSameAccountRevealAndFailedFinish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = StorageProbe()
        let subject = fixture(basePath: root.path, accountCodes: [b], panic: false, probe: probe)
        try subject.configure(basePath: root.path, accessGroup: "group.fixture.privacy-extras", isMainApp: true)
        subject.policy.update(configuration: .init(accounts: [b: .init(hasPasscode: true, hidden: true)]), accounts: [a, b], current: b, foreground: true, locked: true, available: true)
        var visible: [Bool] = []
        let disposable = subject.changes.start(next: { _ in visible.append(subject.canSelect(self.b)) })
        defer { disposable.dispose() }
        visible.removeAll()
        let before = probe.secrets.snapshot
        let attempt = try XCTUnwrap(subject.policy.beginAttempt(now: 0, explicitPasscodeEntry: true))
        let authorization = try XCTUnwrap(subject.policy.authorize(.accountCode(b), attempt: attempt, now: 1))
        XCTAssertNotNil(subject.policy.consume(authorization, now: 2))
        XCTAssertFalse(subject.policy.finishUnlock(authorization, now: 16))
        XCTAssertEqual(visible, [true, false])
        XCTAssertEqual(probe.secrets.snapshot, before)
    }

    func testCNativeReloadObserverCanReadFromAnotherThreadOutsideAllStateLocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = StorageProbe()
        let subject = fixture(basePath: root.path, accountCodes: [b], panic: false, probe: probe)
        try subject.configure(basePath: root.path, accessGroup: "group.fixture.privacy-extras", isMainApp: true)
        var check = false
        var observations: [Bool] = []
        let disposable = subject.changes.start(next: { _ in
            guard check else { return }
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = subject.requiresUnlockRouting; _ = subject.isAvailable; read.signal() }
            observations.append(read.wait(timeout: .now() + 0.5) == .success)
        })
        defer { disposable.dispose() }
        check = true
        try subject.reload()
        XCTAssertEqual(observations, [true])
        check = false
        let wrongRoot = FileManager.default.temporaryDirectory.appendingPathComponent("unrelated-" + UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try subject.configure(basePath: root.path, accessGroup: "group.fixture.privacy-extras", isMainApp: true, durabilityRootURL: wrongRoot))
        check = true
        // A matching configure after failure enters reload under a second native
        // recursive lock. Its observer must still wait for the outermost unlock.
        try subject.configure(basePath: root.path, accessGroup: "group.fixture.privacy-extras", isMainApp: true)
        XCTAssertEqual(observations, [true, true])
    }

    func testDNativeColdStoreAndConfirmedEmptyRoutingNeverMutatePrivateCodes() throws {
        for panic in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = StorageProbe()
            let subject = fixture(basePath: root.path, accountCodes: [b], panic: panic, probe: probe)
            try subject.configure(basePath: root.path, accessGroup: "group.fixture.privacy-extras", isMainApp: true)
            let before = probe.secrets.snapshot
            XCTAssertTrue(subject.requiresUnlockRouting) // stored code, no native account emission yet
            XCTAssertNil(subject.beginAppUnlockAttempt(explicitPasscodeEntry: true))
            XCTAssertNil(subject.beginAppUnlockAttempt(explicitPasscodeEntry: false))
            try subject.reload()
            XCTAssertTrue(subject.requiresUnlockRouting) // reload is not an empty-account confirmation
            subject.update(accounts: [], current: nil, foreground: true, locked: true)
            XCTAssertFalse(subject.requiresUnlockRouting) // ordinary native PIN/biometry route
            XCTAssertNil(subject.beginAppUnlockAttempt(explicitPasscodeEntry: true))
            XCTAssertNil(subject.beginAppUnlockAttempt(explicitPasscodeEntry: false))
            subject.clearContext()
            XCTAssertFalse(subject.requiresUnlockRouting)
            XCTAssertEqual(subject.hasPanicCode, panic)
            XCTAssertEqual(probe.secrets.snapshot, before)
        }
    }

    func testDConfirmedClearBeforeConfigureIsNotLostToGlobalPanicCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = StorageProbe()
        let subject = fixture(basePath: root.path, accountCodes: [], panic: true, probe: probe)
        subject.clearContext()
        try subject.configure(basePath: root.path, accessGroup: "group.fixture.privacy-extras", isMainApp: true)
        XCTAssertTrue(subject.hasPanicCode)
        XCTAssertFalse(subject.requiresUnlockRouting)
        XCTAssertNil(subject.beginAppUnlockAttempt(explicitPasscodeEntry: true))
        XCTAssertNil(subject.beginAppUnlockAttempt(explicitPasscodeEntry: false))
    }

    func testDurabilityRootAndKeychainScopeParticipateInActualConfigureCache() throws {
        let provisioned = FileManager.default.temporaryDirectory
        let root = provisioned.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let basePath = root.appendingPathComponent("telegram-data", isDirectory: true).path
        let probe = StorageProbe()
        let subject = fixture(basePath: basePath, accountCodes: [], panic: false, probe: probe)
        try subject.configure(basePath: basePath, accessGroup: "group.fixture.privacy-extras", isMainApp: true, keychainScope: "scope-a")
        try subject.configure(basePath: basePath, accessGroup: "group.fixture.privacy-extras", isMainApp: true, keychainScope: "scope-a", durabilityRootURL: provisioned)
        XCTAssertEqual(probe.roots.count, 2)
        XCTAssertNil(probe.roots[0])
        XCTAssertEqual(probe.roots[1], provisioned)
        try subject.configure(basePath: basePath, accessGroup: "group.fixture.privacy-extras", isMainApp: true, keychainScope: "scope-a", durabilityRootURL: provisioned)
        XCTAssertEqual(probe.roots.count, 2)
        let wrongRoot = provisioned.appendingPathComponent("unrelated-" + UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try subject.configure(basePath: basePath, accessGroup: "group.fixture.privacy-extras", isMainApp: true, keychainScope: "scope-a", durabilityRootURL: wrongRoot))
        XCTAssertFalse(subject.isAvailable)
        try subject.configure(basePath: basePath, accessGroup: "group.fixture.privacy-extras", isMainApp: true, keychainScope: "scope-a", durabilityRootURL: provisioned)
        XCTAssertTrue(subject.isAvailable)
        try subject.configure(basePath: basePath, accessGroup: "group.fixture.privacy-extras", isMainApp: true, keychainScope: "scope-b", durabilityRootURL: provisioned)
        XCTAssertEqual(probe.scopes.last!, "scope-b")
        XCTAssertEqual(probe.roots.last!, provisioned)
    }
}
