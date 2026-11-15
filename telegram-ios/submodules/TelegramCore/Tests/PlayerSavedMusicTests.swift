import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox
@testable import TelegramCore

/// FPP-06: real in-memory Postbox + canned acknowledgements at the shipping
/// commit seam. No Account, Network, ProfileSavedMusicContext or media fetch.
final class PlayerSavedMusicTests: XCTestCase {
    func testIDsOnlyCacheObservesSuccessfulSaveAndRemoveWithoutProfilePage() throws {
        let db = try PlayerSavedMusicPostboxFixture(ids: [7])
        defer { db.close() }
        XCTAssertEqual(try db.ids(), Set([7]))
        XCTAssertTrue(try db.mutate(saved: true, request: .single(true)))
        let afterSave = try XCTUnwrap(db.ids())
        XCTAssertEqual(afterSave, Set([7, 42]))
        XCTAssertFalse(!afterSave.contains(42), "Next action must be Remove")
        XCTAssertTrue(try db.mutate(saved: false, request: .single(true)))
        let afterRemove = try XCTUnwrap(db.ids())
        XCTAssertEqual(afterRemove, Set([7]))
        XCTAssertTrue(!afterRemove.contains(42), "Next action must be Save")
    }

    func testFailedFalseAndMissingAcknowledgementsLeaveIDsUntouched() throws {
        let db = try PlayerSavedMusicPostboxFixture(ids: [7])
        defer { db.close() }
        let failed: [Signal<Bool, AddSavedMusicError>] = [.fail(.generic), .single(false), .complete()]
        for request in failed {
            XCTAssertFalse(try db.mutate(saved: true, request: request))
            XCTAssertEqual(try db.ids(), Set([7]))
        }
        XCTAssertTrue(try db.mutate(saved: true, request: .single(true)))
        XCTAssertFalse(try db.mutate(saved: false, request: .fail(.generic)))
        XCTAssertEqual(try db.ids(), Set([7, 42]))
    }

    func testPendingAndCancelledOperationDoesNotPublishOptimisticIDs() throws {
        let db = try PlayerSavedMusicPostboxFixture(ids: [7])
        defer { db.close() }
        var source: Subscriber<Bool, AddSavedMusicError>?
        var cancelled = false
        let request = Signal<Bool, AddSavedMusicError> { subscriber in
            source = subscriber
            return ActionDisposable { cancelled = true }
        }
        let operation = db.operation(saved: true, request: request).start(error: { _ in XCTFail("Cancelled operation emitted") }, completed: { XCTFail("Cancelled operation completed") })
        XCTAssertEqual(try db.ids(), Set([7]))
        operation.dispose()
        XCTAssertTrue(cancelled)
        source?.putNext(true)
        source?.putCompletion()
        XCTAssertEqual(try db.ids(), Set([7]))
    }

    func testRepeatedSaveIsIdempotentAndUnknownIDListRemainsUnknown() throws {
        let db = try PlayerSavedMusicPostboxFixture(ids: [7, 42])
        defer { db.close() }
        XCTAssertTrue(try db.mutate(saved: true, request: .single(true)))
        XCTAssertTrue(try db.mutate(saved: true, request: .single(true)))
        XCTAssertEqual(try db.ids(), Set([7, 42]))
        let unknown = try PlayerSavedMusicPostboxFixture(ids: nil)
        defer { unknown.close() }
        XCTAssertTrue(try unknown.mutate(saved: true, request: .single(true)))
        XCTAssertNil(try unknown.ids(), "One successful mutation cannot fabricate the account's entire unknown list")
    }
}

private enum PlayerSavedMusicFixtureError: Error { case timeout }

private final class PlayerSavedMusicPostboxFixture {
    private let queue = Queue(name: "PlayerSavedMusicFixture")
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("player-saved-music-" + UUID().uuidString)
    private let peer = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(700042))
    private var valueBox: SqliteValueBox?
    private var postbox: Postbox!

    init(ids: [Int64]?) throws {
        initializeAccountManagement()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("db"), withIntermediateDirectories: true)
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("Saved music fixture attempted a media/network fetch"); return .fail(.generic) }
        if let ids {
            _ = try value(postbox.transaction { transaction -> Bool in
                transaction.setPreferencesEntry(key: PreferencesKeys.savedMusicIds(), value: PreferencesEntry(SavedMusicIdsList(items: ids)))
                return true
            })
        }
    }

    func ids() throws -> Set<Int64>? { try value(_internal_savedMusicIds(postbox: postbox) |> take(1)) }

    func operation(saved: Bool, request: Signal<Bool, AddSavedMusicError>) -> Signal<Never, AddSavedMusicError> {
        let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: 42), partialReference: nil, resource: LocalFileMediaResource(fileId: 42), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "audio/mpeg", size: 4, attributes: [.Audio(isVoice: false, duration: 60, title: "Fixture", performer: "Fixture", waveform: nil)], alternativeRepresentations: [])
        return _internal_commitSavedMusicUpdate(postbox: postbox, accountPeerId: peer, file: .standalone(media: file), afterFile: nil, isSaved: saved, request: request)
    }

    func mutate(saved: Bool, request: Signal<Bool, AddSavedMusicError>) throws -> Bool {
        let done = DispatchSemaphore(value: 0)
        var success = false
        let disposable = operation(saved: saved, request: request).start(error: { _ in done.signal() }, completed: { success = true; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 1) == .success else { throw PlayerSavedMusicFixtureError.timeout }
        return success
    }

    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        let disposable = signal.start(next: { result = $0; done.signal() })
        defer { disposable.dispose() }
        guard done.wait(timeout: .now() + 1) == .success else { throw PlayerSavedMusicFixtureError.timeout }
        return try XCTUnwrap(result)
    }

    func close() {
        _ = try? value(postbox.mediaBox.storageBox.totalSize())
        postbox = nil
        queue.sync { self.valueBox = nil }
        try? FileManager.default.removeItem(at: root)
    }
}
