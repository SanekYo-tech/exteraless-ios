import Foundation
import TelegramCore
import TelegramUIPreferences
import XCTest

/// Native value tests only: no account, database, network or user action.
final class DialogNativePreferenceTests: XCTestCase {
    func testArchivePullLeaseRoundTripsAndRestoresNativePosition() throws {
        let original = ChatArchiveSettings(isHiddenByDefault: false, hiddenPsaPeerId: EnginePeer.Id(42))
        let enabled = original.withExteralessArchivePull(true)
        XCTAssertTrue(enabled.isHiddenByDefault)
        XCTAssertEqual(enabled.exteralessArchivePullPrevious, false)
        let restored = try JSONDecoder().decode(ChatArchiveSettings.self, from: JSONEncoder().encode(enabled))
        XCTAssertEqual(restored.withExteralessArchivePull(false), original)
        XCTAssertEqual(restored.withExteralessArchivePull(true), restored)
    }

    func testNativeUserUnhideWinsAndAccountsKeepSeparateLeases() {
        let first = ChatArchiveSettings(isHiddenByDefault: false, hiddenPsaPeerId: nil)
        let second = ChatArchiveSettings(isHiddenByDefault: true, hiddenPsaPeerId: EnginePeer.Id(19))
        var overridden = second.withExteralessArchivePull(true)
        overridden.isHiddenByDefault = false
        XCTAssertFalse(overridden.withExteralessArchivePull(false).isHiddenByDefault)
        XCTAssertEqual(first.withExteralessArchivePull(true).withExteralessArchivePull(false), first)
        XCTAssertEqual(second.withExteralessArchivePull(true).withExteralessArchivePull(false), second)
    }
}
