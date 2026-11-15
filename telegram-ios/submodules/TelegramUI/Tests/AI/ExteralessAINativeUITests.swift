import ExteralessCore
import Foundation
import TelegramCore
import UIKit
import XCTest
@testable import TelegramUI

/// Bounded native components and injected I/O, never a real provider or account.
/// These tests need the iOS test target; they are not part of Core's SPM pass.
final class ExteralessAINativeUITests: XCTestCase {
    @MainActor func testProtectedResultHasNoSystemSelectionCopyOrShare() {
        let view = ExteralessAIResultTextView()
        view.text = "PROTECTED FIXTURE"
        view.selectedRange = NSRange(location: 0, length: 9)
        var copies = 0
        view.copySelection = { copies += 1 }
        view.copyAllowed = false
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        view.copy(nil)
        XCTAssertEqual(copies, 0)
        view.copyAllowed = true
        view.copy(nil)
        XCTAssertEqual(copies, 1) // The callback, rather than UIKit's raw pasteboard path.
    }

    func testMapperCountsNilCellsUnknownItemsAndOpaqueTextBeforeOutputAllocation() throws {
        let cell = InstantPageTableCell(text: nil, header: false, alignment: .left, verticalAlignment: .top, colspan: 1, rowspan: 1)
        let table = page([.table(title: .empty, rows: [InstantPageTableRow(cells: Array(repeating: cell, count: 8193))], bordered: false, striped: false, compact: false)])
        var mapper = ExteralessAIRichTextTranslator.Mapper(transform: { $0 })
        XCTAssertThrowsError(try mapper.page(table)) { XCTAssertEqual($0 as? AIError, .inputTooLarge) }
        XCTAssertLessThanOrEqual(mapper.outputSlots, 2) // No 8193-cell output reservation.
        let unknown = page([.list(items: Array(repeating: .unknown, count: 8193), ordered: false)])
        mapper = .init(transform: { $0 })
        XCTAssertThrowsError(try mapper.page(unknown)) { XCTAssertEqual($0 as? AIError, .inputTooLarge) }
        XCTAssertEqual(mapper.outputSlots, 1)
        var opaque: RichText = .plain("code")
        for _ in 0 ..< 49 { opaque = .fixed(opaque) }
        mapper = .init(transform: { _ in XCTFail("Code must be preserved"); return "changed" })
        XCTAssertThrowsError(try mapper.page(page([.paragraph(opaque)])))
    }

    func testMapperDepth48And49AndCollectorDoesNotBuildOutputGraph() throws {
        func nested(_ covers: Int) -> InstantPage {
            var block: InstantPageBlock = .paragraph(.plain("leaf"))
            for _ in 0 ..< covers { block = .cover(block) }
            return page([block])
        }
        var mapper = ExteralessAIRichTextTranslator.Mapper(buildOutput: false, transform: { $0 })
        _ = try mapper.page(nested(47)) // Deepest text depth = 48.
        XCTAssertEqual(mapper.outputSlots, 0)
        mapper = .init(buildOutput: false, transform: { $0 })
        XCTAssertThrowsError(try mapper.page(nested(48)))
    }

    @MainActor func testRealRichTranslatorAdmitsAtMostFiveConcurrentLeaves() async throws {
        let fixture = try AINativeUISettingsFixture()
        defer { fixture.close() }
        let five = expectation(description: "first five leaves admitted")
        let transport = AINativeLeafTransport(firstFive: { five.fulfill() })
        let client = AITranslationClient(transport: transport, settings: fixture.settings)
        var config = AITranslationConfiguration(settings: fixture.settings)
        config.provider = .google
        let source = page((0 ..< 7).map { .paragraph(.plain("leaf-\($0)")) })
        let task = Task { try await ExteralessAIRichTextTranslator.translate(page: source, client: client, to: "fr", configuration: config) }
        await fulfillment(of: [five], timeout: 3)
        XCTAssertEqual(transport.count, 5)
        transport.releaseAndCompleteFollowing()
        let translated = try await task.value
        XCTAssertEqual(transport.count, 7)
        XCTAssertEqual(transport.maximumActive, 5)
        XCTAssertEqual(translated.blocks.count, 7)
    }

