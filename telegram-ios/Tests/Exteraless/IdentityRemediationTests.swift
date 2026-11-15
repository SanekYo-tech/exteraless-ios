import ExteralessCore
import Foundation
import LocalizedPeerData
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit
import XCTest

private func identityFixturePeer(first: String = "Ada", last: String? = "Lovelace", photo: [TelegramMediaImageRepresentation] = []) -> EnginePeer {
    .user(TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(100)), accessHash: nil,
        firstName: first, lastName: last, username: "native_user", phone: nil, photo: photo, botInfo: nil, restrictionInfo: nil,
        flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil))
}

private final class IdentityNativeClocks {
    var wall: TimeInterval = 1_000
    var monotonic: TimeInterval = 0
    var nextId = 0
    var scheduled: [Int: (at: TimeInterval, callback: () -> Void)] = [:]
    var history: [Int: () -> Void] = [:]

    func schedule(_ delay: TimeInterval, _ callback: @escaping () -> Void) -> IdentityExpiryTimer.Cancellation {
        nextId += 1
        let id = nextId
        scheduled[id] = (monotonic + delay, callback)
        history[id] = callback
        return { [weak self] in self?.scheduled.removeValue(forKey: id) }
    }

    func advance(_ interval: TimeInterval, deliver: Bool = true) {
        wall += interval; monotonic += interval
        if deliver {
            for id in scheduled.filter({ $0.value.at <= monotonic }).map(\.key).sorted() {
                scheduled.removeValue(forKey: id)?.callback()
            }
        }
    }
}

/// Executes the real lease/cache/projector publication path with no Account,
/// Postbox, device clock mutation, dispatch timer, or live network.
@MainActor
final class IdentityExpiryLeaseTests: XCTestCase {
    private let owner = IdentityAccountId(recordId: 1, userId: 100, testingEnvironment: false)

    func testEarlyWakeupAfterBackwardJumpPublishesOnlyAtRealWallExpiry() throws {
        let clock = IdentityNativeClocks()
        let cache = IdentityPresentationCache()
        let peer = identityFixturePeer()
        var state = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
        state.localPremium = true
        state.emojiStatus = .init(documentId: 123, until: 1_100)
        let owner = self.owner
        var displayed: [Int64?] = []
        let lease = try ExteralessIdentityAccountLease(accountId: owner, states: .single(.success(state)),
            cache: cache, wallTime: { clock.wall }, schedule: clock.schedule, presentationChanged: {
                displayed.append(exteralessIdentityProjection(peer: peer, owner: owner, state: cache.snapshot(account: owner), policy: .init(), now: Int64(clock.wall)).emojiStatus?.fileId)
            })
        withExtendedLifetime(lease) {
            XCTAssertEqual(displayed, [123])
            clock.advance(50)
            clock.wall -= 100
            clock.advance(50) // The old monotonic wakeup is early in wall time.
            XCTAssertEqual(displayed, [123])
            XCTAssertEqual(clock.scheduled.values.map(\.at), [200])
            clock.advance(100)
            XCTAssertEqual(displayed, [123, nil])
            XCTAssertEqual(cache.snapshot(account: owner)?.emojiStatus, state.emojiStatus)
            lease.refreshExpiration()
            XCTAssertEqual(displayed, [123, nil])
        }
    }

    func testForegroundAndSignificantTimeRefreshRescheduleEveryFutureDeadline() throws {
        let clock = IdentityNativeClocks()
        let cache = IdentityPresentationCache()
        var state = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
        state.localPremium = true; state.emojiStatus = .init(documentId: 123, until: 1_100)
        var changes = 0
        let lease = try ExteralessIdentityAccountLease(accountId: owner, states: .single(.success(state)), cache: cache,
            wallTime: { clock.wall }, schedule: clock.schedule, presentationChanged: { changes += 1 })
        withExtendedLifetime(lease) {
            clock.advance(10)
            let old = clock.history[1]
            clock.wall += 50
            lease.refreshExpiration()
            XCTAssertEqual(clock.scheduled.values.map(\.at), [50])
            old?()
            XCTAssertEqual(changes, 1)
            clock.advance(40)
            XCTAssertEqual(changes, 2)
            XCTAssertTrue(clock.scheduled.isEmpty)
        }

        let suspendedClock = IdentityNativeClocks()
        let suspendedCache = IdentityPresentationCache()
        var resumedChanges = 0
        let suspended = try ExteralessIdentityAccountLease(accountId: owner, states: .single(.success(state)), cache: suspendedCache,
            wallTime: { suspendedClock.wall }, schedule: suspendedClock.schedule, presentationChanged: { resumedChanges += 1 })
        withExtendedLifetime(suspended) {
            let old = suspendedClock.history[1]
            suspendedClock.advance(300, deliver: false)
            suspended.refreshExpiration()
            XCTAssertEqual(resumedChanges, 2)
            XCTAssertTrue(suspendedClock.scheduled.isEmpty)
            old?()
            XCTAssertEqual(resumedChanges, 2)
        }
    }

