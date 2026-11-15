import AccountContext
import Display
import Foundation
import GalleryUI
import SwiftSignalKit
import TelegramCore
import UIKit
import XCTest

private final class FeedReadyPresentation: ViewController {
    let readiness: Promise<Bool>
    private(set) var dismissals = 0
    var animateOutIsBusy = false
    override var ready: Promise<Bool> { self.readiness }

    init(ready: Bool) {
        self.readiness = Promise(ready)
        super.init(navigationBarPresentationData: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func dismiss(completion: (() -> Void)? = nil) {
        self.dismissals += 1
        if self.animateOutIsBusy { return }
        super.dismiss(completion: completion)
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        self.dismissals += 1
        super.dismiss(animated: flag, completion: completion)
    }
}

/// Actual Display presentation contexts + the production permit; no Account, Share fetch,
/// clipboard, Photos, Telegram reads/sends or external activity is constructed or executed.
@MainActor
final class FeedExportPermitTests: XCTestCase {
    private func host() -> (UIWindow, FeedReadyPresentation) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = FeedReadyPresentation(ready: true)
        window.rootViewController = root
        window.isHidden = false
        let layout = ContainerViewLayout(size: window.bounds.size, metrics: LayoutMetrics(widthClass: .compact, heightClass: .regular, orientation: .portrait), deviceMetrics: .iPhone13, intrinsicInsets: .zero, safeInsets: .zero, reservedCorners: .none, division: nil, additionalInsets: .zero, statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
        root.view.frame = window.bounds
        root.containerLayoutUpdated(layout, transition: .immediate)
        return (window, root)
    }

    func testReadyDelayedDirectShareAndRootDescendantsRevokeOnlyTheirOwnFlow() {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        let (window, root) = self.host()
        defer { permit.revoke(); window.isHidden = true; window.rootViewController = nil }

        let gallery = FeedReadyPresentation(ready: true)
        let rootShare = FeedReadyPresentation(ready: true)
        let otherFlow = FeedReadyPresentation(ready: true)
        let pendingDirectShare = FeedReadyPresentation(ready: false)
        let pendingDescendant = FeedReadyPresentation(ready: false)
        var latePresentations = 0
        permit.presentWhenReady(gallery, accountId: 11, from: root) { root.present($0, in: .current) }
        // Like GalleryFooter's mainWindow root path, Share is a SIBLING of Gallery.
        permit.presentWhenReady(rootShare, accountId: 11, from: gallery, requiresExport: true) { root.present($0, in: .current) }
        root.present(otherFlow, in: .current)
        permit.presentWhenReady(pendingDirectShare, accountId: 11, from: root, requiresExport: true) {
            latePresentations += 1; root.present($0, in: .current)
        }
        permit.presentWhenReady(pendingDescendant, accountId: 11, from: rootShare, requiresExport: true) {
            latePresentations += 1; root.present($0, in: .current)
        }
        XCTAssertTrue(root.presentationContext.controllers.contains { $0.0 === gallery })
        XCTAssertTrue(root.presentationContext.controllers.contains { $0.0 === rootShare })
        XCTAssertFalse(root.presentationContext.controllers.contains { $0.0 === pendingDirectShare })
        XCTAssertTrue(rootShare.exteralessExportPermit === permit)

        // Protection/scope/account retirement uses this same permanent revoke operation.
        permit.revoke()
        pendingDirectShare.readiness.set(.single(true))
        pendingDescendant.readiness.set(.single(true))
        XCTAssertEqual(gallery.dismissals, 1)
        XCTAssertEqual(rootShare.dismissals, 1)
        XCTAssertEqual(otherFlow.dismissals, 0)
        XCTAssertEqual(latePresentations, 0)
        XCTAssertEqual(permit.counters.presentations, 2)
        var exportPreparations = 0, saves = 0
        XCTAssertFalse(permit.perform(accountId: 11, operation: .exportPreparation) { exportPreparations += 1 })
        XCTAssertFalse(permit.perform(accountId: 11, operation: .exportEffect) { saves += 1 })
        XCTAssertEqual(exportPreparations, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(permit.counters.effects, 0)

        let afterNativeReadyTimeout = self.expectation(description: "no stock two-second timeout resurrection")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            XCTAssertEqual(latePresentations, 0)
            XCTAssertEqual(root.presentationContext.controllers.count, 1)
            XCTAssertTrue(root.presentationContext.controllers.first?.0 === otherFlow)
            otherFlow.dismiss()
            afterNativeReadyTimeout.fulfill()
        }
        self.wait(for: [afterNativeReadyTimeout], timeout: 3)
    }

    func testOriginalNativeItemGenerationStillGatesAQueuedOwnershipHandoff() {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        let (window, root) = self.host()
        defer { permit.revoke(); window.isHidden = true; window.rootViewController = nil }
        let itemLifetime = ExteralessGalleryActionLifetime()
        let original = itemLifetime.generation
        let pending = FeedReadyPresentation(ready: false)
        var prepares = 0
        let prepare: (ViewController) -> Bool = { controller in
            prepares += 1
            return permit.own(controller, presented: true)
        }
        XCTAssertTrue(prepare(pending))
        permit.presentWhenReady(pending, accountId: 11, from: root, requiresExport: true, additionalReady: itemLifetime.validity(of: original), prepare: prepare) { root.present($0, in: .current) }
        itemLifetime.invalidate() // A -> B
        itemLifetime.invalidate() // B -> A is a new native item generation.
        pending.readiness.set(.single(true))
        XCTAssertEqual(prepares, 1)
        XCTAssertTrue(root.presentationContext.controllers.isEmpty)
        XCTAssertEqual(permit.counters.presentations, 0)

        let current = FeedReadyPresentation(ready: false)
        XCTAssertTrue(prepare(current))
        permit.presentWhenReady(current, accountId: 11, from: root, requiresExport: true, additionalReady: itemLifetime.validity(of: itemLifetime.generation), prepare: prepare) { root.present($0, in: .current) }
        current.readiness.set(.single(true))
        XCTAssertEqual(prepares, 3, "The current flow is prepared before and after native readiness")
        XCTAssertTrue(current.exteralessExportPermit === permit)
        XCTAssertTrue(root.presentationContext.controllers.first?.0 === current)
        XCTAssertEqual(permit.counters.presentations, 1)
    }

    func testRevocationRemovesRootEvenWhenItsContentDismissAnimationIsAlreadyBusy() {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        let (window, root) = self.host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let share = FeedReadyPresentation(ready: true)
        permit.presentWhenReady(share, accountId: 11, from: root) { root.present($0, in: .current) }
        share.animateOutIsBusy = true
        permit.revoke()
        XCTAssertTrue(root.presentationContext.controllers.isEmpty)
        XCTAssertNil(share.viewIfLoaded?.window)
        XCTAssertEqual(share.dismissals, 1)
    }

    func testDetachedUIKitDescendantRetainsTheSameValidatorWithoutRetainingItsGallery() {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
        var owner: NSObject? = NSObject()
        weak var weakOwner = owner
        var gallery: UIViewController? = UIViewController()
        weak var weakGallery = gallery
        XCTAssertTrue(permit.retainOwner(owner!, on: gallery!))
        var share: UIViewController? = UIViewController()
        XCTAssertTrue(permit.own(share!, from: gallery))
        var activity: UIViewController? = UIViewController()
        XCTAssertTrue(permit.own(activity!, from: share))
        XCTAssertTrue(activity?.exteralessExportPermit === permit)
        gallery = nil
        share = nil
        owner = nil
        XCTAssertNil(weakGallery)
        XCTAssertNotNil(weakOwner, "The detached activity must retain fresh source observation")
        activity = nil
        XCTAssertNil(weakOwner, "The permit itself must not retain validators globally")
        permit.revoke()
    }

    func testAccountAndOriginalMessageSubsetCannotBeReplacedByAnotherPermit() {
        let a = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        let b = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(2), id: 7, timestamp: 100).id
        let permit = ExteralessContentExportPermit(accountId: 11, messageIds: [a], exportAllowed: true)
        let other = ExteralessContentExportPermit(accountId: 12, messageIds: [b], exportAllowed: true)
        let controller = UIViewController()
        var effects = 0
        XCTAssertFalse(permit.perform(accountId: 12, operation: .exportEffect) { effects += 1 })
        XCTAssertFalse(permit.perform(accountId: 11, messageIds: [b], operation: .exportEffect) { effects += 1 })
        XCTAssertTrue(permit.own(controller))
        XCTAssertFalse(other.own(controller))
        XCTAssertTrue(controller.exteralessExportPermit === permit)
        permit.revoke()
        XCTAssertFalse(permit.perform(accountId: 11, messageIds: [a], operation: .exportEffect) { effects += 1 })
        XCTAssertEqual(effects, 0)
        other.revoke()
    }
}
