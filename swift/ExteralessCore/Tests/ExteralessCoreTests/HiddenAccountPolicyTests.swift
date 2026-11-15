import Foundation
import XCTest
@testable import ExteralessCore

final class HiddenAccountPolicyTests: XCTestCase {
    private let visible = PrivacyExtrasAccountIdentity(recordId: 10, userId: 100, testingEnvironment: false)
    private let hidden = PrivacyExtrasAccountIdentity(recordId: 11, userId: 200, testingEnvironment: false)
    private let excluded = PrivacyExtrasAccountIdentity(recordId: 12, userId: 300, testingEnvironment: false)

    private var configuration: HiddenAccountConfiguration {
        HiddenAccountConfiguration(accounts: [hidden: .init(hasPasscode: true, hidden: true), excluded: .init(allowPanic: false)], panicConfigured: true)
    }
    private func policy(_ config: HiddenAccountConfiguration? = nil) -> HiddenAccountPolicy {
        let policy = HiddenAccountPolicy()
        policy.update(configuration: config ?? configuration, accounts: [visible, hidden, excluded], current: hidden, foreground: true, locked: true, available: true)
        return policy
    }
    private func authorization(_ proof: HiddenAccountAuthentication, policy: HiddenAccountPolicy, explicit: Bool = true) throws -> HiddenAccountAuthorization? {
        let attempt = try XCTUnwrap(policy.beginAttempt(now: 100, explicitPasscodeEntry: explicit))
        return policy.authorize(proof, attempt: attempt, now: 101)
    }

    func testDefaultsAndHiddenRequiresOwnCode() {
        XCTAssertFalse(HiddenAccountState().isHidden)
        XCTAssertTrue(HiddenAccountState().allowPanic)
        XCTAssertFalse(HiddenAccountState(hasPasscode: false, hidden: true).isHidden)
        XCTAssertTrue(HiddenAccountState(hasPasscode: true, hidden: true).isHidden)
        let policy = policy()
        XCTAssertFalse(policy.isVisible(hidden))
        XCTAssertFalse(policy.shouldNotify(hidden))
        XCTAssertTrue(policy.shouldNotify(visible))
    }

    func testOrdinaryPinAndBiometryChooseVisibleAccountNeverPanic() throws {
        for proof in [HiddenAccountAuthentication.ordinaryPin, .biometry] {
            let policy = policy()
            let authorization = try XCTUnwrap(authorization(proof, policy: policy, explicit: false))
            XCTAssertEqual(policy.consume(authorization, now: 102), .unlock(account: visible, reveal: false))
            XCTAssertFalse(policy.canUse(hidden))
        }
    }

    func testAccountCodeRevealsOnlyMatchingIdentityForOneUnlock() throws {
        let policy = policy()
        let authorization = try XCTUnwrap(authorization(.accountCode(hidden), policy: policy))
        XCTAssertEqual(policy.consume(authorization, now: 102), .unlock(account: hidden, reveal: true))
        XCTAssertTrue(policy.canSelect(hidden)) // switch while still covered by AppLock
        policy.update(configuration: configuration, accounts: [visible, hidden, excluded], current: hidden, foreground: true, locked: false, available: true)
        XCTAssertTrue(policy.canUse(hidden))
        XCTAssertFalse(policy.isVisible(hidden)) // picker and alerts remain hidden
        policy.update(configuration: configuration, accounts: [visible, hidden, excluded], current: hidden, foreground: false, locked: false, available: true)
        XCTAssertFalse(policy.canUse(hidden))
        let recycled = PrivacyExtrasAccountIdentity(recordId: hidden.recordId, userId: 999, testingEnvironment: false)
        XCTAssertNil(try self.authorization(.accountCode(recycled), policy: self.policy()))
    }

    func testWrongPinCancelUnavailableAndUnconfiguredPanicProduceNoPlan() throws {
        for proof in [HiddenAccountAuthentication.wrongPin, .cancelled, .unavailable] {
            XCTAssertNil(try authorization(proof, policy: policy()))
        }
        var config = configuration; config.panicConfigured = false
        XCTAssertNil(try authorization(.panicCode, policy: policy(config)))
        XCTAssertNil(try authorization(.panicCode, policy: policy(), explicit: false))
    }

    func testPendingPanicIsInvalidatedByLifecycleAccountAndConfigurationChanges() throws {
        for scenario in 0 ..< 5 {
            let policy = policy()
            let authorization = try XCTUnwrap(authorization(.panicCode, policy: policy))
            var config = configuration
            if scenario == 3 { config.accounts[visible] = .init(allowPanic: false); config.revision += 1 }
            policy.update(configuration: config, accounts: [visible, hidden, excluded], current: scenario == 2 ? visible : hidden, foreground: scenario != 0, locked: scenario != 1, available: scenario != 4)
            XCTAssertNil(policy.consume(authorization, now: 102))
        }
        let policy = policy()
        let authorization = try XCTUnwrap(authorization(.panicCode, policy: policy))
        XCTAssertNil(policy.consume(authorization, now: 116))
    }

