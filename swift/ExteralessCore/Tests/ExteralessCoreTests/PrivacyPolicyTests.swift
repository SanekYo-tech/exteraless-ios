import Foundation
import XCTest
@testable import ExteralessCore

final class PrivacyPolicyTests: XCTestCase {
    private let peer = PrivacyPeerKey(accountId: 100, peerId: 7)

    func testOriginalDefaultsAndReactivation() {
        let baseline = PrivacyPolicy()
        XCTAssertTrue(baseline.allowsMessageRead(peer))
        XCTAssertTrue(baseline.allowsTyping(peer))
        XCTAssertTrue(baseline.allowsStoryRead(peer))
        XCTAssertTrue(baseline.reportOnline(requested: true))
        XCTAssertFalse(baseline.goOfflineAfterSend(to: peer))
        var values = baseline.ghostModeChanges(enabled: true)
        let ghost = PrivacyPolicy(values: values)
        XCTAssertTrue(ghost.ghostModeActive)
        XCTAssertFalse(ghost.allowsMessageRead(peer))
        XCTAssertFalse(ghost.allowsTyping(peer))
        XCTAssertFalse(ghost.allowsStoryRead(peer))
        XCTAssertFalse(ghost.reportOnline(requested: true))
        XCTAssertTrue(ghost.allowsMessageRead(peer, intent: .afterSend))
        values.merge(ghost.ghostModeChanges(enabled: false), uniquingKeysWith: { _, rhs in rhs })
        let restored = PrivacyPolicy(values: values)
        XCTAssertTrue(restored.allowsMessageRead(peer))
        XCTAssertTrue(restored.allowsTyping(peer))
        XCTAssertFalse(restored.goOfflineAfterSend(to: peer))
    }

    func testLockedToggleIsNotAppLockAndExclusionsDoNotCrossAccountsOrNamespaces() {
        let values: [String: ClientSettingValue] = [
            "privacy.sendUploadProgress": .bool(true), "privacy.sendUploadProgressLocked": .bool(true),
            "privacy.sendReadMessagePackets": .bool(false),
            "privacy.ghostModeReadExclusions": .object([peer.settingKey: .bool(true)])
        ]
        let policy = PrivacyPolicy(values: values)
        XCTAssertNil(policy.ghostModeChanges(enabled: true)["privacy.sendUploadProgress"])
        XCTAssertTrue(policy.allowsMessageRead(peer))
        XCTAssertFalse(policy.allowsMessageRead(PrivacyPeerKey(accountId: 101, peerId: 7)))
        XCTAssertFalse(policy.allowsMessageRead(PrivacyPeerKey(accountId: 100, peerId: -7)))
        XCTAssertFalse(policy.allowsMessageRead(PrivacyPeerKey(accountId: 100, peerId: 1 << 32 | 7)))
        XCTAssertFalse(policy.allowsStoryRead(peer, ghostSession: true))
    }

    func testExplicitReadAndDisabledReadAfterSendAreIndependent() {
        let policy = PrivacyPolicy(values: ["privacy.sendReadMessagePackets": .bool(false), "privacy.markReadAfterSend": .bool(false)])
        XCTAssertFalse(policy.allowsMessageRead(peer, intent: .afterSend))
        XCTAssertTrue(policy.allowsMessageRead(peer, intent: .explicit))
    }

    func testNotificationPrivacyNeverOverridesChatOrAccountPrivacy() {
        let permitLocked = PrivacyPolicy(values: ["privacy.showNotificationPreviewWhenLocked": .bool(true)])
        XCTAssertEqual(NotificationPrivacyContext(appLocked: true).decision(policy: PrivacyPolicy()), .redact)
        XCTAssertEqual(NotificationPrivacyContext(appLocked: true).decision(policy: permitLocked), .show)
        XCTAssertEqual(NotificationPrivacyContext(appLocked: true, chatPreviews: false).decision(policy: permitLocked), .redact)
        XCTAssertEqual(NotificationPrivacyContext(accountResolved: false, appLocked: false).decision(policy: permitLocked), .suppress)
        XCTAssertEqual(NotificationPrivacyContext(accountEnabled: false, appLocked: false).decision(policy: permitLocked), .suppress)
    }

    func testProxyConditionsDoNotGuessVPNOrDisableOnUnknownPath() {
        XCTAssertFalse(ProxyDisableConditions.vpn.matches(mobileData: false, wifi: false))
        XCTAssertTrue(ProxyDisableConditions.vpn.matches(mobileData: false, wifi: false, vpn: true))
        let both: ProxyDisableConditions = [.mobileData, .wifi]
        XCTAssertTrue(both.matches(mobileData: false, wifi: true))
        XCTAssertFalse(ProxyDisableConditions.wifi.matches(mobileData: true, wifi: false))
    }

