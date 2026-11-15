import Foundation
import XCTest
@testable import ExteralessCore

final class AppearancePolicyTests: XCTestCase {
    func testAvatarFormulaAndForumRoundingOrder() {
        XCTAssertEqual(AppearanceAvatarPolicy(corners: 14).radius(size: 60), 15)
        XCTAssertEqual(AppearanceAvatarPolicy(corners: 14).radius(size: 60, kind: .forum), 10)
        XCTAssertEqual(AppearanceAvatarPolicy(corners: 14).radius(size: 60, kind: .forum, hasStories: true), 8)
        XCTAssertEqual(AppearanceAvatarPolicy(corners: 14, singleRadius: true).radius(size: 60, kind: .forum), 15)
        XCTAssertEqual(AppearanceAvatarPolicy(corners: -1).radius(size: 60), 0)
        XCTAssertEqual(AppearanceAvatarPolicy(corners: 100).radius(size: 60), 30)
        XCTAssertEqual(AppearanceAvatarPolicy().radius(size: .infinity), 0)
        XCTAssertEqual(AppearanceAvatarPolicy(corners: 0).onlineDotOffset(base: 3, radius: 8), 8 / sqrt(2), accuracy: 0.00001)
        XCTAssertTrue(AppearanceAvatarPolicy().preservesNativeShape)
        XCTAssertFalse(AppearanceAvatarPolicy(singleRadius: true).preservesNativeShape)
    }

    func testFullCountsDoNotLosePrecisionOrTrapOnMinimumInteger() {
        XCTAssertEqual(AppearanceNumberPolicy.fullNumberOverride(Int.min, disableRounding: true), String(Int.min))
        XCTAssertEqual(AppearanceNumberPolicy.fullNumberOverride(12345, disableRounding: true), "12345")
        XCTAssertNil(AppearanceNumberPolicy.fullNumberOverride(12345, disableRounding: false))
    }

    func testFolderCounterModesUseTheActualUnmutedCount() {
        XCTAssertEqual(AppearanceFolderPolicy.unreadCount(all: 30, unmuted: 7, mode: 0), 30)
        XCTAssertEqual(AppearanceFolderPolicy.unreadCount(all: 30, unmuted: 7, mode: 1), 7)
        XCTAssertEqual(AppearanceFolderPolicy.unreadCount(all: 30, unmuted: 7, mode: 2), 0)
        XCTAssertEqual(AppearanceFolderPolicy.unreadCount(all: 3, unmuted: 7, mode: 1), 3)
        XCTAssertEqual(AppearanceFolderPolicy.unreadCount(all: -1, unmuted: -2, mode: 0), 0)
    }

    func testFolderTitleEntityOffsetsAreUTF16AndDoNotLoseVoiceOverSource() {
        let prefix = AppearanceFolderPolicy.title("Work", mode: 2, allChats: false)
        XCTAssertEqual(prefix.text, "📁 Work")
        XCTAssertEqual(prefix.entityOffset, 3)
        XCTAssertEqual(prefix.originalLimit, 4)
        let emojiOnly = AppearanceFolderPolicy.title("🧑‍💻 Work", mode: 1, allChats: false)
        XCTAssertEqual(emojiOnly.text, "🧑‍💻")
        XCTAssertEqual(emojiOnly.originalLimit, "🧑‍💻".utf16.count)
        XCTAssertEqual(AppearanceFolderPolicy.title("2026", mode: 1, allChats: false).text, "📁")
        XCTAssertEqual(AppearanceFolderPolicy.title("Work", mode: 0, allChats: false).text, "Work")
        XCTAssertEqual(AppearanceFolderPolicy.title("All chats", mode: 1, allChats: true).text, "💬")
    }

    func testHeaderSelectionsAndMissingIdentityFallback() {
        XCTAssertEqual(AppearanceHeaderPolicy.title(mode: 1, custom: "X", appName: "exteraless", chatsTitle: "Chats", username: nil, displayName: "Name"), "Name")
        XCTAssertEqual(AppearanceHeaderPolicy.title(mode: 1, custom: "X", appName: "exteraless", chatsTitle: "Chats", username: "alice", displayName: "Name"), "alice")
        XCTAssertEqual(AppearanceHeaderPolicy.title(mode: 4, custom: "  One\nTwo  ", appName: "exteraless", chatsTitle: "Chats", username: nil, displayName: nil), "One Two")
        XCTAssertEqual(AppearanceHeaderPolicy.title(mode: 3, custom: "X", appName: "exteraless", chatsTitle: "Чаты", username: nil, displayName: nil), "Чаты")
    }

    func testRemovingATabPreservesControllerIdentityAndFallsBackToChats() {
        XCTAssertEqual(AppearanceTabPolicy.selectedIndex(current: "settings", visible: ["calls", "chats", "settings"], fallback: "chats"), 2)
        XCTAssertEqual(AppearanceTabPolicy.selectedIndex(current: "contacts", visible: ["calls", "chats", "settings"], fallback: "chats"), 1)
        XCTAssertNil(AppearanceTabPolicy.selectedIndex(current: "contacts", visible: [], fallback: "chats"))
    }