    func testAllHiddenKeepsOrdinaryAndBiometricUnlockClosed() throws {
        var config = configuration
        for id in [visible, hidden, excluded] { config.accounts[id] = .init(hasPasscode: true, hidden: true) }
        XCTAssertNil(try authorization(.ordinaryPin, policy: policy(config)))
        XCTAssertNil(try authorization(.biometry, policy: policy(config), explicit: false))
        XCTAssertNotNil(try authorization(.accountCode(hidden), policy: policy(config)))
    }

    func testPanicOneShotEffectsRecordExactTargetsAndCleanupFailureDoesNotBroadenScope() throws {
        final class Recorder: HiddenAccountPanicEffects {
            enum Failure: Error { case cleanup }
            let fail: PrivacyExtrasAccountIdentity
            var cleaned: [PrivacyExtrasAccountIdentity] = []
            var loggedOut: [PrivacyExtrasAccountIdentity] = []
            init(fail: PrivacyExtrasAccountIdentity) { self.fail = fail }
            func clearTemporaryFiles(for account: PrivacyExtrasAccountIdentity) throws { cleaned.append(account); if account == fail { throw Failure.cleanup } }
            func logout(_ account: PrivacyExtrasAccountIdentity) throws { loggedOut.append(account) }
        }
        let policy = policy()
        let authorization = try XCTUnwrap(authorization(.panicCode, policy: policy))
        let plan = try XCTUnwrap(policy.consume(authorization, now: 102))
        let recorder = Recorder(fail: hidden)
        let result = HiddenAccountPanicExecutor.execute(plan, effects: recorder)
        XCTAssertEqual(recorder.cleaned, [visible, hidden])
        XCTAssertEqual(recorder.loggedOut, [visible, hidden])
        XCTAssertEqual(result.temporaryCleanupFailed, [hidden])
        XCTAssertNil(policy.consume(authorization, now: 102))
        XCTAssertFalse(recorder.loggedOut.contains(excluded))
    }

    func testSupersededAndCancelledAttemptsCannotBeReplayed() throws {
        let policy = policy()
        let old = try XCTUnwrap(authorization(.panicCode, policy: policy))
        let next = try XCTUnwrap(policy.beginAttempt(now: 102, explicitPasscodeEntry: true))
        XCTAssertNil(policy.consume(old, now: 103))
        let current = try XCTUnwrap(policy.authorize(.panicCode, attempt: next, now: 103))
        policy.cancel(next)
        XCTAssertNil(policy.consume(current, now: 104))
    }

    func testUnlockContinuationSurvivesOnlyTheIntendedAccountSwitch() throws {
        let policy = self.policy()
        let authorized = try XCTUnwrap(authorization(.ordinaryPin, policy: policy))
        XCTAssertNotNil(policy.consume(authorized, now: 102))
        policy.update(configuration: configuration, accounts: [visible, hidden, excluded], current: visible, foreground: true, locked: true, available: true)
        XCTAssertTrue(policy.finishUnlock(authorized, now: 103))
        XCTAssertFalse(policy.finishUnlock(authorized, now: 103))
        let cancelled = self.policy()
        let old = try XCTUnwrap(authorization(.accountCode(hidden), policy: cancelled))
        XCTAssertNotNil(cancelled.consume(old, now: 102))
        cancelled.cancel(nil)
        XCTAssertFalse(cancelled.finishUnlock(old, now: 103))
        let switched = self.policy()
        let pending = try XCTUnwrap(authorization(.ordinaryPin, policy: switched))
        XCTAssertNotNil(switched.consume(pending, now: 102))
        switched.update(configuration: configuration, accounts: [visible, hidden, excluded], current: excluded, foreground: true, locked: true, available: true)
        XCTAssertFalse(switched.finishUnlock(pending, now: 103))
    }

    func testPrivateSettingsUseInjectedSecretsAndExportNoCapabilityOrIdentity() throws {
        final class SecretStore: ClientSecretStore, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
            func set(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClientSettings(storageURL: root.appendingPathComponent("private.json"), secretStore: SecretStore())
        try store.register(PrivacyExtrasFeatures.privateDefinitions)
        try store.set(.string("fixture-only-capability"), for: "privacy.settingsKey")
        try store.set(.object([hidden.storageKey: .bool(true)]), for: "privacy.accountHidden")
        XCTAssertEqual(store.value("privacy.settingsKey"), .string("fixture-only-capability"))
        XCTAssertEqual(store.snapshot()["privacy.settingsKey"], .null)
        let exported = String(decoding: try store.exportJSON(), as: UTF8.self)
        XCTAssertFalse(exported.contains("fixture-only-capability")); XCTAssertFalse(exported.contains(hidden.storageKey))
        let disk = try String(contentsOf: root.appendingPathComponent("private.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains("fixture-only-capability")); XCTAssertFalse(disk.contains(hidden.storageKey))
        XCTAssertThrowsError(try store.setPublic(.bool(false), for: "privacy.settingsHidden"))
    }
}
