import Foundation
import XCTest
@testable import ExteralessCore

/// Pins the actual admitted Cloud preview/apply path supplied in chat-swipe-cloud.patch.
final class ChatSwipeLegacyImportTests: XCTestCase {
    private func settings(register: Bool = true) throws -> ClientSettings {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = try ClientSettings(storageURL: url.appendingPathComponent("settings.json"), secretStore: CloudFixtureSecrets())
        if register { try result.register(ChatSwipeFeatures.definitions) }
        return result
    }

    private func preview(_ value: ClientSettingValue, settings: ClientSettings) throws -> CloudLegacyRestorePlan {
        let bytes = try CloudProtocol.encode(["mainconfig": ClientSettingValue.object([
            "ChatSwipeAction": value, "fontSize": .integer(21), "unknownFutureKey": .bool(true)
        ])])
        let remote = CloudLegacyRemoteSnapshot(owner: CloudFixture.owner, fingerprint: ToolsSHA256.hex(bytes), reportedUpdatedAtMilliseconds: nil, data: bytes)
        return try CloudLegacySettingsArchive.inspect(remote, snapshot: settings.readSnapshot(), includeApiKeys: false, date: CloudFixture.date)
    }

    func testOnlyTheExactPortableFieldEntersPreviewAndAtomicPublicApply() throws {
        let store = try settings()
        for value in -1 ... 5 {
            let plan = try preview(.integer(Int64(value)), settings: store)
            XCTAssertEqual(plan.publicInspection.settings, [ChatSwipePolicy.settingKey: .integer(Int64(value))])
            XCTAssertEqual(plan.publicInspection.payload.clientSettings, plan.publicInspection.settings)
            XCTAssertEqual(plan.publicInspection.payload.clientStoredKeys, [ChatSwipePolicy.settingKey])
            XCTAssertTrue(plan.mapped.contains { $0.originalIDs == ["etgbackup.ChatSwipeAction"] && $0.nativeKeys == [ChatSwipePolicy.settingKey] })
            XCTAssertTrue(plan.skipped.contains { $0.sourcePreference == "mainconfig.fontSize" })
            XCTAssertTrue(plan.skipped.contains { $0.sourcePreference == "mainconfig.unknownFutureKey" })
            _ = try CloudLegacySettingsArchive.apply(plan, settings: store, includeApiKeys: false, credentials: CloudFixtureSecrets())
            XCTAssertEqual(ChatSwipePolicy.current(in: store), value)
        }
    }

    func testWrongTypeUnsupportedValueAndUnregisteredDestinationAreNotAdmitted() throws {
        let store = try settings()
        for value in [ClientSettingValue.bool(true), .string("2"), .number(2.5), .integer(9), .null] {
            let plan = try preview(value, settings: store)
            XCTAssertTrue(plan.publicInspection.settings.isEmpty)
            XCTAssertTrue(plan.skipped.contains { $0.originalIDs == ["etgbackup.ChatSwipeAction"] })
        }
        let missing = try preview(.integer(0), settings: settings(register: false))
        XCTAssertTrue(missing.publicInspection.settings.isEmpty)
        XCTAssertTrue(missing.skipped.contains { $0.originalIDs == ["etgbackup.ChatSwipeAction"] && $0.reason == .nativeUnavailable })
    }
}
