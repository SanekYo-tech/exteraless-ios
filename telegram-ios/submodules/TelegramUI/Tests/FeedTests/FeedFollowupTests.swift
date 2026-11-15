import AccountContext
import AsyncDisplayKit
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import XCTest
@testable import TelegramUI

@MainActor
final class FeedFollowupTests: XCTestCase {
    private final class PageRequest {
        var cancelled = false
        var deliver: (() -> Void)?
    }

    private func verifyFrontiers(shortChannels: Int, reverse: Bool, injectFutureRange: Bool = false) {
        let channels = (1 ... shortChannels + 1).map { FeedNativeFixtures.channel(Int64($0)) }
        let values = channels.flatMap { channel -> [EngineMessage] in
            let isA = channel.peer.id == channels[0].peer.id
            return (1 ... (isA ? 1000 : 20)).map { id in
                FeedNativeFixtures.message(channel: channel, id: Int32(id), timestamp: Int32((isA ? 4000 : 0) + id))
            }
        }
        let byId = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        let byPeer = Dictionary(grouping: values, by: { $0.id.peerId })
        var pending: [PageRequest] = []
        var peakInFlight = 0
        var seen = Set<ChatFeedIdentity>()
        var rounds = 0
        var finished = false
        var injectedBefore: EngineMessage.Index?
        var retriedBefore: EngineMessage.Index?
        var retried = false
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        let end = self.expectation(description: "all \(values.count) ids, order \(reverse)")
        let timeline = ExteralessFeedTimeline(pageSource: { peer, before in
            Signal { subscriber in
                let request = PageRequest()
                let older = (byPeer[peer] ?? []).filter { before == nil || $0.index < before! }.sorted { $0.index > $1.index }
                var page = Array(older.prefix(20))
                if injectFutureRange, peer == channels[0].peer.id, before?.id.id == 501 {
                    if injectedBefore == nil {
                        injectedBefore = before
                        // A changed source returned an unshown future-range item. The page's
                        // otherwise valid oldest cursor must NOT commit past it.
                        page.insert(FeedNativeFixtures.message(channel: channels[0], id: 1001, timestamp: 5001), at: 0)
                    } else { retriedBefore = before }
                }
                request.deliver = { [weak request] in
                    guard let request, !request.cancelled else { return }
                    subscriber.putNext(.init(messages: page, oldest: page.map(\.index).min(), hasEarlier: older.count > page.count))
                    subscriber.putCompletion()
                }
                pending.append(request)
                peakInFlight = max(peakInFlight, pending.filter { !$0.cancelled }.count)
                return ActionDisposable { request.cancelled = true }
            }
        }, projectionSource: { ids in
            .single(Dictionary(uniqueKeysWithValues: ids.compactMap { id in byId[id].map { (id, FeedNativeFixtures.projection($0)) } }))
        })
        defer { finished = true; timeline.stop(); pending.removeAll() }
        timeline.updated = { XCTAssertLessThanOrEqual(timeline.messages.count, 616) }
        func recordWindow() {
            let ids = Set(timeline.visible.map(\.identity))
            XCTAssertEqual(ids.count, timeline.visible.count)
            XCTAssertTrue(seen.isDisjoint(with: ids), "A consumed ID was displayed twice")
            seen.formUnion(ids)
        }
        func pump() {
            guard !finished else { return }
            if ProcessInfo.processInfo.systemUptime > deadline || rounds >= 256 {
                XCTFail("Bounded replay did not find end; seen \(seen.count)/\(values.count)")
                finished = true; end.fulfill(); return
            }
            let batch = pending
            pending.removeAll()
            if !batch.isEmpty {
                rounds += 1
                XCTAssertLessThanOrEqual(batch.filter { !$0.cancelled }.count, 4)
                let ordered = reverse ? Array(batch.reversed()) : batch
                for request in ordered { request.deliver?() }
            }
            if !timeline.failedChannels.isEmpty {
                if injectFutureRange, injectedBefore != nil, !retried {
                    XCTAssertFalse(timeline.reachedEnd)
                    XCTAssertTrue(timeline.hasNewerGap)
                    retried = true
                    timeline.retry()
                    XCTAssertEqual(retriedBefore, injectedBefore, "Retry must use the original real before-cursor")
                    finished = true; end.fulfill(); return
                }
                XCTFail("A correct next-window frontier rejected an unseen range")
                finished = true; end.fulfill(); return
            }
            if timeline.pendingCount == 0 && !timeline.hasFrontierGap && !timeline.isProjecting {
                if timeline.reachedEnd {
                    recordWindow()
                    finished = true; end.fulfill(); return
                }
                if timeline.visible.count >= timeline.requestedCount {
                    if timeline.requestedCount == 500 { recordWindow() }
                    timeline.loadMore()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { pump() }
        }
        timeline.configure(channels: channels, configuration: ChatFeedConfiguration())
        timeline.start()
        pump()
        self.wait(for: [end], timeout: 7)
        if injectFutureRange {
            XCTAssertTrue(retried)
            timeline.updated = nil
            return
        }
        XCTAssertEqual(seen, Set(values.map { ExteralessFeedTimeline.identity($0.id) }))
        XCTAssertTrue(timeline.reachedEnd)
        XCTAssertLessThanOrEqual(peakInFlight, 4)
        timeline.updated = nil
    }

    func testFU01AThousandMessagesAndOneOldBufferedChannel() { self.verifyFrontiers(shortChannels: 1, reverse: false) }
    func testFU01FortyOneChannelsForwardCapturedRequests() { self.verifyFrontiers(shortChannels: 40, reverse: false) }
    func testFU01FortyOneChannelsReverseCapturedRequests() { self.verifyFrontiers(shortChannels: 40, reverse: true) }
    func testFU01UnshownFutureRangeCannotAdvanceTheRealCursor() { self.verifyFrontiers(shortChannels: 1, reverse: false, injectFutureRange: true) }

    func testFU03ProjectionOwnerRetainsTokensAcrossIntersectionAndSemanticDecode() {
        let a = FeedNativeFixtures.channel(1), b = FeedNativeFixtures.channel(2)
        let aId = FeedNativeFixtures.message(channel: a, id: 1, timestamp: 100).id
        let bId = FeedNativeFixtures.message(channel: b, id: 1, timestamp: 90).id
        var protected = false
        var replyText = "Unchanged reply"
        let refresh = ValuePipe<Void>()
        func snapshot(_ ids: Set<EngineMessage.Id>) -> [EngineMessage.Id: ExteralessFeedMessageProjection] {
            var result: [EngineMessage.Id: ExteralessFeedMessageProjection] = [:]
            for id in ids {
                let peer = id == aId ? FeedNativeFixtures.channel(1, protected: protected) : b
                let root = FeedNativeFixtures.message(channel: peer, id: 1, timestamp: id == aId ? 100 : 90)
                let reply = FeedNativeFixtures.message(channel: a, id: 9, timestamp: 80, text: replyText)
                let message = EngineMessage(root._asMessage().withUpdatedAuthor(nil).withUpdatedAssociatedMessages(EngineSimpleDictionary(id == aId ? [reply.id: reply._asMessage()] : [:])))
                result[id] = FeedNativeFixtures.projection(message)
            }
            return result
        }
        let session = ExteralessFeedProjectionSession(source: { ids in
            (Signal<Void, NoError>.single(()) |> then(refresh.signal()) |> deliverOnMainQueue) |> map { snapshot(ids) }
        })
        let disposable = MetaDisposable()
        defer { disposable.dispose(); session.clear() }
        var current: [EngineMessage.Id: ExteralessFeedMessageProjection] = [:]
        var updated: (() -> Void)?
        func load(_ ids: Set<EngineMessage.Id>) {
            let loaded = self.expectation(description: "projection owner scope")
            var first = true
            disposable.set((session.observe(ids: ids) |> deliverOnMainQueue).start(next: { value in
                current = value
                if first { first = false; loaded.fulfill() }
                updated?()
            }))
            self.wait(for: [loaded], timeout: 1)
        }
        load([aId])
        let original = current[aId]?.renderToken
        let originalMessage = current[aId]?.message
        load([aId, bId])
        XCTAssertEqual(current[aId]?.renderToken, original)
        load([aId])
        XCTAssertEqual(current[aId]?.renderToken, original)
        protected = true
        let protectionChanged = self.expectation(description: "peer-only change on current observation")
        updated = { updated = nil; protectionChanged.fulfill() }
        refresh.putNext(())
        self.wait(for: [protectionChanged], timeout: 1)
        XCTAssertNotEqual(current[aId]?.renderToken, original)
        XCTAssertEqual(current[aId]?.message, originalMessage, "The root's shallow native version is unchanged")
        XCTAssertTrue(current[aId]?.isCopyProtected == true)
        let protectedToken = current[aId]?.renderToken
        replyText = "Updated reply content"
        let replyChanged = self.expectation(description: "reply-only change on current observation")
        updated = { updated = nil; replyChanged.fulfill() }
        refresh.putNext(())
        self.wait(for: [replyChanged], timeout: 1)
        XCTAssertNotEqual(current[aId]?.renderToken, protectedToken)
        XCTAssertEqual(current[aId]?.message, originalMessage)
        XCTAssertEqual(current[aId]?.message.associatedMessages.map { $0.1.text }.first, replyText)
        let beforeRemoval = current[aId]?.renderToken
        load([])
        load([aId])
        XCTAssertNotEqual(current[aId]?.renderToken, beforeRemoval, "A removed root does not retain its old lease")
    }

    func testFU02RevokedDescendantSignalAndTerminalEffectStayInert() {
        let message = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100)
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [message.id], exportAllowed: true)
        let ready = ValuePipe<Bool>()
        var presentations = 0, saves = 0, prepared = 0, success = 0
        let pending = permit.guardSignal(accountId: 11, operation: .presentation) { ready.signal() }.start(next: { _ in
            permit.perform(accountId: 11, operation: .presentation) { presentations += 1 }
        }, completed: { success += 1 })
        permit.revoke()
        ready.putNext(true)
        XCTAssertFalse(permit.perform(accountId: 11, operation: .exportPreparation) { prepared += 1 })
        XCTAssertFalse(permit.perform(accountId: 11, operation: .exportEffect) { saves += 1 })
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(success, 0, "Cancellation is not successful Save/Share completion")
        XCTAssertEqual(permit.counters.presentations, 0)
        XCTAssertEqual(permit.counters.effects, 0)
        XCTAssertEqual(permit.counters.preparations, 0)
        XCTAssertFalse(permit.allows(accountId: 12))
        pending.dispose()
    }