    func testReplacedAccountTokenRejectsOldDeadlineAndOldDeinit() throws {
        let clock = IdentityNativeClocks()
        let cache = IdentityPresentationCache()
        var state = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
        state.localPremium = true; state.emojiStatus = .init(documentId: 123, until: 1_100)
        var changes = 0
        var lease: ExteralessIdentityAccountLease? = try ExteralessIdentityAccountLease(accountId: owner, states: .single(.success(state)), cache: cache,
            wallTime: { clock.wall }, schedule: clock.schedule, presentationChanged: { changes += 1 })
        let old = clock.history[1]
        let replacement = try cache.begin(account: owner)
        clock.advance(100)
        lease?.refreshExpiration()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(clock.scheduled.isEmpty)
        lease = nil
        old?()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(cache.isCurrent(replacement))
        cache.end(replacement)
    }

    func testRejectedForeignSnapshotDoesNotInstallItsExpiry() throws {
        let clock = IdentityNativeClocks()
        let cache = IdentityPresentationCache()
        var foreign = IdentityAccountState(ownerUserId: 101, testingEnvironment: false)
        foreign.localPremium = true; foreign.emojiStatus = .init(documentId: 123, until: 1_100)
        var changes = 0
        let lease = try ExteralessIdentityAccountLease(accountId: owner, states: .single(.success(foreign)), cache: cache,
            wallTime: { clock.wall }, schedule: clock.schedule, presentationChanged: { changes += 1 })
        withExtendedLifetime(lease) {
            XCTAssertNil(cache.snapshot(account: owner))
            XCTAssertTrue(clock.scheduled.isEmpty)
            clock.advance(100)
            XCTAssertEqual(changes, 0)
        }
    }
}

private final class IdentityFixtureSecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data[key] }
    func set(_ value: Data?, for key: String) throws { lock.lock(); data[key] = value; lock.unlock() }
}

/// Real title/contact presentation and the shipping presentation-update stream.
/// The account wrappers delegate to these snapshot overloads; only the isolated
/// temporary Zalgo preference changes while the native peer/payload stay fixed.
@MainActor
final class IdentityNameFormattingTests: XCTestCase {
    private let owner = IdentityAccountId(recordId: 1, userId: 100, testingEnvironment: false)
    private let marks = String(repeating: "\u{0301}", count: 4)

    private func withSettings(_ body: (ClientSettings) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-names-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = ClientSettings.shared
        try settings.configure(storageURL: directory.appendingPathComponent("settings.json"), secretStore: IdentityFixtureSecrets(), durabilityRootURL: directory)
        try settings.register([.init(key: "privacy.zalgoFilter", title: "Zalgo filter", section: "Identity fixture", defaultValue: .bool(false))])
        defer {
            try? settings.reset("privacy.zalgoFilter")
            try? FileManager.default.removeItem(at: directory)
        }
        try body(settings)
    }

    func testNoAliasAndNoSnapshotUseTheSameFinalFilterAsStockTitles() throws {
        try withSettings { settings in
            let peer = identityFixturePeer(first: "A" + marks, last: "Déjà 👩🏽‍💻")
            let identity = exteralessIdentityProjection(peer: peer, owner: owner, state: nil, policy: .init(), now: 1)
            for enabled in [false, true] {
                try settings.set(.bool(enabled), for: "privacy.zalgoFilter")
                XCTAssertEqual(peer.exteralessDisplayTitle(identity: identity, strings: defaultPresentationStrings, displayOrder: .firstLast),
                    peer.displayTitle(strings: defaultPresentationStrings, displayOrder: .firstLast))
                XCTAssertEqual(peer.exteralessCompactDisplayTitle(identity: identity), peer.compactDisplayTitle)
                XCTAssertEqual(peer.exteralessDisplayTitle(identity: identity, strings: defaultPresentationStrings, displayOrder: .firstLast),
                    enabled ? "A Déjà 👩🏽‍💻" : "A" + marks + " Déjà 👩🏽‍💻")
            }
            if case let .user(user) = peer { XCTAssertEqual(Array((user.firstName ?? "").utf16), Array(("A" + marks).utf16)) }
        }
    }

