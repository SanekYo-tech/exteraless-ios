import Foundation
import XCTest
@testable import ExteralessCore

private struct DialogFixtureSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretStorageUnavailable }
}

private final class DialogFixtureWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let fail = armed
        armed = false
        lock.unlock()
        if fail { throw NSError(domain: "DialogFixture", code: 5) }
    }
}

final class DialogPolicyTests: XCTestCase {
    private struct Scope: Hashable {
        let account: Int64
        let testing: Bool
        let group: Int
        let filter: Int?
        init(_ account: Int64 = 1, testing: Bool = false, group: Int = 0, filter: Int? = nil) {
            self.account = account; self.testing = testing; self.group = group; self.filter = filter
        }
    }

    private struct Row: Equatable {
        let id: Int64
        let scope: Scope
        let pinned: Bool
        let unread: Int
        let muted: Bool
        let mention: Bool
        let reaction: Bool
        let title: String
        let draft: String
        init(_ id: Int64, scope: Scope = Scope(), pinned: Bool = false, unread: Int = 0, muted: Bool = false, mention: Bool = false, reaction: Bool = false, title: String = "", draft: String = "") {
            self.id = id; self.scope = scope; self.pinned = pinned; self.unread = unread; self.muted = muted
            self.mention = mention; self.reaction = reaction; self.title = title; self.draft = draft
        }
    }

    private func order(_ rows: [Row], enabled: Bool = true) -> [Row] {
        DialogOrderingPolicy.promoteUnread(rows, enabled: enabled, scope: { $0.scope }, isFixed: { $0.pinned }, isPriority: {
            DialogOrderingPolicy.isUnreadPriority(unreadCount: $0.unread, counterMuted: $0.muted, hasMentions: $0.mention, hasReactions: $0.reaction)
        })
    }

    func testOriginalPriorityAndPinnedDraftOrdering() {
        let rows = [
            Row(1, pinned: true), Row(2, pinned: true, unread: 4),
            Row(3, draft: "newer native draft"), Row(4, unread: 30, muted: true),
            Row(5, muted: true, mention: true), Row(6, muted: true, reaction: true),
            Row(7, unread: 1), Row(8, title: "manual unread dot"), Row(9, unread: 2)
        ]
        XCTAssertEqual(order(rows).map(\.id), [1, 2, 5, 6, 7, 9, 3, 4, 8])
        XCTAssertEqual(order(rows, enabled: false), rows)
        XCTAssertEqual(order(rows).first(where: { $0.id == 3 })?.draft, "newer native draft")
        XCTAssertFalse(DialogOrderingPolicy.isUnreadPriority(unreadCount: 0, counterMuted: false, hasMentions: false, hasReactions: false))
        XCTAssertFalse(DialogOrderingPolicy.isUnreadPriority(unreadCount: 0, counterMuted: false, hasMentions: true, hasReactions: false, isMonoforum: true))
        XCTAssertTrue(DialogOrderingPolicy.isUnreadPriority(unreadCount: 0, counterMuted: true, hasMentions: false, hasReactions: true, isMonoforum: true))
    }

    func testAccountEnvironmentArchiveAndFilterIdsRemainIndependent() {
        let scopes = [Scope(), Scope(2), Scope(testing: true), Scope(group: 1), Scope(filter: 7), Scope(filter: 8)]
        let rows = scopes.flatMap { scope in
            [Row(77, scope: scope, pinned: true), Row(88, scope: scope, title: "Я / العربية"), Row(99, scope: scope, unread: 1, title: "A")]
        }
        let result = order(rows)
        for scope in scopes {
            XCTAssertEqual(result.filter { $0.scope == scope }.map(\.id), [77, 99, 88])
        }
        XCTAssertEqual(result.map(\.scope), rows.map(\.scope))
        XCTAssertEqual(result.filter(\.pinned), rows.filter(\.pinned))
        XCTAssertEqual(Set(result.map(\.title)), Set(rows.map(\.title)))
    }

