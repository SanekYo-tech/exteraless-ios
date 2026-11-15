import Foundation
import XCTest
@testable import ExteralessCore

final class IdentityPolicyTests: XCTestCase {
    private let owner = IdentityAccountId(recordId: 10, userId: 100, testingEnvironment: false)
    private let user = IdentityPeerKey(kind: .user, id: 42)
    private let group = IdentityPeerKey(kind: .group, id: 42)

    func testAliasesAreScopedByPeerKindAndResetUsesLatestNativeName() throws {
        var state = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
        try state.setAlias("  Local 👩🏽‍💻  ", for: user)
        try state.setAlias("Project", for: group)
        XCTAssertEqual(state.alias(for: user), "Local 👩🏽‍💻")
        XCTAssertEqual(state.alias(for: group), "Project")
        XCTAssertEqual(IdentityNamePolicy.userName(first: "New", last: "Server", alias: state.alias(for: user), order: .lastFirst), "Local 👩🏽‍💻")
        try state.setAlias(" \n ", for: user)
        XCTAssertEqual(IdentityNamePolicy.userName(first: "New", last: "Server", alias: state.alias(for: user), order: .lastFirst), "Server New")
        XCTAssertEqual(state.alias(for: group), "Project")
        XCTAssertFalse(String(decoding: try IdentityArchive.encode(state), as: UTF8.self).contains("Server"))
    }

    func testNameOrderSingleNamesEmptyFallbackAndGraphemeInitials() {
        XCTAssertEqual(IdentityNamePolicy.userName(first: " Ada ", last: " Lovelace ", alias: nil, order: .lastFirst), "Lovelace Ada")
        XCTAssertEqual(IdentityNamePolicy.userName(first: "Ada", last: "Lovelace", alias: nil, order: .lastFirst, compact: true), "Lovelace")
        XCTAssertEqual(IdentityNamePolicy.userName(first: "", last: "Only", alias: nil, order: .firstLast), "Only")
        XCTAssertNil(IdentityNamePolicy.userName(first: nil, last: " ", alias: nil, order: .firstLast))
        XCTAssertEqual(IdentityNamePolicy.initials("👩🏽‍💻 李"), ["👩🏽‍💻", "李"])
        XCTAssertEqual(IdentityNamePolicy.userName(first: nil, last: nil, alias: "Two word alias", order: .lastFirst, compact: true), "Two word alias")
    }

    func testAliasAndNativePeerIdQuotasRejectWithoutPartialMutation() throws {
        var state = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
        for i in 1...IdentityAccountState.maximumAliases { try state.setAlias("Alias", for: .init(kind: .user, id: Int64(i))) }
        let original = state
        XCTAssertThrowsError(try state.setAlias("Overflow", for: .init(kind: .user, id: 99_999)))
        XCTAssertEqual(original, state)
        XCTAssertThrowsError(try state.setAlias("a\nb", for: user))
        XCTAssertThrowsError(try state.setAlias(String(repeating: "a", count: 129), for: user))
        XCTAssertThrowsError(try state.setAlias("bad", for: .init(kind: .user, id: Int64.max)))
        XCTAssertNil(IdentityPeerKey(storageKey: "user:00042"))
        XCTAssertNil(IdentityPeerKey(storageKey: "user:-1"))
        try state.setAlias(nil, for: user)
        try state.setAlias("Replacement", for: .init(kind: .user, id: 99_999))
    }

    func testArchiveAccountIsolationDocumentPrecisionAndReset() throws {
        var state = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
        state.localPremium = true
        state.emojiStatus = .init(documentId: 9_007_199_254_740_993, until: 2_000_000_000)
        state.colors = .init(colorId: 5, emojiId: -9_007_199_254_740_993, profileColorId: 12)
        try state.setAlias("Local", for: user)
        let encoded = try IdentityArchive.encode(state)
        XCTAssertEqual(try IdentityArchive.decode(encoded, owner: owner), state)
        XCTAssertThrowsError(try IdentityArchive.decode(encoded, owner: .init(recordId: 10, userId: 101, testingEnvironment: false)))
        XCTAssertThrowsError(try IdentityArchive.decode(encoded, owner: .init(recordId: 10, userId: 100, testingEnvironment: true)))
        // A restore into the same user/environment on another install is valid.
        XCTAssertEqual(try IdentityArchive.decode(encoded, owner: .init(recordId: 999, userId: 100, testingEnvironment: false)), state)
        state.resetPremium()
        XCTAssertNil(state.emojiStatus); XCTAssertNil(state.colors); XCTAssertFalse(state.localPremium)
        XCTAssertEqual(state.alias(for: user), "Local")
        XCTAssertThrowsError(try IdentityArchive.decode(Data(repeating: 32, count: IdentityAccountState.maximumEncodedBytes + 1), owner: owner))
    }

    func testAndroidRecordsNormalizeEmptySentinelsAndNeverFanOut() throws {
        let empty = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
        let value = try IdentityArchive.importAndroid(statusJSON: "{\"documentId\":9007199254740993,\"until\":0}",
            colorsJSON: "{\"colorId\":5,\"emojiId\":0,\"profileColorId\":-1,\"profileEmojiId\":123}", into: empty)
        XCTAssertEqual(value.emojiStatus, .init(documentId: 9_007_199_254_740_993))
        XCTAssertEqual(value.colors, .init(colorId: 5, profileEmojiId: 123))
        XCTAssertEqual(value.ownerUserId, owner.userId)
        XCTAssertFalse(value.localPremium)
        XCTAssertThrowsError(try IdentityArchive.importAndroid(statusJSON: "{\"documentId\":true}", colorsJSON: nil, into: empty))
        XCTAssertThrowsError(try IdentityArchive.importAndroid(statusJSON: nil, colorsJSON: "{\"colorId\":2147483648}", into: empty))
        XCTAssertThrowsError(try IdentityArchive.importAndroid(statusJSON: "{\"documentId\":1,\"until\":2147483648}", colorsJSON: nil, into: empty))
        XCTAssertEqual(try IdentityArchive.importAndroid(statusJSON: "", colorsJSON: "", into: value), empty)
    }

