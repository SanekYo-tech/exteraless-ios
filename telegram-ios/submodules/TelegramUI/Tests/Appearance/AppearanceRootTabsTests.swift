import AccountContext
import ContactListUI
import Display
import ExteralessCore
import PeerInfoScreen
import TelegramUI
import XCTest

final class AppearanceRootTabsTests: XCTestCase {
    func testRebuildPredicateRecognizesTheActualSettingsControllerType() {
        // No fake SettingsController conformance and no Account construction.
        XCTAssertTrue(exteralessIsSettingsRootTab(PeerInfoScreenImpl.self))
        XCTAssertFalse(exteralessIsSettingsRootTab(ContactsController.self))
        XCTAssertFalse(exteralessIsSettingsRootTab(ViewController.self))
    }

    @MainActor
    func testRetainedFeedAndCallsCompositionKeepsChatsFallback() throws {
        let contacts = ViewController(navigationBarPresentationData: nil)
        let calls = ViewController(navigationBarPresentationData: nil)
        let chats = ViewController(navigationBarPresentationData: nil)
        let settings = ViewController(navigationBarPresentationData: nil)
        let feed = ViewController(navigationBarPresentationData: nil)
        for callsVisible in [false, true] {
            let native = [contacts] + (callsVisible ? [calls] : []) + [chats, settings]
            let withFeed = exteralessReplaceContactsWithFeed(native, contacts: contacts, feed: feed, enabled: true)
            let hiddenSettings = withFeed.filter { $0 !== settings }
            XCTAssertTrue(hiddenSettings.first === feed)
            XCTAssertFalse(hiddenSettings.contains { $0 === contacts || $0 === settings })
            let index = try XCTUnwrap(AppearanceTabPolicy.selectedIndex(current: ObjectIdentifier(settings), visible: hiddenSettings.map(ObjectIdentifier.init), fallback: ObjectIdentifier(chats)))
            XCTAssertTrue(hiddenSettings[index] === chats)
            let withoutFeed = exteralessReplaceContactsWithFeed(native, contacts: contacts, feed: feed, enabled: false)
            XCTAssertTrue(withoutFeed.first === contacts)
            XCTAssertFalse(withoutFeed.contains { $0 === feed })
        }
    }
}
