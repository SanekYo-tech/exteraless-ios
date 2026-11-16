import Foundation
import XCTest
@testable import PluginHost

final class PluginResourcePathTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOwnershipIsIndependentOfExistenceGrantsAndSiblingPrefixes() throws {
        let root = try directory()
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let owned = try PluginResourcePath(path: files.appendingPathComponent("absent.bin").path, allowedRoots: [files])
        XCTAssertFalse(owned.requiresFiles, "Classifying ownership must not open/read the resource")
        XCTAssertTrue(try PluginResourcePath(path: root.appendingPathComponent("files-sibling/absent.bin").path, allowedRoots: [files]).requiresFiles)
        XCTAssertTrue(try PluginResourcePath(path: files.path, allowedRoots: [files]).requiresFiles)
        XCTAssertThrowsError(try PluginResourcePath(path: "relative.bin", allowedRoots: [files]))
        XCTAssertThrowsError(try PluginResourcePath(path: "/bad\0name", allowedRoots: [files]))
        XCTAssertThrowsError(try PluginResourcePath(path: "/" + String(repeating: "a", count: 4096), allowedRoots: [files]))
    }

    #if !os(Windows)
    func testCanonicalSymlinkOwnershipAndRetargetRejectBeforeReading() throws {
        let root = try directory()
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("external.bin")
        let inside = files.appendingPathComponent("inside.bin")
        try Data([1]).write(to: outside)
        try Data([2]).write(to: inside)
        let alias = files.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertTrue(try PluginResourcePath(path: alias.path, allowedRoots: [files]).requiresFiles)
        let admitted = try PluginResourcePath(path: inside.path, allowedRoots: [files])
        XCTAssertFalse(admitted.requiresFiles)
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
        XCTAssertThrowsError(try admitted.validatedURL(), "A held own-root resource must not turn into an external read")
    }
    #endif
}
