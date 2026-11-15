import AccountContext
import Display
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore

/// Holds presentation, rather than a network request, until the viewer's choice.
/// No story is marked viewed before the choice and the lease ends with this viewer.
final class ExteralessPrivacyStoryContent: StoryContentContext {
    private let context: AccountContext
    let source: StoryContentContext
    private let allowed = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let updates = ValuePipe<Void>()
    private var sourceDisposable: Disposable?
    private var ghostLease: Disposable?
    private var presentedChoice = false
    private var closed = false
    private var privateViewing = false
    private(set) var pendingChoice: Bool

    init(context: AccountContext, source: StoryContentContext) {
        self.context = context
        self.source = source
        pendingChoice = exteralessShouldAskBeforeOpeningStory(accountPeerId: context.account.peerId, focusedPeerId: source.stateValue?.slice?.peer.id)
        allowed.set(!pendingChoice)
        sourceDisposable = (source.updated |> deliverOnMainQueue).start(next: { [weak self] in
            guard let self, !self.closed, !self.pendingChoice else { return }
            self.updates.putNext(())
        })
    }

    deinit { sourceDisposable?.dispose(); ghostLease?.dispose() }
    var stateValue: StoryContentContextState? { pendingChoice || closed ? nil : source.stateValue }
    var state: Signal<StoryContentContextState, NoError> {
        return allowed.get() |> filter { $0 } |> take(1) |> mapToSignal { [weak self] _ in
            guard let self, !self.closed else { return .complete() }
            return self.source.state
        }
    }
    var updated: Signal<Void, NoError> { updates.signal() }
    func resetSideStates() { if !pendingChoice && !closed { source.resetSideStates() } }
    func navigate(navigation: StoryContentContextNavigation) { if !pendingChoice && !closed { source.navigate(navigation: navigation) } }
    func markAsSeen(id: EngineStoryId) {
        if privateViewing && !ExteralessStoryPrivacySessions.shared.isActive(accountId: context.account.id.int64) { return }
        if !pendingChoice && !closed { source.markAsSeen(id: id) }
    }

    func requestChoice(controller: ViewController, proceed: @escaping () -> Void) {
        guard pendingChoice, !presentedChoice, !closed else { return }
        if source.stateValue?.slice?.peer.id == context.account.peerId {
            resolve(ghost: false); proceed(); return
        }
        presentedChoice = true
        let choose: (Bool) -> Void = { [weak self] ghost in
            guard let self, !self.closed else { return }
            self.resolve(ghost: ghost)
            proceed()
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        controller.present(textAlertController(sharedContext: context.sharedContext, title: "View stories", text: "How would you like to view this session?", actions: [
            TextAlertAction(type: .defaultAction, title: "View privately", action: { choose(true) }),
            TextAlertAction(type: .genericAction, title: "View normally", action: { choose(false) }),
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: { [weak self, weak controller] in self?.close(); controller?.dismiss() })
        ], actionLayout: .vertical, dismissOnOutsideTap: false), in: .window(.root))
    }

    private func resolve(ghost: Bool) {
        privateViewing = ghost
        if ghost { ghostLease = ExteralessStoryPrivacySessions.shared.begin(accountId: context.account.id.int64) }
        pendingChoice = false
        allowed.set(true)
        if source.stateValue != nil { updates.putNext(()) }
    }

    func close() {
        closed = true
        pendingChoice = false
        allowed.set(true)
        sourceDisposable?.dispose()
        sourceDisposable = nil
        ghostLease?.dispose()
        ghostLease = nil
    }
}

func exteralessUnderlyingStoryContent(_ content: StoryContentContext) -> StoryContentContext {
    return (content as? ExteralessPrivacyStoryContent)?.source ?? content
}