    func testAliasesNameOrdersResetAndFlagChangesDoNotRewriteStoredNames() throws {
        try withSettings { settings in
            let peer = identityFixturePeer(first: "A" + marks, last: "Déjà 👩🏽‍💻")
            let key = IdentityPeerKey(kind: .user, id: 100)
            let alias = "Alias" + marks + " 👩🏽‍💻"
            for order in [IdentityNameOrder.firstLast, .lastFirst] {
                var state = IdentityAccountState(ownerUserId: 100, testingEnvironment: false)
                state.nameOrder = order
                for enabled in [false, true] {
                    try settings.set(.bool(enabled), for: "privacy.zalgoFilter")
                    let nativeOrder: PresentationPersonNameOrder = order == .firstLast ? .firstLast : .lastFirst
                    var identity = exteralessIdentityProjection(peer: peer, owner: owner, state: state, policy: .init(), now: 1)
                    XCTAssertEqual(peer.exteralessDisplayTitle(identity: identity, strings: defaultPresentationStrings, displayOrder: nativeOrder),
                        peer.displayTitle(strings: defaultPresentationStrings, displayOrder: nativeOrder))
                    let originalCompact = order == .lastFirst ? "Déjà 👩🏽‍💻" : (enabled ? "A" : "A" + marks)
                    XCTAssertEqual(peer.exteralessCompactDisplayTitle(identity: identity), originalCompact)
                    try state.setAlias(alias, for: key)
                    identity = exteralessIdentityProjection(peer: peer, owner: owner, state: state, policy: .init(), now: 1)
                    let expected = enabled ? "Alias 👩🏽‍💻" : alias
                    XCTAssertEqual(peer.exteralessDisplayTitle(identity: identity, strings: defaultPresentationStrings, displayOrder: nativeOrder), expected)
                    XCTAssertEqual(peer.exteralessCompactDisplayTitle(identity: identity), expected)
                    XCTAssertEqual(Array((state.alias(for: key) ?? "").utf16), Array(alias.utf16))
                    state = try IdentityMutation.alias(peer: key, value: nil, expected: alias).applying(to: state)
                    identity = exteralessIdentityProjection(peer: peer, owner: owner, state: state, policy: .init(), now: 1)
                    XCTAssertEqual(peer.exteralessDisplayTitle(identity: identity, strings: defaultPresentationStrings, displayOrder: nativeOrder),
                        peer.displayTitle(strings: defaultPresentationStrings, displayOrder: nativeOrder))
                    XCTAssertEqual(peer.exteralessCompactDisplayTitle(identity: identity), originalCompact)
                    XCTAssertNil(state.alias(for: key))
                }
            }
        }
    }

    func testOrdinaryDiacriticsZWJAndAttributedFirstLastFontsArePreserved() throws {
        try withSettings { settings in
            try settings.set(.bool(true), for: "privacy.zalgoFilter")
            let ordinary = identityFixturePeer(first: "Jose\u{0301}", last: "👩🏽‍💻")
            let identity = exteralessIdentityProjection(peer: ordinary, owner: owner, state: nil, policy: .init(), now: 1)
            XCTAssertEqual(Array(ordinary.exteralessDisplayTitle(identity: identity, strings: defaultPresentationStrings, displayOrder: .firstLast).utf16), Array("Jose\u{0301} 👩🏽‍💻".utf16))
            let bold = UIFont.boldSystemFont(ofSize: 17)
            let regular = UIFont.systemFont(ofSize: 17)
            let first = "A" + marks
            for lastFirst in [false, true] {
                try settings.set(.bool(true), for: "privacy.zalgoFilter")
                let firstPart = NSAttributedString(string: first, attributes: [.font: bold, .foregroundColor: UIColor.red])
                let lastPart = NSAttributedString(string: "José 👩🏽‍💻", attributes: [.font: regular, .foregroundColor: UIColor.blue])
                let value = NSMutableAttributedString(attributedString: lastFirst ? lastPart : firstPart)
                value.append(NSAttributedString(string: " ", attributes: [.font: regular]))
                value.append(lastFirst ? firstPart : lastPart)
                value.addAttribute(.link, value: "https://example.invalid", range: (value.string as NSString).range(of: "José"))
                let displayed = exteralessZalgoDisplayText(value)
                XCTAssertEqual(displayed.string, lastFirst ? "José 👩🏽‍💻 A" : "A José 👩🏽‍💻")
                let firstIndex = (displayed.string as NSString).range(of: "A").location
                let lastIndex = (displayed.string as NSString).range(of: "José").location
                XCTAssertEqual((displayed.attribute(.font, at: firstIndex, effectiveRange: nil) as? UIFont)?.fontName, bold.fontName)
                XCTAssertEqual((displayed.attribute(.font, at: lastIndex, effectiveRange: nil) as? UIFont)?.fontName, regular.fontName)
                XCTAssertEqual(displayed.attribute(.link, at: lastIndex, effectiveRange: nil) as? String, "https://example.invalid")
                XCTAssertTrue(value.string.contains(first))
                try settings.set(.bool(false), for: "privacy.zalgoFilter")
                XCTAssertTrue(exteralessZalgoDisplayText(value) === value)
            }
        }
    }

