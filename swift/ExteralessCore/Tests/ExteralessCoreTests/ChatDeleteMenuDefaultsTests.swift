import Foundation
import XCTest
@testable import ExteralessCore

final class ChatDeleteMenuDefaultsTests: XCTestCase {
    func testLinkedFlagsUpdateOneMaskAndPreserveUnknownBits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = try ClientSettings(storageURL: url)
        try settings.register(ChatFeatures.definitions)
        try settings.set(.integer(64), for: ChatDeleteMenuDefaults.key)
        try ChatDeleteMenuDefaults.set(.banUsers, enabled: true, in: settings)
        try ChatDeleteMenuDefaults.set(.deleteAll, enabled: true, in: settings)
        XCTAssertEqual(ChatDeleteMenuDefaults.current(in: settings).rawValue, 74)
        try ChatDeleteMenuDefaults.set(.banUsers, enabled: false, in: settings)
        let reopened = try ClientSettings(storageURL: url)
        try reopened.register(ChatFeatures.definitions)
        XCTAssertEqual(ChatDeleteMenuDefaults.current(in: reopened).rawValue, 66)
    }
    func testDefaultSnapshotDoesNotOverwriteLaterUserChoices() {
        let defaults = ChatDeleteMenuDefaults(rawValue: 15)
        var choice = defaults
        choice = choice.setting(.commonGroups, enabled: false).setting(.reportSpam, enabled: false)
        XCTAssertTrue(defaults.contains(.commonGroups))
        XCTAssertFalse(choice.contains(.commonGroups))
        XCTAssertFalse(choice.contains(.reportSpam))
        XCTAssertTrue(choice.contains(.banUsers))
        XCTAssertTrue(choice.contains(.deleteAll))
    }
    func testCommonGroupActionsRequireRightsAndNativeHistorySupport() {
        XCTAssertEqual(ChatCommonGroupModerationPolicy.allowed(ban: true, restrict: false, clearHistory: true, cloudChannel: true, canBan: false, canDelete: false), [])
        XCTAssertEqual(ChatCommonGroupModerationPolicy.allowed(ban: true, restrict: false, clearHistory: true, cloudChannel: false, canBan: true, canDelete: true), [.ban])
        XCTAssertEqual(ChatCommonGroupModerationPolicy.allowed(ban: true, restrict: true, clearHistory: true, cloudChannel: true, canBan: true, canDelete: true), [.restrict, .clearHistory])
    }
}
