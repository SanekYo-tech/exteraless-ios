import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsSubtitleStoreTests: XCTestCase, @unchecked Sendable {
    func testNativePlaybackClockFreezesBufferingAndFollowsRateAndSeek() {
        let playing = ToolsSubtitlePlaybackSample(timestamp: 10, generationTimestamp: 100, duration: 30, rate: 2, playing: true)
        XCTAssertEqual(playing.time(at: 102), 14)
        XCTAssertEqual(playing.time(at: 120), 30)
        let paused = ToolsSubtitlePlaybackSample(timestamp: 10, generationTimestamp: 100, duration: 30, rate: 2, playing: false)
        XCTAssertEqual(paused.time(at: 120), 10)
        let seek = ToolsSubtitlePlaybackSample(timestamp: 1, generationTimestamp: 102, duration: 30, rate: 0.5, playing: true)
        XCTAssertEqual(seek.time(at: 104), 2)
    }

    func testSidecarsAreAccountIsolatedAndClearHasAnEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-subtitle-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolsSubtitleStore(directory: root)
        let data = Data("1\n00:00:01,000 --> 00:00:02,000\nFixture".utf8)
        _ = try await store.save(data, identity: "account:1:media:10")
        let first = try await store.load(identity: "account:1:media:10")
        let other = try await store.load(identity: "account:2:media:10")
        XCTAssertEqual(first?.text(at: 1.5), "Fixture")
        XCTAssertNil(other)
        try await store.clear(identity: "account:1:media:10")
        let cleared = try await store.load(identity: "account:1:media:10")
        XCTAssertNil(cleared)
    }
}
