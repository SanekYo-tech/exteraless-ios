import ExteralessCore
import Foundation
import PluginHost
import XCTest

/// Compile with PluginPillIdentityArchive.swift + PluginPillWire.swift in the native contract target.
/// These fixtures use only disposable local files and DTOs, never a plugin interpreter or provider network.
final class PluginPillContractsTests: XCTestCase {
    private func archiveURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-pill-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("identities.json")
    }

    func testPersistedMappingSurvivesRestartAndReversedLoadOrder() throws {
        let url = try self.archiveURL()
        let first = try PluginPillIdentityArchive(url: url)
        let alpha = try first.resolve(pluginId: "Alpha", androidId: 910, reserving: [10_000, 10_001, 100])
        let beta = try first.resolve(pluginId: "Beta", androidId: 910, reserving: [])
        XCTAssertEqual(alpha.nativeId, 10_002)
        XCTAssertNotEqual(alpha.nativeId, beta.nativeId)
        let restarted = try PluginPillIdentityArchive(url: url)
        XCTAssertEqual(try restarted.resolve(pluginId: "Beta", androidId: 910, reserving: []), beta)
        XCTAssertEqual(try restarted.resolve(pluginId: "Alpha", androidId: 910, reserving: [Int(alpha.nativeId)]), alpha)
        XCTAssertEqual(try restarted.identities(pluginId: "Alpha"), [alpha])
    }

    func testOriginalInt32ExtremesDoNotOffsetOverflowOrAlias() throws {
        let archive = try PluginPillIdentityArchive(url: self.archiveURL())
        let small = try archive.resolve(pluginId: "SamePlugin", androidId: Int32.min, reserving: [])
        let large = try archive.resolve(pluginId: "SamePlugin", androidId: Int32.max, reserving: [])
        XCTAssertGreaterThanOrEqual(small.nativeId, 10_000)
        XCTAssertGreaterThan(large.nativeId, small.nativeId)
        XCTAssertEqual(small.androidId, Int32.min)
        XCTAssertEqual(large.androidId, Int32.max)
    }

    func testCorruptArchiveIsPreservedAndIdentityNeverRegenerated() throws {
        let url = try self.archiveURL()
        let archive = try PluginPillIdentityArchive(url: url)
        _ = try archive.resolve(pluginId: "Alpha", androidId: 900, reserving: [])
        let corrupt = Data("{not-valid-json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try archive.resolve(pluginId: "Alpha", androidId: 900, reserving: []))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testIndependentArchiveWritersMergeAndNeverReuseDormantIdentity() throws {
        let url = try self.archiveURL()
        let one = try PluginPillIdentityArchive(url: url)
        let two = try PluginPillIdentityArchive(url: url)
        let original = try one.resolve(pluginId: "Alpha", androidId: 901, reserving: [])
        let other = try two.resolve(pluginId: "Beta", androidId: 902, reserving: [])
        let later = try one.resolve(pluginId: "Alpha", androidId: 903, reserving: [])
        XCTAssertEqual(Set([original.nativeId, other.nativeId, later.nativeId]).count, 3)
        XCTAssertEqual(try two.identities(pluginId: "Alpha"), [original, later])
    }

    func testWireRejectsBuiltinOverrideBooleanIDsAndReusedCallbacks() throws {
        XCTAssertThrowsError(try PluginPillDescriptor(.object(["androidId": .integer(5), "title": .string("Override")])))
        XCTAssertThrowsError(try PluginPillDescriptor(.object(["androidId": .bool(true), "title": .string("Bad")])))
        let zeroInterval = try PluginPillDescriptor(.object(["androidId": .integer(900), "title": .string("Test"), "refreshIntervalMs": .integer(0)]))
        XCTAssertEqual(zeroInterval.refreshIntervalMs, 0)
        let fast = try PluginPillDescriptor(.object(["androidId": .integer(901), "title": .string("Test"), "refreshIntervalMs": .integer(100)]))
        XCTAssertEqual(fast.refreshIntervalMs, 5000)
        let handle: PluginJSONValue = .object(["__handle__": .integer(9_007_199_254_740_993)])
        XCTAssertThrowsError(try PluginPillWire.callbacks(.object(["update": handle, "tap": handle])))
        XCTAssertEqual(try PluginPillWire.callbacks(.object(["update": handle]))["update"], 9_007_199_254_740_993)
    }

    func testModelRequiresSelectionAndCannotChangeNativeID() throws {
        let descriptor = try PluginPillDescriptor(.object(["androidId": .integer(900), "title": .string("Test")]))
        let selection = UUID()
        let (_, value) = try PluginPillWire.model(.object([
            "selection": .string(selection.uuidString), "value": .string("12 MB"), "updatedAtMs": .integer(1_234_000)
        ]), nativeId: 10_000, descriptor: descriptor, pluginId: "Alpha")
        XCTAssertEqual(value.id, 10_000)
        XCTAssertEqual(value.updatedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertThrowsError(try PluginPillWire.model(.object(["value": .string("old")]), nativeId: 10_000, descriptor: descriptor, pluginId: "Alpha"))
        XCTAssertThrowsError(try PluginPillWire.model(.object(["selection": .string(selection.uuidString), "value": .string("bad"), "id": .integer(5)]), nativeId: 10_000, descriptor: descriptor, pluginId: "Alpha"))
    }

    func testSanitizedLayoutPreservesDormantSlotsWithoutChangingRequestedKnownOrder() {
        let previous = PillLayout(active: [5, 12_345, 6], hidden: [91_234, 900])
        let requested = PillLayout(active: [6, 5], hidden: [900], selected: 6, loop: false)
        let result = PluginPillWire.preservingDormant(requested, previous: previous, available: [5, 6, 900])
        XCTAssertEqual(result.active, [6, 12_345, 5])
        XCTAssertEqual(result.hidden, [900, 91_234])
        XCTAssertEqual(result.selected, 6)
        XCTAssertFalse(result.loop)
    }
}
