import Display
import Foundation
import ObjectiveC
import SwiftSignalKit
import TelegramCore
import UIKit

/// A single native content flow, including detached/root descendants and deferred effects.
/// Nil at a consumer means the ordinary native path. Revocation is permanent and synchronous
/// for admission; UIKit cleanup is delivered on main and touches only owned presentations.
public final class ExteralessContentExportPermit: @unchecked Sendable {
    public enum Operation: Equatable, Sendable { case presentation, exportPreparation, exportEffect }
    public struct Counters {
        public let presentations: Int
        public let preparations: Int
        public let effects: Int
        public let denied: Int
    }

    public let accountId: Int64
    public let messageIds: Set<EngineMessage.Id>
    private let exportAllowed: Bool
    private let lock = NSRecursiveLock()
    private var revoked = false
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private var presentationCount = 0
    private var preparationCount = 0
    private var effectCount = 0
    private var deniedCount = 0

    public init(accountId: Int64, messageIds: Set<EngineMessage.Id>, exportAllowed: Bool) {
        self.accountId = accountId
        self.messageIds = messageIds
        self.exportAllowed = exportAllowed
    }

    public func allows(accountId: Int64, messageIds: Set<EngineMessage.Id>? = nil, operation: Operation = .exportEffect) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.admitted(accountId: accountId, messageIds: messageIds, operation: operation)
    }

    private func admitted(accountId: Int64, messageIds: Set<EngineMessage.Id>?, operation: Operation) -> Bool {
        guard !self.revoked, accountId == self.accountId, !self.messageIds.isEmpty else { return false }
        if let messageIds, !messageIds.isSubset(of: self.messageIds) { return false }
        return operation == .presentation || self.exportAllowed
    }

    @discardableResult
    public func perform(accountId: Int64, messageIds: Set<EngineMessage.Id>? = nil, operation: Operation, current: () -> Bool = { true }, _ body: () -> Void) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.admitted(accountId: accountId, messageIds: messageIds, operation: operation), current() else { self.deniedCount += 1; return false }
        switch operation {
        case .presentation: self.presentationCount += 1
        case .exportPreparation: self.preparationCount += 1
        case .exportEffect: self.effectCount += 1
        }
        body()
        return true
    }

    public var counters: Counters {
        self.lock.lock(); defer { self.lock.unlock() }
        return Counters(presentations: self.presentationCount, preparations: self.preparationCount, effects: self.effectCount, denied: self.deniedCount)
    }

    public func onRevocation(_ handler: @escaping @MainActor () -> Void) -> Disposable {
        let id = UUID()
        self.lock.lock()
        let revoked = self.revoked
        if !revoked { self.handlers[id] = handler }
        self.lock.unlock()
        if revoked { Self.deliver([handler]) }
        return ActionDisposable { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.handlers.removeValue(forKey: id); self.lock.unlock()
        }
    }

    /// Cleanup for artifacts uniquely created by this flow (never shared caches/user files).
    public func addOwnedCleanup(_ handler: @escaping @MainActor () -> Void) {
        self.lock.lock()
        let revoked = self.revoked
        if !revoked { self.handlers[UUID()] = handler }
        self.lock.unlock()
        if revoked { Self.deliver([handler]) }
    }

    public func revoke() {
        self.lock.lock()
        guard !self.revoked else { self.lock.unlock(); return }
        self.revoked = true
        let handlers = Array(self.handlers.values)
        self.handlers.removeAll()
        self.lock.unlock()
        Self.deliver(handlers)
    }

    private static func deliver(_ handlers: [@MainActor () -> Void]) {
        if Thread.isMainThread { MainActor.assumeIsolated { for handler in handlers { handler() } } }
        else { DispatchQueue.main.async { for handler in handlers { handler() } } }
    }

    /// Rechecks at subscription and cancels owned continuations on revocation. Terminal
    /// side effects after an asynchronous wait also check/perform at their actual callsite.
    public func guardSignal<T, E>(accountId: Int64, messageIds: Set<EngineMessage.Id>? = nil, operation: Operation, _ source: @escaping () -> Signal<T, E>) -> Signal<T, E> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            let revoke = self.onRevocation { disposable.dispose() }
            // Starting/waiting is not an actual presentation or effect. Counters belong at
            // terminal perform callsites, and each delivered value is admitted again.
            self.lock.lock()
            if self.admitted(accountId: accountId, messageIds: messageIds, operation: operation) {
                disposable.set(source().start(next: { value in
                    if self.allows(accountId: accountId, messageIds: messageIds, operation: operation) { subscriber.putNext(value) }
                }, error: { error in
                    if self.allows(accountId: accountId, messageIds: messageIds, operation: operation) { subscriber.putError(error) }
                }, completed: {
                    if self.allows(accountId: accountId, messageIds: messageIds, operation: operation) { subscriber.putCompletion() }
                }))
            } else {
                self.deniedCount += 1
            }
            self.lock.unlock()
            return ActionDisposable { disposable.dispose(); revoke.dispose() }
        }
    }

    @MainActor @discardableResult
    public func own(_ controller: UIViewController, presented: Bool = false, from source: UIViewController? = nil) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.admitted(accountId: self.accountId, messageIds: nil, operation: .presentation) else { return false }
        if let binding = controller.exteralessExportBinding {
            guard binding.permit === self else { return false }
            binding.presented = binding.presented || presented
            if let previous = source?.exteralessExportBinding, previous.permit === self {
                binding.owners.merge(previous.owners, uniquingKeysWith: { old, _ in old })
            }
            controller.exteralessExportPermitReference.set(self, owners: binding.owners)
            return true
        }
        let binding = ExteralessExportPresentationBinding(permit: self, controller: controller)
        binding.presented = presented
        if let previous = source?.exteralessExportBinding, previous.permit === self { binding.owners = previous.owners }
        controller.exteralessExportPermitReference.set(self, owners: binding.owners)
        controller.exteralessExportBinding = binding
        return true
    }

    /// Keep a caller's source validator alive on a presentation. Native descendants inherit
    /// these owners through own(from:) / presentWhenReady; the permit does not retain them
    /// globally. Validators should retain their controllers weakly to avoid a cycle.
    @MainActor @discardableResult
    public func retainOwner(_ owner: AnyObject, on controller: UIViewController) -> Bool {
        guard self.own(controller), let binding = controller.exteralessExportBinding else { return false }
        binding.owners[ObjectIdentifier(owner)] = owner
        controller.exteralessExportPermitReference.set(self, owners: binding.owners)
        return true
    }

    /// Do not hand a pending controller to PresentationContext: its stock two-second timeout
    /// would present it even after revocation. Prepare layout, wait here, then call the native
    /// presenter on main only while its ready value is already true and this permit is valid.
    @MainActor
    public func presentWhenReady(_ controller: ViewController, accountId: Int64, from source: ViewController, requiresExport: Bool = false, additionalReady: Signal<Bool, NoError>? = nil, prepare: ((ViewController) -> Bool)? = nil, present: @escaping (ViewController) -> Void) {
        let operation: Operation = requiresExport ? .exportPreparation : .presentation
        guard self.allows(accountId: accountId, operation: operation), let window = source.viewIfLoaded?.window,
              let layout = source.currentlyAppliedLayout, self.own(controller, from: source), let binding = controller.exteralessExportBinding else { return }
        controller.view.frame = CGRect(origin: .zero, size: layout.size)
        controller.containerLayoutUpdated(layout, transition: .immediate)
        let ready = combineLatest(controller.ready.get(), additionalReady ?? .single(true)) |> map { $0 && $1 }
        binding.waiting.set((ready |> filter { $0 } |> take(1)
        |> timeout(10, queue: .mainQueue(), alternate: .single(false)) |> deliverOnMainQueue).start(next: { [weak self, weak source, weak window, controller, binding] ready in
            binding.waiting.set(nil)
            guard ready, let self, let source, let window, source.viewIfLoaded?.window === window,
                  self.allows(accountId: accountId, operation: operation) else { return }
            // Captured throughout the pending wait, but handoff must happen only after ready.
            // Otherwise an item/scope change during the wait could revive the old intent.
            guard prepare?(controller) ?? true else { return }
            self.perform(accountId: accountId, operation: .presentation) {
                guard self.allows(accountId: accountId, operation: operation) else { return }
                binding.presented = true
                present(controller)
            }
        }))
    }
}

