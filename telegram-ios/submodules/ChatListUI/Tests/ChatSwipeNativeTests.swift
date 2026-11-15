import AccountContext
import Display
import ExteralessCore
import ItemListUI
import Postbox
import TelegramCore
import TelegramPresentationData
import UIKit
import XCTest
@testable import ChatListUI

@MainActor
final class ChatSwipeNativeTests: XCTestCase {
    private let accountId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1))
    private let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(2))

    private func user(_ id: PeerId) -> EnginePeer {
        .user(TelegramUser(id: id, accessHash: nil, firstName: "Fixture", lastName: nil, username: nil,
            phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
    }

    private func trailing(peer: PeerId? = nil, pinned: Bool = false, muted: Bool? = false,
                          location: ChatListControllerLocation = .chatList(groupId: .root), canDelete: Bool = true) -> [ItemListRevealOption] {
        revealOptions(strings: defaultPresentationStrings, theme: defaultPresentationTheme,
            isPinned: pinned, isMuted: muted, location: location, peerId: peer ?? peerId,
            accountPeerId: accountId, canDelete: canDelete, isEditing: false, filterData: nil)
    }

    func testPrimaryPinReadMuteDeleteUseExactNativeOptionsAndRetainEveryButton() throws {
        for pinned in [false, true] {
            for unread in [false, true] {
                let left = leftRevealOptions(strings: defaultPresentationStrings, theme: defaultPresentationTheme,
                    isUnread: unread, isEditing: false, isPinned: pinned, isSavedMessages: false,
                    location: .chatList(groupId: .root), peer: user(peerId), filterData: nil)
                for muted in [false, true] {
                    let right = trailing(pinned: pinned, muted: muted)
                    let expected: [(Int, RevealOptionKey)] = [(0, pinned ? .unpin : .pin), (1, .toggleMarkedUnread), (2, .archive), (3, muted ? .unmute : .mute), (4, .delete)]
                    for (value, key) in expected {
                        let projected = exteralessChatSwipeRevealOptions(left: left, right: right, rawValue: value, hasFilters: true)
                        let original = try XCTUnwrap((left + right).first { $0.key == key.rawValue })
                        XCTAssertEqual(projected.right.last, original)
                        XCTAssertEqual(Set((projected.left + projected.right).map(\.key)), Set((left + right).map(\.key)))
                        XCTAssertEqual(projected.left.count + projected.right.count, left.count + right.count)
                    }
                }
            }
        }
    }

    func testSavedServiceAndForumRestrictionsChooseOnlyAllowedNativeFallback() {
        for peer in [accountId, PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(777000))] {
            let right = trailing(peer: peer, muted: nil)
            XCTAssertFalse(right.contains { $0.key == RevealOptionKey.archive.rawValue })
            let projected = exteralessChatSwipeRevealOptions(left: [], right: right, rawValue: 2, hasFilters: false)
            XCTAssertEqual(projected.right, right)
            XCTAssertEqual(projected.right.last?.key, RevealOptionKey.delete.rawValue)
        }
        let forum = TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(5)), accessHash: nil, title: "Forum", username: nil, photo: [], creationDate: 0, version: 0, participationStatus: .member, info: .group(TelegramChannelGroupInfo(flags: [])), flags: [.isForum], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        let left = leftRevealOptions(strings: defaultPresentationStrings, theme: defaultPresentationTheme, isUnread: false, isEditing: false, isPinned: false, isSavedMessages: false, location: .chatList(groupId: .root), peer: .channel(forum), filterData: nil)
        XCTAssertFalse(left.contains { $0.key == RevealOptionKey.toggleMarkedUnread.rawValue })
        let right = trailing(peer: forum.id)
        let projected = exteralessChatSwipeRevealOptions(left: left, right: right, rawValue: 1, hasFilters: false)
        XCTAssertEqual(projected.right.last, right.last)
        XCTAssertFalse((projected.left + projected.right).contains { $0.key == RevealOptionKey.toggleMarkedUnread.rawValue })
    }

    func testFinalNativePrivacyEditingGateAndFoldersKeepAdmittedControls() {
        let right = trailing(location: .chatList(groupId: .archive))
        let folder = exteralessChatSwipeRevealOptions(left: [], right: right, rawValue: 5, hasFilters: true)
        XCTAssertEqual(folder.right, right)
        let noFolders = exteralessChatSwipeRevealOptions(left: [], right: right, rawValue: 5, hasFilters: false)
        XCTAssertEqual(noFolders.right.last?.key, RevealOptionKey.unarchive.rawValue)
        for action in -1 ... 5 {
            // These are the arrays passed by ChatListItem AFTER its real final gates.
            let blocked = exteralessChatSwipeRevealOptions(left: [], right: [], rawValue: action, hasFilters: true)
            XCTAssertTrue(blocked.left.isEmpty && blocked.right.isEmpty)
        }
        let cannotDelete = trailing(canDelete: false)
        let fallback = exteralessChatSwipeRevealOptions(left: [], right: cannotDelete, rawValue: 4, hasFilters: false)
        XCTAssertEqual(fallback.right.last?.key, RevealOptionKey.archive.rawValue)
    }

    func testRealHorizontalSubviewWinsBothRowAndPagerArbitration() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 90))
        let horizontal = UIScrollView(frame: CGRect(x: 40, y: 0, width: 300, height: 90))
        horizontal.contentSize = CGSize(width: 900, height: 90)
        root.addSubview(horizontal)
        let point = CGPoint(x: 200, y: 45)
        XCTAssertTrue(exteralessChatSwipeHasHorizontalContent(at: point, in: root))
        XCTAssertFalse(exteralessChatSwipeAllowsPager(at: point, in: root, hasFilters: true))
        horizontal.isScrollEnabled = false
        XCTAssertFalse(exteralessChatSwipeHasHorizontalContent(at: point, in: root))
        XCTAssertTrue(exteralessChatSwipeAllowsPager(at: point, in: root, hasFilters: true))
        horizontal.disablesInteractiveTransitionGestureRecognizerNow = { true }
        let contentRecognizerEnabled = horizontal.panGestureRecognizer.isEnabled
        XCTAssertTrue(exteralessChatSwipeHasHorizontalContent(at: point, in: root))
        XCTAssertFalse(exteralessChatSwipeAllowsPager(at: point, in: root, hasFilters: true))
        XCTAssertEqual(horizontal.panGestureRecognizer.isEnabled, contentRecognizerEnabled, "arbitration never changes the content's recognizer")
    }
}
