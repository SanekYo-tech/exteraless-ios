import Foundation
import SwiftSignalKit
import TelegramCore

/// Both reads and the pending-manager hop belong to one immutable captured edit.
/// Injected source/install closures are the same boundaries used by native Edit.
func exteralessSubmitChatEdit<Source, Request>(
    read: @escaping () -> Signal<Source?, NoError>,
    token: PendingMessageUpdateAdmissionToken,
    isCurrent: @escaping () -> Bool,
    sameSource: @escaping (Source, Source) -> Bool,
    prepare: @escaping (Source) -> Request?,
    unchanged: @escaping (Source, Request) -> Bool,
    install: @escaping (Source, Request) -> Signal<PendingMessageUpdateAdmission, NoError>
) -> Signal<PendingMessageUpdateAdmission, NoError> {
    return read() |> take(1) |> deliverOnMainQueue |> mapToSignal { first -> Signal<PendingMessageUpdateAdmission, NoError> in
        guard isCurrent(), token.isPending else { return .single(.rejected(.cancelledBeforeCommit)) }
        guard let first, let request = prepare(first) else { return .single(.rejected(.localEnqueueUnavailable)) }
        return read() |> take(1) |> deliverOnMainQueue |> mapToSignal { current -> Signal<PendingMessageUpdateAdmission, NoError> in
            guard isCurrent(), token.isPending else { return .single(.rejected(.cancelledBeforeCommit)) }
            guard let current, sameSource(first, current) else { return .single(.rejected(.localEnqueueUnavailable)) }
            if unchanged(current, request) {
                return .single(token.claimCommit() ? .unchanged : .rejected(.cancelledBeforeCommit))
            }
            return install(current, request)
        }
    }
    |> deliverOnMainQueue
}

struct ExteralessChatEditRequest {
    let text: String
    let media: RequestEditMessageMedia
    let entities: TextEntitiesMessageAttribute?
    let richText: RichTextMessageAttribute?
    let inlineStickers: [EngineMedia.Id: TelegramMediaFile]
    let webpagePreviewAttribute: WebpagePreviewMessageAttribute?
    let invertMediaAttribute: InvertMediaMessageAttribute?
    let disableUrlPreview: Bool
    let updatingMedia: Bool

    func matches(_ message: EngineMessage) -> Bool {
        let current = message._asMessage()
        let currentPreview = current.webpagePreviewAttribute ?? WebpagePreviewMessageAttribute(leadingPreview: false, forceLargeMedia: nil, isManuallyAdded: true, isSafe: false)
        return current.text == text && (current.textEntitiesAttribute?.entities ?? []) == (entities?.entities ?? [])
            && current.richText == nil && richText == nil && !updatingMedia
            && webpagePreviewAttribute == currentPreview && !disableUrlPreview
    }
}