    func testEveryNativeIdentityCanBeReachedAcrossOrderedWindows() {
        let rows = (0 ..< 250).map { Row(Int64($0), pinned: $0 < 4, unread: $0 == 220 ? 1 : 0) }
        let sorted = order(rows)
        XCTAssertEqual(Array(sorted.prefix(6)).map(\.id), [0, 1, 2, 3, 220, 4])
        var visited = Set<Int64>()
        var anchor: Int? = nil
        for _ in 0 ..< 12 {
            let range = DialogOrderingPolicy.window(totalCount: sorted.count, count: 50, anchorIndex: anchor)
            visited.formUnion(sorted[range].map(\.id))
            if range.upperBound == sorted.count { break }
            anchor = range.upperBound - 1
        }
        XCTAssertEqual(visited, Set(rows.map(\.id)))
        XCTAssertEqual(DialogOrderingPolicy.window(totalCount: 0, count: 80, anchorIndex: nil), 0 ..< 0)
        XCTAssertEqual(DialogOrderingPolicy.window(totalCount: 12, count: 80, anchorIndex: 11), 0 ..< 12)
    }

    func testPinsKeepNativeSlotsButNeverClaimExtraServerCapacity() {
        let local = [10, 20, 30, 40, 50, 60]
        let merged = DialogPinPolicy.preservingLocalPins(nativeResult: [20, 10, 30], currentLocal: local, enabled: true)
        XCTAssertEqual(merged, [20, 10, 30, 40, 50, 60])
        XCTAssertEqual(DialogPinPolicy.serverOrder(merged, serverLimit: 3), [20, 10, 30])
        XCTAssertEqual(DialogPinPolicy.preservingLocalPins(nativeResult: [20, 10, 30], currentLocal: local, enabled: false), [20, 10, 30])
        XCTAssertEqual(DialogPinPolicy.localRootLimit(enabled: true, serverRootLimit: 5, archiveLimit: 100), 100)
        XCTAssertEqual(DialogPinPolicy.localRootLimit(enabled: false, serverRootLimit: 5, archiveLimit: 100), 5)
        // Explicit unpin is absent from the current native order and stays absent.
        XCTAssertFalse(DialogPinPolicy.preservingLocalPins(nativeResult: [10, 20], currentLocal: [10, 20, 40], enabled: true).contains(30))
    }

    func testForumInheritFalseAndTrueAreThreeDifferentStates() throws {
        XCTAssertTrue(DialogForumLayout.inherit.usesTabs(nativeDefault: true))
        XCTAssertFalse(DialogForumLayout.list.usesTabs(nativeDefault: true))
        XCTAssertTrue(DialogForumLayout.tabs.usesTabs(nativeDefault: false))
        for layout in DialogForumLayout.allCases {
            XCTAssertEqual(try JSONDecoder().decode(DialogForumLayout.self, from: JSONEncoder().encode(layout)), layout)
        }
    }

    func testNavigationScopesArchivePrecedenceAndHashtagExplicitChoice() {
        let policy = DialogPolicy(values: ["appearance.hideArchive": .bool(true), "chats.openArchiveOnPull": .bool(true), "chats.doNotUnarchiveBySwipe": .bool(true), "chats.disableSwipeToNext": .bool(true), "chats.searchHashtagDefaultPageChat": .integer(1), "chats.searchHashtagDefaultPageChannel": .integer(2)])
        XCTAssertFalse(policy.opensArchiveAfterPull(isRootList: true, nativeHiddenRow: true, editing: false, searching: false))
        XCTAssertFalse(policy.allowsArchiveRowSwipe(isArchive: true, isPeer: true))
        XCTAssertTrue(policy.allowsArchiveRowSwipe(isArchive: false, isPeer: true))
        XCTAssertFalse(policy.allowsSwipeToNext(isTopic: false))
        XCTAssertTrue(policy.allowsSwipeToNext(isTopic: true))
        XCTAssertEqual(policy.initialHashtagPage(isPublicBroadcast: false, hasCurrentChat: true), .myMessages)
        XCTAssertEqual(policy.initialHashtagPage(isPublicBroadcast: true, hasCurrentChat: true), .publicPosts)
        XCTAssertEqual(policy.initialHashtagPage(isPublicBroadcast: true, hasCurrentChat: true, explicit: .thisChat), .thisChat)
        XCTAssertEqual(DialogPolicy().initialHashtagPage(isPublicBroadcast: false, hasCurrentChat: false), .myMessages)
        XCTAssertNil(DialogPolicy().backBadge("12", entryPointAllowsBadge: true))
        XCTAssertNil(DialogPolicy(values: ["chats.unreadBadgeOnBackButton": .bool(true)]).backBadge("12", entryPointAllowsBadge: false))
    }

