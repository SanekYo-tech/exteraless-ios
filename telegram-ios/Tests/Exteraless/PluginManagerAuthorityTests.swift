import Foundation
import XCTest

private final class ManagerAuthorityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func revoke() { lock.lock(); allowed = false; lock.unlock() }
}

/// Uses the production preferences writer. No Host, interpreter, Account or
/// Keychain is created; the captured authority stands in for owner/grant state.
final class PluginManagerAuthorityTests: XCTestCase {
    private func fixture() throws -> (PluginManagerPreferences, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("manager.json")
        return (try PluginManagerPreferences(url: file), file)
    }

    func testRevokedPinnedSetPreservesEveryValueAndTheExistingFile() throws {
        let (store, file) = try fixture()
        try store.apply(.pinned("cc", true))
        try store.apply(.pinned("future", true))
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.apply(.pinnedSet(wanted: ["aa", "bb"], installed: ["aa", "bb", "cc"]),
                                             isCurrent: { false })) { error in
            XCTAssertEqual((error as? PluginUIFailure)?.kind, "InvalidHandle")
        }
        XCTAssertEqual(store.snapshot.pinned, ["cc", "future"])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testOneAdmittedPinnedSetCompletesAtomicallyAndPreservesUninstalledEntries() throws {
        let (store, file) = try fixture()
        try store.apply(.pinned("cc", true))
        try store.apply(.pinned("future", true))
        var checks = 0
        var allowed = true
        try store.apply(.pinnedSet(wanted: ["aa", "bb", "notInstalled"], installed: ["aa", "bb", "cc"]), isCurrent: {
            checks += 1
            defer { allowed = false }
            return allowed
        })
        // A per-ID sequence would lose authority before its second write.
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(allowed)
        XCTAssertEqual(store.snapshot.pinned, ["aa", "bb", "future"])
        XCTAssertEqual(try PluginManagerPreferences(url: file).snapshot, store.snapshot)
    }

    func testQueuedPreferenceWriterRechecksAuthorityAfterTheAsyncHop() async throws {
        let (store, file) = try fixture()
        let before = try Data(contentsOf: file)
        let changes: [PluginManagerPreferenceChange] = [
            .pinnedSet(wanted: ["aa", "bb"], installed: ["aa", "bb"]), .compact(true), .developer(true)
        ]
        for change in changes {
            let gate = DispatchSemaphore(value: 0)
            let authority = ManagerAuthorityFlag()
            let write = Task.detached {
                guard gate.wait(timeout: .now() + 2) == .success else {
                    throw PluginUIFailure.unavailable("Bounded fixture gate expired")
                }
                try store.apply(change, isCurrent: { authority.isCurrent })
            }
            authority.revoke()
            gate.signal()
            do {
                try await write.value
                XCTFail("A revoked queued writer must not publish preferences")
            } catch let error as PluginUIFailure {
                XCTAssertEqual(error.kind, "InvalidHandle")
            }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
        XCTAssertTrue(store.snapshot.pinned.isEmpty)
        XCTAssertFalse(store.snapshot.compactView)
        XCTAssertFalse(store.snapshot.developerMode)
    }
}
