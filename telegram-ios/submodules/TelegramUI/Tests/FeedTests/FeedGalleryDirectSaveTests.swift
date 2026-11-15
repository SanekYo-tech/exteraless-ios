import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import XCTest
@testable import GalleryUI
@testable import SaveToCameraRoll

/// Exercises the same retained-reference/generation and Photos sink seam used by the
/// four direct item Save actions. No Account, file read, Photos or export is performed.
final class FeedGalleryDirectSaveTests: XCTestCase, @unchecked Sendable {
    @MainActor private func host(permit: ExteralessContentExportPermit?) -> (UIWindow, ViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = ViewController(navigationBarPresentationData: nil)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        if let permit { XCTAssertTrue(permit.own(controller)) }
        return (window, controller)
    }

    @MainActor private func permit() -> ExteralessContentExportPermit {
        let id = FeedNativeFixtures.message(channel: FeedNativeFixtures.channel(1), id: 7, timestamp: 100).id
        return ExteralessContentExportPermit(accountId: 11, messageIds: [id], exportAllowed: true)
    }

    @MainActor func testMissingPresenterNeverTurnsAnInheritedSaveIntoStockNil() throws {
        let permit = self.permit()
        let (window, controller) = self.host(permit: permit)
        defer { permit.revoke(); window.isHidden = true; window.rootViewController = nil }
        let lifetime = ExteralessGallerySaveLifetime()
        let initial = try XCTUnwrap(lifetime.capture(from: controller, accountId: 11))
        XCTAssertTrue(initial.canStart())
        window.rootViewController = nil
        controller.view.removeFromSuperview()
        let delayed = try XCTUnwrap(lifetime.capture(from: nil, accountId: 11))
        XCTAssertTrue(delayed.reference === initial.reference)
        XCTAssertTrue(delayed.permit === permit)
        XCTAssertFalse(delayed.canStart())
        XCTAssertFalse(permit.allows(accountId: 11))
        XCTAssertNil(ExteralessGallerySaveLifetime().capture(from: nil, accountId: 11))
    }

    @MainActor func testOnlyAnAttachedStockPresenterEstablishesNilSemantics() throws {
        let (window, controller) = self.host(permit: nil)
        defer { window.isHidden = true; window.rootViewController = nil }
        let lifetime = ExteralessGallerySaveLifetime()
        let stock = try XCTUnwrap(lifetime.capture(from: controller, accountId: 11))
        XCTAssertNil(stock.permit)
        XCTAssertTrue(stock.canStart())
        XCTAssertTrue(stock.canReportSuccess(), "The stock helper keeps its ordinary completion convention")
    }

    @MainActor func testItemPlayerReplacementRevokesAHeldPermissionAndCannotReviveOnReturn() throws {
        let permit = self.permit()
        let (window, controller) = self.host(permit: permit)
        defer { permit.revoke(); window.isHidden = true; window.rootViewController = nil }
        let lifetime = ExteralessGallerySaveLifetime()
        let access = try XCTUnwrap(lifetime.capture(from: controller, accountId: 11)?.operation())
        var permission: ((Bool) -> Void)?
        var preparations = 0, effects = 0, success = 0
        let input = ExteralessCameraRollData(main: .init(path: "injected-only", availableSize: 1, isComplete: true), video: nil, isImage: true)
        let sinks = ExteralessCameraRollSinks(authorize: { permission = $0; return EmptyDisposable }, prepare: { _, _ in
            preparations += 1; return EmptyDisposable
        }, save: { _, commit, completed in
            completed(commit { effects += 1 }); return EmptyDisposable
        })
        let pending = exteralessCameraRollSave(input: .single(.ready(input)), permit: permit, accountId: 11, owner: access.reference, current: access.current, validity: access.validity, sinks: sinks).start(next: { if $0 == 1 { success += 1 } })
        defer { pending.dispose() }
        lifetime.invalidate() // Item/player replaced before the delayed permission callback.
        lifetime.invalidate() // Same item appears again with a different generation.
        permission?(true)
        XCTAssertFalse(access.current())
        XCTAssertFalse(permit.allows(accountId: 11))
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(success, 0)
    }

    @MainActor func testPhotosFinalGenerationCheckWorksEvenWhenValidityDeliveryIsHeld() throws {
        let permit = self.permit()
        let (window, controller) = self.host(permit: permit)
        defer { permit.revoke(); window.isHidden = true; window.rootViewController = nil }
        let lifetime = ExteralessGallerySaveLifetime()
        let access = try XCTUnwrap(lifetime.capture(from: controller, accountId: 11)?.operation())
        var commit: ((() -> Void) -> Bool)?
        var completed: ((Bool) -> Void)?
        var effects = 0, receipts = 0, cleanups = 0
        let input = ExteralessCameraRollData(main: .init(path: "injected-only", availableSize: 1, isComplete: true), video: nil, isImage: true)
        let sinks = ExteralessCameraRollSinks(authorize: { $0(true); return EmptyDisposable }, prepare: { _, next in
            next(ExteralessCameraRollPrepared(content: .image(Data([1])), cleanup: ActionDisposable { cleanups += 1 }))
            return EmptyDisposable
        }, save: { _, effect, next in commit = effect; completed = next; return EmptyDisposable })
        let pending = exteralessCameraRollSave(input: .single(.ready(input)), permit: permit, accountId: 11, owner: access.reference, current: access.current, validity: .single(true), sinks: sinks).start(next: { if $0 == 1 { receipts += 1 } })
        defer { pending.dispose() }
        lifetime.invalidate()
        XCTAssertTrue(permit.allows(accountId: 11), "Simulate a validity notification still waiting for main")
        XCTAssertFalse(commit?({ effects += 1 }) ?? true)
        completed?(true)
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(receipts, 0)
        XCTAssertEqual(cleanups, 1)
        XCTAssertFalse(permit.allows(accountId: 11))
    }

    @MainActor func testEachSaveAttemptNeedsItsOwnReceiptAndCannotRenewAnOldGeneration() throws {
        let permit = self.permit()
        let (window, controller) = self.host(permit: permit)
        defer { permit.revoke(); window.isHidden = true; window.rootViewController = nil }
        let lifetime = ExteralessGallerySaveLifetime()
        let captured = try XCTUnwrap(lifetime.capture(from: controller, accountId: 11))
        let first = try XCTUnwrap(captured.operation())
        first.receive(1)
        XCTAssertTrue(first.canReportSuccess())
        let second = try XCTUnwrap(captured.operation())
        XCTAssertTrue(second.reference === first.reference)
        XCTAssertTrue(second.permit === permit)
        second.receive(0.99)
        XCTAssertFalse(second.canReportSuccess())
        lifetime.invalidate()
        XCTAssertNil(captured.operation())
        XCTAssertFalse(captured.current())
    }
}
