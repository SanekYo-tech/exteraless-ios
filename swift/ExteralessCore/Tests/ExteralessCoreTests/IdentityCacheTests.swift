import Foundation
import XCTest
@testable import ExteralessCore

final class IdentityCacheTests: XCTestCase {
    func testAccountLifetimeRejectsRetiredAndOutOfOrderPublications() throws {
        let cache = IdentityPresentationCache()
        let a = IdentityAccountId(recordId: 1, userId: 10, testingEnvironment: false)
        let b = IdentityAccountId(recordId: 2, userId: 10, testingEnvironment: false)
        let la = try cache.begin(account: a)
        let lb = try cache.begin(account: b)
        var first = IdentityAccountState(ownerUserId: 10, testingEnvironment: false)
        let peer = IdentityPeerKey(kind: .user, id: 11)
        try first.setAlias("A", for: peer)
        XCTAssertTrue(try cache.publish(first, lease: la, sequence: 1))
        XCTAssertNil(cache.snapshot(account: b))
        var second = first
        try second.setAlias("B", for: peer)
        XCTAssertTrue(try cache.publish(second, lease: la, sequence: 3))
        XCTAssertFalse(try cache.publish(first, lease: la, sequence: 2))
        let revision = cache.revision
        XCTAssertFalse(try cache.publish(second, lease: la, sequence: 4))
        XCTAssertEqual(revision, cache.revision)
        XCTAssertTrue(cache.end(la))
        let renewed = try cache.begin(account: a)
        XCTAssertFalse(try cache.publish(first, lease: la, sequence: 100))
        XCTAssertFalse(cache.end(la))
        XCTAssertTrue(cache.isCurrent(renewed))
        XCTAssertTrue(try cache.publish(first, lease: lb, sequence: 1))
        XCTAssertNil(cache.snapshot(account: a))
        XCTAssertEqual(cache.snapshot(account: b)?.alias(for: peer), "A")
        cache.end(lb); cache.end(renewed)
    }

    func testThreadedReadersSeeCoherentSnapshots() throws {
        let cache = IdentityPresentationCache()
        let owner = IdentityAccountId(recordId: 1, userId: 10, testingEnvironment: false)
        let lease = try cache.begin(account: owner)
        let a = IdentityPeerKey(kind: .user, id: 1), b = IdentityPeerKey(kind: .user, id: 2)
        final class Failures: @unchecked Sendable {
            let lock = NSLock()
            private var count = 0
            func record() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            if index % 2 == 0 {
                var state = IdentityAccountState(ownerUserId: 10, testingEnvironment: false)
                do {
                    try state.setAlias(String(index), for: a)
                    try state.setAlias(String(index), for: b)
                    _ = try cache.publish(state, lease: lease, sequence: UInt64(index + 1))
                } catch { failures.record() }
            } else if let state = cache.snapshot(account: owner), state.alias(for: a) != state.alias(for: b) {
                failures.record()
            }
        }
        XCTAssertEqual(failures.value, 0)
        cache.end(lease)
        XCTAssertNil(cache.snapshot(account: owner))
    }

    func testQueuedEditorPermitIsPinnedAndRetiredOnAccountSwitch() throws {
        let owner = IdentityAccountId(recordId: 1, userId: 10, testingEnvironment: false)
        let permit = IdentityEditPermit(account: owner)
        XCTAssertNoThrow(try permit.check(owner: owner))
        XCTAssertThrowsError(try permit.check(owner: .init(recordId: 2, userId: 10, testingEnvironment: false)))
        permit.invalidate()
        XCTAssertThrowsError(try permit.check(owner: owner))
    }
}
