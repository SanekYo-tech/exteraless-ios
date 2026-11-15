import AccountContext
import Display
import Foundation
import MediaPlayer
import SwiftSignalKit
import UIKit
import XCTest
@testable import Postbox
@testable import TelegramCore
@testable import TelegramUI
@testable import GalleryUI

@MainActor
final class ChatMediaRemediationNativeTests: XCTestCase {
    func testCMC03ActualSavedSelectionCallbacksReloadBothPrivateFlagsAndAllowReopenedAction() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        let second = EngineMessage.Id(peerId: db.peer, namespace: Namespaces.Message.Cloud, id: 2)
        try db.transaction { transaction in _ = transaction.addMessages([db.stored(id: 2, text: "second selected")], location: .Random) }
        let protections: [CachedUserFlags] = [[.copyProtectionEnabled], [.myCopyProtectionEnabled]]
        for flags in protections {
            for kind in ExteralessSelectionExportAction.allCases {
                try db.protect([])
                let ids: Set<EngineMessage.Id> = [db.id, second]
                let access = db.access(ids: ids)
                let session = db.session(access)
                var menuShown = false
                session.read(requiresCopy: false, operation: .presentation) { snapshot, actions in menuShown = kind.isAvailable(snapshot, actions) }
                XCTAssertTrue(menuShown)
                var effects = 0
                let captured = session.action(kind) { snapshot, _ in XCTAssertEqual(Set(snapshot.messages.map(\.id)), ids); effects += 1 }
                let version = try db.message().stableVersion
                try db.protect(flags)
                XCTAssertEqual(try db.message().stableVersion, version)
                captured()
                XCTAssertEqual(effects, 0, "\(kind)")
                XCTAssertFalse(access.permit.allows(accountId: db.accountId))
                access.cancel()
                try db.protect([])
                let fresh = db.access(ids: ids)
                db.session(fresh).action(kind) { _, _ in effects += 1 }()
                XCTAssertEqual(effects, 1, "\(kind)")
                fresh.cancel()
            }
        }
    }

    func testCMC03SameIdsReplacementSelectionThreadPresentationAndAccountAreNotCapabilities() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        var selection: Set<EngineMessage.Id> = [db.id]
        let validity = ValuePromise(true, ignoreRepeated: true)
        let accounts = ValuePromise(true, ignoreRepeated: true)
        var effects = 0
        let access = db.access(account: accounts.get(), validity: validity.get(), current: { selection == [db.id] })
        let session = db.session(access)
        session.read(requiresCopy: false, operation: .presentation) { _, _ in }
        let old = session.action(requiresCopy: true) { _, _ in effects += 1 }
        try db.transaction { $0.updateMessage(db.id, update: { _ in .update(db.stored(text: "replacement", thread: 42)) }) }
        old()
        XCTAssertEqual(effects, 0)
        access.cancel()
        for invalidation in 0 ..< 3 {
            let current = db.access(account: accounts.get(), validity: validity.get(), current: { selection == [db.id] })
            let callback = db.session(current).action(requiresCopy: true) { _, _ in effects += 1 }
            switch invalidation {
            case 0: accounts.set(false); accounts.set(true)
            case 1: validity.set(false); validity.set(true)
            default: selection = []; validity.set(false); selection = [db.id]; validity.set(true)
            }
            callback()
            XCTAssertEqual(effects, 0)
            current.cancel()
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let source = UIView(frame: window.bounds)
        window.addSubview(source)
        let presentation = db.access(sourceView: source)
        let callback = db.session(presentation).action(.copy) { _, _ in effects += 1 }
        source.removeFromSuperview()
        window.addSubview(source)
        callback()
        XCTAssertEqual(effects, 0, "reattaching the same UIView must not revive the old action")
        presentation.cancel()
        let covered = db.access(sourceView: source)
        let picker = ViewController(navigationBarPresentationData: nil)
        XCTAssertTrue(covered.coverSource(with: picker))
        source.removeFromSuperview()
        window.addSubview(picker.view)
        var accepted = 0
        covered.perform { _ in accepted += 1 }
        XCTAssertEqual(accepted, 1, "an owned native picker may cover its source")
        covered.expectCoverDismissal()
        picker.view.removeFromSuperview()
        window.addSubview(source)
        covered.perform { _ in accepted += 1 }
        XCTAssertEqual(accepted, 2, "accepted picker dismissal keeps the same source permit")
        covered.cancel()
    }

    func testCMC03PendingDestinationAndDraftConfirmationUseOriginalPermit() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        let permit = ExteralessContentExportPermit(accountId: db.accountId, messageIds: [db.id], exportAllowed: true)
        let access = db.access(permit: permit)
        defer { access.cancel() }
        let session = db.session(access)
        let picker = ViewController(navigationBarPresentationData: nil)
        var destination: (() -> Void)?
        var draftConfirmation: (() -> Void)?
        var effects = 0
        session.action(requiresCopy: true, operation: .exportPreparation) { _, _ in
            XCTAssertTrue(access.own(picker))
            destination = { session.read(requiresCopy: true, operation: .exportEffect) { _, _ in effects += 1 } }
            draftConfirmation = { session.read(requiresCopy: true, operation: .exportEffect) { _, _ in effects += 1 } }
        }()
        XCTAssertTrue(picker.exteralessExportPermit === permit)
        XCTAssertNotNil(destination)
        try db.protect([.myCopyProtectionEnabled])
        destination?()
        draftConfirmation?()
        XCTAssertEqual(effects, 0)
        XCTAssertFalse(permit.allows(accountId: db.accountId))
        try db.protect([])
        let inheritedDenial = ExteralessContentExportPermit(accountId: db.accountId, messageIds: [db.id], exportAllowed: false)
        let denied = db.access(permit: inheritedDenial)
        defer { denied.cancel() }
        XCTAssertTrue(denied.permit === inheritedDenial)
        denied.perform(requiresCopy: false, operation: .presentation) { snapshot in XCTAssertFalse(snapshot.canCopy) }
        denied.perform { _ in effects += 1 }
        XCTAssertEqual(effects, 0, "a fresh Core grant must not replace the inherited FU-02 denial")
    }

    func testCMC04HeldFetchAndDecodeCannotExportAfterRevocationDeletionReplacementOrCancel() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        for reason in 0 ..< 6 {
            try db.protect([])
            try db.transaction { transaction in _ = transaction.addMessages([db.stored(media: [db.imageB])], location: .Random) }
            let message = try db.message()
            let accounts = ValuePromise(true, ignoreRepeated: true)
            let access = db.access(expected: [message], account: accounts.get())
            let spy = ChatMediaExportSpy()
            spy.holdFetch = reason == 0
            let selection = try XCTUnwrap(ExteralessGalleryMediaSelection(message: message, subject: nil, itemGeneration: UUID()))
            let operation = ExteralessImageActionOperation(access: access, action: .copy, reference: selection.reference(in:), timestamp: nil, services: spy.services)
            operation.start()
            XCTAssertEqual(spy.references.count, 1)
            switch reason {
            case 0: try db.protect([.copyProtectionEnabled])
            case 1: try db.protect([.myCopyProtectionEnabled])
            case 2: try db.transaction { $0.deleteMessages([db.id], forEachMedia: { _ in }) }
            case 3: try db.transaction { $0.updateMessage(db.id, update: { _ in .update(db.stored(media: [db.imageA])) }) }
            case 4: accounts.set(false); accounts.set(true)
            default: operation.cancel()
            }
            spy.fetch.putNext(URL(fileURLWithPath: "/not-read"))
            spy.decode.putNext(UIImage())
            XCTAssertEqual(spy.effects, 0, "reason \(reason)")
            if reason == 0 { XCTAssertEqual(spy.imageDecodes, 0) }
            operation.cancel()
            spy.clear()
        }
    }

    func testCMC04ActualQRAndProfilePromptCallbacksAndHeldProfileReadReauthorize() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        try db.setRich([db.imageB])
        for mode in 0 ..< 3 {
            try db.protect([])
            let message = try db.message()
            let access = db.access(expected: [message])
            let selection = try XCTUnwrap(ExteralessGalleryMediaSelection(message: message, subject: .richTextMedia(db.imageB.imageId), itemGeneration: UUID()))
            let spy = ChatMediaExportSpy()
            spy.holdProfile = mode == 2
            let operation = ExteralessImageActionOperation(access: access, action: mode == 0 ? .scanQR : .profile, reference: selection.reference(in:), timestamp: nil, services: spy.services)
            operation.start()
            spy.decode.putNext(UIImage())
            if mode == 0 { XCTAssertNotNil(spy.copyQR) } else { XCTAssertNotNil(spy.confirmProfile) }
            if mode == 2 { spy.confirmProfile?(); XCTAssertEqual(spy.preparedProfile, 1) }
            try db.protect(mode == 1 ? [.copyProtectionEnabled] : [.myCopyProtectionEnabled])
            if mode == 0 { spy.copyQR?(); spy.openQR?() }
            else if mode == 1 { spy.confirmProfile?() }
            else { spy.profile.putNext({ spy.effects += 1 }) }
            XCTAssertEqual(spy.effects, 0)
            operation.cancel()
            spy.clear()
        }
    }

    func testCMC09TwentySecondVideoPassesExactPlaybackDoubleMissingStatusFailsAndOldGenerationCancels() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        try db.setRich([db.imageA, db.video])
        let message = try db.message()
        for mode in 0 ..< 3 {
            let lifetime = ExteralessGalleryActionLifetime()
            let selection = try XCTUnwrap(ExteralessGalleryMediaSelection(message: message, subject: .richTextMedia(db.video.fileId), itemGeneration: lifetime.generation))
            let access = db.access(expected: [message], validity: lifetime.validity(of: lifetime.generation))
            let spy = ChatMediaExportSpy()
            let status = MediaPlayerStatus(generationTimestamp: 10, duration: 20, dimensions: CGSize(width: 2, height: 2), timestamp: 8.25, baseRate: 1, seekId: 0, status: .paused, soundEnabled: false)
            let sample = UniversalVideoGalleryItemNode.exteralessImageActionPlaybackSample(status: mode == 1 ? nil : status, now: 10)
            let operation = ExteralessImageActionOperation(access: access, action: .copy, reference: selection.reference(in:), timestamp: sample?.timestamp, services: spy.services)
            operation.start()
            if mode == 1 {
                XCTAssertTrue(spy.timestamps.isEmpty)
                XCTAssertTrue(spy.references.isEmpty)
                XCTAssertEqual(spy.notices.count, 1)
            } else {
                XCTAssertEqual(spy.timestamps, [8.25])
                XCTAssertEqual(spy.imageDecodes, 0)
                if mode == 2 { lifetime.invalidate() }
                spy.decode.putNext(UIImage())
                XCTAssertEqual(spy.effects, mode == 0 ? 1 : 0)
            }
            operation.cancel()
        }
    }

    func testCMC10RichBandMixedMediaUseNativeReferenceAndDoNotFlattenOrFallback() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        try db.setRich([db.imageA, db.imageB, db.video])
        let message = try db.message()
        let generation = UUID()
        let selection = try XCTUnwrap(ExteralessGalleryMediaSelection(message: message, subject: .richTextMedia(db.imageB.imageId), itemGeneration: generation))
        let access = db.access(expected: [message])
        let spy = ChatMediaExportSpy()
        let operation = ExteralessImageActionOperation(access: access, action: .copy, reference: selection.reference(in:), timestamp: nil, services: spy.services)
        operation.start()
        XCTAssertEqual(spy.references.first?.media.id, db.imageB.id)
        XCTAssertTrue((spy.references.first?.media as? TelegramMediaImage)?.representations.first?.resource.isEqual(to: db.imageB.representations[0].resource) == true)
        XCTAssertTrue(message.media.isEmpty)
        XCTAssertEqual(message.richText?.instantPage, try db.message().richText?.instantPage)
        spy.decode.putNext(UIImage())
        XCTAssertEqual(spy.effects, 1)
        operation.cancel()
        XCTAssertNil(ExteralessGalleryMediaSelection(message: message, subject: .richTextMedia(MediaId(namespace: Namespaces.Media.CloudImage, id: 999)), itemGeneration: generation))
        let empty = EngineMessage(message._asMessage().withUpdatedAttributes([]))
        XCTAssertNil(ExteralessGalleryMediaSelection(message: empty, subject: nil, itemGeneration: generation))
        let replaced = EngineMessage(message._asMessage().withUpdatedAttributes([db.rich([db.imageA, ChatMediaNativeFixture.image(12, resource: 999), db.video])]))
        XCTAssertEqual(message.stableVersion, replaced.stableVersion)
        XCTAssertFalse(exteralessChatExportSourceEqual(message, replaced))
        XCTAssertNil(selection.reference(in: replaced))
        let missingAccess = db.access(expected: [message])
        let missingSpy = ChatMediaExportSpy()
        let missing = ExteralessImageActionOperation(access: missingAccess, action: .copy, reference: { _ in nil }, timestamp: nil, services: missingSpy.services)
        missing.start()
        XCTAssertEqual(missingSpy.notices, ["The selected attachment is unavailable."])
        XCTAssertTrue(missingSpy.references.isEmpty)
        missing.cancel()
    }

    func testCMC04NativeCachedDataObserverRevokesOwnedPresentationWithUnchangedMessageVersion() throws {
        let db = try ChatMediaNativeFixture()
        defer { db.close() }
        let access = db.access()
        defer { access.cancel() }
        let prompt = ViewController(navigationBarPresentationData: nil)
        let revoked = expectation(description: "native cached-data observer")
        access.perform(operation: .presentation) { _ in XCTAssertTrue(access.own(prompt)) }
        access.onInvalidated = { revoked.fulfill() }
        let version = try db.message().stableVersion
        try db.protect([.copyProtectionEnabled])
        wait(for: [revoked], timeout: 1)
        XCTAssertEqual(try db.message().stableVersion, version)
        XCTAssertFalse(prompt.exteralessExportPermit?.allows(accountId: db.accountId) ?? true)
    }
}