private final class ExteralessExportPresentationBinding {
    let permit: ExteralessContentExportPermit
    let waiting = MetaDisposable()
    var presented = false
    var owners: [ObjectIdentifier: AnyObject] = [:]
    private var revoke: Disposable?

    @MainActor init(permit: ExteralessContentExportPermit, controller: UIViewController) {
        self.permit = permit
        self.revoke = permit.onRevocation { [weak self, weak controller] in
            guard let self else { return }
            self.waiting.set(nil)
            guard self.presented, let controller else { return }
            if controller.isViewLoaded { controller.view.isUserInteractionEnabled = false }
            // Bypass a content controller's optional animate-out completion: Share may
            // already be animating when revoked, and its success continuation must not
            // be needed to remove this root sibling from its native presentation context.
            controller.dismiss(animated: false)
        }
    }

    deinit { self.waiting.dispose(); self.revoke?.dispose() }
}

/// Capturable before a controller is presented. Download callbacks retain this reference so a
/// later attached/revoked permit cannot disappear merely because the Gallery deallocated.
public final class ExteralessContentExportPermitReference: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExteralessContentExportPermit?
    private var owners: [ObjectIdentifier: AnyObject] = [:]
    public var permit: ExteralessContentExportPermit? { self.lock.lock(); defer { self.lock.unlock() }; return self.value }
    fileprivate func set(_ value: ExteralessContentExportPermit, owners: [ObjectIdentifier: AnyObject]) {
        self.lock.lock()
        self.value = value
        self.owners = owners
        self.lock.unlock()
    }
}

private enum ExteralessExportAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
    nonisolated(unsafe) static var referenceKey: UInt8 = 0
}

public extension UIViewController {
    @MainActor var exteralessExportPermit: ExteralessContentExportPermit? { self.exteralessExportPermitReference.permit }
    @MainActor var exteralessExportPermitReference: ExteralessContentExportPermitReference {
        if let value = objc_getAssociatedObject(self, &ExteralessExportAssociation.referenceKey) as? ExteralessContentExportPermitReference { return value }
        let value = ExteralessContentExportPermitReference()
        objc_setAssociatedObject(self, &ExteralessExportAssociation.referenceKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
}

private extension UIViewController {
    @MainActor var exteralessExportBinding: ExteralessExportPresentationBinding? {
        get { objc_getAssociatedObject(self, &ExteralessExportAssociation.key) as? ExteralessExportPresentationBinding }
        set { objc_setAssociatedObject(self, &ExteralessExportAssociation.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
