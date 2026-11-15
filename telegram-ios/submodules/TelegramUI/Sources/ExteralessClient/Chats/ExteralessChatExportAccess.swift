import AccountContext
import ChatPresentationInterfaceState
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Reads the real, local Core scope. In particular this includes BOTH CachedUserData
/// protection flags and associated-peer identity; the channel-only Feed projection
/// is not a private-chat authorization source.
struct ExteralessChatExportSource {
    let read: (Set<EngineMessage.Id>, AINativeOperationLease) -> Signal<[ExteralessAIScope]?, NoError>
    let validate: ([ExteralessAIScope]) -> Signal<Bool, NoError>
    let observe: ([ExteralessAIScope]) -> Signal<Bool, NoError>

    init(engine: TelegramEngine) {
        self.read = { ids, lease in
            engine.data.get(EngineDataMap(ids.sorted().map(TelegramEngine.EngineData.Item.Messages.Message.init)))
            |> mapToSignal { values -> Signal<[ExteralessAIScope]?, NoError> in
                let messages = ids.sorted().compactMap { values[$0] ?? nil }
                guard messages.count == ids.count else { return .single(nil) }
                return combineLatest(messages.map { message in
                    engine.messages.resolveExteralessAIScope(capability: .init(messageId: message.id, expectedStableVersion: message.stableVersion, peerId: message.id.peerId, threadId: message.threadId, allowsExternalProcessing: false, allowsCopy: true), lease: lease)
                }) |> map { scopes in
                    let present = scopes.compactMap { $0 }
                    return present.count == ids.count ? present : nil
                }
            }
        }
        self.validate = { scopes in
            return combineLatest(scopes.map { scope -> Signal<Bool, NoError> in
                guard let source = scope.source else { return .single(false) }
                let expected = exteralessChatExportBaseline(source)
                return engine.messages.validateExteralessAIScope(scope) |> mapToSignal { valid -> Signal<Bool, NoError> in
                    guard valid else { return .single(false) }
                    // Couple the last actual message/media read and BOTH cached
                    // protection flags in the same Core acquisition transaction.
                    return engine.messages.resolveExteralessAIScope(capability: scope.capability, lease: scope.lease) |> map { fresh in
                        guard let fresh, let current = fresh.source, !scope.allowsCopy || fresh.allowsCopy else { return false }
                        return exteralessChatExportSourceEqual(expected, current)
                    }
                }
            }) |> map { !$0.isEmpty && $0.allSatisfy { $0 } }
        }
        self.observe = { scopes in
            let expected = scopes.compactMap(\.source).map(exteralessChatExportBaseline)
            let ids = Set(expected.map(\.id))
            return combineLatest(
                combineLatest(scopes.map { engine.messages.exteralessAIScopeValidity($0) }),
                engine.data.subscribe(EngineDataMap(ids.sorted().map(TelegramEngine.EngineData.Item.Messages.Message.init)))
            ) |> map { valid, values in
                valid.allSatisfy { $0 } && expected.allSatisfy { previous in
                    guard let value = values[previous.id] ?? nil else { return false }
                    return exteralessChatExportSourceEqual(previous, value)
                }
            }
        }
    }

    /// Native in-memory tests inject Postbox transactions at the same Core boundary.
    init(read: @escaping (Set<EngineMessage.Id>, AINativeOperationLease) -> Signal<[ExteralessAIScope]?, NoError>, validate: @escaping ([ExteralessAIScope]) -> Signal<Bool, NoError>, observe: @escaping ([ExteralessAIScope]) -> Signal<Bool, NoError>) {
        self.read = read
        self.validate = validate
        self.observe = observe
    }
}

