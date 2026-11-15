import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import XCTest
@testable import TelegramUI

@MainActor
final class FeedNativeOrchestrationTests: XCTestCase {
    func testRegistryTraverses1250ChannelsAndEmptyFilteredPagesWithoutAnAccount() {
        let complete = self.expectation(description: "both native groups enumerated")
        let channels = (1 ... 1250).map { FeedNativeFixtures.channel(Int64($0)) }
        var requests: [(EngineChatList.Group, EngineChatList.Item.Index?)] = []
        var nextPage = 0
        let registry = ExteralessFeedChannelRegistry(pageSource: { group, cursor in
            requests.append((group, cursor))
            if group == .archive { return .single(.init(channels: [], oldest: nil, hasEarlier: false, hasGap: false)) }
            let page = nextPage
            nextPage += 1
            if page == 0 {
                // A first page containing only non-channel chats must still advance.
                return .single(.init(channels: [], oldest: FeedNativeFixtures.cursor(100), hasEarlier: true, hasGap: false))
            }
            let lower = (page - 1) * 100
            let upper = min(lower + 100, channels.count)
            return .single(.init(channels: Array(channels[lower ..< upper]), oldest: FeedNativeFixtures.cursor(upper + 100), hasEarlier: upper < channels.count, hasGap: false))
        }, changes: .never())
        registry.updated = { state in if state.isComplete { complete.fulfill() } }
        registry.start()
        self.wait(for: [complete], timeout: 3)
        registry.stop()
        XCTAssertEqual(registry.state.channels.count, 1250)
        XCTAssertEqual(Set(registry.state.channels.map(\.id)).count, 1250)
        XCTAssertEqual(requests.count, 15)
        if requests.count >= 2 {
            XCTAssertNil(requests[0].1)
            XCTAssertEqual(requests[1].1, FeedNativeFixtures.cursor(100))
        }
        XCTAssertEqual(requests.last?.0, .archive)
        XCTAssertFalse(registry.state.needsRetry)
    }

    func testRegistryGapTimesOutPartialThenRetriesFromARealCursor() {
        let partial = self.expectation(description: "gap is not an end")
        let complete = self.expectation(description: "retry completes")
        let first = FeedNativeFixtures.channel(1)
        var failing = true
        let registry = ExteralessFeedChannelRegistry(pageSource: { group, _ in
            if group == .archive { return .single(.init(channels: [], oldest: nil, hasEarlier: false, hasGap: false)) }
            return .single(.init(channels: [first], oldest: FeedNativeFixtures.cursor(100), hasEarlier: failing, hasGap: failing))
        }, changes: .never(), requestTimeout: 0.01)
        registry.updated = { state in if state.needsRetry { partial.fulfill() } }
        registry.start()
        self.wait(for: [partial], timeout: 1)
        XCTAssertFalse(registry.state.isComplete)
        XCTAssertEqual(registry.state.channels.map(\.id), [first.id])
        failing = false
        registry.updated = { state in if state.isComplete { complete.fulfill() } }
        registry.refresh()
        self.wait(for: [complete], timeout: 1)
        registry.stop()
    }

    func testTimelineNativeMessageEditsDeletesAndPeerScopedGroupsAreIncremental() {
        let a = FeedNativeFixtures.channel(1)
        let b = FeedNativeFixtures.channel(2)
        let a1 = FeedNativeFixtures.message(channel: a, id: 10, timestamp: 100, group: 50)
        let a2 = FeedNativeFixtures.message(channel: a, id: 11, timestamp: 101, group: 50)
        let b1 = FeedNativeFixtures.message(channel: b, id: 10, timestamp: 100, group: 50)
        let originals = [a1, a2, b1]
        let window = Promise(Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) }))
        let loaded = self.expectation(description: "full native window")
        let timeline = ExteralessFeedTimeline(pageSource: { peer, _ in
            let messages = originals.filter { $0.id.peerId == peer }
            return .single(.init(messages: messages, oldest: messages.map(\.index).min(), hasEarlier: false))
        }, projectionSource: { ids in window.get() |> map { values in values.filter { ids.contains($0.key) }.mapValues { FeedNativeFixtures.projection($0) } } })
        timeline.updated = {
            if timeline.visible.count == 3 && timeline.posts.count == 2 && timeline.pendingCount == 0 { timeline.updated = nil; loaded.fulfill() }
        }
        timeline.configure(channels: [a, b], configuration: ChatFeedConfiguration())
        timeline.start()
        self.wait(for: [loaded], timeout: 2)
        XCTAssertEqual(timeline.posts.count, 2)
        XCTAssertNotEqual(timeline.posts.first?.id, timeline.posts.last?.id)
        let edited = self.expectation(description: "edit and delete observed")
        timeline.updated = {
            if timeline.visible.count == 2 && timeline.messages[ExteralessFeedTimeline.identity(a1.id)]?.text == "Edited" { timeline.updated = nil; edited.fulfill() }
        }
        let changed = FeedNativeFixtures.message(channel: a, id: 10, timestamp: 100, version: 1, text: "Edited", group: 50)
        window.set(.single([changed.id: changed, b1.id: b1]))
        self.wait(for: [edited], timeout: 2)
        XCTAssertNil(timeline.messages[ExteralessFeedTimeline.identity(a2.id)])
        XCTAssertEqual(timeline.posts.count, 2)
        timeline.updated = nil
        timeline.stop()
    }

    func testCancelledMissingSourceCannotPublishAnOldPageOrFalseEnd() {
        let a = FeedNativeFixtures.channel(1)
        let b = FeedNativeFixtures.channel(2)
        let first = FeedNativeFixtures.message(channel: a, id: 1, timestamp: 10)
        let delayed = ValuePipe<ExteralessFeedHistoryPage>()
        let waiting = self.expectation(description: "waiting for missing source")
        let timeline = ExteralessFeedTimeline(pageSource: { peer, _ in
            if peer == a.peer.id { return .single(.init(messages: [first], oldest: first.index, hasEarlier: false)) }
            return delayed.signal()
        }, projectionSource: { _ in .never() })
        timeline.updated = {
            if timeline.loadedChannelCount == 1 && timeline.pendingCount == 1 { timeline.updated = nil; waiting.fulfill() }
        }
        timeline.configure(channels: [a, b], configuration: ChatFeedConfiguration())
        timeline.start()
        self.wait(for: [waiting], timeout: 2)
        XCTAssertTrue(timeline.visible.isEmpty)
        XCTAssertFalse(timeline.reachedEnd)
        timeline.updated = nil
        timeline.stop()
        let late = FeedNativeFixtures.message(channel: b, id: 1, timestamp: 20)
        delayed.putNext(.init(messages: [late], oldest: late.index, hasEarlier: false))
        XCTAssertNil(timeline.messages[ExteralessFeedTimeline.identity(late.id)])
        XCTAssertFalse(timeline.reachedEnd)
        XCTAssertEqual(timeline.pendingCount, 0)
    }
}
