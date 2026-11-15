import Foundation
import XCTest
@testable import ExteralessCore

final class FilteringPolicyTests: XCTestCase {
    private let account = PrivacyExtrasAccountIdentity(recordId: 91, userId: 17, testingEnvironment: false)
    private let other = PrivacyExtrasAccountIdentity(recordId: 92, userId: 17, testingEnvironment: false)

    private func message(account: PrivacyExtrasAccountIdentity? = nil, peer: Int64 = 100, sender: Int64 = 8, reply: Int64? = nil, mega: Bool = true, privateChat: Bool = false, outgoing: Bool = false, text: String = "hello", oauth: Bool = false) -> FilteringMessage {
        FilteringMessage(account: account ?? self.account, peerId: peer, senderId: sender, replySenderId: reply, isMegagroup: mega, isPrivateChat: privateChat, isOutgoing: outgoing, text: text, isOAuthNotification: oauth)
    }
    private func decision(_ policy: FilteringPolicy, _ message: FilteringMessage, _ surface: FilteringSurface = .history, operations: Int = 200_000) -> FilteringDecision {
        var budget = FilteringWorkBudget(operations: operations)
        return policy.decision(message, surface: surface, budget: &budget)
    }

    func testOriginalDefaultsAndPrivateDefinitionBoundary() throws {
        let values = Dictionary(uniqueKeysWithValues: PrivacyExtrasFeatures.definitions.map { ($0.key, $0.defaultValue) })
        XCTAssertEqual(values["privacy.ignoreBlocked"], .bool(false))
        XCTAssertEqual(values["privacy.ignoreContentRestrictions"], .bool(true))
        XCTAssertEqual(values["privacy.regexFiltersEnabled"], .bool(false))
        XCTAssertEqual(values["privacy.regexFiltersEnableInChats"], .bool(false))
        XCTAssertTrue(PrivacyExtrasFeatures.privateDefinitions.allSatisfy(\.isSecret))
        XCTAssertTrue(Set(PrivacyExtrasFeatures.privateDefinitions.map(\.key)).isDisjoint(with: Set(values.keys)))
        let configuration = try FilteringConfiguration(account: account, values: values)
        XCTAssertEqual(configuration, FilteringConfiguration())
    }

    func testAccountRecordUserEnvironmentAndPeerNamespacesDoNotAlias() throws {
        let packedChannel: Int64 = 2 << 32 | 8
        let values: [String: ClientSettingValue] = ["privacy.customFilteredUsersData": .object([account.storageKey: .array([.string("8")])])]
        let configured = try FilteringConfiguration(account: account, values: values)
        let policy = FilteringPolicy(account: account, configuration: configured)
        XCTAssertTrue(decision(policy, message(sender: 8)).isHidden)
        XCTAssertFalse(decision(policy, message(sender: packedChannel)).isHidden)
        XCTAssertFalse(decision(policy, message(account: other)).isHidden)
        for identity in [other, .init(recordId: 91, userId: 18, testingEnvironment: false), .init(recordId: 91, userId: 17, testingEnvironment: true)] {
            XCTAssertTrue(try FilteringConfiguration(account: identity, values: values).customFilteredUsers.isEmpty)
        }
    }

    func testSenderAndReplyScopesMatchOriginalRatherThanServerBlocking() {
        var configuration = FilteringConfiguration()
        configuration.ignoreBlocked = true
        configuration.blockedChannels = [19]
        configuration.customFilteredUsers = [9]
        let policy = FilteringPolicy(account: account, configuration: configuration, blockedPeers: [8])
        XCTAssertEqual(decision(policy, message(sender: 8)).hiddenReason, .sender)
        XCTAssertEqual(decision(policy, message(sender: 10, reply: 9)).hiddenReason, .replySender)
        XCTAssertFalse(decision(policy, message(sender: 8, mega: false, privateChat: true)).isHidden)
        XCTAssertTrue(decision(policy, message(sender: 8, mega: false, privateChat: true), .notification).isHidden)
        XCTAssertFalse(decision(policy, message(sender: 10, reply: 9), .notification).isHidden)
        XCTAssertFalse(decision(policy, message(sender: 8), .automaticDownload).isHidden)
        configuration.ignoreBlocked = false
        let unblocked = FilteringPolicy(account: account, configuration: configuration, blockedPeers: [8])
        XCTAssertFalse(decision(unblocked, message(sender: 8)).isHidden)
        XCTAssertTrue(decision(unblocked, message(sender: 9)).isHidden)
        XCTAssertTrue(decision(unblocked, message(sender: 19)).isHidden)
    }

