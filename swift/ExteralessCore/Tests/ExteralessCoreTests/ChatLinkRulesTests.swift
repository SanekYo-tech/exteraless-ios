import Foundation
import XCTest
@testable import ExteralessCore

final class ChatLinkRulesTests: XCTestCase {
    func testDomainRulesExceptionsAndRawURLRebuild() throws {
        let rules = try ChatAdGuardRules(source: """
        ||example.com^$removeparam=track
        ||example.com^$removeparam=campaign
        @@||example.com/signed^$removeparam
        @@||example.com/article^$removeparam=campaign
        """)
        XCTAssertEqual(rules.clean("https://sub.example.com/article?track=x&campaign=y&x=%2f+a#F"), "https://sub.example.com/article?campaign=y&x=%2f+a#F")
        XCTAssertEqual(rules.clean("https://example.com/signed?track=x"), "https://example.com/signed?track=x")
        XCTAssertEqual(rules.clean("https://notexample.com/?track=x"), "https://notexample.com/?track=x")
    }

    func testRegexModifierCommasDollarsAndCase() throws {
        let rules = try ChatAdGuardRules(source: """
        $removeparam=/^utm_/i
        $removeparam=/^ref=(one,two|three)$/
        """)
        XCTAssertEqual(rules.clean("https://example.com/?UtM_source=x&ref=one,two&q=keep"), "https://example.com/?q=keep")
        XCTAssertEqual(rules.clean("https://example.com/?ref=other"), "https://example.com/?ref=other")
    }

    func testInvertedRemovalAndDomainExclusions() throws {
        let rules = try ChatAdGuardRules(source: """
        ||example.com^$removeparam=~keep
        $removeparam=track,domain=example.org|~safe.example.org,denyallow=trusted.example.org
        """)
        XCTAssertEqual(rules.clean("https://example.com/?a=1&keep=a%26b&other=2"), "https://example.com/?keep=a%26b")
        XCTAssertEqual(rules.clean("https://sub.example.org/?track=1&x=2"), "https://sub.example.org/?x=2")
        XCTAssertEqual(rules.clean("https://safe.example.org/?track=1"), "https://safe.example.org/?track=1")
        XCTAssertEqual(rules.clean("https://trusted.example.org/?track=1"), "https://trusted.example.org/?track=1")
    }

    func testOnlyDocumentRemoveparamRulesCanChangeNavigation() throws {
        let rules = try ChatAdGuardRules(source: """
        ||example.com^$removeparam=x,script
        ||example.com^$removeparam=y,header=Server
        ||example.com^$removeparam=z,document
        example.com##script:inject(x)
        """)
        XCTAssertEqual(rules.ruleCount, 1)
        XCTAssertEqual(rules.ignoredRuleCount, 2)
        XCTAssertEqual(rules.clean("https://example.com/?x=1&y=2&z=3"), "https://example.com/?x=1&y=2")
    }

