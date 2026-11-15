import Foundation
import XCTest
@testable import ExteralessCore

final class FilteringNotificationRemediationTests: XCTestCase {
    private let identity = PrivacyExtrasAccountIdentity(recordId: 1, userId: 2, testingEnvironment: false)

    private func message(_ text: String) -> FilteringMessage {
        FilteringMessage(account: identity, peerId: 3, senderId: 4, isMegagroup: true, isPrivateChat: false, isOutgoing: false, text: text)
    }

    func testBActualTinyBudgetExhaustionNeverApprovesANotification() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "reversed", regex: "safe$", reversed: true)]
        let policy = FilteringPolicy(account: identity, configuration: configuration)
        var budget = FilteringWorkBudget(operations: 1)
        let decision = policy.decision(message("not safe yet"), surface: .notification, budget: &budget)
        XCTAssertEqual(budget.remaining, 0)
        XCTAssertFalse(decision.isHidden)
        XCTAssertTrue(decision.incomplete)
        XCTAssertEqual(decision.notificationDisposition, .awaitMessage)
    }

    func testBInputLimitAndInvalidRuleKeepTheirThirdState() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "reversed", regex: "safe", reversed: true)]
        var budget = FilteringWorkBudget(operations: 50)
        let oversized = FilteringPolicy(account: identity, configuration: configuration).decision(message(String(repeating: "a", count: FilteringRegex.maximumInputScalars + 1)), surface: .notification, budget: &budget)
        XCTAssertEqual(oversized.notificationDisposition, .awaitMessage)
        configuration.sharedRules = [.init(id: "invalid", regex: "(?=unsafe)", reversed: true)]
        let invalid = FilteringPolicy(account: identity, configuration: configuration).decision(message("small"), surface: .notification, budget: &budget)
        XCTAssertEqual(invalid.notificationDisposition, .awaitMessage)
    }

    func testBKnownHidePrecedesIncompleteAndCompleteVisibleStillAllows() {
        var configuration = FilteringConfiguration()
        configuration.regexFiltersEnabled = true
        configuration.sharedRules = [.init(id: "invalid", regex: "(?=x)"), .init(id: "matching", regex: "spam")]
        var budget = FilteringWorkBudget(operations: 100)
        let hidden = FilteringPolicy(account: identity, configuration: configuration).decision(message("spam"), surface: .notification, budget: &budget)
        XCTAssertTrue(hidden.isHidden)
        XCTAssertTrue(hidden.incomplete)
        XCTAssertEqual(hidden.notificationDisposition, .suppress)
        configuration.sharedRules = [.init(id: "matching", regex: "spam")]
        let visible = FilteringPolicy(account: identity, configuration: configuration).decision(message("clean"), surface: .notification, budget: &budget)
        XCTAssertEqual(visible.notificationDisposition, .allow)
    }
}
