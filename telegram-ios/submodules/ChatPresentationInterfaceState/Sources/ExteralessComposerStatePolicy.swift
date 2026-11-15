import ExteralessCore
import Foundation

public func exteralessComposeLinkPreviewsDisabled(_ state: ChatPresentationInterfaceState, url: String) -> Bool {
    return ChatComposerPolicy.disablesPreview(url: url, overrides: state.interfaceState.composeDisableUrlPreviews, defaultDisabled: ClientSettings.shared.bool("chats.disableLinkPreviewByDefault"))
}
