import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import XCTest
@testable import TelegramUI

private final class FeedMetadataFixtureLease: ExteralessFeedMetadataLease {
    private let disposable = MetaDisposable()
    private var ids = Set<EngineMessage.Id>()
    private(set) var updates = 0
    private(set) var disposals = 0
    init(events: ValuePipe<EngineMessage>, received: @escaping (EngineMessage) -> Void) {
        self.disposable.set(events.signal().start(next: { [weak self] message in
            guard let self, self.disposals == 0, self.ids.contains(message.id) else { return }
            received(message)
        }))
    }
    func update(messages: [EngineMessage]) { self.ids = Set(messages.map(\.id)); self.updates += 1 }
    func dispose() { guard self.disposals == 0 else { return }; self.disposals += 1; self.disposable.dispose() }
}

@MainActor
final class FeedRemediationNativeTests: XCTestCase {
    func testFPP02PeerFlagsWithoutMessageEditChangeRenderKeyAndExportPermission() {
        let open = FeedNativeFixtures.channel(1)
        let protected = FeedNativeFixtures.channel(1, protected: true)
        let message = EngineMessage(FeedNativeFixtures.message(channel: open, id: 7, timestamp: 100)._asMessage().withUpdatedAuthor(nil))
        let before = FeedNativeFixtures.projection(message, peer: open.peer)
        let after = FeedNativeFixtures.projection(message, peer: protected.peer)
        let reverse = FeedNativeFixtures.projection(message, peer: open.peer)
        XCTAssertEqual(before.message, after.message, "EngineMessage shallow equality deliberately cannot be the render key")
        XCTAssertEqual(before.message.stableVersion, after.message.stableVersion)
        XCTAssertNotEqual(before.renderToken, after.renderToken)
        XCTAssertFalse(before.isCopyProtected)
        XCTAssertTrue(after.isCopyProtected)
        XCTAssertFalse(after.allowsExport(contentSettings: .default))
        XCTAssertTrue(after.allowsMedia(contentSettings: .default), "Gallery may view, but must receive protected policy")
        XCTAssertTrue(reverse.allowsExport(contentSettings: .default))
        let replies = FeedNativeFixtures.message(channel: open, id: 8, timestamp: 99, text: "Reply edited", group: nil)
        let root = message._asMessage()
        let refreshed = EngineMessage(stableId: root.stableId, stableVersion: root.stableVersion, id: root.id, globallyUniqueId: root.globallyUniqueId, groupingKey: root.groupingKey, groupInfo: root.groupInfo, threadId: root.threadId, timestamp: root.timestamp, flags: root.flags, tags: root.tags, globalTags: root.globalTags, localTags: root.localTags, customTags: root.customTags, forwardInfo: root.forwardInfo, author: nil, text: root.text, attributes: root.attributes, media: message.engineMedia, peers: message.enginePeers, associatedMessages: [replies.id: replies], associatedMessageIds: [replies.id], associatedMedia: root.associatedMedia, associatedThreadInfo: root.associatedThreadInfo, associatedStories: root.associatedStories)
        let replyProjection = FeedNativeFixtures.projection(refreshed)
        XCTAssertEqual(message, replyProjection.message)
        XCTAssertNotEqual(before.renderToken, replyProjection.renderToken)
        XCTAssertEqual(replyProjection.message.associatedMessages[replies.id]?.text, "Reply edited")
    }

    func testFPP02FreshActionDeniesChangedProtectionAndRetiredAccountOrScope() {
        let open = FeedNativeFixtures.channel(1)
        let protected = FeedNativeFixtures.channel(1, protected: true)
        let message = FeedNativeFixtures.message(channel: open, id: 7, timestamp: 100)
        let pipe = ValuePipe<[EngineMessage.Id: ExteralessFeedMessageProjection]>()
        var fetches = 0, effects = 0, denied = 0
        var account = 1
        var scope = 1
        let authorizer = ExteralessFeedFreshActions(fetch: { ids in
            XCTAssertEqual(ids, [message.id]); fetches += 1; return pipe.signal()
        })
        authorizer.perform(ids: [message.id], current: { account == 1 && scope == 1 }, allowed: { $0.allSatisfy { $0.allowsExport(contentSettings: .default) } }, rejected: { denied += 1 }, action: { _ in effects += 1 })
        pipe.putNext([message.id: FeedNativeFixtures.projection(message, peer: protected.peer)])
        XCTAssertEqual(denied, 1)
        XCTAssertEqual(effects, 0)
        authorizer.perform(ids: [message.id], current: { account == 1 && scope == 1 }, allowed: { $0.allSatisfy { $0.allowsExport(contentSettings: .default) } }, rejected: { denied += 1 }, action: { _ in effects += 1 })
        account = 2
        pipe.putNext([message.id: FeedNativeFixtures.projection(message)])
        XCTAssertEqual(effects, 0)
        account = 1
        authorizer.perform(ids: [message.id], current: { scope == 1 }, allowed: { _ in true }, rejected: { denied += 1 }, action: { _ in effects += 1 })
        scope = 2
        pipe.putNext([message.id: FeedNativeFixtures.projection(message)])
        XCTAssertEqual(effects, 0)
        scope = 1
        authorizer.perform(ids: [message.id], current: { true }, allowed: { $0.allSatisfy { $0.allowsExport(contentSettings: .default) } }, rejected: { denied += 1 }, action: { _ in effects += 1 })
        pipe.putNext([message.id: FeedNativeFixtures.projection(message)])
        XCTAssertEqual(fetches, 4)
        XCTAssertEqual(effects, 1)
        authorizer.invalidate()
    }