/// EngineMessage equality intentionally only compares the NUMBER of attributes.
/// Preserve and compare the native rich/media payload, not a flattened projection.
func exteralessChatExportSourceEqual(_ previous: EngineMessage, _ current: EngineMessage) -> Bool {
    guard previous.stableId == current.stableId, previous == current,
          previous.attributes.count == current.attributes.count else { return false }
    for (lhs, rhs) in zip(previous.attributes, current.attributes) where lhs !== rhs {
        if let lhs = lhs as? RichTextMessageAttribute {
            guard let rhs = rhs as? RichTextMessageAttribute, lhs == rhs else { return false }
            // InstantPage's native equality compares media by key. Its encoded
            // dictionary iteration order is not a content revision.
            continue
        }
        let a = EnginePostboxEncoder(), b = EnginePostboxEncoder()
        a.encodeRootObject(lhs)
        b.encodeRootObject(rhs)
        if a.makeData() != b.makeData() { return false }
    }
    let oldMedia = previous._asMessage().effectiveMedia
    let newMedia = current._asMessage().effectiveMedia
    return oldMedia.count == newMedia.count && zip(oldMedia, newMedia).allSatisfy { pair in pair.0.isEqual(to: pair.1) }
}

private func exteralessChatExportBaseline(_ message: EngineMessage) -> EngineMessage {
    // fullInstantPage is the one mutable field on the rich attribute. Freeze its
    // reference for comparison without flattening or altering the exported value.
    EngineMessage(message._asMessage().withUpdatedAttributes(message.attributes.map { attribute in
        if let rich = attribute as? RichTextMessageAttribute { return RichTextMessageAttribute(instantPage: rich.instantPage, fullInstantPage: rich.fullInstantPage) }
        return attribute
    }))
}

struct ExteralessChatExportSnapshot {
    let messages: [EngineMessage]
    let canCopy: Bool
}

/// One operation from its original sheet through fetch/decode and every confirmation.
/// An inherited FU-02 permit is used by identity, never replaced by a permissive one.
/// Revocation is permanent: A -> B -> A cannot revive a captured callback.
@MainActor
final class ExteralessChatExportAccess {
    let permit: ExteralessContentExportPermit
    let accountId: Int64
    let ids: Set<EngineMessage.Id>
    private let source: ExteralessChatExportSource
    private let current: () -> Bool
    private let presentationCurrent: () -> Bool
    private let accountValidity: Signal<Bool, NoError>
    private weak var sourceWindow: UIWindow?
    private weak var coveringController: UIViewController?
    private var coveringControllerMayExit = false
    private var presentations: [ExteralessChatExportPresentation] = []
    private let copyAllowed: () -> Bool
    private let lease = AINativeOperationLease()
    private let work = DisposableSet()
    private let observation = MetaDisposable()
    private var expected: [EngineMessage]?
    private var accountIsCurrent = false
    private var observing = false
    private var invalidated = false
    private var sourcePresentationDetached = false
    private var nativeEffectsDelegated = false
    var selectionCommitted: (() -> Void)?
    var onInvalidated: (() -> Void)?