    func testContactPresentationFiltersPayloadAliasOrderAndCustomInitialsInEveryBranch() throws {
        try withSettings { settings in
            let cachedPeer = identityFixturePeer(first: "Cached", last: "Server Name")
            let key = IdentityPeerKey(kind: .user, id: 100)
            let payloadFirst = "A" + marks
            let alias = "L" + marks + " Name"
            for enabled in [false, true] {
                try settings.set(.bool(enabled), for: "privacy.zalgoFilter")
                for hasPeerId in [false, true] {
                    for hasCachedPeer in [false, true] {
                        let peer: EnginePeer? = hasCachedPeer ? cachedPeer : nil
                        let contact = TelegramMediaContact(firstName: payloadFirst, lastName: "B", phoneNumber: "123", peerId: hasPeerId ? cachedPeer.id : nil, vCardData: "fixture-vcard")
                        for order in [IdentityNameOrder.firstLast, .lastFirst] {
                            for aliasMode in 0...2 { // absent / present / reset
                                var state = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
                                state.nameOrder = order
                                if aliasMode != 0 { try state.setAlias(alias, for: key) }
                                if aliasMode == 2 { state = try IdentityMutation.alias(peer: key, value: nil, expected: alias).applying(to: state) }
                                let result = exteralessIdentityContactPresentation(owner: owner, state: state, contact: contact, peer: peer, fallbackName: "Contact")
                                let first = enabled ? "A" : payloadFirst
                                let expectedName: String
                                let expectedInitials: [String]
                                if hasPeerId && aliasMode == 1 {
                                    expectedName = enabled ? "L Name" : alias
                                    expectedInitials = [enabled ? "L" : "L" + marks, "N"]
                                } else if order == .firstLast {
                                    expectedName = first + " B"
                                    expectedInitials = [first, "B"]
                                } else {
                                    expectedName = "B " + first
                                    expectedInitials = ["B", first]
                                }
                                XCTAssertEqual(result.name, expectedName)
                                XCTAssertEqual(result.initials, expectedInitials)
                                XCTAssertEqual(result.avatarPeer, hasPeerId ? peer : nil)
                                XCTAssertEqual(Array(contact.firstName.utf16), Array(payloadFirst.utf16))
                                XCTAssertEqual(contact.lastName, "B")
                                XCTAssertEqual(contact.vCardData, "fixture-vcard")
                                XCTAssertEqual(contact.phoneNumber, "123")
                                XCTAssertEqual(state.alias(for: key), aliasMode == 1 ? alias : nil)
                                if case let .user(user) = cachedPeer {
                                    XCTAssertEqual(user.firstName, "Cached")
                                    XCTAssertEqual(user.lastName, "Server Name")
                                }
                            }
                        }
                    }
                }
            }
            let empty = TelegramMediaContact(firstName: marks, lastName: "", phoneNumber: "", peerId: nil, vCardData: nil)
            let fallback = exteralessIdentityContactPresentation(owner: owner, state: nil, contact: empty, peer: nil, fallbackName: "Contact")
            XCTAssertEqual(fallback.name, "Contact")
            XCTAssertEqual(fallback.initials, ["C"])
            let organization = exteralessIdentityContactPresentation(owner: owner, state: nil, contact: empty, peer: nil, fallbackName: "O" + marks + " Team")
            XCTAssertEqual(organization.name, "O Team")
            XCTAssertEqual(organization.initials, ["O", "T"])
            let associated = TelegramMediaContact(firstName: payloadFirst, lastName: "B", phoneNumber: "123", peerId: cachedPeer.id, vCardData: nil)
            for foreignOwner in [IdentityAccountId(recordId: 2, userId: 101, testingEnvironment: false), IdentityAccountId(recordId: 3, userId: owner.userId, testingEnvironment: true)] {
                var foreign = IdentityAccountState(ownerUserId: foreignOwner.userId, testingEnvironment: foreignOwner.testingEnvironment)
                foreign.nameOrder = .lastFirst
                try foreign.setAlias(alias, for: key)
                let result = exteralessIdentityContactPresentation(owner: owner, state: foreign, contact: associated, peer: cachedPeer, fallbackName: "Contact")
                XCTAssertEqual(result.name, "A B")
                XCTAssertEqual(result.initials, ["A", "B"])
                XCTAssertEqual(foreign.alias(for: key), alias)
            }
        }
    }