    func testCompletionAndCancellationAreExactlyOnce() {
        var values: [Int] = []
        let completion = PrivacyCompletion<Int> { values.append($0) }
        XCTAssertTrue(completion.finish(1))
        XCTAssertFalse(completion.finish(2))
        completion.cancel()
        XCTAssertEqual(values, [1])
        let cancelled = PrivacyCompletion<Int> { values.append($0) }
        cancelled.cancel()
        XCTAssertFalse(cancelled.finish(3))
        XCTAssertEqual(values, [1])
    }

    func testConcurrentCompletionAndCancellationRace() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let count = Counter()
        let completion = PrivacyCompletion<Int> { _ in count.increment() }
        DispatchQueue.concurrentPerform(iterations: 32) { index in completion.finish(index) }
        XCTAssertEqual(count.value, 1)
        let cancelledCount = Counter()
        let cancelled = PrivacyCompletion<Int> { _ in cancelledCount.increment() }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index % 3 == 0 { cancelled.cancel() } else { cancelled.finish(index) }
        }
        XCTAssertLessThanOrEqual(cancelledCount.value, 1)
        XCTAssertFalse(cancelled.finish(100))
    }

    func testBotSelectionRequiresEstablishedHistoryAndCompleteEvidence() {
        XCTAssertEqual(BotAccountPolicy.choose(useSelectedAccount: true, alwaysAsk: false, requested: 1, configured: 2, explicit: false, established: [], available: [1, 2], complete: true), .account(2))
        XCTAssertEqual(BotAccountPolicy.choose(useSelectedAccount: true, alwaysAsk: false, requested: 1, configured: 2, explicit: true, established: [1], available: [1, 2], complete: false), .account(1))
        XCTAssertEqual(BotAccountPolicy.choose(useSelectedAccount: true, alwaysAsk: false, requested: 1, configured: 2, explicit: false, established: [1], available: [1, 2], complete: false), .unknown)
        XCTAssertEqual(BotAccountPolicy.choose(useSelectedAccount: true, alwaysAsk: false, requested: 1, configured: nil, explicit: false, established: [], available: [1], complete: true), .unavailable)
        XCTAssertEqual(BotAccountPolicy.choose(useSelectedAccount: false, alwaysAsk: true, requested: 1, configured: nil, explicit: false, established: [1, 2], available: [1, 2], complete: true), .choose([1, 2]))
    }

    func testFailedBotStartsRetryButOtherIdentitiesDoNotShareDeduplication() {
        let starts = BotStartDeduplicator()
        XCTAssertTrue(starts.begin(accountId: 1, identity: 20, botId: 30, payload: "a:b"))
        XCTAssertFalse(starts.begin(accountId: 1, identity: 20, botId: 30, payload: "a:b"))
        XCTAssertTrue(starts.begin(accountId: 1, identity: 21, botId: 30, payload: "a:b"))
        starts.failed(accountId: 1, identity: 20, botId: 30, payload: "a:b")
        XCTAssertTrue(starts.begin(accountId: 1, identity: 20, botId: 30, payload: "a:b"))
    }

    func testLocalObservationsExpireAndReplayCannotRewriteDates() throws {
        var observations = PrivacyObservations()
        observations.observeActivity(peerId: 7, timestamp: 900, now: 1000)
        observations.observeActivity(peerId: 7, timestamp: 800, now: 1000)
        observations.observeActivity(peerId: 7, timestamp: 1001, now: 1000)
        XCTAssertEqual(observations.observedActivity(peerId: 7, now: 1000), 900)
        XCTAssertNil(observations.observedActivity(peerId: 7, now: 1000 + PrivacyObservations.lastSeenRetention))
        observations.observeRead(peerId: 7, namespace: 0, id: 9, timestamp: 100, played: false)
        observations.observeRead(peerId: 7, namespace: 0, id: 9, timestamp: 200, played: false)
        observations.observeRead(peerId: 7, namespace: 0, id: 9, timestamp: 300, played: true)
        let roundTrip = try JSONDecoder().decode(PrivacyObservations.self, from: JSONEncoder().encode(observations))
        XCTAssertEqual(roundTrip.reads["7:0:9"], PrivacyObservations.Read(readAt: 100, playedAt: 300))
        XCTAssertNil(roundTrip.reads["7:2:9"])
    }

    func testRawRequestGuardDoesNotLeakThroughAnUnknownPeerOrInventPTS() {
        let ghost = PrivacyPolicy(values: PrivacyPolicy().ghostModeChanges(enabled: true))
        for method in ["messages.readHistory", "channels.readHistory", "messages.readMessageContents", "messages.readDiscussion", "stories.readStories", "stories.incrementStoryViews", "messages.setTyping", "messages.setEncryptedTyping"] {
            XCTAssertFalse(ghost.permitsRequest(method: method, peer: nil, incrementViews: nil, requestsOnline: nil), method)
        }
        XCTAssertTrue(ghost.permitsRequest(method: "messages.getMessagesViews", peer: peer, incrementViews: false, requestsOnline: nil))
        XCTAssertFalse(ghost.permitsRequest(method: "messages.getMessagesViews", peer: peer, incrementViews: true, requestsOnline: nil))
        XCTAssertTrue(ghost.permitsRequest(method: "account.updateStatus", peer: nil, incrementViews: nil, requestsOnline: false))
        XCTAssertFalse(ghost.permitsRequest(method: "account.updateStatus", peer: nil, incrementViews: nil, requestsOnline: true))
        XCTAssertTrue(ghost.permitsRequest(method: "updates.getDifference", peer: nil, incrementViews: nil, requestsOnline: nil))
    }

    func testValidatedMultiPeerReadRequiresEveryExceptionAndCompleteResolution() {
        let allowed = PrivacyPeerKey(accountId: 1, peerId: 7)
        let denied = PrivacyPeerKey(accountId: 1, peerId: 8)
        let otherAccount = PrivacyPeerKey(accountId: 2, peerId: 7)
        let policy = PrivacyPolicy(values: ["privacy.sendReadMessagePackets": .bool(false), "privacy.ghostModeReadExclusions": .object([allowed.settingKey: .bool(true)])])
        func permits(_ peers: [PrivacyPeerKey], complete: Bool) -> Bool {
            policy.permitsRequest(method: "messages.readMessageContents", peers: peers, allPeersResolved: complete, incrementViews: nil, requestsOnline: nil)
        }
        XCTAssertTrue(permits([allowed], complete: true))
        XCTAssertFalse(permits([allowed, denied], complete: true))
        XCTAssertFalse(permits([allowed], complete: false))
        XCTAssertFalse(permits([otherAccount], complete: true))
        XCTAssertFalse(permits([], complete: false))
    }

    func testGhostSchedulerPreservesExplicitAndSpecialSendFlows() {
        func date(explicit: Bool = false, special: Bool = false, bot: Bool = false, secret: Bool = false, isSelf: Bool = false) -> Int32? {
            PrivacyScheduledSendPolicy.scheduleDate(enabled: true, sendsOnline: false, now: 1000, hasExplicitSchedule: explicit, isSelf: isSelf, isSecret: secret, isBotOrUnknownUser: bot, isSpecialFlow: special)
        }
        XCTAssertEqual(date(), 1012)
        XCTAssertNil(date(explicit: true))
        XCTAssertNil(date(special: true))
        XCTAssertNil(date(bot: true))
        XCTAssertNil(date(secret: true))
        XCTAssertNil(date(isSelf: true))
        XCTAssertNil(PrivacyScheduledSendPolicy.scheduleDate(enabled: true, sendsOnline: true, now: 1000, hasExplicitSchedule: false, isSelf: false, isSecret: false, isBotOrUnknownUser: false, isSpecialFlow: false))
    }

    func testNotificationDiagnosticsAreAccountScopedAndProviderAcceptanceIsExplicit() throws {
        let diagnostics = PrivacyNotificationDiagnostics()
        diagnostics.recordTokenReceived()
        diagnostics.recordRegistration(accountId: 1, transport: .apns, state: .registered, sandbox: true)
        diagnostics.recordRegistration(accountId: 2, transport: .apns, state: .failed(code: 400), sandbox: false)
        XCTAssertEqual(diagnostics.snapshot(accountId: 1).apnsRegistration, .registered)
        XCTAssertEqual(diagnostics.snapshot(accountId: 2).apnsRegistration, .failed(code: 400))
        XCTAssertEqual(diagnostics.snapshot(accountId: 3).apnsRegistration, .notAttempted)
        diagnostics.removeAccount(1)
        XCTAssertEqual(diagnostics.snapshot(accountId: 1).apnsRegistration, .notAttempted)
        let report = PrivacyNotificationDiagnostics.ExtensionReport(stage: .redacted, accountId: 2, timestamp: 1000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["stage", "accountId", "timestamp"]))
    }

    func testNotificationDeletionAndReadMarksCannotCrossAccountOrNamespace() {
        let notification = PrivacyNotificationIdentity(accountId: 1, peerId: 7, namespace: 0, messageId: 8)
        XCTAssertFalse(notification.isCleared(by: .init(accountId: 2, peerId: 7, namespace: 0, messageId: 99), exact: false))
        XCTAssertFalse(notification.isCleared(by: .init(accountId: 1, peerId: 7, namespace: 2, messageId: 99), exact: false))
        XCTAssertTrue(notification.isCleared(by: .init(accountId: 1, peerId: 7, namespace: 0, messageId: 99), exact: false))
        XCTAssertFalse(notification.isCleared(by: .init(accountId: 1, peerId: 7, namespace: 0, messageId: 99), exact: true))
        XCTAssertTrue(notification.isCleared(by: notification, exact: true))
    }
}
