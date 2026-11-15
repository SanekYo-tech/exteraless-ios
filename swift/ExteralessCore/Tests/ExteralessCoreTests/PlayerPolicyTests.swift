import Foundation
import XCTest
@testable import ExteralessCore

final class PlayerPolicyTests: XCTestCase {
    func testOriginalStyleDefaultsAndNamespaceOwnership() {
        let defaults = PlayerStylePolicy()
        XCTAssertTrue(defaults.modernPlayer)
        XCTAssertTrue(defaults.modernMiniPlayer)
        XCTAssertTrue(defaults.profileMusicCard)
        XCTAssertFalse(defaults.onlineLyrics)
        XCTAssertEqual(defaults.cover, .card)
        XCTAssertEqual(defaults.coverScale, 1)
        XCTAssertEqual(defaults.coverRadius, 28)
        XCTAssertEqual(defaults.order, [.progress, .controls, .actions])
        XCTAssertTrue(defaults.miniThemeColors)
        XCTAssertFalse(defaults.miniTop)
        XCTAssertTrue(Set(PlayerFeatures.definitions.map(\.key)).isDisjoint(with: ChatFeatures.definitions.map(\.key)))
        XCTAssertEqual(Set(PlayerFeatures.definitions.map(\.key)).count, PlayerFeatures.definitions.count)
    }

    func testFramedOnlyTitleAboveAndSwipeAndDefensiveRanges() {
        let style = PlayerStylePolicy(values: [
            "appearance.playerCoverStyle": .integer(2), "appearance.playerTitleAbove": .bool(true),
            "appearance.playerCoverSwipe": .bool(true), "appearance.playerCoverSize": .integer(2),
            "appearance.playerCoverRadius": .integer(900), "appearance.playerMiniProgress": .integer(99)
        ])
        XCTAssertFalse(style.titleAbove)
        XCTAssertFalse(style.coverSwipe)
        XCTAssertEqual(style.coverScale, 0.6)
        XCTAssertEqual(style.coverRadius, 48)
        XCTAssertEqual(style.miniProgress, .ring)
        XCTAssertEqual(PlayerStylePolicy.blockOrder("2,2,junk,0,900"), [.actions, .progress, .controls])
    }

    func testDiscStopsWhenPausedHiddenOrReducedMotion() {
        let style = PlayerStylePolicy(values: ["appearance.playerCoverStyle": .integer(3)])
        XCTAssertTrue(style.rotatesDisc(playing: true, visible: true, reduceMotion: false))
        XCTAssertFalse(style.rotatesDisc(playing: false, visible: true, reduceMotion: false))
        XCTAssertFalse(style.rotatesDisc(playing: true, visible: false, reduceMotion: false))
        XCTAssertFalse(style.rotatesDisc(playing: true, visible: true, reduceMotion: true))
    }

    func testTimelineUsesActualRateAndDoesNotAdvanceBufferingOrInvalidValues() {
        XCTAssertEqual(PlayerTimelinePolicy.position(timestamp: 10, generationTimestamp: 100, now: 102, duration: 90, rate: 1.7, advancing: true), 13.4, accuracy: 0.001)
        XCTAssertEqual(PlayerTimelinePolicy.position(timestamp: 10, generationTimestamp: 100, now: 102, duration: 90, rate: 1.7, advancing: false), 10)
        XCTAssertEqual(PlayerTimelinePolicy.position(timestamp: 10, generationTimestamp: 100, now: 1000, duration: 90, rate: 2, advancing: true), 90)
        XCTAssertEqual(PlayerTimelinePolicy.position(timestamp: .nan, generationTimestamp: 100, now: 102, duration: 90, rate: 1, advancing: true), 0)
    }

    func testLRCFractionsMultipleTimestampsOffsetUnicodeAndWordTimes() throws {
        let document = try XCTUnwrap(PlayerLyricsDocument.parse("[ar:Fixture]\n[offset:500]\n[00:02.50][00:08.500]Привет\n[00:01.5]<00:01.500>Hello <00:01.800>world\n[00:09.0]"))
        XCTAssertTrue(document.synced)
        XCTAssertEqual(document.lines.map(\.time), [1.0, 2.0, 8.0])
        XCTAssertEqual(document.lines[0].text, "Hello world")
        XCTAssertEqual(document.lines[0].words[0].time, 1.0, accuracy: 0.0001)
        XCTAssertEqual(document.lines[0].words[1].time, 1.3, accuracy: 0.0001)
        XCTAssertEqual(document.lines[1].text, "Привет")
        XCTAssertNil(document.index(at: 0.9))
        XCTAssertEqual(document.index(at: 2.0), 1)
        XCTAssertEqual(document.index(at: 2.0, userOffset: 0.5), 0)
        XCTAssertEqual(document.seekTime(line: 1, userOffset: 0.5, duration: 20), 2.5)
        XCTAssertNil(document.seekTime(line: 80, userOffset: 0, duration: 20))
    }

