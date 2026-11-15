import AccountContext
import ChatPresentationInterfaceState
import Display
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore

/// Main-queue operation lifetime. Retirement is sticky across A -> B -> A and
/// across a foreground loss; a later true value cannot revive this operation.
final class ExteralessChatOperationScope {
    private let disposable = MetaDisposable()
    private var retired = false
    private(set) var isCurrent = false
    private let readyValue = ValuePromise<Bool?>(nil, ignoreRepeated: true)
    var invalidated: (() -> Void)? { didSet { if retired { invalidated?() } } }
    var ready: Signal<Bool, NoError> {
        readyValue.get() |> filter { $0 != nil } |> map { $0! } |> take(1)
    }
    init(validity: Signal<Bool, NoError>) {
        disposable.set((validity |> deliverOnMainQueue).start(next: { [weak self] current in
            guard let self, !self.retired else { return }
            if current { self.isCurrent = true; self.readyValue.set(true) }
            else { self.cancel() }
        }))
    }
    convenience init(context: AccountContext, requireForeground: Bool = false) {
        self.init(validity: combineLatest(context.sharedContext.activeAccountContexts, context.sharedContext.applicationBindings.applicationInForeground)
            |> map { accounts, foreground in accounts.primary === context && (!requireForeground || foreground) })
    }
    func cancel() {
        guard !retired else { return }
        retired = true
        isCurrent = false
        readyValue.set(false)
        disposable.dispose()
        invalidated?()
    }
    deinit { disposable.dispose() }
}

/// Explicit operation ownership, independent of animation/correlation availability.
/// The same producer is injectable in fixtures without an Account or history node.
final class ExteralessChatSendOperation {
    let id = UUID()
    private let matchesRevision: () -> Bool
    private var cleanup: () -> Void
    private let retireLayout: (UUID) -> Void
    private let cancelTransitions: (Set<Int64>) -> Void
    private let failure: (EnqueueMessagesResult) -> Void
    private var correlations = Set<Int64>()
    private var result: EnqueueMessagesResult?
    private var didCleanup = false
    private var retired = false
    var scope: ExteralessChatOperationScope?
    var exportPermitReference: ExteralessContentExportPermitReference?
    private var watchedExportPermit: ExteralessContentExportPermit?
    private let exportRevocation = MetaDisposable()

    init(matchesRevision: @escaping () -> Bool, cleanup: @escaping () -> Void,
         retireLayout: @escaping (UUID) -> Void, cancelTransitions: @escaping (Set<Int64>) -> Void,
         failure: @escaping (EnqueueMessagesResult) -> Void) {
        self.matchesRevision = matchesRevision
        self.cleanup = cleanup
        self.retireLayout = retireLayout
        self.cancelTransitions = cancelTransitions
        self.failure = failure
    }
    var isCurrent: Bool { !retired && (scope?.isCurrent ?? true) && matchesRevision() }
    var exportPermit: ExteralessContentExportPermit? { exportPermitReference?.permit }
    var isCancelled: Bool { retired }
    func setCleanup(_ cleanup: @escaping () -> Void) {
        guard result == nil, !retired else { return }
        self.cleanup = cleanup
    }
    func attach(correlationId: Int64?) {
        if let correlationId { correlations.insert(correlationId) }
        if retired { cancelTransitions(correlations) }
    }
    func attach(messages: [EnqueueMessage]) {
        correlations.formUnion(messages.compactMap(Self.correlation))
        if let permit = exportPermit, watchedExportPermit !== permit {
            watchedExportPermit = permit
            exportRevocation.set(permit.onRevocation { [weak self] in self?.cancel() })
        }
        if retired { cancelTransitions(correlations) }
    }
    private static func correlation(_ message: EnqueueMessage) -> Int64? {
        switch message {
        case let .message(_, _, _, _, _, _, _, _, correlation, _), let .forward(_, _, _, _, correlation): return correlation
        }
    }
    /// A history callback has no authority while admission is pending/rejected,
    /// including the Reduce Motion path where the callback's correlation is nil.
    @discardableResult func cleanupIfAdmitted() -> Bool {
        guard !didCleanup, result?.allEnqueued == true, isCurrent else { return false }
        didCleanup = true
        retireLayout(id)
        cleanup()
        return true
    }
    func complete(_ result: EnqueueMessagesResult, messages: [EnqueueMessage]) {
        guard self.result == nil else { return }
        self.result = result
        attach(messages: messages)
        var admittedCorrelations = Set<Int64>()
        for (message, slot) in zip(messages, result.slots) {
            if case .enqueued = slot, let correlation = Self.correlation(message) { admittedCorrelations.insert(correlation) }
        }
        cancelTransitions(isCurrent ? correlations.subtracting(admittedCorrelations) : correlations)
        retireLayout(id)
        if !cleanupIfAdmitted(), !result.allEnqueued, isCurrent { failure(result) }
    }
    /// Business-link editing is not a message enqueue. Its native API supplies a
    /// successful mutation callback; it must not manufacture a local MessageId.
    func completeMutation() {
        retireLayout(id)
        guard !didCleanup, result == nil, isCurrent else { return }
        didCleanup = true
        cleanup()
    }
    func cancel() {
        guard !retired else { return }
        retired = true
        retireLayout(id)
        cancelTransitions(correlations)
        scope?.cancel()
    }
    deinit { exportRevocation.dispose() }
}

