import Foundation
import XCTest
@testable import ExteralessCore

final class ChatPolicyTests: XCTestCase {
    func testMathPrecedenceRightAssociativityAndPercent() throws {
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("2+3*4")).value, 14)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("2^3^2")).value, 512)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("-2^2")).value, -4)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("200+10%")).value, 220)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("200-10%")).value, 180)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("200*10%")).value, 20)
        // Parentheses end the special additive percentage operand, as in the Android parser.
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("200+(10%)")).value, 200.1, accuracy: 0.00001)
    }

    func testMathFunctionsAndDecimalComma() throws {
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("max(2;min(8;3))+fact(3)")).value, 9)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("log2(32)+sqrt(9)")).value, 8)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("sin(pi/2)")).value, 1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("1,5+2,5")).decimalSeparator, ",")
        XCTAssertEqual(ChatMathExpression.format(1.25, decimalSeparator: ","), "1,25")
        XCTAssertEqual(ChatMathExpression.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(try XCTUnwrap(ChatMathExpression.evaluate("round(-1.5)")).value, -1)
        XCTAssertNil(ChatMathExpression.evaluate("1,234+1"))
    }

    func testMathSuggestionUsesUTF16AndKeepsSurroundingDraft() throws {
        let draft = "😀 Total: 2 + 2 ="
        let suggestion = try XCTUnwrap(ChatMathExpression.suggestion(in: draft, caret: (draft as NSString).length))
        XCTAssertEqual(suggestion.value, "4")
        XCTAssertEqual(suggestion.insertionText, " 4")
        let updated = NSMutableString(string: draft)
        updated.insert(suggestion.insertionText, at: suggestion.insertionOffset)
        XCTAssertEqual(updated as String, "😀 Total: 2 + 2 = 4")
        XCTAssertNil(ChatMathExpression.suggestion(in: "2+2=4", caret: 4))
        XCTAssertNil(ChatMathExpression.suggestion(in: "cost=", caret: 5))
        XCTAssertNil(ChatMathExpression.suggestion(in: "привет2+2=", caret: 10))
        XCTAssertNil(ChatMathExpression.suggestion(in: "5=", caret: 2))
    }

    func testMathRejectsDatesInvalidNumbersAndBoundedAdversarialInputs() {
        for expression in ["2026-11-14=", "14/11/2026=", "1/0=", "sqrt(-1)=", "171!=", "log1(2)=", "1e200=", "sin()="] {
            XCTAssertNil(ChatMathExpression.suggestion(in: expression, caret: expression.utf16.count), expression)
        }
        XCTAssertNil(ChatMathExpression.evaluate(String(repeating: "(", count: 33) + "1+1" + String(repeating: ")", count: 33)))
        XCTAssertNil(ChatMathExpression.evaluate(String(repeating: "1+", count: 150) + "1"))
        XCTAssertNil(ChatMathExpression.format(.nan))
        XCTAssertNil(ChatMathExpression.format(.infinity))
        XCTAssertNil(ChatMathExpression.format(1e12))
        XCTAssertNil(ChatMathExpression.format(1e-10))
    }

    func testFormattingOrderHidingAndNativeAdditions() {
        let available = ["quote", "bold", "italic", "table", "code"]
        XCTAssertEqual(ChatFormattingPolicy.ordered(available, order: "code,bold,bold,unknown", hidden: ["italic"]), ["code", "bold", "quote", "table"])
        XCTAssertEqual(ChatFormattingPolicy.ordered(available, order: "", hidden: []), available)
        XCTAssertEqual(ChatFormattingPolicy.ordered(available, order: "", hidden: Set(available)), [])
    }

    func testCurrencyQueryRecognizesOriginalCodesAliasesAndSymbolsWithoutSendingProse() {
        for query in ["25 usd in eur", "100 рублей в долларах", "2 біткоїни в гривнях", "★100", "$25", "5 kč"] {
            let text = "Cost: " + query + "="
            XCTAssertEqual(ChatCurrencyQuery.query(in: text, caret: text.utf16.count), query)
        }
        XCTAssertNil(ChatCurrencyQuery.query(in: "Meet at 4=", caret: 10))
        XCTAssertNil(ChatCurrencyQuery.query(in: "usd=", caret: 4))
        XCTAssertNil(ChatCurrencyQuery.query(in: "25 usd=20", caret: 7))
        XCTAssertNil(ChatCurrencyQuery.query(in: "x25usd=", caret: 7))
        XCTAssertEqual(ChatCurrencyQuery.result(title: "= 23.45 EUR"), "23.45 EUR")
        XCTAssertNil(ChatCurrencyQuery.result(title: "Open the bot"))
        XCTAssertNil(ChatCurrencyQuery.result(title: "= first\nsecond"))
    }

    func testCurrencyRequestCoalescingAndCancellationRejectsLateAccountResults() throws {
        var state = ChatCurrencyRequestState()
        let first = try XCTUnwrap(state.begin(query: "25 usd"))
        XCTAssertNil(state.begin(query: "25 usd"))
        let second = try XCTUnwrap(state.begin(query: "25 eur"))
        XCTAssertFalse(state.complete(query: "25 usd", generation: first))
        XCTAssertTrue(state.complete(query: "25 eur", generation: second))
        XCTAssertFalse(state.complete(query: "25 eur", generation: second))
        let oldAccount = try XCTUnwrap(state.begin(query: "25 usd"))
        state.cancel()
        let newAccount = try XCTUnwrap(state.begin(query: "25 usd"))
        XCTAssertFalse(state.complete(query: "25 usd", generation: oldAccount))
        XCTAssertTrue(state.complete(query: "25 usd", generation: newAccount))
    }

    func testWholeURLTrackingRemovalPreservesEncodingOrderAndFragment() {
        let url = "https://example.org/a%2Fb?q=a+b&UtM_source=x&x=%26%2F&fbclid=123#part%2Ftwo"
        XCTAssertEqual(ChatLinkPolicy.removingTracking(from: url), "https://example.org/a%2Fb?q=a+b&x=%26%2F#part%2Ftwo")
        XCTAssertEqual(ChatLinkPolicy.removingTracking(from: "https://example.org/?utm_source=x#f"), "https://example.org/#f")
        let normal = "https://example.org/?ref=invoice&id=002&search=a%20b"
        XCTAssertEqual(ChatLinkPolicy.removingTracking(from: normal), normal)
    }

    func testSignedLinksNonHTTPAndProseRemainByteIdentical() {
        for text in [
            "https://cdn.example/file?utm_source=x&X-Amz-Signature=abc",
            "https://example.org/?token=secret&utm_campaign=a",
            "tg://resolve?domain=example&utm_source=x",
            "Read https://example.org/?utm_source=x",
            "https://user:pass@example.org/?utm_source=x",
            "https://example.org/#?utm_source=x"
        ] {
            XCTAssertEqual(ChatLinkPolicy.removingTracking(from: text), text)
        }
    }

    func testPlayerRateCycleAndSeekBounds() {
        var speed = 1.0
        var observed: [Double] = []
        for _ in 0 ..< 6 { speed = ChatPlaybackPolicy.nextSpeed(after: speed); observed.append(speed) }
        XCTAssertEqual(observed, [1.2, 1.5, 1.7, 2.0, 0.5, 1.0])
        XCTAssertEqual(ChatPlaybackPolicy.nextSpeed(after: .nan), 1)
        XCTAssertEqual(ChatPlaybackPolicy.seekPosition(timestamp: 3, delta: -10, duration: 100), 0)
        XCTAssertEqual(ChatPlaybackPolicy.seekPosition(timestamp: 95, delta: 30, duration: 100), 100)
        XCTAssertNil(ChatPlaybackPolicy.seekPosition(timestamp: .infinity, delta: 10, duration: 100))
        XCTAssertEqual(ChatPlaybackPolicy.seekDuration(index: -1), 10)
        XCTAssertEqual(ChatPlaybackPolicy.seekDuration(index: 3), 30)
        XCTAssertEqual(ChatPlaybackPolicy.musicSpeed(.nan), 1)
        XCTAssertEqual(ChatPlaybackPolicy.storedSpeed(1.7), 1.7)
        XCTAssertEqual(ChatPlaybackPolicy.storedSpeed(.infinity), 1)
    }

    func testScrubLeaseDoesNotSeekAnAutomaticallyAdvancedTrack() {
        var lease = ChatPlaybackSeekLease<String>()
        lease.begin(identity: "account1.track1")
        XCTAssertNil(lease.finish(identity: "account1.track2", fraction: 0.9, duration: 100))
        lease.begin(identity: "account1.track2")
        XCTAssertEqual(lease.finish(identity: "account1.track2", fraction: 0.9, duration: 100), 90)
        XCTAssertNil(lease.finish(identity: "account1.track2", fraction: 0.2, duration: 100))
        lease.begin(identity: "account1.track2")
        lease.cancel()
        XCTAssertNil(lease.finish(identity: "account1.track2", fraction: 0.2, duration: 100))
    }

    func testPillOrderHidingWrapAndUnavailablePluginIdentity() {
        let active = ChatPillPolicy.ids("5,88,6,5,garbage")
        XCTAssertEqual(active, [5, 88, 6])
        let visible = ChatPillPolicy.visibleIds(active: active, hidden: [], available: [5, 6])
        XCTAssertEqual(visible, [5, 6])
        XCTAssertEqual(ChatPillPolicy.nextId(current: 6, ids: visible, forward: true, loop: true), 5)
        XCTAssertEqual(ChatPillPolicy.nextId(current: 6, ids: visible, forward: true, loop: false), 6)
        XCTAssertEqual(ChatPillPolicy.nextId(current: 88, ids: visible, forward: true, loop: true), 5)
        XCTAssertNil(ChatPillPolicy.nextId(current: 5, ids: [], forward: false, loop: true))
        XCTAssertEqual(ChatPillPolicy.visibleIds(active: active, hidden: [5], available: [5, 6]), [6])
        // Unavailable 88 is still in persisted ordering, so a later registration restores its slot.
        XCTAssertEqual(ChatPillPolicy.visibleIds(active: active, hidden: [], available: [5, 6, 88]), [5, 88, 6])
    }

    func testFeedMembershipSnapshotsNewChannelPolicyAndArchive() {
        var config = ChatFeedConfiguration()
        XCTAssertTrue(config.includes(100, archived: false))
        XCTAssertFalse(config.includes(100, archived: true))
        config.setAddNewChannels(false, currentChannels: [100, 200])
        XCTAssertFalse(config.includes(300, archived: false))
        config.setIncluded(300, included: true)
        XCTAssertTrue(config.includes(300, archived: false))
        config.setIncluded(100, included: false)
        config.setAddNewChannels(true, currentChannels: [])
        XCTAssertFalse(config.includes(100, archived: false))
        XCTAssertTrue(config.includes(400, archived: false))
        config.includeArchived = true
        config.includeAll([100])
        XCTAssertTrue(config.includes(100, archived: true))
    }

    func testFeedMergesEditsAndPeerScopedAlbumsWithoutIDCollisions() {
        func entry(_ peer: Int64, _ id: Int32, _ time: Int32, _ group: Int64? = nil, version: UInt32 = 0) -> ChatFeedEntry {
            ChatFeedEntry(position: ChatFeedPosition(timestamp: time, identity: ChatFeedIdentity(peerId: peer, namespace: 0, messageId: id)), groupId: group, version: version)
        }
        let a = entry(1, 1, 100, 8)
        let b = entry(1, 2, 98, 8)
        let otherPeer = entry(2, 1, 99, 8)
        let edited = entry(1, 1, 100, 8, version: 3)
        let forbidden = entry(99, 1, 200)
        let result = ChatFeedPolicy.ordered([a, otherPeer, b, edited, a, forbidden], allowedPeers: [1, 2])
        XCTAssertEqual(result.map(\.identity), [a.identity, b.identity, otherPeer.identity])
        XCTAssertEqual(result[0].version, 3)
        XCTAssertEqual(ChatFeedPolicy.ordered(result, allowedPeers: [2]).map(\.identity), [otherPeer.identity])
        XCTAssertEqual(ChatFeedPolicy.ordered(result, allowedPeers: [1, 2], limit: 1).map(\.identity), [a.identity, b.identity])
    }

    func testFeedTieOrderAndBoundedPage() {
        let entries = (0 ..< 1200).map { value in
            ChatFeedEntry(position: ChatFeedPosition(timestamp: 100, identity: ChatFeedIdentity(peerId: Int64(value % 3), namespace: 0, messageId: Int32(value))))
        }
        let result = ChatFeedPolicy.ordered(entries, allowedPeers: [0, 1, 2], limit: 500)
        XCTAssertEqual(result.count, 500)
        XCTAssertEqual(result.first?.identity.peerId, 2)
        XCTAssertEqual(result.first?.identity.messageId, 1199)
        XCTAssertEqual(Set(result.map(\.identity)).count, 500)
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { pair in pair.0.position > pair.1.position })
    }

    func testFeedWindowBoundaryCannotSkipInterleavedPostsOrRepeatAlbumTail() {
        func entry(_ peer: Int64, _ id: Int32, _ time: Int32, _ group: Int64? = nil) -> ChatFeedEntry {
            ChatFeedEntry(position: ChatFeedPosition(timestamp: time, identity: ChatFeedIdentity(peerId: peer, namespace: 0, messageId: id)), groupId: group)
        }
        let albumHead = entry(1, 2, 100, 8)
        let interleaved = entry(2, 1, 99)
        let albumTail = entry(1, 1, 98, 8)
        let entries = [albumHead, interleaved, albumTail]
        let first = ChatFeedPolicy.ordered(entries, allowedPeers: [1, 2], limit: 2)
        XCTAssertEqual(first.map(\.identity), [albumHead.identity, albumTail.identity])
        XCTAssertEqual(ChatFeedPolicy.ordered(entries, allowedPeers: [1, 2], limit: 1).map(\.identity), [albumHead.identity, albumTail.identity])
        let remaining = ChatFeedPolicy.remaining(after: first, in: entries)
        XCTAssertEqual(remaining.map(\.identity), [interleaved.identity])
        let second = ChatFeedPolicy.ordered(remaining, allowedPeers: [1, 2], limit: 2)
        XCTAssertEqual(first.count + second.count, 3)
        XCTAssertEqual(Set((first + second).map(\.identity)).count, 3)
    }

    func testFeedDoesNotExposeHolesAsCompleteHistory() {
        func position(_ timestamp: Int32) -> ChatFeedPosition {
            ChatFeedPosition(timestamp: timestamp, identity: ChatFeedIdentity(peerId: 1, namespace: 0, messageId: timestamp))
        }
        let incomplete = ChatFeedPolicy.safeLowerBound([.init(oldestLoaded: position(90), isComplete: false), .init(oldestLoaded: nil, isComplete: false)])
        XCTAssertFalse(incomplete.ready)
        let safe = ChatFeedPolicy.safeLowerBound([.init(oldestLoaded: position(90), isComplete: false), .init(oldestLoaded: position(30), isComplete: false), .init(oldestLoaded: nil, isComplete: true)])
        XCTAssertTrue(safe.ready)
        XCTAssertEqual(safe.position, position(90))
        let finished = ChatFeedPolicy.safeLowerBound([.init(oldestLoaded: position(1), isComplete: true)])
        XCTAssertTrue(finished.ready)
        XCTAssertNil(finished.position)
    }

    func testFeedRoundRejectsLateAndDuplicateCompletionAfterCancel() {
        var round = ChatFeedLoadRound()
        let first = round.begin(channels: [1, 1, 2, 3, 4, 5], now: 0)
        XCTAssertEqual(first.map(\.channel), [1, 2, 3, 4])
        XCTAssertTrue(round.complete(first[1]))
        XCTAssertFalse(round.complete(first[1]))
        round.cancel()
        let next = round.begin(channels: [1, 2], now: 1)
        XCTAssertFalse(round.complete(first[0]))
        XCTAssertEqual(round.pending, [1, 2])
        XCTAssertTrue(round.complete(next[1]))
        XCTAssertTrue(round.complete(next[0]))
        XCTAssertNil(round.deadline)
    }

    func testFeedTimeoutIsRetryableAndEmptyRoundDoesNotHang() {
        var round = ChatFeedLoadRound()
        let first = round.begin(channels: [1, 2], now: 100)
        XCTAssertTrue(round.complete(first[0]))
        XCTAssertTrue(round.expire(now: 109.9).isEmpty)
        XCTAssertEqual(round.expire(now: 110), [2])
        XCTAssertFalse(round.complete(first[1]))
        let retry = round.begin(channels: [2], now: 111)
        XCTAssertTrue(round.complete(retry[0]))
        XCTAssertTrue(round.begin(channels: [], now: 112).isEmpty)
        XCTAssertNil(round.deadline)
    }

    func testFeedRefreshCoalescesWithoutStarvationAndCancels() {
        var gate = ChatFeedRefreshGate()
        gate.request(now: 5)
        for index in 1 ... 4 { gate.request(now: 5 + Double(index) / 10) }
        XCTAssertFalse(gate.consume(now: 5.49))
        XCTAssertTrue(gate.consume(now: 5.5))
        XCTAssertFalse(gate.consume(now: 6))
        gate.request(now: 7)
        gate.cancel()
        XCTAssertFalse(gate.consume(now: 8))
    }
}
