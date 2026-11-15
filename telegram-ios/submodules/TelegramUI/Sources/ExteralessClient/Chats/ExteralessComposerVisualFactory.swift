#if DEBUG
import AccountContext
import ChatPresentationInterfaceState
import ChatTextInputPanelNode
import Foundation

/// Bounded loginless host entry. Rendering, media hosting and paste parsing are
/// selected by the SAME panel producer as ChatController; no renderer is copied.
@MainActor
public func makeExteralessComposerPanel(
    context: AccountContext,
    state: ChatPresentationInterfaceState,
    interaction: ChatPanelInterfaceInteraction
) -> ChatTextInputPanelNode? {
    guard context.account.supplementary,
          URL(fileURLWithPath: context.account.basePath).pathComponents.contains(where: { $0.hasPrefix("composer-harness-") }) else { return nil }
    let result = inputPanelForChatPresentationIntefaceState(state, context: context,
        currentPanel: nil, currentSecondaryPanel: nil, textInputPanelNode: nil,
        chatControllerInteraction: nil, interfaceInteraction: interaction)
    guard result.secondary == nil, let panel = result.primary as? ChatTextInputPanelNode else { return nil }
    panel.loadTextInputNodeIfNeeded()
    return panel
}
#endif