/// Actual native batch ingress; tests supply the enqueue closure, not an account.
func exteralessSubmitChatBatch(messages: [EnqueueMessage], operation: ExteralessChatSendOperation?, enqueue: @escaping ([EnqueueMessage]) -> Signal<EnqueueMessagesResult, NoError>) -> Signal<EnqueueMessagesResult, NoError> {
    operation?.attach(messages: messages)
    let ready = operation?.scope?.ready ?? .single(true)
    return ready |> mapToSignal { current -> Signal<EnqueueMessagesResult, NoError> in
        guard current else { return .single(.rejected(count: messages.count, reason: .cancelledBeforeCommit)) }
        return enqueue(messages)
    } |> deliverOnMainQueue |> map { result in
        operation?.complete(result, messages: messages)
        return result
    }
}

func exteralessSameChatDraft(_ lhs: ChatPresentationInterfaceState, _ rhs: ChatPresentationInterfaceState) -> Bool {
    let a = lhs.interfaceState, b = rhs.interfaceState
    return lhs.chatLocation == rhs.chatLocation && a.composeInputState == b.composeInputState
        && a.editMessage == b.editMessage && lhs.editMessageState == rhs.editMessageState
        && a.replyMessageSubject == b.replyMessageSubject && a.forwardMessageIds == b.forwardMessageIds
        && a.forwardOptionsState == b.forwardOptionsState && a.mediaDraftState == b.mediaDraftState
        && a.composeDisableUrlPreviews == b.composeDisableUrlPreviews
        && lhs.editingUrlPreview == rhs.editingUrlPreview && lhs.urlPreview == rhs.urlPreview
        && a.sendMessageEffect == b.sendMessageEffect && a.postSuggestionState == b.postSuggestionState
}

extension ChatControllerImpl {
    func exteralessPrepareSendOperation(cleanup: @escaping () -> Void, correlationId: Int64?, additionalRevisionMatches: @escaping () -> Bool = { true }) -> ExteralessChatSendOperation {
        let revision = self.exteralessDraftRevision
        let snapshot = self.presentationInterfaceState
        let input = self.chatDisplayNode.textInputPanelNode?.inputTextState
        let operation = ExteralessChatSendOperation(matchesRevision: { [weak self] in
            guard let self else { return false }
            return additionalRevisionMatches() && self.exteralessDraftRevision == revision && exteralessSameChatDraft(snapshot, self.presentationInterfaceState)
                && self.chatDisplayNode.textInputPanelNode?.inputTextState == input
        }, cleanup: cleanup, retireLayout: { [weak self] id in
            guard let self, self.exteralessSendLayoutOwner == id else { return }
            self.exteralessSendLayoutOwner = nil
            self.layoutActionOnViewTransitionAction = nil
            self.chatDisplayNode.historyNode.layoutActionOnViewTransition = nil
        }, cancelTransitions: { [weak self] ids in
            self?.chatDisplayNode.messageTransitionNode.cancelPending(correlationIds: ids)
        }, failure: { [weak self] result in self?.exteralessShowSendAdmissionFailure(result) })
        operation.scope = ExteralessChatOperationScope(context: self.context)
        operation.exportPermitReference = self.exteralessExportPermitReference
        operation.scope?.invalidated = { [weak operation] in operation?.cancel() }
        operation.attach(correlationId: correlationId)
        return operation
    }

    func exteralessShowSendAdmissionFailure(_ result: EnqueueMessagesResult) {
        let text: String
        if result.hasEnqueuedMessages {
            text = "Some messages were queued, but others were not. Your draft has been kept."
        } else {
            switch result.firstRejection ?? .localEnqueueUnavailable {
            case .pluginCancelled: text = "Sending was cancelled by a plugin. Your draft has been kept."
            case .botAuthorizationDenied: text = "Sending to this bot was not authorized. Your draft has been kept."
            case .retainedReplyUnavailable: text = "The deleted reply could not be included. Shorten the message or remove the reply, then try again. Your draft has been kept."
            case .cancelledBeforeCommit: text = "Sending was cancelled before the message was queued. Your draft has been kept."
            case .localEnqueueUnavailable: text = "The message could not be queued. Your draft has been kept."
            }
        }
        self.present(textAlertController(context: self.context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }
}
