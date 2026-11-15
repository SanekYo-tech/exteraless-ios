import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsUtilityTests: XCTestCase {
    func testSRTAndVTTTracksRespectSeekAndOpenEndTimes() throws {
        let srt = Data("1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\n\r\n2\r\n00:00:02,000 --> 00:00:03,000\r\n<i>World</i>\r\n".utf8)
        let track = try ToolsSubtitleTrack(data: srt)
        XCTAssertNil(track.text(at: 0.9))
        XCTAssertEqual(track.text(at: 1), "Hello")
        XCTAssertEqual(track.text(at: 2.1), "Hello\nWorld")
        XCTAssertEqual(track.text(at: 2.5), "World")
        XCTAssertNil(track.text(at: 3))
        XCTAssertEqual(track.text(at: 1.1), "Hello", "seeking backward must not leave stale subtitle text")
        let vtt = try ToolsSubtitleTrack(data: Data("WEBVTT\n\ncue-id\n00:01.000 --> 00:02.000 align:center\nA &amp; B".utf8))
        XCTAssertEqual(vtt.text(at: 1.5), "A & B")
        XCTAssertThrowsError(try ToolsSubtitleTrack(data: Data("1\n00:00:03,000 --> 00:00:01,000\nWrong".utf8)))
        XCTAssertThrowsError(try ToolsSubtitleTrack(data: Data(repeating: 65, count: ToolsSubtitleTrack.maximumBytes + 1)))
    }

    func testSHA256PublishedVectorsAndChunkBoundary() {
        XCTAssertEqual(ToolsSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ToolsSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let vector = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        var hash = ToolsSHA256()
        hash.update(vector.prefix(13))
        hash.update(vector.dropFirst(13))
        XCTAssertEqual(hash.hexDigest(), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hash.hexDigest(), hash.hexDigest(), "finalization must not consume the state")
    }

    func testDocumentClassificationDoesNotExecuteSourceAndHandlesOriginalSpecialNames() {
        XCTAssertEqual(ToolsDocumentKind.detect(name: "C:\\downloads\\Dockerfile.dev"), .code("docker"))
        XCTAssertEqual(ToolsDocumentKind.detect(name: ".env.local"), .code("ini"))
        XCTAssertEqual(ToolsDocumentKind.detect(name: "fixture.plugin"), .code("python"))
        XCTAssertEqual(ToolsDocumentKind.detect(name: "NOTES.MD"), .markdown)
        XCTAssertEqual(ToolsDocumentKind.detect(name: "unknown", mimeType: "application/json5; charset=UTF-8"), .code("json5"))
        XCTAssertNil(ToolsDocumentKind.detect(name: "image.bin", mimeType: "application/octet-stream"))
        XCTAssertNil(ToolsJPEGPlatform.guess(header: Data([0xff, 0xd8, 0xff])))
    }

    func testZoomBoundsDoNotInventUltrawideAndRejectNonFiniteInput() {
        XCTAssertEqual(ToolsCameraPolicy.lensStops(minimum: 1, maximum: 3, optical: [0.5, 2, .nan, 9]), [1, 2])
        XCTAssertEqual(ToolsCameraPolicy.zoom(.infinity, minimum: 1, maximum: 5), 1)
        XCTAssertEqual(ToolsCameraPolicy.zoom(10, minimum: 0.5, maximum: 4), 4)
        XCTAssertEqual(ToolsCameraPolicy.frameRate(requested: 30, supported: 24...30, extended: true, multiCamera: false), 30)
        XCTAssertEqual(ToolsCameraPolicy.frameRate(requested: 30, supported: 24...60, extended: true, multiCamera: true), 30)
        XCTAssertEqual(ToolsCameraPolicy.frameRate(requested: 30, supported: 24...60, extended: true, multiCamera: false), 60)
    }

    func testFlashDefaultsAndEndpointsMatchAndroidFlashViews() {
        let neutral = ToolsCameraPolicy.flashColor(warmth: 50)
        XCTAssertEqual(neutral.red, 1); XCTAssertEqual(neutral.green, 1); XCTAssertEqual(neutral.blue, 1)
        XCTAssertEqual(ToolsCameraPolicy.flashColor(warmth: 0).red, 140.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(ToolsCameraPolicy.flashColor(warmth: 100).blue, 140.0 / 255, accuracy: 0.00001)
    }

    func testDisplayLinkStatsUseChangingRefreshPeriodAndBoundWorstSamples() {
        var profile = ToolsFrameProfile()
        profile.record(timestamp: 1, expectedInterval: 1.0 / 60)
        profile.record(timestamp: 1.0083, expectedInterval: 1.0 / 120)
        profile.record(timestamp: 1.05, expectedInterval: 1.0 / 120)
        XCTAssertEqual(profile.samples, 2)
        XCTAssertEqual(profile.delayed, 1)
        for i in 1...100 { profile.record(timestamp: 1.05 + Double(i), expectedInterval: 1.0 / 60) }
        XCTAssertEqual(profile.slowest.count, 40)
        profile.record(timestamp: .nan, expectedInterval: 1.0 / 60)
        XCTAssertEqual(profile.samples, 102)
    }
}