    func testContactPresentationKeepsTheAssociatedPhotoPeerWithoutUsingItsName() throws {
        try withSettings { settings in
            try settings.set(.bool(true), for: "privacy.zalgoFilter")
            let resource = CloudPeerPhotoSizeMediaResource(datacenterId: 2, photoId: 3, sizeSpec: .small, volumeId: nil, localId: nil)
            let image = TelegramMediaImageRepresentation(dimensions: .init(width: 40, height: 40), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
            let peer = identityFixturePeer(first: "Cached", last: "Server", photo: [image])
            let contact = TelegramMediaContact(firstName: "A" + marks, lastName: "B", phoneNumber: "123", peerId: peer.id, vCardData: nil)
            let result = exteralessIdentityContactPresentation(owner: owner, state: nil, contact: contact, peer: peer, fallbackName: "Contact")
            XCTAssertEqual(result.name, "A B")
            XCTAssertEqual(result.initials, ["A", "B"])
            XCTAssertEqual(result.avatarPeer, peer)
            if case let .user(user)? = result.avatarPeer {
                XCTAssertEqual(user.firstName, "Cached")
                XCTAssertTrue(user.photo.first === image)
            }
        }
    }

    private func drainIdentityPresentationQueue() {
        let drained = expectation(description: "identity presentation main-queue drain")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 1)
    }

