import Foundation
import XCTest
@testable import ExteralessCore

final class AIPluginReviewTests: XCTestCase, @unchecked Sendable {
    private let gzip = "H4sIAAAAAAAC/8vJT07MUUjLrCgpLUrlyhnlUcgDALL+aYVQAQAA"
    private let zlib = "eJzLyU9OzFFIy6woKS1K5coZ5WVSxgMA24Z9oQ=="
    private let zip = "UEsDBBQAAAAIAAAAIVDe+rOwGAAAABYAAAAHAAAAbWFpbi5weSsoyswr0VBKy6woKS1KVcjPy6lU0uQCAFBLAwQUAAAAAAAAACFQru5u6goAAAAKAAAACwAAAHBheWxvYWQudHh0bG9jYWwgZGF0YVBLAQIUABQAAAAIAAAAIVDe+rOwGAAAABYAAAAHAAAAAAAAAAAAAACAAQAAAABtYWluLnB5UEsBAhQAFAAAAAAAAAAhUK7ubuoKAAAACgAAAAsAAAAAAAAAAAAAAIABPQAAAHBheWxvYWQudHh0UEsFBgAAAAACAAIAbgAAAHAAAAAAAA=="

    func testGzipZlibZipAreDecodedAsDataWithCRCAndSizeLimits() throws {
        let expected = Data(String(repeating: "local fixture\n", count: 24).utf8)
        XCTAssertEqual(try AIReviewArchive.unpack(XCTUnwrap(Data(base64Encoded: gzip))), expected)
        XCTAssertEqual(try AIReviewArchive.unpack(XCTUnwrap(Data(base64Encoded: zlib))), expected)
        let entries = try AIReviewArchive.entries(XCTUnwrap(Data(base64Encoded: zip)))
        XCTAssertEqual(entries.map(\.name), ["main.py", "payload.txt"])
        XCTAssertEqual(String(decoding: entries[0].data, as: UTF8.self), "print(\"fixture only\")\n")
        XCTAssertEqual(String(decoding: entries[1].data, as: UTF8.self), "local data")
        XCTAssertThrowsError(try AIReviewArchive.unpack(XCTUnwrap(Data(base64Encoded: gzip)), maximumBytes: 8))
        var corrupted = try XCTUnwrap(Data(base64Encoded: gzip))
        corrupted[corrupted.count - 8] ^= 1
        XCTAssertThrowsError(try AIReviewArchive.unpack(corrupted))
    }

    func testOriginalToolsReadOnlySelectedSnapshotAndPageActualSource() async throws {
        let source = (1 ... 500).map { "line\($0)" }.joined(separator: "\n")
        let snapshot = AIPluginReviewSnapshot(descriptor: .init(id: "fixture", title: "Fixture"), revision: "one", files: [.init(name: "main.py", data: Data(source.utf8))])
        let tools = try AIPluginReviewTools(snapshot: snapshot)
        let first = try await tools.call("read_source", arguments: .object(["start_line": .integer(1), "end_line": .integer(500)]))
        XCTAssertTrue(first.contains("400| line400"))
        XCTAssertFalse(first.contains("401| line401"))
        XCTAssertTrue(first.contains("start_line=401"))
        let refused = try await tools.call("read_source", arguments: .object(["file": .string("../../settings.json")]))
        XCTAssertTrue(refused.hasPrefix("error:"))
        do { _ = try await tools.call("send_message", arguments: .object([:])); XCTFail("Unlisted tool ran") }
        catch { XCTAssertEqual(error as? AIError, .unsupportedTools) }
        let decoded = try await tools.call("decode_base64", arguments: .object(["data": .string(gzip)]))
        XCTAssertTrue(decoded.contains("local fixture"))
        let handler = await tools.handler()
        XCTAssertEqual(handler.definitions.map(\.name), ["read_source", "list_blobs", "decode_base64"])
        let callback = try await handler.call("read_source", .object(["file": .string("main.py"), "start_line": .integer(499), "end_line": .integer(500)]))
        XCTAssertTrue(callback.contains("500| line500"))
    }

    func testReviewCacheHasRealTTLAndDisabledToolsDoesNotInvokeCallbacks() async throws {
        let clock = AIReviewFixtureClock()
        let cache = AIPluginReviewCache(now: { clock.now })
        await cache.remember(.init(text: "fixture review"), for: "plugin-revision")
        let value = await cache.response(for: "plugin-revision")
        XCTAssertEqual(value?.text, "fixture review")
        clock.now = 400
        let expired = await cache.response(for: "plugin-revision")
        XCTAssertNil(expired)
        await cache.remember(.init(text: "second"), for: "plugin-revision")
        await cache.clear()
        let cleared = await cache.response(for: "plugin-revision")
        XCTAssertNil(cleared)
        let transport = AIScriptedTransport([.init(body: #"{"choices":[{"message":{"content":"review"}}]}"#)])
        let handler = AIToolHandler(definitions: [.init(name: "forbidden_fixture", description: "must not run", parameters: .object([:]))]) { _, _ in
            XCTFail("Disabled tool callback was invoked")
            throw AIError.toolFailed
        }
        let result = try await AIClient(transport: transport).generate(service: .init(url: "https://fixture.invalid/v1", model: "fixture"), apiKey: "fixture-only-key", request: .init(messages: [.init(role: .user, content: "fixture")], streaming: false, disableTools: true), tools: handler)
        XCTAssertEqual(result.text, "review")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.first?.httpBody)) as? [String: Any])
        XCTAssertNil(body["tools"])
    }
}

private final class AIReviewFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