    func testFPP03OcclusionsAreWindowAccountAndOwnerScoped() {
        let registry = ExteralessContentOcclusions()
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let second = UIWindow(frame: first.frame)
        let owner = UUID(), other = UUID()
        var a: [CGRect] = [], b: [CGRect] = [], otherWindow: [CGRect] = []
        let s1 = registry.subscribe(accountId: 1, window: first) { a = $0.rects }
        let s2 = registry.subscribe(accountId: 2, window: first) { b = $0.rects }
        let s3 = registry.subscribe(accountId: 1, window: second) { otherWindow = $0.rects }
        defer { registry.unsubscribe(s1); registry.unsubscribe(s2); registry.unsubscribe(s3) }
        let bottom = CGRect(x: 12, y: 650, width: 376, height: 64)
        let top = CGRect(x: 12, y: 94, width: 376, height: 52)
        registry.publish(owner: owner, accountId: 1, window: first, rects: [bottom])
        XCTAssertEqual(a, [bottom]); XCTAssertTrue(b.isEmpty); XCTAssertTrue(otherWindow.isEmpty)
        registry.publish(owner: other, accountId: 1, window: first, rects: [top])
        XCTAssertEqual(a, [top, bottom])
        registry.clear(owner: owner)
        XCTAssertEqual(a, [top])
        registry.publish(owner: other, accountId: 2, window: second, rects: [top])
        XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty); XCTAssertTrue(otherWindow.isEmpty)
        registry.clear(owner: other)
    }

    func testFPP03ReentrantPublicationCannotReplayAStaleRectangle() {
        let registry = ExteralessContentOcclusions()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let owner = UUID()
        var revisions: [UInt64] = []
        var received: [[CGRect]] = []
        let token = registry.subscribe(accountId: 1, window: window) { snapshot in
            revisions.append(snapshot.revision)
            received.append(snapshot.rects)
            if !snapshot.rects.isEmpty { registry.clear(owner: owner) }
        }
        defer { registry.unsubscribe(token) }
        registry.publish(owner: owner, accountId: 1, window: window, rects: [CGRect(x: 0, y: 50, width: 100, height: 50)])
        XCTAssertEqual(received.count, 3)
        XCTAssertTrue(received.last?.isEmpty == true)
        XCTAssertEqual(revisions, revisions.sorted())
    }

    func testFPP04MetadataLeaseOutlivesOneShotAndSurvivesMembershipFiltering() {
        let a = FeedNativeFixtures.channel(1), b = FeedNativeFixtures.channel(2)
        let base = FeedNativeFixtures.message(channel: a, id: 1, timestamp: 100)
        let poll = TelegramMediaPoll(pollId: EngineMedia.Id(namespace: 0, id: 11), publicity: .anonymous, kind: .poll(multipleAnswers: false), text: "Fixture poll", textEntities: [], options: [], correctAnswers: nil, results: TelegramMediaPollResults(voters: [], totalVoters: 0, recentVoters: [], solution: nil, hasUnseenVotes: false, canViewStats: false), isClosed: false, deadlineTimeout: nil, deadlineDate: nil, pollHash: 0)
        let pollMessage = EngineMessage(base._asMessage().withUpdatedMedia([poll]))
        let pending = TelegramMediaWebpage(webpageId: EngineMedia.Id(namespace: 0, id: 22), content: .Pending(100, nil))
        let webMessage = EngineMessage(FeedNativeFixtures.message(channel: b, id: 1, timestamp: 99)._asMessage().withUpdatedMedia([pending]))
        let events = ValuePipe<EngineMessage>()
        var lease: FeedMetadataFixtureLease?
        var received: [EngineMessage.Id] = []
        var factories = 0
        let metadata = ExteralessFeedVisibleMetadata(makeLease: {
            factories += 1
            let value = FeedMetadataFixtureLease(events: events, received: { received.append($0.id) })
            lease = value
            return value
        })
        var pageCompleted = false
        let page = Signal<ExteralessFeedHistoryPage, NoError>.single(.init(messages: [pollMessage, webMessage], oldest: webMessage.index, hasEarlier: false)).start(completed: { pageCompleted = true })
        page.dispose()
        XCTAssertTrue(pageCompleted)
        let p1 = FeedNativeFixtures.projection(pollMessage), p2 = FeedNativeFixtures.projection(webMessage)
        metadata.update(projections: [p1, p2], active: true)
        events.putNext(EngineMessage(pollMessage._asMessage().withUpdatedStableVersion(stableVersion: 1)))
        events.putNext(EngineMessage(webMessage._asMessage().withUpdatedMedia([])))
        XCTAssertEqual(received, [pollMessage.id, webMessage.id])
        metadata.update(projections: [p1], active: true)
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(lease?.disposals, 0)
        events.putNext(webMessage)
        XCTAssertEqual(received.count, 2)
        events.putNext(pollMessage)
        XCTAssertEqual(received.last, pollMessage.id)
        metadata.stop()
        XCTAssertEqual(lease?.disposals, 1)
        events.putNext(pollMessage)
        XCTAssertEqual(received.count, 3)
    }

    func testFPP05PrepareBeforeCachedForegroundStartsOnlyCurrentHeader() {
        final class Header { var starts = 0; var stops = 0 }
        var creations = 0
        let lifecycle = ExteralessFeedHeaderLifecycle(make: { creations += 1; return Header() }, start: { $0.starts += 1 }, stop: { $0.stops += 1 })
        let header = lifecycle.prepare()
        let subscription = (combineLatest(Signal<Bool, NoError>.single(true), Signal<Bool, NoError>.single(true)) |> deliverOnMainQueue).start(next: { foreground, _ in lifecycle.setVisible(foreground) })
        XCTAssertEqual(header.starts, 1)
        lifecycle.setVisible(true)
        lifecycle.setVisible(false)
        XCTAssertEqual(header.stops, 1)
        XCTAssertTrue(lifecycle.prepare() === header)
        lifecycle.setVisible(true)
        XCTAssertEqual(header.starts, 2)
        XCTAssertEqual(creations, 1)
        lifecycle.setVisible(false)
        subscription.dispose()
    }

    func testGlobalLookaheadReloadsEvictedSourcesWithoutSkippingOlderWindow() {
        let channels = (1 ... 40).map { FeedNativeFixtures.channel(Int64($0)) }
        let messages = channels.flatMap { channel in (1 ... 20).map { id in
            FeedNativeFixtures.message(channel: channel, id: Int32(id), timestamp: Int32((channel.peer.id.id._internalGetInt64Value() - 1) * 20 + Int64(id)))
        } }
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let ready = self.expectation(description: "bounded initial window")
        let timeline = ExteralessFeedTimeline(pageSource: { peer, before in
            let candidates = messages.filter { $0.id.peerId == peer && (before == nil || $0.index < before!) }.sorted { $0.index > $1.index }
            let page = Array(candidates.prefix(20))
            return .single(.init(messages: page, oldest: page.map(\.index).min(), hasEarlier: candidates.count > page.count))
        }, projectionSource: { ids in .single(Dictionary(uniqueKeysWithValues: ids.compactMap { id in byId[id].map { (id, FeedNativeFixtures.projection($0)) } })) })
        defer { timeline.updated = nil; timeline.stop() }
        timeline.updated = {
            XCTAssertLessThanOrEqual(timeline.messages.count, 616)
            if timeline.loadedChannelCount == 40 && timeline.pendingCount == 0 && !timeline.posts.isEmpty { timeline.updated = nil; ready.fulfill() }
        }
        timeline.configure(channels: channels, configuration: ChatFeedConfiguration())
        timeline.start()
        self.wait(for: [ready], timeout: 3)
        while timeline.requestedCount < 500 { timeline.loadMore() }
        let first = Set(timeline.visible.map(\.identity))
        XCTAssertEqual(first.count, 500)
        timeline.loadMore()
        let end = self.expectation(description: "evicted source bodies reloaded")
        timeline.updated = {
            XCTAssertLessThanOrEqual(timeline.messages.count, 616)
            if timeline.reachedEnd && timeline.visible.count == 300 { timeline.updated = nil; end.fulfill() }
        }
        while timeline.requestedCount < 500 { timeline.loadMore() }
        self.wait(for: [end], timeout: 3)
        XCTAssertTrue(first.isDisjoint(with: Set(timeline.visible.map(\.identity))))
        XCTAssertEqual(first.count + timeline.visible.count, 800)
    }
}
