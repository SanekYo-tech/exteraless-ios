import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore

/// The exact native Gallery selection, including a named rich-message medium.
/// The reference retains its original MessageReference; rich content is never
/// rewritten into message.media or a flattened message just to make it exportable.
public struct ExteralessGalleryMediaSelection {
    public let reference: AnyMediaReference
    public let subject: GalleryMediaSubject?
    public let itemGeneration: UUID

    public init?(message: EngineMessage, subject: GalleryMediaSubject?, itemGeneration: UUID) {
        guard let media = Self.resolve(message: message, subject: subject), media is TelegramMediaImage || media is TelegramMediaFile else { return nil }
        self.reference = .message(message: MessageReference(message._asMessage()), media: media)
        self.subject = subject
        self.itemGeneration = itemGeneration
    }

    public var isImage: Bool { self.reference.media is TelegramMediaImage }
    public var isVideo: Bool { (self.reference.media as? TelegramMediaFile)?.isVideo == true }

    /// Resolve the SAME native subject again after fetch/decode/confirmation. A
    /// missing named medium or a replaced resource is not a first-media fallback.
    public func reference(in message: EngineMessage) -> AnyMediaReference? {
        guard let media = Self.resolve(message: message, subject: self.subject), self.reference.media.isEqual(to: media) else { return nil }
        return .message(message: MessageReference(message._asMessage()), media: media)
    }

    private static func resolve(message: EngineMessage, subject: GalleryMediaSubject?) -> EngineRawMedia? {
        let raw = message._asMessage()
        // Some legacy native subjects fall back to the first item on a miss.
        // That fallback cannot authorize a specifically named export.
        if case let .pollOption(id) = subject {
            guard let poll = raw.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll,
                  poll.options.first(where: { $0.opaqueIdentifier == id })?.media != nil else { return nil }
        }
        if case let .paidMediaIndex(index) = subject {
            guard index >= 0, index < mediaForMessage(message: raw, mediaSubject: subject).count else { return nil }
        }
        guard let media = selectedMediaForMessage(message: raw, mediaSubject: subject) else { return nil }
        switch subject {
        case let .richTextMedia(id), let .instantPageMedia(id):
            guard media.id == id else { return nil }
        default: break
        }
        return media
    }
}

/// Separate from share-link MediaParameters (Int32 and a ten-minute threshold).
/// The optional Double is a real playback sample; unavailable status is an error.
public struct ExteralessGalleryPlaybackSample {
    public let timestamp: Double

    public init?(timestamp: Double?) {
        guard let timestamp, timestamp.isFinite, timestamp >= 0 else { return nil }
        self.timestamp = timestamp
    }
}

/// Owned by the native footer. Leaving the item and returning to the same IDs
/// never revives an old action, even if its decode callback was already queued.
public final class ExteralessGalleryActionLifetime {
    public private(set) var generation: UUID
    private let value: ValuePromise<UUID>

    public init() {
        let generation = UUID()
        self.generation = generation
        self.value = ValuePromise(generation, ignoreRepeated: true)
    }
    public func invalidate() { self.generation = UUID(); self.value.set(self.generation) }
    public func validity(of generation: UUID) -> Signal<Bool, NoError> { self.value.get() |> map { $0 == generation } }
}

public struct ExteralessGalleryMessageActionRequest {
    public let context: AccountContext
    public let message: EngineMessage
    public let selection: ExteralessGalleryMediaSelection?
    public let itemGeneration: UUID
    public let playbackSample: () -> ExteralessGalleryPlaybackSample?
    public let exportPermit: ExteralessContentExportPermit?
    public let itemValidity: Signal<Bool, NoError>
    public let interaction: GalleryControllerInteraction
    public let isCurrent: () -> Bool
    /// FU-02's native Share/Save flow must bind the SAME permit and retain its
    /// source validator on every detached controller before it is presented.
    public let nativeShare: (ExteralessContentExportPermit, @escaping (ViewController) -> Bool) -> Void
    public let setDisposable: (Disposable?) -> Void
    public let setInteracting: (Bool) -> Void
    public init(context: AccountContext, message: EngineMessage, selection: ExteralessGalleryMediaSelection?, itemGeneration: UUID, playbackSample: @escaping () -> ExteralessGalleryPlaybackSample?, exportPermit: ExteralessContentExportPermit?, itemValidity: Signal<Bool, NoError>, interaction: GalleryControllerInteraction, isCurrent: @escaping () -> Bool, nativeShare: @escaping (ExteralessContentExportPermit, @escaping (ViewController) -> Bool) -> Void, setDisposable: @escaping (Disposable?) -> Void, setInteracting: @escaping (Bool) -> Void) {
        self.context = context; self.message = message; self.selection = selection; self.itemGeneration = itemGeneration
        self.playbackSample = playbackSample; self.exportPermit = exportPermit; self.itemValidity = itemValidity; self.interaction = interaction
        self.isCurrent = isCurrent; self.nativeShare = nativeShare; self.setDisposable = setDisposable
        self.setInteracting = setInteracting
    }
}

@MainActor public enum ExteralessGalleryMessageActions {
    public static var present: ((ExteralessGalleryMessageActionRequest) -> Bool)?
}