    init(accountId: Int64, ids: Set<EngineMessage.Id>, expected: [EngineMessage]? = nil, permit: ExteralessContentExportPermit? = nil, source: ExteralessChatExportSource, accountIsCurrent: Signal<Bool, NoError>, presentationValidity: Signal<Bool, NoError> = .single(true), sourceWindow: UIWindow? = nil, sourceView: UIView? = nil, current: @escaping () -> Bool, presentationCurrent: @escaping () -> Bool = { true }, copyAllowed: @escaping () -> Bool = { true }) {
        self.accountId = accountId
        self.ids = ids
        self.expected = expected?.map(exteralessChatExportBaseline)
        self.permit = permit ?? ExteralessContentExportPermit(accountId: accountId, messageIds: ids, exportAllowed: true)
        self.source = source
        self.current = current
        self.presentationCurrent = presentationCurrent
        self.accountValidity = accountIsCurrent
        self.sourceWindow = sourceWindow
        self.copyAllowed = copyAllowed
        self.work.add(self.observation)
        self.work.add(self.permit.onRevocation { [weak self] in self?.invalidate() })
        self.work.add((accountIsCurrent |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            self.accountIsCurrent = value
            if !value { self.invalidate() }
        }))
        self.work.add((presentationValidity |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            if !value && !self.sourcePresentationDetached { self.invalidate() }
        }))
        if let sourceView {
            self.observeWindowExit(of: sourceView) { [weak self] in
                guard let self, !self.sourcePresentationDetached, self.coveringController == nil else { return }
                self.invalidate()
            }
        }
        if ids.isEmpty || ids.count > 100 || !self.permit.allows(accountId: accountId, messageIds: ids, operation: .presentation) { self.invalidate() }
    }

    convenience init(context: AccountContext, ids: Set<EngineMessage.Id>, expected: [EngineMessage]? = nil, permit: ExteralessContentExportPermit? = nil, presentationValidity: Signal<Bool, NoError> = .single(true), sourceWindow: UIWindow? = nil, sourceView: UIView? = nil, current: @escaping () -> Bool, presentationCurrent: @escaping () -> Bool = { true }, copyAllowed: @escaping () -> Bool = { true }) {
        self.init(accountId: context.account.id.int64, ids: ids, expected: expected, permit: permit, source: ExteralessChatExportSource(engine: context.engine), accountIsCurrent: combineLatest(context.sharedContext.activeAccountContexts, context.sharedContext.applicationBindings.applicationInForeground) |> map { accounts, foreground in accounts.primary === context && foreground }, presentationValidity: presentationValidity, sourceWindow: sourceWindow, sourceView: sourceView, current: current, presentationCurrent: presentationCurrent, copyAllowed: copyAllowed)
    }

    deinit {
        self.lease.cancel()
        self.work.dispose()
    }

    var isCurrent: Bool {
        guard !self.invalidated, !self.lease.isCancelled else { return false }
        let ownedPresentation = self.sourceWindow.map { window in self.presentations.contains { $0.controller?.viewIfLoaded?.window === window } } ?? false
        guard self.sourcePresentationDetached || self.current(), self.presentationCurrent() || ownedPresentation, self.permit.allows(accountId: self.accountId, messageIds: self.ids, operation: .presentation) else { self.invalidate(); return false }
        return self.accountIsCurrent
    }

    func invalidate() {
        guard !self.invalidated else { return }
        self.permit.revoke()
        self.cancel()
    }

    /// Ordinary Cancel ends this operation without revoking an inherited Gallery
    /// flow. Its callbacks still fail permanently through this cancelled lease.
    func cancel() {
        guard !self.invalidated else { return }
        self.invalidated = true
        self.lease.cancel()
        if self.nativeEffectsDelegated { self.permit.revoke() }
        self.work.dispose()
        self.onInvalidated?()
    }

    func add(_ disposable: Disposable) { self.work.add(disposable) }

    var presentationController: ViewController? {
        guard let window = self.sourceWindow else { return nil }
        return self.presentations.reversed().compactMap { $0.controller as? ViewController }.first { $0.viewIfLoaded?.window === window }
    }

    private func observeWindowExit(of view: UIView, exited: @escaping () -> Void) {
        let observer = ExteralessChatExportWindowObserver(exited: exited)
        view.addSubview(observer)
        self.work.add(ActionDisposable { [weak observer] in
            Queue.mainQueue().async { MainActor.assumeIsolated { observer?.removeFromSuperview() } }
        })
    }

    /// A native picker may temporarily cover the source. Unrelated removal and
    /// return of the same source view is still a new presentation lifetime.
    @discardableResult
    func coverSource(with controller: ViewController) -> Bool {
        guard self.own(controller, presented: true) else { return false }
        self.coveringController = controller
        self.coveringControllerMayExit = false
        self.observeWindowExit(of: controller.view) { [weak self, weak controller] in
            guard let self, let controller, self.coveringController === controller else { return }
            self.coveringController = nil
            if !self.sourcePresentationDetached && !self.coveringControllerMayExit { self.invalidate() }
        }
        return true
    }

    func expectCoverDismissal() {
        guard self.isCurrent else { return }
        self.coveringControllerMayExit = true
    }

    /// Transfer the ORIGINAL permit/lease and immutable source to the native
    /// destination write. The returned executor has no MainActor or UI reads.
    func draftWriteAdmission(peerId: EnginePeer.Id, threadId: Int64?, permit recordedPermit: ExteralessContentExportPermit?, accountId recordedAccountId: Int64, sourceMessageIds recordedIds: Set<EngineMessage.Id>?) -> ChatInterfaceStateWriteAdmission {
        let sources = self.expected ?? []
        let identityMatches = self.isCurrent && self.copyAllowed() && recordedPermit === self.permit && recordedAccountId == self.accountId && recordedIds == self.ids && Set(sources.map(\.id)) == self.ids
        let admission = exteralessMakeForwardDraftAdmission(accountId: self.accountId, peerId: peerId, threadId: threadId, sourceMessages: sources, sourceIds: self.ids, permit: self.permit, lease: self.lease, identityMatches: identityMatches)
        self.work.add(ActionDisposable { admission.cancel() })
        return admission
    }

    /// Body runs on main, inside the SAME permit's terminal admission. Call again
    /// after every async hop; a previously returned snapshot is not authorization.
    func perform(requiresCopy: Bool = true, operation: ExteralessContentExportPermit.Operation = .exportEffect, _ body: @escaping (ExteralessChatExportSnapshot) -> Void) {
        guard !self.invalidated, self.sourcePresentationDetached || self.current() else { self.invalidate(); return }
        let pending = MetaDisposable()
        self.work.add(pending)
        let read = self.accountValidity |> take(1) |> mapToSignal { [source = self.source, ids = self.ids, lease = self.lease] valid -> Signal<[ExteralessAIScope]?, NoError> in
            valid ? source.read(ids, lease) : .single(nil)
        }
        pending.set((read |> take(1)
        |> timeout(5, queue: .mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self] scopes in
            guard let self, self.isCurrent else { return }
            guard let scopes else { self.invalidate(); return }
            let messages = scopes.compactMap(\.source).sorted { $0.index < $1.index }
            guard messages.count == self.ids.count, Set(messages.map(\.id)) == self.ids else { self.invalidate(); return }
            if let expected = self.expected {
                let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                guard expected.count == messages.count, expected.allSatisfy({ previous in byId[previous.id].map { exteralessChatExportSourceEqual(previous, $0) } == true }) else { self.invalidate(); return }
            } else {
                self.expected = messages.map(exteralessChatExportBaseline)
            }
            let canCopy = scopes.allSatisfy(\.allowsCopy) && self.copyAllowed() && self.permit.allows(accountId: self.accountId, messageIds: self.ids, operation: .exportPreparation)
            guard !requiresCopy || canCopy else { self.invalidate(); return }
            if !self.observing {
                self.observing = true
                self.observation.set((self.source.observe(scopes) |> deliverOnMainQueue).start(next: { [weak self] valid in
                    guard let self else { return }
                    if !valid || (!self.sourcePresentationDetached && !self.current()) { self.invalidate() }
                }))
            }
            self.add((self.source.validate(scopes) |> take(1)
            |> mapToSignal { [accountValidity = self.accountValidity] valid in
                accountValidity |> take(1) |> map { valid && $0 }
            }
            |> timeout(5, queue: .mainQueue(), alternate: .single(false))
            |> deliverOnMainQueue).start(next: { [weak self] valid in
                guard let self, self.isCurrent else { return }
                guard valid, !requiresCopy || self.copyAllowed() else { self.invalidate(); return }
                guard self.permit.allows(accountId: self.accountId, messageIds: self.ids, operation: operation) else { self.invalidate(); return }
                self.permit.perform(accountId: self.accountId, messageIds: self.ids, operation: operation) {
                    guard self.isCurrent else { return }
                    body(ExteralessChatExportSnapshot(messages: messages, canCopy: canCopy))
                }
            }))
        }))
    }

    /// Keep the validator alive on detached/root native descendants, not on the
    /// dismissed sheet alone. Their export permit remains exactly this permit.
    @discardableResult
    func own(_ controller: UIViewController, presented: Bool = false) -> Bool {
        guard self.isCurrent, self.permit.own(controller, presented: presented), self.permit.retainOwner(self, on: controller) else { return false }
        self.presentations.removeAll { $0.controller == nil }
        if !self.presentations.contains(where: { $0.controller === controller }) { self.presentations.append(ExteralessChatExportPresentation(controller)) }
        return true
    }

    /// Explicit, authorized navigation transfers ONLY presentation ownership.
    /// Expected source versions/media, account observation and the permit do not
    /// change. Use at the accepted destination, never when opening its picker.
    @discardableResult
    func handoff(to controller: UIViewController) -> Bool {
        guard self.own(controller, presented: true) else { return false }
        self.sourcePresentationDetached = true
        return true
    }

    /// Native Forward may intentionally clear the source selection after the user
    /// accepts a destination. This does not change the captured messages/versions.
    func commitSelection() {
        guard self.isCurrent else { return }
        self.expectCoverDismissal()
        self.selectionCommitted?()
        self.selectionCommitted = nil
    }

    @discardableResult
    func handoffNativeExport(to controller: ViewController) -> Bool {
        guard self.handoff(to: controller) else { return false }
        self.nativeEffectsDelegated = true
        return true
    }

    var disposable: Disposable {
        ActionDisposable {
            if Thread.isMainThread { MainActor.assumeIsolated { if !self.sourcePresentationDetached { self.cancel() } } }
            else { DispatchQueue.main.async { if !self.sourcePresentationDetached { self.cancel() } } }
        }
    }
}

