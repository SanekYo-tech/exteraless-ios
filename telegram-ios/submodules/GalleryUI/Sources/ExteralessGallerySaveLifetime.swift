import AccountContext
import Display
import Foundation
import SwiftSignalKit
import UIKit

/// Item/player generation only, not another export grant. UI mutation invalidates before
/// replacement; the Photos change block reads the same generation under this lock.
final class ExteralessGallerySaveLifetime {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let value = ValuePromise<UInt64>(0, ignoreRepeated: true)
    // Accessed only by capture(from:accountId:) on main. Keep the original reference even
    // after the presenter disappears: an inherited flow must never fall back to stock nil.
    private var reference: ExteralessContentExportPermitReference?

    func invalidate() {
        self.lock.lock()
        self.generation &+= 1
        let generation = self.generation
        self.lock.unlock()
        self.value.set(generation)
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.generation == generation
    }

    func validity(_ generation: UInt64) -> Signal<Bool, NoError> {
        self.value.get() |> map { $0 == generation }
    }

    func check(_ generation: UInt64) -> () -> Bool {
        return { self.isCurrent(generation) }
    }

    @MainActor func capture(from presenter: ViewController?, accountId: Int64) -> ExteralessGallerySaveAccess? {
        if let presenter {
            let reference = presenter.exteralessExportPermitReference
            if let original = self.reference, original !== reference {
                original.permit?.revoke()
                return nil
            }
            self.reference = reference
        }
        guard let reference = self.reference else { return nil }
        // Only a real, attached presenter establishes an ordinary stock flow.
        if reference.permit == nil && presenter?.viewIfLoaded?.window == nil { return nil }
        self.lock.lock()
        let generation = self.generation
        self.lock.unlock()
        return ExteralessGallerySaveAccess(reference: reference, accountId: accountId, presenter: presenter, lifetime: self, generation: generation)
    }
}

@MainActor
final class ExteralessGallerySaveAccess {
    let reference: ExteralessContentExportPermitReference
    private let accountId: Int64
    private weak var presenter: ViewController?
    private let lifetime: ExteralessGallerySaveLifetime
    private let generation: UInt64
    private var receivedSuccess = false

    init(reference: ExteralessContentExportPermitReference, accountId: Int64, presenter: ViewController?, lifetime: ExteralessGallerySaveLifetime, generation: UInt64) {
        self.reference = reference
        self.accountId = accountId
        self.presenter = presenter
        self.lifetime = lifetime
        self.generation = generation
    }

    var permit: ExteralessContentExportPermit? { self.reference.permit }
    var current: () -> Bool { self.lifetime.check(self.generation) }
    var validity: Signal<Bool, NoError> { self.lifetime.validity(self.generation) }

    func canStart() -> Bool {
        guard let permit = self.permit else { return true }
        guard self.presenter?.viewIfLoaded?.window != nil, self.current(),
              permit.allows(accountId: self.accountId, operation: .exportPreparation) else {
            permit.revoke()
            return false
        }
        return true
    }

    func operation() -> ExteralessGallerySaveAccess? {
        guard self.canStart() else { return nil }
        // New receipt state, same captured generation and SAME grant/reference.
        return ExteralessGallerySaveAccess(reference: self.reference, accountId: self.accountId, presenter: self.presenter, lifetime: self.lifetime, generation: self.generation)
    }

    func receive(_ progress: Float) {
        if progress.isFinite && progress >= 1 { self.receivedSuccess = true }
    }

    func canReportSuccess() -> Bool {
        guard let permit = self.permit else { return true }
        guard self.receivedSuccess, self.canStart() else { permit.revoke(); return false }
        return true
    }

    func present(_ controller: ViewController, arguments: Any?) {
        guard self.canStart(), let presenter = self.presenter else { return }
        presenter.present(controller, in: .window(.root), with: arguments)
    }
}