    func testSegmentedAndMaterialRowsForceSeparatedHeaders() {
        let segmented = AppearanceListPolicy(radius: 100, separateHeaders: false, dividerStyle: 2)
        XCTAssertTrue(segmented.separateHeaders)
        XCTAssertFalse(segmented.showsDividers)
        XCTAssertEqual(segmented.radius, 28)
        let material = AppearanceListPolicy(separateHeaders: false, dividerStyle: 1, materialRows: true)
        XCTAssertTrue(material.separateHeaders)
        XCTAssertFalse(material.showsDividers)
        XCTAssertEqual(material.minimumRowHeight(hasDetail: false), 56)
        XCTAssertEqual(material.minimumRowHeight(hasDetail: true), 72)
        XCTAssertTrue(AppearanceListPolicy().showsDividers)
    }

    func testSecondsRespectExplicitRequestsWhenPreferenceResets() {
        XCTAssertEqual(AppearanceTimePolicy.seconds(47, explicitlyRequested: false, showSeconds: true), 47)
        XCTAssertEqual(AppearanceTimePolicy.seconds(47, explicitlyRequested: true, showSeconds: false), 47)
        XCTAssertNil(AppearanceTimePolicy.seconds(47, explicitlyRequested: false, showSeconds: false))
    }

    func testChatThemeSuppressionRestoresBothSavedValues() {
        let savedTheme = "🌙"
        let savedWallpaper = "wallpaper-resource"
        let disabled = AppearanceChatThemePolicy.resolve(enabled: false, theme: savedTheme, wallpaper: savedWallpaper)
        XCTAssertNil(disabled.theme)
        XCTAssertNil(disabled.wallpaper)
        let restored = AppearanceChatThemePolicy.resolve(enabled: true, theme: savedTheme, wallpaper: savedWallpaper)
        XCTAssertEqual(restored.theme, savedTheme)
        XCTAssertEqual(restored.wallpaper, savedWallpaper)
    }

    func testRelativePresenceBoundariesAcrossMidnightAndReset() {
        XCTAssertEqual(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 59, enabled: true), .justNow)
        XCTAssertEqual(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 60, enabled: true), .minutes(1))
        XCTAssertEqual(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 3599, enabled: true), .minutes(59))
        XCTAssertEqual(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 3600, enabled: true), .hours(1))
        XCTAssertEqual(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 86399, enabled: true), .hours(23))
        XCTAssertNil(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 86400, enabled: true))
        XCTAssertNil(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 300, enabled: false))
        XCTAssertNil(AppearancePresencePolicy.relativeValue(lastSeen: 0, now: 300, enabled: true, expanded: true))
        XCTAssertNil(AppearancePresencePolicy.relativeValue(lastSeen: .min, now: .max, enabled: true))
        XCTAssertEqual(AppearancePresencePolicy.nextRelativeRefresh(lastSeen: 0, now: 65, enabled: true), 55)
        XCTAssertEqual(AppearancePresencePolicy.nextRelativeRefresh(lastSeen: 0, now: 7199, enabled: true), 1)
    }

    func testMenuRoundTripDeduplicationDividersAndReachability() {
        let available = [14, 2, 11, 8, 6, 110]
        let layout = AppearanceMenuLayout(rawValue: "14,14,-1,999,11,-1;14,8,6", availableIds: available, settingsInTabs: false)
        XCTAssertEqual(layout.visible, [14, -1, 11, -1, 8])
        XCTAssertEqual(layout.hidden, [6, 2, 110])
        XCTAssertEqual(AppearanceMenuLayout(rawValue: layout.rawValue, availableIds: available, settingsInTabs: false), layout)
        XCTAssertEqual(AppearanceMenuLayout(rawValue: "", availableIds: available).visible, [14, 2, 11])
        XCTAssertEqual(AppearanceMenuLayout(rawValue: ";", availableIds: available, settingsInTabs: false).visible, [8])
    }

    func testIconCatalogUsesDeclaredNamesNotImageNamesAndPadAssets() {
        let info: [String: Any] = [
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": ["CFBundleIconName": "AppIconLLC"],
                "CFBundleAlternateIcons": ["Blue": ["CFBundleIconFiles": ["BlueIcon"]], "Broken": [:]]
            ],
            "CFBundleIcons~ipad": [
                "CFBundlePrimaryIcon": ["CFBundleIconName": "AppIconLLC"],
                "CFBundleAlternateIcons": ["Blue": ["CFBundleIconFiles": ["BlueIconIpad"]]]
            ]
        ]
        let phone = AppearanceAppIconPolicy.catalog(info: info, isPad: false)
        XCTAssertEqual(phone.map(\.name), ["Default", "Blue"])
        XCTAssertTrue(phone[0].isDefault)
        XCTAssertEqual(phone[1].imageName, "BlueIcon")
        XCTAssertEqual(AppearanceAppIconPolicy.catalog(info: info, isPad: true)[1].imageName, "BlueIconIpad")
    }
}