    func testScopedTransportRechecksEveryExportAndNeverStartsAfterRevocation() async throws {
        let transport = AINativeCountingTransport(response: #"{"sentences":[{"trans":"ok"}]}"#)
        let lease = AINativeOperationLease()
        let guarded = ExteralessAIScopedTransport(base: transport, validate: {
            guard !lease.isCancelled else { throw AIError.cancelled }
        })
        let request = URLRequest(url: URL(string: "https://fixture.invalid/no-network")!)
        _ = try await guarded.data(for: request)
        lease.cancel()
        do { _ = try await guarded.data(for: request); XCTFail("Revoked source exported") }
        catch { XCTAssertEqual(error as? AIError, .cancelled) }
        XCTAssertEqual(transport.count, 1)
        let denied = ExteralessAIScopedTransport(base: transport, validate: { throw AIError.cancelled })
        do { _ = try await denied.data(for: request); XCTFail("Denied source exported") } catch {}
        XCTAssertEqual(transport.count, 1)
    }

    @MainActor func testCancellingRichTranslationDoesNotAdmitRemainingLeaves() async throws {
        let fixture = try AINativeUISettingsFixture()
        defer { fixture.close() }
        let five = expectation(description: "five pending leaves")
        let transport = AINativeLeafTransport(firstFive: { five.fulfill() })
        let client = AITranslationClient(transport: transport, settings: fixture.settings)
        var config = AITranslationConfiguration(settings: fixture.settings)
        config.provider = .google
        let source = page((0 ..< 7).map { .paragraph(.plain("cancel-leaf-\($0)")) })
        let task = Task { try await ExteralessAIRichTextTranslator.translate(page: source, client: client, to: "fr", configuration: config) }
        await fulfillment(of: [five], timeout: 3)
        task.cancel()
        transport.releaseAndCompleteFollowing()
        do { _ = try await task.value; XCTFail("Cancelled page was published") } catch {}
        XCTAssertEqual(transport.count, 5)
    }

    @MainActor func testSpeechMissingCredentialsNeverDecodesAndAppleUsesOnlyInjectedRecognizer() async throws {
        let fixture = try AINativeUISettingsFixture()
        defer { fixture.close() }
        let transport = AINativeCountingTransport(response: "{}")
        let speech = ExteralessSpeechService(transport: transport)
        let decoded = AINativeUICounter()
        speech.decodeAudio = { _, seconds in
            decoded.increment()
            XCTAssertEqual(seconds, 60)
            return try AIWaveFile.encode(pcm: Data([0, 0, 1, 0]), sampleRate: 48_000)
        }
        var config = AITranscriptionConfiguration(settings: fixture.settings)
        config.provider = .workersAI
        let url = fixture.root.appendingPathComponent("synthetic.ogg")
        do { _ = try await speech.transcribe(fileURL: url, locale: "en", configuration: config); XCTFail("Missing credentials succeeded") }
        catch { XCTAssertEqual(error as? ExteralessAITranscriptionError, .configuration) }
        XCTAssertEqual(decoded.value, 0)
        XCTAssertEqual(transport.count, 0)
        config.provider = .apple
        speech.recognitionOverride = { _, _ in "actual callback text" }
        let recognized = try await speech.transcribe(fileURL: url, locale: "en", configuration: config)
        XCTAssertEqual(recognized, "actual callback text")
        speech.recognitionOverride = { _, _ in throw ExteralessSpeechError.permission }
        do { _ = try await speech.transcribe(fileURL: url, locale: "en", configuration: config); XCTFail("Permission failure succeeded") }
        catch { XCTAssertTrue(error is ExteralessSpeechError) }
        XCTAssertEqual(transport.count, 0)
        XCTAssertEqual(decoded.value, 2)
    }

    @MainActor func testSpeechCloudProviderUsesActualResponseAndFailureIsNotSuccess() async throws {
        let fixture = try AINativeUISettingsFixture()
        defer { fixture.close() }
        let good = AINativeCountingTransport(response: #"{"success":true,"result":{"text":"worker transcript"}}"#)
        let speech = ExteralessSpeechService(transport: good)
        speech.decodeAudio = { _, seconds in
            XCTAssertEqual(seconds, 180)
            return try AIWaveFile.encode(pcm: Data([0, 0, 1, 0]), sampleRate: 48_000)
        }
        var config = AITranscriptionConfiguration(settings: fixture.settings)
        config.provider = .workersAI
        config.cloudflareAccountId = String(repeating: "a", count: 32)
        config.cloudflareToken = "fixture-key"
        let url = fixture.root.appendingPathComponent("synthetic.ogg")
        let recognized = try await speech.transcribe(fileURL: url, locale: "en", configuration: config)
        XCTAssertEqual(recognized, "worker transcript")
        XCTAssertEqual(good.count, 1)
        let bad = AINativeCountingTransport(response: #"{"success":false}"#)
        do { _ = try await speech.transcribe(fileURL: url, locale: "en", configuration: config, transport: bad); XCTFail("Provider failure succeeded") } catch {}
        XCTAssertEqual(bad.count, 1)
    }

    private func page(_ blocks: [InstantPageBlock]) -> InstantPage {
        InstantPage(blocks: blocks, media: [:], isComplete: true, rtl: false, url: "", views: nil)
    }
}

private final class AINativeCountingTransport: AIHTTPTransport, @unchecked Sendable {
    private let counter = AINativeUICounter()
    private let response: String
    var count: Int { counter.value }
    init(response: String) { self.response = response }
    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        counter.increment()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(status: 200, headers: ["content-type": "application/json"]))
            continuation.yield(.data(Data(response.utf8)))
            continuation.finish()
        }
    }
}

private final class AINativeLeafTransport: AIHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: AsyncThrowingStream<AIHTTPEvent, Error>.Continuation] = [:]
    private var requests = 0
    private var peak = 0
    private var completeFollowing = false
    private let firstFive: () -> Void
    init(firstFive: @escaping () -> Void) { self.firstFive = firstFive }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            lock.lock()
            requests += 1
            pending[id] = continuation
            peak = max(peak, pending.count)
            let announce = requests == 5
            let finishNow = completeFollowing
            lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in self?.remove(id) }
            if announce { firstFive() }
            if finishNow { finish(id, continuation) }
        }
    }
    func releaseAndCompleteFollowing() {
        lock.lock()
        completeFollowing = true
        let values = pending
        lock.unlock()
        for (id, continuation) in values { finish(id, continuation) }
    }
    private func remove(_ id: UUID) { lock.lock(); pending.removeValue(forKey: id); lock.unlock() }
    private func finish(_ id: UUID, _ continuation: AsyncThrowingStream<AIHTTPEvent, Error>.Continuation) {
        remove(id)
        continuation.yield(.response(status: 200, headers: ["content-type": "application/json"]))
        continuation.yield(.data(Data(#"{"sentences":[{"trans":"translated leaf"}]}"#.utf8)))
        continuation.finish()
    }
}

private final class AINativeUICounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private struct AINativeUISettingsFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-native-ui-" + UUID().uuidString)
    let settings: AISettings
    init() throws {
        settings = AISettings(store: try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: AINativeUIMemorySecrets()))
        try settings.register()
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}
private final class AINativeUIMemorySecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
}
