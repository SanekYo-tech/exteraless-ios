import Foundation
import SwiftSignalKit
import XCTest
@testable import Postbox

final class MediaBoxRetentionKeepTests: XCTestCase {
    func testTwoKeepLeasesProtectTheWholeNativeInodeGroupUntilLastRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retention-keep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("resource")
        let alias = directory.appendingPathComponent("resource.jpg")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)
        let gate = MediaBoxResourceKeepGate()
        let a = gate.keep("resource"), b = gate.keep("resource")
        let remove = {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: alias)
        }
        XCTAssertFalse(gate.evictIfUnkept(paths: [alias.path, original.path], root: directory.path, remove: remove))
        a.dispose()
        XCTAssertFalse(gate.evictIfUnkept(paths: [alias.path], root: directory.path, remove: remove))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        b.dispose()
        XCTAssertTrue(gate.evictIfUnkept(paths: [alias.path, original.path], root: directory.path, remove: remove))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
    }

    func testDerivedCacheDoesNotBecomeAnUnboundedPinnedArchive() {
        let gate = MediaBoxResourceKeepGate()
        let lease = gate.keep("resource")
        defer { lease.dispose() }
        var removed = false
        XCTAssertTrue(gate.evictIfUnkept(paths: ["/fixture/media/cache/resource:decoded"], root: "/fixture/media", remove: { removed = true }))
        XCTAssertTrue(removed)
        XCTAssertFalse(gate.evictIfUnkept(paths: ["/fixture/media/resource_partial.meta"], root: "/fixture/media", remove: { XCTFail("a kept partial was removed") }))
        let dotted = gate.keep("resource.with.dots")
        defer { dotted.dispose() }
        XCTAssertFalse(gate.evictIfUnkept(paths: ["/fixture/media/resource.with.dots.jpg"], root: "/fixture/media", remove: { XCTFail("a dotted ID alias was removed") }))
    }
}