    func testFU03RichMediaDecodeOrderIsStableAndMutableFullPageStillInvalidates() {
        let channel = FeedNativeFixtures.channel(1)
        let root = FeedNativeFixtures.message(channel: channel, id: 7, timestamp: 100)
        let images = (1 ... 2).map { id in
            TelegramMediaImage(imageId: EngineMedia.Id(namespace: Namespaces.Media.LocalImage, id: Int64(id)), representations: [], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        }
        func page(_ text: String, reverse: Bool) -> InstantPage {
            var media: [EngineMedia.Id: EngineMedia] = [:]
            for image in (reverse ? Array(images.reversed()) : images) { media[image.imageId] = .image(image) }
            return InstantPage(blocks: [.paragraph(.plain(text))], media: media, isComplete: true, rtl: false, url: "", views: nil)
        }
        let rich = RichTextMessageAttribute(instantPage: page("Preview", reverse: false), fullInstantPage: nil)
        var value = FeedNativeFixtures.projection(EngineMessage(root._asMessage().withUpdatedAttributes([rich])))
        let session = ExteralessFeedProjectionSession(source: { ids in
            Signal { subscriber in
                subscriber.putNext(ids.contains(root.id) ? [root.id: value] : [:])
                subscriber.putCompletion()
                return EmptyDisposable
            } |> runOn(.mainQueue())
        })
        let disposable = MetaDisposable()
        defer { disposable.dispose(); session.clear() }
        func read() -> ExteralessFeedMessageProjection? {
            let loaded = self.expectation(description: "native rich projection baseline")
            var result: ExteralessFeedMessageProjection?
            disposable.set((session.observe(ids: [root.id]) |> deliverOnMainQueue).start(next: { values in
                result = values[root.id]; loaded.fulfill()
            }))
            self.wait(for: [loaded], timeout: 1)
            return result
        }
        let initial = read()
        rich.fullInstantPage = page("Full body", reverse: false)
        let full = read() // Deliberately the SAME message/attribute/upstream token.
        XCTAssertNotEqual(full?.renderToken, initial?.renderToken)
        XCTAssertEqual((full?.message.attributes.first as? RichTextMessageAttribute)?.fullInstantPage?.blocks, [.paragraph(.plain("Full body"))])
        let decoded = RichTextMessageAttribute(instantPage: page("Preview", reverse: true), fullInstantPage: page("Full body", reverse: true))
        value = FeedNativeFixtures.projection(EngineMessage(root._asMessage().withUpdatedAttributes([decoded])))
        XCTAssertEqual(read()?.renderToken, full?.renderToken, "Recreated dictionaries are not a render revision")
        decoded.fullInstantPage = page("Changed full body", reverse: true)
        XCTAssertNotEqual(read()?.renderToken, full?.renderToken)
    }
}
