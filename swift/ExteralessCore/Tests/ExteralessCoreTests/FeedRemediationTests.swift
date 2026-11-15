import Foundation
import XCTest
@testable import ExteralessCore

private struct FeedRemediationSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { throw ClientSettingsError.secretAccessDenied }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretAccessDenied }
}

private final class FeedRemediationSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClientSettingsSnapshot] = []
    func append(_ value: ClientSettingsSnapshot) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [ClientSettingsSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

final class FeedRemediationTests: XCTestCase {
    private typealias Rect = FeedContentGeometry.Rect
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect { Rect(x: x, y: y, width: w, height: h) }

    func testBottom64AndCompact52BarsNeverAdmitCoveredPostOrTallAlbum() {
        let screen = rect(0, 0, 400, 800)
        let nativeViewport = rect(0, 88, 400, 630)
        for height in [64.0, 52.0] {
            let bar = rect(12, nativeViewport.maxY - height - 16, 376, height)
            let extra = FeedContentGeometry.additionalInsets(viewport: nativeViewport, occlusions: [bar])
            XCTAssertEqual(extra.bottom, height + 16)
            let viewport = rect(0, 88, 400, nativeViewport.height - extra.bottom)
            let covered = rect(12, bar.y + 4, 376, 40)
            XCTAssertFalse(FeedContentGeometry.admitsReceipt(post: covered, viewport: viewport, onScreen: screen, occlusions: [bar], active: true, positioned: true))
            let tallAlbum = rect(12, 0, 376, 1000)
            XCTAssertFalse(FeedContentGeometry.admitsReceipt(post: tallAlbum, viewport: viewport, onScreen: screen, occlusions: [bar], active: true, positioned: true))
            let uncovered = rect(12, bar.y - 45, 376, 40)
            XCTAssertTrue(FeedContentGeometry.admitsReceipt(post: uncovered, viewport: viewport, onScreen: screen, occlusions: [bar], active: true, positioned: true))
            let scrolledTall = rect(12, bar.y - 1000, 376, 1000)
            XCTAssertTrue(FeedContentGeometry.admitsReceipt(post: scrolledTall, viewport: viewport, onScreen: screen, occlusions: [bar], active: true, positioned: true))
        }
    }

    func testTopBarDuoSideBandAndKeyboardUseActualRectsWithoutDoubleInset() {
        let band = rect(0, 88, 300, 630)
        let topBar = rect(20, 94, 260, 52)
        let keyboard = rect(0, 500, 300, 300)
        let aboveKeyboard = rect(0, 88, 300, 412)
        let insets = FeedContentGeometry.additionalInsets(viewport: aboveKeyboard, occlusions: [topBar, keyboard])
        XCTAssertEqual(insets.top, 58)
        XCTAssertEqual(insets.bottom, 0, "Native keyboard inset is already excluded")
        let outsideDuoBand = rect(310, 88, 80, 100)
        XCTAssertEqual(FeedContentGeometry.additionalInsets(viewport: band, occlusions: [outsideDuoBand]).top, 0)
        XCTAssertFalse(FeedContentGeometry.admitsReceipt(post: rect(0, 480, 300, 40), viewport: aboveKeyboard, onScreen: rect(0, 0, 300, 800), occlusions: [keyboard], active: true, positioned: true))
    }

    func testOverlappingPublishersSubtractUnionAndMiddleOverlayBlocksTallReceipt() {
        let viewport = rect(0, 0, 100, 100)
        let first = rect(0, 40, 60, 20)
        let second = rect(40, 40, 60, 20)
        XCTAssertEqual(FeedContentGeometry.visibleArea(post: viewport, viewport: viewport, occlusions: [first, second]), 8000)
        XCTAssertFalse(FeedContentGeometry.admitsReceipt(post: rect(0, -100, 100, 300), viewport: viewport, onScreen: viewport, occlusions: [first, second], active: true, positioned: true))
        XCTAssertTrue(FeedContentGeometry.admitsReceipt(post: rect(0, -100, 100, 300), viewport: viewport, onScreen: viewport, occlusions: [], active: true, positioned: true))
    }

    func testRetentionIsGlobalAndEvictedPeersKeepReplayFrontiersWithoutBodies() {
        let entries = (1 ... 1800).map { number in
            ChatFeedEntry(position: ChatFeedPosition(timestamp: Int32(number), identity: .init(peerId: Int64(number % 90 + 1), namespace: 0, messageId: Int32(number))))
        }
        let retained = FeedPresentationPolicy.retention(entries: entries)
        XCTAssertLessThanOrEqual(retained.identities.count, 616)
        XCTAssertEqual(retained.reloads.count, 90)
        for (peer, reload) in retained.reloads {
            let lost = entries.filter { $0.identity.peerId == peer && !retained.identities.contains($0.identity) }
            XCTAssertEqual(reload.highestDiscarded, lost.map(\.position).max())
            if let before = reload.before { XCTAssertGreaterThan(before, reload.highestDiscarded) }
        }
        let onePerPeer = (1 ... 700).map { number in
            ChatFeedEntry(position: ChatFeedPosition(timestamp: Int32(number), identity: .init(peerId: Int64(number), namespace: 0, messageId: 1)))
        }
        let sparse = FeedPresentationPolicy.retention(entries: onePerPeer)
        XCTAssertLessThanOrEqual(sparse.identities.count, 616)
        XCTAssertEqual(sparse.reloads.count, 84)
        XCTAssertTrue(sparse.reloads.values.allSatisfy { $0.before == nil })
    }

    private func settings() throws -> ClientSettings {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-cas-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let settings = try ClientSettings(storageURL: directory.appendingPathComponent("settings.json"), secretStore: FeedRemediationSecrets())
        try settings.register(ChatFeatures.definitions.filter { FeedSettingsStore.keys.contains($0.key) })
        return settings
    }

    func testCompoundMembershipPublishesOneCompleteSnapshot() throws {
        let settings = try self.settings()
        let store = FeedSettingsStore(settings: settings)
        let observed = FeedRemediationSnapshots()
        let observer = settings.observe { _ in observed.append(settings.readSnapshot()) }
        defer { observer.cancel() }
        let before = settings.readSnapshot()
        var configuration = FeedSettingsStore.configuration(account: "A", snapshot: before)
        configuration.includeArchived = true
        configuration.setAddNewChannels(false, currentChannels: [1, 2, 3])
        configuration.setIncluded(2, included: false)
        try store.write(configuration, account: "A", expected: before)
        XCTAssertEqual(observed.read().count, 1)
        let snapshot = try XCTUnwrap(observed.read().first)
        XCTAssertEqual(FeedSettingsStore.configuration(account: "A", snapshot: snapshot), configuration)
        XCTAssertTrue(store.read(account: "A").includes(1, archived: true))
        XCTAssertFalse(store.read(account: "A").includes(4, archived: false))
    }

    func testConcurrentAccountEditFailsCASWithoutPartialKnownOrArchiveWrite() throws {
        let settings = try self.settings()
        let store = FeedSettingsStore(settings: settings)
        let stale = settings.readSnapshot()
        var a = FeedSettingsStore.configuration(account: "A", snapshot: stale)
        a.setIncluded(10, included: false)
        try store.write(a, account: "A", expected: stale)
        var b = FeedSettingsStore.configuration(account: "B", snapshot: stale)
        b.includeArchived = true
        b.setAddNewChannels(false, currentChannels: [30])
        XCTAssertThrowsError(try store.write(b, account: "B", expected: stale)) { error in
            XCTAssertEqual(error as? ClientSettingsError, .concurrentModification)
        }
        XCTAssertEqual(store.read(account: "A"), a)
        XCTAssertEqual(store.read(account: "B"), ChatFeedConfiguration())
        try store.write(b, account: "B", expected: settings.readSnapshot())
        XCTAssertEqual(store.read(account: "A"), a)
        XCTAssertEqual(store.read(account: "B"), b)
    }
}
