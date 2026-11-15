import AccountContext
import ChatRichTextEditorComposer
import Display
import ExteralessCore
import Foundation
import Pasteboard
import SwiftSignalKit
import TelegramCore

/// Uses the native rich translation sheet and its AI provider hooks. The source
/// capability and account lease are checked across asynchronous preparation.
@MainActor
@discardableResult
func exteralessPresentMessageTranslationSheet(context: AccountContext, from presenter: ViewController, message: EngineMessage, automaticLanguage: String?, isSummarized: Bool, capability suppliedCapability: ExteralessAIProcessingCapability? = nil) -> Bool {
    let target: String?
    let capability: ExteralessAIProcessingCapability
    if let chat = presenter as? ChatControllerImpl {
        target = chat.exteralessAIAutomaticLanguage
        capability = suppliedCapability ?? chat.exteralessAISelectionCapability(message: message._asMessage(), canCopy: true)
    } else {
        target = automaticLanguage
        capability = suppliedCapability ?? .message(message, canCopy: true)
    }
    func projected(_ message: EngineMessage) -> ExteralessAIMessageDisplay? {
        let display = ExteralessAIMessageDisplay.resolve(message: message, accountId: context.account.id.int64, accountPeerId: context.account.peerId, automaticLanguage: target, isSummarized: isSummarized, richExpanded: true)
        let raw = message._asMessage()
        guard ChatMediaPolicy.translateInSheet(enabled: ClientSettings.shared.bool("chats.translateInSheet"),
            hasContent: display.page != nil || !display.text.isEmpty,
            poll: raw.media.contains { $0 is TelegramMediaPoll },
            voice: raw.effectiveMedia.contains { ($0 as? TelegramMediaFile)?.isVoice == true },
            alreadyTranslated: display.selection.origin != .original) else { return nil }
        return display
    }
    guard projected(message) != nil else { return false }
    let lease = AINativeOperationLease()
    let ownership = (context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { accounts in
        if accounts.primary !== context { lease.cancel() }
    })
    Task { @MainActor [weak presenter] in
        defer { ownership.dispose(); lease.cancel() }
        guard !lease.isCancelled, let presenter, presenter.viewIfLoaded?.window != nil else { return }
        guard let scope = try? await ExteralessAISignalOperation<ExteralessAIScope?>().value(context.engine.messages.resolveExteralessAIScope(capability: capability, lease: lease)),
              !lease.isCancelled else { return }
        if let rich = scope.source?.richText, !ExteralessAIRichSource.wholePage(rich).isComplete {
            guard let loaded = try? await ExteralessAISignalOperation<RichTextMessageAttribute?>().value(context.engine.messages.loadExteralessAIFullRichSource(scope: scope)),
                  ExteralessAIRichSource.wholePage(loaded).isComplete else { return }
        }
        guard let current = scope.source, let display = projected(current), !lease.isCancelled,
              (try? await ExteralessAISignalOperation<Bool>().value(context.engine.messages.validateExteralessAIScope(scope))) == true else { return }
        let input: ComposedRichMessage
        if let page = display.page { input = .rich(instantPage: page) }
        else { input = .plain(text: display.text, entities: display.entities) }
        let controller = await context.sharedContext.makeTextProcessingScreen(context: context,
            capability: .init(messageId: current.id, expectedStableVersion: current.stableVersion, peerId: current.id.peerId, threadId: current.threadId, allowsExternalProcessing: scope.allowsExternalProcessing, allowsCopy: scope.allowsCopy), theme: nil,
            mode: .translate(fromLanguage: nil, applyResult: nil), inputText: input,
            copyResult: scope.allowsCopy ? { result in storeComposedRichMessageInPasteboard(result) } : nil,
            translateChat: nil)
        let valid = try? await ExteralessAISignalOperation<Bool>().value(context.engine.messages.validateExteralessAIScope(scope))
        guard valid == true, !lease.isCancelled, presenter.viewIfLoaded?.window != nil else { return }
        presenter.present(controller, in: .window(.root))
    }
    return true
}