    func testZalgoFlagAloneRefreshesStableNativePresentationNamesAndInitials() throws {
        try withSettings { settings in
            let runtime = ExteralessIdentityPresentation.shared
            runtime.reloadDisplayPolicy()
            drainIdentityPresentationQueue()
            let policy = runtime.policy
            let stable = defaultPresentationData()
            let peer = identityFixturePeer(first: "A" + marks, last: "B")
            var state = IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: false)
            try state.setAlias("A" + marks + " B", for: .init(kind: .user, id: 100))
            let identity = exteralessIdentityProjection(peer: peer, owner: owner, state: state, policy: .init(), now: 1)
            let contact = TelegramMediaContact(firstName: "A" + marks, lastName: "B", phoneNumber: "123", peerId: nil, vCardData: nil)
            let associatedContact = TelegramMediaContact(firstName: contact.firstName, lastName: contact.lastName, phoneNumber: contact.phoneNumber, peerId: peer.id, vCardData: nil)
            var nativeLoads = 0
            let native = Signal<PresentationData, NoError> { subscriber in
                nativeLoads += 1
                subscriber.putNext(stable)
                return EmptyDisposable
            }
            var received: [PresentationData] = []
            var listNames: [String] = []
            var compactNames: [String] = []
            var contactNames: [String] = []
            var peerContactNames: [String] = []
            var initials: [[String]] = []
            var peerInitials: [[String]] = []
            var revisions: [UInt64] = []
            let revisionDisposable = runtime.changes.start(next: { revisions.append($0) })
            defer { revisionDisposable.dispose() }
            let stream = exteralessAppearancePresentationData(native: native, updates: exteralessAppearanceUpdates(), dateTimeFormat: {
                let value = runtime.formattingSnapshot
                let base = stable.dateTimeFormat
                return PresentationDateTimeFormat(timeFormat: base.timeFormat, dateFormat: base.dateFormat, dateSeparator: base.dateSeparator,
                    dateSuffix: base.dateSuffix, requiresFullYear: base.requiresFullYear, decimalSeparator: base.decimalSeparator,
                    groupingSeparator: base.groupingSeparator, showSeconds: base.showSeconds, identityCalendar: value.calendar, identityRevision: value.revision)
            }, hideDividers: { false })
            let disposable = stream.start(next: { data in
                XCTAssertTrue(Thread.isMainThread)
                // Invoke the shipping formatters from the real stream, with
                // retained inputs and no manual invalidation after a flag write.
                received.append(data)
                listNames.append(peer.exteralessDisplayTitle(identity: identity, strings: data.strings, displayOrder: data.nameDisplayOrder))
                compactNames.append(peer.exteralessCompactDisplayTitle(identity: identity))
                let renderedContact = exteralessIdentityContactPresentation(owner: self.owner, state: state, contact: contact, peer: nil,
                    fallbackName: data.strings.Message_Contact)
                let renderedPeerContact = exteralessIdentityContactPresentation(owner: self.owner, state: state, contact: associatedContact, peer: peer,
                    fallbackName: data.strings.Message_Contact)
                contactNames.append(renderedContact.name)
                peerContactNames.append(renderedPeerContact.name)
                initials.append(renderedContact.initials)
                peerInitials.append(renderedPeerContact.initials)
                XCTAssertNil(renderedContact.avatarPeer)
                XCTAssertEqual(renderedPeerContact.avatarPeer, peer)
            })
            defer { disposable.dispose() }
            drainIdentityPresentationQueue()
            XCTAssertEqual(received.count, 1)
            for enabled in [true, false, true] {
                try settings.set(.bool(enabled), for: "privacy.zalgoFilter")
                drainIdentityPresentationQueue()
            }
            try settings.reset("privacy.zalgoFilter")
            drainIdentityPresentationQueue()
            XCTAssertEqual(nativeLoads, 1, "A display flag must not reload the native/file-backed theme source")
            XCTAssertEqual(received.count, 5)
            let raw = "A" + marks + " B"
            XCTAssertEqual(listNames, [raw, "A B", raw, "A B", raw])
            XCTAssertEqual(compactNames, listNames) // An alias is a single display name.
            XCTAssertEqual(contactNames, listNames)
            XCTAssertEqual(peerContactNames, listNames)
            let rawInitials = ["A" + marks, "B"]
            XCTAssertEqual(initials, [rawInitials, ["A", "B"], rawInitials, ["A", "B"], rawInitials])
            XCTAssertEqual(peerInitials, initials, "setPeer override and setCustomLetters receive the same final initials")
            XCTAssertEqual(revisions, received.map { $0.dateTimeFormat.identityRevision })
            XCTAssertEqual(runtime.policy, policy, "The revision must change even though IdentityDisplayPolicy does not")
            for (previous, current) in zip(received, received.dropFirst()) {
                XCTAssertGreaterThan(current.dateTimeFormat.identityRevision, previous.dateTimeFormat.identityRevision)
                XCTAssertNotEqual(current.dateTimeFormat, previous.dateTimeFormat)
                XCTAssertFalse(current.theme === previous.theme)
                XCTAssertNotEqual(current, previous, "Retained native list/profile/contact equality gates must invalidate")
                XCTAssertTrue(current.theme.list === stable.theme.list)
                XCTAssertTrue(current.strings === stable.strings)
                XCTAssertEqual(current.chatWallpaper, stable.chatWallpaper)
            }
            XCTAssertEqual(state.alias(for: .init(kind: .user, id: 100)), raw)
            XCTAssertEqual(Array(contact.firstName.utf16), Array(("A" + marks).utf16))
            if case let .user(user) = peer { XCTAssertEqual(Array((user.firstName ?? "").utf16), Array(contact.firstName.utf16)) }
            let count = received.count
            try settings.set(.bool(false), for: "privacy.zalgoFilter")
            drainIdentityPresentationQueue()
            XCTAssertEqual(received.count, count, "An unchanged logical flag needs no extra invalidation")
            XCTAssertEqual(revisions.count, count)
            disposable.dispose()
            try settings.set(.bool(true), for: "privacy.zalgoFilter")
            drainIdentityPresentationQueue()
            XCTAssertEqual(received.count, count, "Disposed presentation lifetime cannot receive later flag changes")
        }
    }
}