    func testWildcardHostFullRegexAndEmptyDelimiter() throws {
        let wildcard = try ChatAdGuardRules(source: "||example.*^$removeparam=track")
        XCTAssertEqual(wildcard.clean("https://sub.example.org/?track=1&a=2"), "https://sub.example.org/?a=2")
        let regex = try ChatAdGuardRules(source: #"/^https:\/\/example\.org\/article\?/$removeparam"#)
        XCTAssertEqual(regex.clean("https://example.org/article?"), "https://example.org/article")
        let literal = try ChatAdGuardRules(source: "$removeparam=track")
        XCTAssertEqual(literal.clean("https://example.org/?"), "https://example.org/?")
    }

    func testSignedURLsAndEvaluationLimitsReturnOriginal() throws {
        let rules = try ChatAdGuardRules(source: "$removeparam")
        let signed = "https://example.org/?track=1&x-amz-signature=abc"
        XCTAssertEqual(rules.clean(signed), signed)
        let login = "https://user:password@example.org/?track=1"
        XCTAssertEqual(rules.clean(login), login)
        let url = "https://example.org/?track=1"
        XCTAssertEqual(rules.clean(url, maximumEvaluationTime: 0), url)
        let long = "https://example.org/?x=" + String(repeating: "a", count: 8192)
        XCTAssertEqual(rules.clean(long), long)
    }

    func testReverseUTF16EditsKeepTextBetweenMultipleURLs() throws {
        let first = "https://a.test/?utm_source=x&keep=1"
        let second = "https://b.test/?fbclid=y#part"
        let text = "😀 \(first) — bold text — \(second) ✅"
        let source = text as NSString
        let ranges = [first, second].map { value -> Range<Int> in
            let range = source.range(of: value)
            return range.location ..< (range.location + range.length)
        }
        let result = NSMutableString(string: text)
        let edits = ChatLinkPolicy.replacements(in: text, urlRanges: ranges)
        XCTAssertEqual(edits.count, 2)
        XCTAssertGreaterThan(edits[0].range.lowerBound, edits[1].range.lowerBound)
        for edit in edits { result.replaceCharacters(in: NSRange(location: edit.range.lowerBound, length: edit.range.count), with: edit.text) }
        XCTAssertEqual(result as String, "😀 https://a.test/?keep=1 — bold text — https://b.test/#part ✅")
        XCTAssertTrue(ChatLinkPolicy.replacements(in: "😀", urlRanges: [0 ..< 1]).isEmpty)
    }

    func testBadFilterAndCancelledCommitPreserveActiveFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-links-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("adguard_url_tracking.txt")
        let store = ChatTrackingRulesStore()
        let original = "! TimeUpdated: 2026-11-13T11:08:24+00:00\n$removeparam=track"
        try store.install(source: original, overrideURL: url)
        XCTAssertEqual(store.clean("https://example.org/?track=1&q=2"), "https://example.org/?q=2")
        XCTAssertThrowsError(try store.install(source: "<html>not a filter</html>", overrideURL: url))
        XCTAssertThrowsError(try store.install(source: "! TimeUpdated: 2026-11-14\n$removeparam=q", overrideURL: url, shouldCommit: { false }))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertEqual(store.clean("https://example.org/?track=1&q=2"), "https://example.org/?q=2")
        let reloaded = ChatTrackingRulesStore()
        try reloaded.configure(overrideURL: url, bundledURL: nil)
        XCTAssertEqual(reloaded.clean("https://example.org/?track=1"), "https://example.org/")
        try store.reset(overrideURL: url, bundledURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.clean("https://example.org/?track=1"), "https://example.org/?track=1")
        XCTAssertEqual(store.clean("https://example.org/?utm_source=1"), "https://example.org/")
    }

    func testConfirmationControlsRetainMandatoryChecksAndConsumeOneTicket() {
        XCTAssertTrue(ChatLinkConfirmationPolicy.shouldConfirm(concealed: true, mandatory: false, callerSkipped: false, confirmAll: false, skipBasic: false))
        XCTAssertFalse(ChatLinkConfirmationPolicy.shouldConfirm(concealed: true, mandatory: false, callerSkipped: false, confirmAll: false, skipBasic: true))
        XCTAssertTrue(ChatLinkConfirmationPolicy.shouldConfirm(concealed: false, mandatory: true, callerSkipped: false, confirmAll: false, skipBasic: true))
        XCTAssertTrue(ChatLinkConfirmationPolicy.shouldConfirm(concealed: false, mandatory: false, callerSkipped: false, confirmAll: true, skipBasic: true))
        XCTAssertFalse(ChatLinkConfirmationPolicy.shouldConfirm(concealed: true, mandatory: false, callerSkipped: true, confirmAll: true, skipBasic: false))
        let ledger = ChatLinkConfirmationLedger()
        ledger.note("https://example.org/", now: 0)
        XCTAssertFalse(ledger.consume("https://different.org/", now: 1))
        XCTAssertTrue(ledger.consume("https://example.org/", now: 1))
        XCTAssertFalse(ledger.consume("https://example.org/", now: 1))
        ledger.note("https://example.org/", now: 2)
        XCTAssertFalse(ledger.consume("https://example.org/", now: 17))
        ledger.note("https://example.org/", now: 20)
        ledger.clear()
        XCTAssertFalse(ledger.consume("https://example.org/", now: 21))
    }

    func testResetDoesNotRecursivelyRemoveADirectoryAtTheFilterPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-links-directory-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filter = directory.appendingPathComponent("adguard_url_tracking.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: filter, withIntermediateDirectories: true)
        let sentinel = filter.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try ChatTrackingRulesStore().reset(overrideURL: filter, bundledURL: nil))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }
}
