import ExteralessCore
import TelegramCore
import XCTest

/// Pure native objects only: no Account, Postbox, logged-in session or network.
final class IdentityPresentationTests: XCTestCase {
    private let owner = IdentityAccountId(recordId: 1, userId: 100, testingEnvironment: false)

    private func user(id: Int64 = 100, status: PeerEmojiStatus? = nil, color: PeerColor? = nil, emoji: Int64? = nil) -> TelegramUser {
        TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)), accessHash: nil,
            firstName: "Ada", lastName: "Lovelace", username: "native_user", phone: nil, photo: [], botInfo: nil, restrictionInfo: nil,
            flags: [], emojiStatus: status, usernames: [], storiesHidden: nil, nameColor: color, backgroundEmojiId: emoji,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }

    func testLocalSelfRenderCannotAlterNativeNamesFlagsOrStatus() throws {
        let native = user()
        var local = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
        local.localPremium = true
        local.emojiStatus = .init(documentId: 123, until: 200)
        local.colors = .init(colorId: 3, emojiId: 456, profileColorId: 7, profileEmojiId: 789)
        try local.setAlias("Local Ada", for: .init(kind: .user, id: 100))
        let rendered = exteralessIdentityProjection(peer: .user(native), owner: owner, state: local, policy: .init(), now: 199)
        XCTAssertEqual(rendered.name, "Local Ada")
        XCTAssertEqual(rendered.emojiStatus?.fileId, 123)
        XCTAssertEqual(rendered.nameColor, .preset(.green))
        XCTAssertEqual(rendered.profileColor, PeerNameColor(rawValue: 7))
        XCTAssertEqual(rendered.profileBackgroundEmojiId, 789)
        XCTAssertTrue(rendered.premiumBadge)
        XCTAssertEqual(native.firstName, "Ada"); XCTAssertEqual(native.lastName, "Lovelace")
        XCTAssertFalse(EnginePeer.user(native).isPremium)
        XCTAssertNil(native.emojiStatus); XCTAssertNil(native.nameColor); XCTAssertNil(native.backgroundEmojiId)
        XCTAssertNil(exteralessIdentityProjection(peer: .user(native), owner: owner, state: local, policy: .init(), now: 200).emojiStatus)
    }

    func testServerFieldsWinAndRenderingFlagsDoNotRemoveNativeData() {
        let status = PeerEmojiStatus(content: .emoji(fileId: 99), expirationDate: nil)
        let native = user(status: status, color: .preset(.red), emoji: 66)
        var local = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
        local.localPremium = true
        local.emojiStatus = .init(documentId: 123)
        local.colors = .init(colorId: 3, emojiId: 456)
        let policy = IdentityDisplayPolicy(values: ["identity.premiumItemEmojiStatus": .bool(false), "identity.premiumItemCustomColorInReplies": .bool(false), "identity.premiumItemEmojiInReplies": .bool(false)])
        let profile = exteralessIdentityProjection(peer: .user(native), owner: owner, state: local, policy: policy, now: 100)
        XCTAssertEqual(profile.emojiStatus, status)
        XCTAssertEqual(profile.nameColor, .preset(.red)); XCTAssertEqual(profile.backgroundEmojiId, 66)
        let reply = exteralessIdentityProjection(peer: .user(native), owner: owner, state: local, policy: policy, surface: .reply, now: 100)
        XCTAssertNil(reply.nameColor); XCTAssertNil(reply.backgroundEmojiId)
        let author = exteralessIdentityProjection(peer: .user(native), owner: owner, state: local, policy: policy, surface: .messageAuthor, now: 100)
        XCTAssertNil(author.emojiStatus)
        XCTAssertFalse(author.premiumBadge)
        XCTAssertEqual(native.emojiStatus, status); XCTAssertEqual(native.nameColor, .preset(.red)); XCTAssertEqual(native.backgroundEmojiId, 66)
    }

    func testAnotherAccountAndRemoteUserNeverBorrowLocalPremiumState() throws {
        var local = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
        local.localPremium = true; local.emojiStatus = .init(documentId: 123)
        local.colors = .init(colorId: 3)
        try local.setAlias("A only", for: .init(kind: .user, id: 101))
        let remote = exteralessIdentityProjection(peer: .user(user(id: 101)), owner: owner, state: local, policy: .init(), now: 1)
        XCTAssertEqual(remote.name, "A only")
        XCTAssertFalse(remote.premiumBadge); XCTAssertNil(remote.emojiStatus)
        let b = IdentityAccountId(recordId: 2, userId: 102, testingEnvironment: false)
        let other = exteralessIdentityProjection(peer: .user(user(id: 101)), owner: b, state: local, policy: .init(), now: 1)
        XCTAssertEqual(other.name, "Ada Lovelace")
        XCTAssertFalse(other.premiumBadge); XCTAssertNil(other.emojiStatus)
    }
}