    func testFieldCASDedupAndUnrelatedEdits() throws {
        var state = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
        let add = IdentityMutation.alias(peer: user, value: "A", expected: nil)
        state = try add.applying(to: state)
        XCTAssertThrowsError(try add.applying(to: state))
        let changed = try IdentityMutation.nameOrder(.lastFirst, expected: .firstLast).applying(to: state)
        XCTAssertEqual(changed.alias(for: user), "A")
        XCTAssertEqual(try IdentityMutation.alias(peer: user, value: "A", expected: "A").applying(to: changed), changed)
        XCTAssertEqual(try IdentityMutation.clearAliases.applying(to: changed).nameOrder, .lastFirst)
        XCTAssertEqual(try IdentityMutation.resetAll.applying(to: changed), IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false))
    }

    func testLocalPresentationDoesNotGrantServerCapabilityAndExpiresAtBoundary() {
        let local = IdentityPremiumCapabilities(actualPremium: false, isOwningUser: true, localPremium: true)
        XCTAssertTrue(local.rendersPremiumBadge)
        XCTAssertFalse(local.canSubmitPremiumIdentity)
        let status = IdentityEmojiStatus(documentId: 9, until: 101)
        XCTAssertEqual(local.emojiStatus(server: nil, local: status, now: 100), status)
        XCTAssertNil(local.emojiStatus(server: nil, local: status, now: 101))
        let server = IdentityEmojiStatus(documentId: 10)
        XCTAssertEqual(local.emojiStatus(server: server, local: status, now: 100), server)
        let remote = IdentityPremiumCapabilities(actualPremium: false, isOwningUser: false, localPremium: true)
        XCTAssertFalse(remote.rendersPremiumBadge)
        XCTAssertNil(remote.emojiStatus(server: nil, local: status, now: 100))
        XCTAssertFalse(IdentityPremiumCapabilities(actualPremium: true, isOwningUser: false, localPremium: true).canSubmitPremiumIdentity)
        let off = IdentityPremiumCapabilities(actualPremium: true, isOwningUser: true, localPremium: false)
        XCTAssertTrue(off.canSubmitPremiumIdentity)
        XCTAssertEqual(off.emojiStatus(server: server, local: status, now: 100), server)
    }

    func testActivityBandsNeverInventHiddenLastSeenOrAffectSelfAndBots() {
        func band(_ until: Int32?, now: Int64 = 10_000) -> IdentityActivityBand? {
            IdentityMetadataPolicy.activityBand(enabled: true, isSelf: false, isBot: false, visibleUntil: until, locallyOnline: false, now: now)
        }
        XCTAssertEqual(band(10_001), .online)
        XCTAssertEqual(band(10_000), .within15Minutes)
        XCTAssertEqual(band(9_100), .within30Minutes)
        XCTAssertEqual(band(8_200), .withinHour)
        XCTAssertNil(band(6_400)); XCTAssertNil(band(nil)); XCTAssertNil(band(-1))
        XCTAssertNil(IdentityMetadataPolicy.activityBand(enabled: true, isSelf: true, isBot: false, visibleUntil: 10_001, locallyOnline: true, now: 10_000))
        XCTAssertNil(IdentityMetadataPolicy.activityBand(enabled: true, isSelf: false, isBot: true, visibleUntil: 10_001, locallyOnline: true, now: 10_000))
    }

    func testIdMigrationAndCommonGroupsRespectOriginalPrecedence() {
        XCTAssertEqual(IdentityFeatures.migratedIdDisplay(current: 2, legacyShowIdAndDc: false), 2)
        XCTAssertEqual(IdentityFeatures.migratedIdDisplay(current: nil, legacyShowIdAndDc: false), 0)
        XCTAssertEqual(IdentityFeatures.migratedIdDisplay(current: nil, legacyShowIdAndDc: true), 1)
        XCTAssertNil(IdentityMetadataPolicy.displayedId(peer: user, type: 0))
        XCTAssertEqual(IdentityMetadataPolicy.displayedId(peer: group, type: 2), "-42")
        XCTAssertEqual(IdentityMetadataPolicy.displayedId(peer: .init(kind: .channel, id: 42), type: 2), "-1000000000042")
        XCTAssertEqual(IdentityMetadataPolicy.displayedId(peer: .init(kind: .channel, id: 42), type: 1), "42")
        XCTAssertNil(IdentityMetadataPolicy.displayedId(peer: .init(kind: .channel, id: .max), type: 2))
        XCTAssertTrue(IdentityMetadataPolicy.preferCommonGroups(enabled: true, defaultIsGifts: true, hasCommonGroups: true, explicitSelection: false))
        XCTAssertFalse(IdentityMetadataPolicy.preferCommonGroups(enabled: true, defaultIsGifts: true, hasCommonGroups: true, explicitSelection: true))
        XCTAssertFalse(IdentityMetadataPolicy.preferCommonGroups(enabled: true, defaultIsGifts: false, hasCommonGroups: true, explicitSelection: false))
    }
}
