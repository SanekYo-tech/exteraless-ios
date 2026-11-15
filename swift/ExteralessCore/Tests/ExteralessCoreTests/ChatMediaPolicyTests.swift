import Foundation
import XCTest
@testable import ExteralessCore

final class ChatMediaPolicyTests: XCTestCase {
    func testLegacyMigrationUsesSourcePredicatesAndIsIdempotent() {
        let archive: [String: ClientSettingValue] = [
            "DisableChannelMuteButton": .bool(true), "OEChatsBottomButton": .integer(2),
            "HideReactions": .bool(true), "OEChatsHideReactionsPrivate": .bool(false),
            "MessageColoredBackground": .bool(false), "OEChatsReplyBackground": .bool(true),
            "DefaultHlsVideoQuality": .integer(1), "OEChatsPreferOriginalQuality": .bool(false),
            "unrelated": .object(["opaque": .array([.integer(7)])])
        ]
        let migrated = ChatLegacyPreferenceMigration.apply(to: archive)
        XCTAssertEqual(migrated["OEChatsBottomButton"], .integer(0))
        for key in ["OEChatsHideReactionsChannels", "OEChatsHideReactionsGroups", "OEChatsHideReactionsPrivate"] {
            XCTAssertEqual(migrated[key], .bool(true))
        }
        XCTAssertEqual(migrated["HideReactions"], .bool(false))
        XCTAssertEqual(migrated["OEChatsReplyBackground"], .bool(false))
        XCTAssertEqual(migrated["MessageColoredBackground"], .bool(true))
        XCTAssertEqual(migrated["OEChatsPreferOriginalQuality"], .bool(true))
        XCTAssertEqual(migrated["DefaultHlsVideoQuality"], .integer(0))
        XCTAssertEqual(migrated["unrelated"], archive["unrelated"])
        XCTAssertEqual(ChatLegacyPreferenceMigration.apply(to: migrated), migrated)
    }

    func testInactiveAliasesDoNotInventOverridesOrMigrateOtherQualityValues() {
        XCTAssertEqual(ChatLegacyPreferenceMigration.apply(to: [:]), [:])
        let inactive: [String: ClientSettingValue] = ["HideReactions": .bool(false), "MessageColoredBackground": .bool(true), "DefaultHlsVideoQuality": .integer(3)]
        XCTAssertEqual(ChatLegacyPreferenceMigration.apply(to: inactive), inactive)
        XCTAssertEqual(ChatLegacyPreferenceMigration.apply(to: ["OEChatsBottomButton": .integer(0)])["DisableChannelMuteButton"], .bool(true))
        let fields = Set(ChatFeatures.definitions.map(\.key))
        XCTAssertTrue(fields.isDisjoint(with: ["chats.hideReactions", "chats.messageColoredBackground", "chats.disableChannelMuteButton", "chats.unmuteWithVolumeButtons", "chats.disablePreviewVideoSoundShortcut"]))
    }

    func testStreamingQualityBandsFallThroughAndExplicitHighestWins() {
        let available = [360, 720, 1080, 2160]
        XCTAssertNil(ChatMediaPolicy.videoQuality(available: available, preferOriginal: false, defaultHls: 0))
        XCTAssertEqual(ChatMediaPolicy.videoQuality(available: available, preferOriginal: false, defaultHls: 2), 2160)
        XCTAssertEqual(ChatMediaPolicy.videoQuality(available: available, preferOriginal: false, defaultHls: 3), 1080)
        XCTAssertEqual(ChatMediaPolicy.videoQuality(available: available, preferOriginal: false, defaultHls: 4), 720)
        XCTAssertEqual(ChatMediaPolicy.videoQuality(available: available, preferOriginal: false, defaultHls: 5), 360)
        XCTAssertEqual(ChatMediaPolicy.videoQuality(available: [360, 720], preferOriginal: false, defaultHls: 2), 720)
        XCTAssertEqual(ChatMediaPolicy.videoQuality(available: available, preferOriginal: true, defaultHls: 5), 2160)
        XCTAssertNil(ChatMediaPolicy.videoQuality(available: [], preferOriginal: true, defaultHls: 1))
    }

    func testBackgroundPolicyResumesOnlyItsOwnPausedItemOnce() {
        var policy = ChatVideoBackgroundPolicy<String>()
        XCTAssertEqual(policy.update(foreground: false, enabled: true, identity: "A", playing: true, eligible: true), .pause)
        XCTAssertEqual(policy.update(foreground: false, enabled: true, identity: "A", playing: false, eligible: true), .none)
        XCTAssertEqual(policy.update(foreground: true, enabled: true, identity: "A", playing: false, eligible: true), .resume)
        XCTAssertEqual(policy.update(foreground: true, enabled: true, identity: "A", playing: false, eligible: true), .none)
        XCTAssertEqual(policy.update(foreground: false, enabled: true, identity: "A", playing: false, eligible: true), .none)
        XCTAssertEqual(policy.update(foreground: true, enabled: true, identity: "A", playing: false, eligible: true), .none)
        _ = policy.update(foreground: false, enabled: true, identity: "A", playing: true, eligible: true)
        XCTAssertEqual(policy.update(foreground: true, enabled: true, identity: "B", playing: false, eligible: true), .none)
        _ = policy.update(foreground: false, enabled: true, identity: "A", playing: true, eligible: true)
        XCTAssertEqual(policy.update(foreground: true, enabled: false, identity: "A", playing: false, eligible: true), .none)
    }

    func testSheetEligibilityKeepsPollVoiceAndTranslatedMessagePaths() {
        XCTAssertTrue(ChatMediaPolicy.translateInSheet(enabled: true, hasContent: true, poll: false, voice: false, alreadyTranslated: false))
        XCTAssertFalse(ChatMediaPolicy.translateInSheet(enabled: false, hasContent: true, poll: false, voice: false, alreadyTranslated: false))
        XCTAssertFalse(ChatMediaPolicy.translateInSheet(enabled: true, hasContent: true, poll: true, voice: false, alreadyTranslated: false))
        XCTAssertFalse(ChatMediaPolicy.translateInSheet(enabled: true, hasContent: true, poll: false, voice: true, alreadyTranslated: false))
        XCTAssertFalse(ChatMediaPolicy.translateInSheet(enabled: true, hasContent: true, poll: false, voice: false, alreadyTranslated: true))
    }
}