private final class ExteralessChatExportPresentation {
    weak var controller: UIViewController?
    init(_ controller: UIViewController) { self.controller = controller }
}

private final class ExteralessChatSelectionRequirement { var required: Bool; init(_ required: Bool) { self.required = required } }

private final class ExteralessChatExportWindowObserver: UIView {
    private weak var observedWindow: UIWindow?
    private let exited: () -> Void

    init(exited: @escaping () -> Void) {
        self.exited = exited
        super.init(frame: .zero)
        self.isHidden = true
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let previous = self.observedWindow
        self.observedWindow = self.window
        if let previous, self.window !== previous { self.exited() }
    }
}

extension ChatControllerImpl {
    func exteralessSelectionExportAccess(ids: Set<EngineMessage.Id>, expected: [EngineMessage]? = nil, requireSelection: Bool = true) -> ExteralessChatExportAccess {
        let context = self.context
        let location = self.chatLocation
        let subject = self.presentationInterfaceState.subject
        let copyProtection = self.presentationInterfaceState.copyProtectionEnabled
        let selection = ExteralessChatSelectionRequirement(requireSelection)
        let current: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.context === context && self.chatLocation == location && self.presentationInterfaceState.subject == subject && (!selection.required || self.presentationInterfaceState.interfaceState.selectionState?.selectedIds == ids)
        }
        let window = (self.viewIfLoaded?.window).map { Weak($0) }
        let access = ExteralessChatExportAccess(context: context, ids: ids, expected: expected, permit: self.exteralessExportPermit, presentationValidity: self.presentationInterfaceStatePromise.get() |> map { state in current() && state.copyProtectionEnabled == copyProtection }, sourceWindow: window?.value, sourceView: self.viewIfLoaded, current: current, presentationCurrent: { [weak self] in guard let window = window?.value else { return false }; return self?.viewIfLoaded?.window === window }, copyAllowed: { [weak self] in self?.presentationInterfaceState.copyProtectionEnabled == false })
        access.selectionCommitted = { selection.required = false }
        return access
    }
}