    func testUntimedLyricsAndBlankLineNormalizationStayReadable() throws {
        let document = try XCTUnwrap(PlayerLyricsDocument.parse("\r\n[ti:Fixture]\r\nFirst\r\n\r\n\r\nSecond\r\n"))
        XCTAssertFalse(document.synced)
        XCTAssertEqual(document.lines.map(\.text), ["First", "", "Second"])
        XCTAssertNil(document.index(at: 30))
        XCTAssertNil(document.seekTime(line: 0, userOffset: 1, duration: 90))
        XCTAssertThrowsError(try PlayerLyricsDocument.parse(String(repeating: "x", count: PlayerLyricsLimits.textBytes + 1)))
        XCTAssertThrowsError(try PlayerLyricsDocument.parse(String(repeating: "[00:01.00]x\n", count: PlayerLyricsLimits.lines + 1)))
    }

    func testCandidateMatchingRejectsWrongArtistAndWrongRecording() throws {
        let lyrics = try XCTUnwrap(PlayerLyricsDocument.parse("[00:01]Hello"))
        let query = PlayerLyricsQuery(artist: "Fixture Band", title: "A Real Song", duration: 180)
        let good = PlayerLyricsCandidate(id: "good", title: "A Real Song", artist: "Fixture Band", album: "", duration: 182, lyrics: lyrics)
        let wrongArtist = PlayerLyricsCandidate(id: "wrong-artist", title: "A Real Song", artist: "Somebody Else", album: "", duration: 180, lyrics: lyrics)
        let wrongRecording = PlayerLyricsCandidate(id: "wrong-duration", title: "A Real Song", artist: "Fixture Band", album: "", duration: 310, lyrics: lyrics)
        XCTAssertEqual(PlayerLyricsMatching.best([wrongArtist, wrongRecording, good], query: query)?.id, "good")
        XCTAssertNil(PlayerLyricsMatching.score(wrongArtist, query: query))
        XCTAssertNil(PlayerLyricsMatching.score(wrongRecording, query: query))
    }

    func testFallbackPunctuationPreservesTimingAndNeedsNinetyPercentAlignment() throws {
        let timed = try XCTUnwrap(PlayerLyricsDocument.parse("[00:01]hello world\n[00:02]again", source: .online, provider: "lrcmux"))
        let plain = try XCTUnwrap(PlayerLyricsDocument.parse("Hello, world!\nAgain.", source: .online, provider: "LRCLIB"))
        let aligned = try XCTUnwrap(PlayerLyricsMatching.punctuate(timed: timed, plain: plain))
        XCTAssertEqual(aligned.lines.map(\.time), timed.lines.map(\.time))
        XCTAssertEqual(aligned.lines.map(\.text), ["hello, world!", "again."])
        XCTAssertEqual(aligned.provider, "lrcmux + LRCLIB")
        let unrelated = try XCTUnwrap(PlayerLyricsDocument.parse("Something entirely different"))
        XCTAssertNil(PlayerLyricsMatching.punctuate(timed: timed, plain: unrelated))
    }

    func testPerTrackDurationAndAccountLeaseRejectsLateResultAndSeek() {
        let query = PlayerLyricsQuery(artist: "Band", title: "Song", duration: 120)
        let a = PlayerLyricsTrack(account: 1, resource: "file-a", duration: 120, query: query)
        let b = PlayerLyricsTrack(account: 1, resource: "file-a", duration: 121, query: query)
        let c = PlayerLyricsTrack(account: 2, resource: "file-a", duration: 120, query: query)
        var generation = PlayerLyricsGeneration()
        let first = generation.begin(a)
        let second = generation.begin(b)
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
        generation.cancel()
        XCTAssertFalse(generation.accepts(second))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        var seek = ChatPlaybackSeekLease<PlayerLyricsTrack>()
        seek.begin(identity: a)
        XCTAssertNil(seek.finish(identity: b, fraction: 0.4, duration: 121))
        seek.begin(identity: a)
        XCTAssertEqual(seek.finish(identity: a, fraction: 0.4, duration: 120), 48)
    }

    func testProfileAndVideoPoliciesDoNotBypassNativePrerequisites() {
        let hidden = PlayerStylePolicy(values: ["appearance.profileMusicCard": .bool(false)])
        XCTAssertFalse(hidden.showsProfileMusic(hasMusic: true, isSettings: false))
        XCTAssertFalse(PlayerStylePolicy().showsProfileMusic(hasMusic: true, isSettings: true))
        XCTAssertTrue(PlayerStylePolicy().showsProfileMusic(hasMusic: true, isSettings: false))
        XCTAssertFalse(PlayerVideoGesturePolicy.entersPictureInPicture(enabled: true, downward: true, supported: false, isViewOnce: false, isAnimated: false))
        XCTAssertFalse(PlayerVideoGesturePolicy.entersPictureInPicture(enabled: true, downward: true, supported: true, isViewOnce: true, isAnimated: false))
        XCTAssertTrue(PlayerVideoGesturePolicy.entersPictureInPicture(enabled: true, downward: true, supported: true, isViewOnce: false, isAnimated: false))
    }
}
