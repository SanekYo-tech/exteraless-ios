import Foundation
import XCTest
@testable import ExteralessCore

final class ChatSwipePolicyTests: XCTestCase {
    func testOriginalValuesAndAutomaticFolderFallback() {
        XCTAssertEqual(ChatSwipePolicy.Action.allCases.map(\.rawValue), [-1, 0, 1, 2, 3, 4, 5])
        for raw in [-1, 5] {
            XCTAssertEqual(ChatSwipePolicy.resolvedAction(rawValue: raw, hasFilters: false), .archive)
            XCTAssertEqual(ChatSwipePolicy.resolvedAction(rawValue: raw, hasFilters: true), .folders)
        }
        for action in [ChatSwipePolicy.Action.pin, .read, .archive, .mute, .delete] {
            XCTAssertEqual(ChatSwipePolicy.resolvedAction(rawValue: action.rawValue, hasFilters: false), action)
            XCTAssertEqual(ChatSwipePolicy.resolvedAction(rawValue: action.rawValue, hasFilters: true), action)
        }
    }

    func testRequestedActionNeverExpandsNativeEligibility() {
        let actions: [ChatSwipePolicy.Action] = [.pin, .read, .archive, .mute, .delete]
        for mask in 0 ..< 32 {
            let allowed = Set(actions.enumerated().compactMap { index, action in mask & (1 << index) == 0 ? nil : action })
            let fallback = actions.last(where: { allowed.contains($0) })
            for raw in -1 ... 5 {
                if let chosen = ChatSwipePolicy.primaryAction(rawValue: raw, hasFilters: false, allowed: allowed, nativeFallback: fallback) {
                    XCTAssertTrue(allowed.contains(chosen))
                } else {
                    XCTAssertTrue(allowed.isEmpty)
                }
            }
        }
        XCTAssertEqual(ChatSwipePolicy.primaryAction(rawValue: 3, hasFilters: false, allowed: [.pin, .delete], nativeFallback: .delete), .delete)
        XCTAssertNil(ChatSwipePolicy.primaryAction(rawValue: 0, hasFilters: true, allowed: [], nativeFallback: nil))
        XCTAssertNil(ChatSwipePolicy.primaryAction(rawValue: 5, hasFilters: true, allowed: [.pin, .archive], nativeFallback: .archive))
    }

    func testFoldersKeepPagerCenterAndNativeEdgeButtons() {
        for raw in [-1, 5] {
            XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: raw, hasFilters: true, rowHasActions: true, isActionEdge: false, revealIsOpen: false, horizontalContent: false), .folderPager)
            XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: raw, hasFilters: true, rowHasActions: true, isActionEdge: true, revealIsOpen: false, horizontalContent: false), .native)
        }
        for raw in 0 ... 4 {
            XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: raw, hasFilters: true, rowHasActions: true, isActionEdge: false, revealIsOpen: false, horizontalContent: false), .rowReveal)
        }
        XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: 5, hasFilters: false, rowHasActions: true, isActionEdge: false, revealIsOpen: false, horizontalContent: false), .native)
        XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: 0, hasFilters: true, rowHasActions: false, isActionEdge: false, revealIsOpen: false, horizontalContent: false), .native)
    }

    func testHorizontalContentAndOpenRevealTakeTheirOwnGestures() {
        for raw in -1 ... 5 {
            XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: raw, hasFilters: true, rowHasActions: true, isActionEdge: false, revealIsOpen: false, horizontalContent: true), .horizontalContent)
        }
        XCTAssertEqual(ChatSwipePolicy.gestureOwner(rawValue: 5, hasFilters: true, rowHasActions: true, isActionEdge: false, revealIsOpen: true, horizontalContent: false), .rowReveal)
        XCTAssertTrue(ChatSwipePolicy.isActionEdge(x: 20, width: 120))
        XCTAssertFalse(ChatSwipePolicy.isActionEdge(x: 22, width: 120))
        XCTAssertTrue(ChatSwipePolicy.isActionEdge(x: 79, width: 1200))
        XCTAssertFalse(ChatSwipePolicy.isActionEdge(x: 80, width: 1200))
        XCTAssertTrue(ChatSwipePolicy.isActionEdge(x: .nan, width: 400))
    }

    func testSelectorDefinitionPersistsAllOriginalValuesAndRejectsOtherTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = try ClientSettings(storageURL: url)
        try settings.register(ChatSwipeFeatures.definitions)
        XCTAssertEqual(ChatSwipePolicy.current(in: settings), -1)
        for value in -1 ... 5 {
            try settings.set(.integer(Int64(value)), for: ChatSwipePolicy.settingKey)
            let reopened = try ClientSettings(storageURL: url)
            try reopened.register(ChatSwipeFeatures.definitions)
            XCTAssertEqual(ChatSwipePolicy.current(in: reopened), value)
        }
        XCTAssertThrowsError(try settings.set(.integer(6), for: ChatSwipePolicy.settingKey))
        XCTAssertThrowsError(try settings.set(.bool(true), for: ChatSwipePolicy.settingKey))
    }
}
