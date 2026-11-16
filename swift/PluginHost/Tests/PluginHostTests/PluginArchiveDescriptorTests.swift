import Foundation
import XCTest
@testable import PluginHost

/// Actual POSIX descriptor and rename/symlink witnesses. No fake CPython engine
/// is used for these tests; Windows has an explicit unsupported archive backend.
final class PluginArchiveDescriptorTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let load = String(repeating: "b", count: 64) + "-" + String(repeating: "c", count: 32)

    private func fixture() throws -> (PluginServiceStorage, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-archive-fds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = PluginServiceStorage(rootDirectory: root)
        let cache = try storage.cacheDirectory(pluginId: "_archive")
        let tree = cache.appendingPathComponent("elyx/\(owner)/\(load)")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("contents"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: tree.appendingPathComponent("contents/main.py"))
        return (storage, root, cache, tree)
    }

    #if canImport(Darwin) || canImport(Glibc)
    func testPurgeKeepsUncapturedReplacementGenerationAndUnrelatedCache() throws {
        let (storage, _, cache, tree) = try fixture()
        let keep = cache.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        let lease = try storage.captureArchiveCache(pluginId: "_archive")
        let replacement = tree.deletingLastPathComponent().appendingPathComponent(String(repeating: "d", count: 64) + "-" + String(repeating: "e", count: 32))
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let marker = replacement.appendingPathComponent("keep.txt")
        try Data("replacement".utf8).write(to: marker)
        try lease.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        try lease.purge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCheckedParentSwapDuringCaptureFailsWithoutFollowingItsLink() throws {
        let (storage, root, _, tree) = try fixture()
        let target = tree.deletingLastPathComponent()
        let saved = root.appendingPathComponent("saved-owner")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt")
        try Data("outside".utf8).write(to: marker)
        let swapped = MaintenanceTestFlag(false)
        let hooks = PluginArchiveFileHooks { point, path in
            guard case .directoryOpened = point, path.path == target.path, !swapped.value else { return }
            swapped.set(true)
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
        XCTAssertThrowsError(try storage.captureArchiveCache(pluginId: "_archive", hooks: hooks))
        XCTAssertTrue(swapped.value)
        XCTAssertEqual(try Data(contentsOf: marker), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent(tree.lastPathComponent + "/contents/main.py").path))
    }

    func testParentSwapAfterCaptureCannotRedirectPurge() throws {
        let (storage, root, _, tree) = try fixture()
        let lease = try storage.captureArchiveCache(pluginId: "_archive")
        let target = tree.deletingLastPathComponent()
        let saved = root.appendingPathComponent("saved-owner")
        let outside = root.appendingPathComponent("outside")
        let marker = outside.appendingPathComponent(tree.lastPathComponent + "/contents/main.py")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("outside generation".utf8).write(to: marker)
        try FileManager.default.moveItem(at: target, to: saved)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertThrowsError(try lease.purge())
        XCTAssertEqual(try Data(contentsOf: marker), Data("outside generation".utf8))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent(tree.lastPathComponent + "/contents/main.py")), Data("original".utf8))
    }

    func testParentSwapAtUnlinkBarrierPreservesBothTrees() throws {
        let (storage, root, _, tree) = try fixture()
        let target = tree.deletingLastPathComponent()
        let saved = root.appendingPathComponent("saved-owner")
        let outside = root.appendingPathComponent("outside")
        let marker = outside.appendingPathComponent(tree.lastPathComponent + "/contents/main.py")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("outside generation".utf8).write(to: marker)
        let swapped = MaintenanceTestFlag(false)
        let hooks = PluginArchiveFileHooks { point, _ in
            guard case .beforeUnlink = point, !swapped.value else { return }
            swapped.set(true)
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
        let lease = try storage.captureArchiveCache(pluginId: "_archive", hooks: hooks)
        XCTAssertThrowsError(try lease.purge())
        XCTAssertTrue(swapped.value)
        XCTAssertEqual(try Data(contentsOf: marker), Data("outside generation".utf8))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent(tree.lastPathComponent + "/contents/main.py")), Data("original".utf8))
    }

    func testCapturedLeaseRejectsAReplacementFileInode() throws {
        let (storage, _, _, tree) = try fixture()
        let lease = try storage.captureArchiveCache(pluginId: "_archive")
        let file = tree.appendingPathComponent("contents/main.py")
        try Data("replacement".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try lease.purge())
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }

    func testNewFileAfterCaptureIsRetainedInsteadOfRecursivelyErased() throws {
        let (storage, _, _, tree) = try fixture()
        let lease = try storage.captureArchiveCache(pluginId: "_archive")
        let added = tree.appendingPathComponent("contents/keep.txt")
        try Data("new".utf8).write(to: added)
        try lease.purge()
        XCTAssertEqual(try Data(contentsOf: added), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.appendingPathComponent("contents/main.py").path))
    }

    func testRawOSPathUsesDescriptorAnchorIncludingDarwinRootAlias() throws {
        let raw = URL(fileURLWithPath: "/tmp/owned-archive-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let storage = PluginServiceStorage(rootDirectory: raw)
        let cache = try storage.cacheDirectory(pluginId: "12")
        let tree = cache.appendingPathComponent("elyx/\(owner)/\(load)")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: tree.appendingPathComponent("probe.txt"))
        try storage.captureArchiveCache(pluginId: "12").purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
    }
    #else
    func testUnsupportedPlatformDoesNotFallBackToPathRecursivePurge() throws {
        let (storage, _, _, tree) = try fixture()
        XCTAssertThrowsError(try storage.captureArchiveCache(pluginId: "_archive"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("contents/main.py").path))
    }
    #endif
}