    func testRulePriorityPrivateChatExceptionOAuthAndOutgoing() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "shared", regex: "spam", caseInsensitive: true)]
        configuration.chatRules[100] = [.init(id: "private", regex: "local")]
        let policy = FilteringPolicy(account: account, configuration: configuration)
        XCTAssertTrue(decision(policy, message(text: "SPAM")).isHidden)
        XCTAssertFalse(decision(policy, message(mega: false, privateChat: true, text: "spam")).isHidden)
        XCTAssertTrue(decision(policy, message(mega: false, privateChat: true, text: "local")).isHidden)
        XCTAssertFalse(decision(policy, message(outgoing: true, text: "spam")).isHidden)
        XCTAssertFalse(decision(policy, message(text: "")).isHidden)
        XCTAssertFalse(decision(policy, message(text: "spam", oauth: true), .notification).isHidden)
        XCTAssertTrue(decision(policy, message(text: "spam"), .automaticDownload).isHidden)
        configuration.excludedDialogs.insert(100)
        let excluded = FilteringPolicy(account: account, configuration: configuration)
        XCTAssertFalse(decision(excluded, message(text: "local spam")).isHidden)
    }

    func testReversedDisabledAndIncompleteRulesNeverTurnUnknownIntoHide() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "allow", regex: "safe", reversed: true)]
        let policy = FilteringPolicy(account: account, configuration: configuration)
        XCTAssertTrue(decision(policy, message(text: "other")).isHidden)
        XCTAssertFalse(decision(policy, message(text: "safe")).isHidden)
        let limited = decision(policy, message(text: String(repeating: "x", count: FilteringRegex.maximumInputScalars + 1)))
        XCTAssertFalse(limited.isHidden); XCTAssertTrue(limited.incomplete)
        let exhausted = decision(policy, message(text: "other"), operations: 0)
        XCTAssertFalse(exhausted.isHidden); XCTAssertTrue(exhausted.incomplete)
        configuration.sharedRules[0].enabled = false
        XCTAssertFalse(decision(FilteringPolicy(account: account, configuration: configuration), message(text: "other")).isHidden)
        configuration.sharedRules = [.init(id: "invalid", regex: "(?=a)", reversed: true)]
        let invalid = FilteringPolicy(account: account, configuration: configuration)
        XCTAssertEqual(invalid.invalidRuleIds, ["invalid"])
        XCTAssertFalse(decision(invalid, message()).isHidden)
    }

    func testRegexMultilineFindClassesAlternativesAndUnicodeLiterals() throws {
        let cases: [(String, String, Bool)] = [
            ("^spam$", "safe\nspam\nother", true), ("^spam$", "spam text", false),
            ("^a$", "a\r\nb", true), ("^$", "a\r\nb", false),
            ("a(?:b|c){1,3}d", "xxaccdyy", true), ("a(?:b|c){1,3}d", "ad", false),
            (#"\bspam\b"#, "spammer", false), (#"\bspam\b"#, "a spam!", true),
            (#"\d+\s[^a-z]"#, "99 !", true), (#"\Aone\z"#, "one\n", false),
            ("привет|hello", "a привет b", true), ("a.*?b", "aXXb", true),
            ("", "anything", true), ("a?", "b", true)
        ]
        for (pattern, text, matches) in cases {
            var budget = FilteringWorkBudget()
            XCTAssertEqual(try FilteringRegex(pattern).find(in: text, budget: &budget), matches ? .matched : .notMatched, pattern)
        }
        var budget = FilteringWorkBudget()
        XCTAssertEqual(try FilteringRegex("SPAM", caseInsensitive: true).find(in: "spam", budget: &budget), .matched)
    }

    func testAdversarialNFAWorkAndCompilerBounds() throws {
        let expression = try FilteringRegex("(a|aa)+$")
        var budget = FilteringWorkBudget(operations: 2_000)
        XCTAssertEqual(expression.find(in: String(repeating: "a", count: 1_000) + "!", budget: &budget), .workLimit)
        XCTAssertEqual(budget.remaining, 0)
        for pattern in [#"(a)\1"#, "(?=a)", "(?<=a)", "a++", "(?i)a", "[a&&b]", "[z-a]", "a{500}"] {
            XCTAssertThrowsError(try FilteringRegex(pattern), pattern)
        }
        XCTAssertThrowsError(try FilteringRegex(String(repeating: "a", count: 257)))
        XCTAssertThrowsError(try FilteringRegex("(a{32}){32}"))
    }

    func testReactionsSubtractOnlyKnownPeersAndRetainOwnChoice() {
        var configuration = FilteringConfiguration(); configuration.customFilteredUsers = [8]
        let policy = FilteringPolicy(account: account, configuration: configuration)
        let counts = [FilteringReactionCount(value: "emoji:👍", count: 12, isChosen: false), .init(value: "custom:12", count: 1, isChosen: true)]
        let recent = [FilteringRecentReaction(value: "emoji:👍", peerId: 8, unread: true), .init(value: "emoji:👍", peerId: 8, unread: false), .init(value: "custom:12", peerId: 8, unread: false, isOwn: true)]
        let projected = policy.reactionProjection(counts, recent: recent, isMegagroup: true)
        XCTAssertEqual(projected.counts.map(\.count), [11, 1])
        XCTAssertFalse(projected.hasUnread)
        XCTAssertEqual(projected.recent.count, 1)
        XCTAssertEqual(policy.reactionProjection(counts, recent: recent, isMegagroup: false).counts, counts)
        XCTAssertEqual(policy.reactionProjection(counts, recent: [], isMegagroup: true).counts, counts)
    }

    func testUnreadProjectionDeduplicatesAndDoesNotInventMissingHistory() {
        XCTAssertEqual(FilteringUnreadProjection(totalUnread: 5, inspectedUnread: 5, hiddenUnreadIds: ["0:1", "0:2"], hasHoles: false, evaluationIncomplete: false).visibleCount, 3)
        XCTAssertNil(FilteringUnreadProjection(totalUnread: 5, inspectedUnread: 2, hiddenUnreadIds: ["0:1"], hasHoles: false, evaluationIncomplete: false).visibleCount)
        XCTAssertNil(FilteringUnreadProjection(totalUnread: 5, inspectedUnread: 5, hiddenUnreadIds: [], hasHoles: true, evaluationIncomplete: false).visibleCount)
        XCTAssertEqual(FilteringUnreadProjection(totalUnread: 5, inspectedUnread: 5, hiddenUnreadIds: [], hasHoles: false, evaluationIncomplete: false).visibleCount, 5)
    }

    func testZalgoThresholdLengthAndAttributedUTF16Preservation() {
        let marks = String(repeating: "\u{0301}", count: 4)
        let text = "😀A" + marks + "B\u{0308}C"
        XCTAssertEqual(FilteringTextPolicy.displayedText(text, enabled: true), "😀ABC")
        let attribute = NSAttributedString.Key("fixture.link")
        let source = NSMutableAttributedString(string: text)
        source.addAttribute(attribute, value: "https://example.invalid/", range: NSRange(location: 7, length: 3))
        let displayed = FilteringTextPolicy.displayedText(source, enabled: true)
        XCTAssertEqual(displayed.string, "😀ABC")
        XCTAssertEqual(displayed.attribute(attribute, at: 3, effectiveRange: nil) as? String, "https://example.invalid/")
        XCTAssertEqual(source.string, text)
        XCTAssertEqual(FilteringTextPolicy.displayedText("A\u{0301}\u{0301}\u{0301}", enabled: true), "A\u{0301}\u{0301}\u{0301}")
        XCTAssertEqual(FilteringTextPolicy.displayedText(text, enabled: false), text)
        let oversized = String(repeating: "a", count: 2_045) + marks
        XCTAssertEqual(FilteringTextPolicy.displayedText(oversized, enabled: true), oversized)
    }
}