    func testReturnHistoryBelongsToItsNativeThreadOwner() {
        struct NativeReference: Equatable { let account: Int; let thread: Int64; let message: Int32 }
        var first = DialogHistoryStack<NativeReference>()
        var second = DialogHistoryStack<NativeReference>()
        first.add(NativeReference(account: 1, thread: 10, message: 100), rememberAll: true)
        first.add(NativeReference(account: 1, thread: 10, message: 200), rememberAll: true)
        second.add(NativeReference(account: 2, thread: 20, message: 100), rememberAll: true)
        first.prune(rememberAll: true, where: { _ in true })
        XCTAssertEqual(first.pop(rememberAll: true)?.message, 200)
        XCTAssertEqual(first.pop(rememberAll: true)?.thread, 10)
        XCTAssertEqual(second.pop(rememberAll: true)?.account, 2)
        first.add(NativeReference(account: 1, thread: 10, message: 1), rememberAll: true)
        first.add(NativeReference(account: 1, thread: 10, message: 2), rememberAll: false)
        XCTAssertEqual(first.pop(rememberAll: false)?.message, 2)
        XCTAssertTrue(first.isEmpty)
    }

    func testDurableRollbackRestoresAbsentOverridesAndUnknownFixtureState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dialog-policy-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let unrelated: [String: ClientSettingValue] = ["fixture.draft": .string("unchanged 😀 draft"), "fixture.readState": .integer(108)]
        try JSONEncoder().encode(unrelated).write(to: url)
        let fault = DialogFixtureWriteFault()
        let settings = try ClientSettings(storageURL: url, secretStore: DialogFixtureSecrets(), afterFileReplace: { try fault.check() })
        try settings.register(DialogFeatures.definitions)
        let before = settings.readSnapshot()
        let change: [String: ClientSettingValue] = ["chats.sortByUnread": .bool(true), "appearance.hideArchive": .bool(true)]
        let committed = ClientSettingsSnapshot(definitions: before.definitions, values: before.values.merging(change) { _, new in new }, storedKeys: before.storedKeys.union(change.keys))
        fault.arm()
        XCTAssertThrowsError(try settings.applyPublic(change, expected: before))
        XCTAssertTrue(DialogPolicy(values: settings.snapshot()).sortByUnread) // rename committed despite the durability error
        try settings.applyPublic([:], resetting: Set(change.keys), expected: committed)
        XCTAssertFalse(DialogPolicy(values: settings.snapshot()).sortByUnread)
        XCTAssertFalse(settings.readSnapshot().storedKeys.contains("chats.sortByUnread"))
        let document = try JSONDecoder().decode([String: ClientSettingValue].self, from: Data(contentsOf: url))
        guard case let .object(values) = document["values"] else { return XCTFail("Missing settings document") }
        for (key, value) in unrelated { XCTAssertEqual(values[key], value) }
        XCTAssertFalse(DialogFeatures.definitions.contains(where: { $0.androidSymbols.contains("NekoConfig.sortByUnread") }))
    }
}
