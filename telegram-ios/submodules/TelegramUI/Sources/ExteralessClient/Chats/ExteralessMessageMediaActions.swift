import AccountContext
import AVFoundation
import CoreImage
import Display
import Foundation
import ImageIO
import PeerInfoScreen
import SaveToCameraRoll
import SwiftSignalKit
import TelegramCore
import UIKit

enum ExteralessChatImageAction: Equatable { case copy, copySticker, createSticker, scanQR, profile }

/// Every caller supplies its exact native reference resolver. Gallery never
/// reselects the first effectiveMedia entry, including for mixed rich media.
@MainActor
func exteralessMessageImageAction(context: AccountContext, access: ExteralessChatExportAccess, action: ExteralessChatImageAction, reference: @escaping (EngineMessage) -> AnyMediaReference?, timestamp: Double?, presenter: ViewController, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) -> Disposable {
    weak var sourcePresenter = presenter
    func show(_ controller: ViewController, pushing: Bool = false, operation: ExteralessContentExportPermit.Operation = .presentation, beforePresentation: @escaping () -> Void = {}) {
        guard let presenter = sourcePresenter, access.own(controller) else { return }
        access.permit.presentWhenReady(controller, accountId: context.account.id.int64, from: presenter, requiresExport: true, present: { controller in
            access.perform(operation: operation) { _ in
                guard access.own(controller, presented: true) else { return }
                if pushing && !access.handoff(to: controller) { return }
                beforePresentation()
                if pushing { push(controller) } else { present(controller) }
            }
        })
    }
    let services = ExteralessImageActionServices(fetch: { reference in
        fetchMediaData(context: context, userLocation: .peer(access.ids.first!.peerId), mediaReference: reference)
        |> filter { state, _ in if case let .data(data) = state { return data.isComplete }; return false }
        |> take(1)
        |> map { state, _ -> URL? in if case let .data(data) = state { return URL(fileURLWithPath: data.path) }; return nil }
        |> timeout(15, queue: .mainQueue(), alternate: .single(nil))
    }, decodeImage: { url in
        Signal { subscriber in
            let cancelled = Atomic(value: false)
            DispatchQueue.global(qos: .userInitiated).async {
                guard !cancelled.with({ $0 }) else { return }
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920, kCGImageSourceCreateThumbnailWithTransform: true]
                let image = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }.map { UIImage(cgImage: $0) }
                guard !cancelled.with({ $0 }) else { return }
                subscriber.putNext(image)
                subscriber.putCompletion()
            }
            return ActionDisposable { _ = cancelled.swap(true) }
        }
    }, decodeFrame: { url, timestamp in
        Signal { subscriber in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // Preserve the Double from playback; no share-link Int32 conversion,
            // ten-minute gate, clamping, or fallback to the first frame.
            let time = CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000)
            let cancelled = Atomic(value: false)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                guard !cancelled.with({ $0 }) else { return }
                subscriber.putNext(image.map { UIImage(cgImage: $0) })
                subscriber.putCompletion()
            }
            return ActionDisposable { _ = cancelled.swap(true); generator.cancelAllCGImageGeneration() }
        }
    }, scanQR: { image in
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return CIImage(image: image).flatMap { detector?.features(in: $0).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first }
    }, copy: { image, sticker in
        if sticker { UIPasteboard.general.items = [["com.apple.png-sticker": image, "com.apple.uikit.image": image]] }
        else { UIPasteboard.general.image = image }
    }, createSticker: { image, authorizeCommit in
        let controller = context.sharedContext.makeStickerEditorScreen(context: context, source: image, mode: .generic(canSend: false), transitionArguments: nil, completion: { _, _, commit in authorizeCommit(commit) }, cancelled: { access.cancel() })
        show(controller, pushing: true)
    }, qrPrompt: { code, copy, open, cancel in
        show(textAlertController(context: context, title: "QR code", text: code, actions: [
            TextAlertAction(type: .genericAction, title: "Cancel", action: cancel),
            TextAlertAction(type: .defaultAction, title: "Copy", action: copy),
            TextAlertAction(type: .defaultAction, title: "Open", action: open)
        ]))
    }, copyText: { UIPasteboard.general.string = $0 }, openURL: { code in
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: code, forceExternal: false, presentationData: context.sharedContext.currentPresentationData.with { $0 }, navigationController: nil, dismissInput: {})
    }, profilePrompt: { confirm, cancel in
        show(textAlertController(context: context, title: "Set profile photo?", text: "Use this image for your profile?", actions: [TextAlertAction(type: .genericAction, title: "Cancel", action: cancel), TextAlertAction(type: .defaultAction, title: "Set photo", action: confirm)]))
    }, prepareProfile: { image in
        context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> map { peer -> (() -> Void)? in
            guard let peer else { return nil }
            return {
                guard let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) as? PeerInfoScreenImpl else { return }
                show(controller, pushing: true, operation: .exportEffect, beforePresentation: {
                    // show reauthorizes after its readiness wait as well. The
                    // upload starts before an intentional Gallery dismissal.
                    controller.updateProfilePhoto(image)
                    access.cancel()
                })
            }
        }
    }, notice: { text in
        show(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
    })
    let operation = ExteralessImageActionOperation(access: access, action: action, reference: reference, timestamp: timestamp, services: services)
    operation.start()
    return operation.disposable
}

extension ChatControllerImpl {
    func exteralessImageAction(_ message: EngineRawMessage, action: ExteralessChatImageAction, timestamp: Double? = nil) {
        let candidates: [EngineRawMedia]
        if timestamp != nil {
            // This chat menu action explicitly says "Copy first video frame".
            candidates = Array(message.effectiveMedia.filter { ($0 as? TelegramMediaFile)?.isVideo == true }.prefix(1))
        } else {
            let images = message.effectiveMedia.filter { $0 is TelegramMediaImage }
            candidates = images.isEmpty ? message.effectiveMedia.filter { $0 is TelegramMediaFile } : images
        }
        guard candidates.count == 1, let medium = candidates.first else {
            self.present(textAlertController(context: self.context, title: nil, text: "Open the desired attachment in Gallery.", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
            return
        }
        let access = self.exteralessSelectionExportAccess(ids: [message.id], expected: [EngineMessage(message)], requireSelection: false)
        let disposable = self.saveMediaDisposable ?? MetaDisposable()
        self.saveMediaDisposable = disposable
        disposable.set(exteralessMessageImageAction(context: self.context, access: access, action: action, reference: { current in
            guard let media = current._asMessage().effectiveMedia.first(where: { medium.isEqual(to: $0) }) else { return nil }
            return .message(message: MessageReference(current._asMessage()), media: media)
        }, timestamp: timestamp, presenter: self, present: { [weak self] in self?.present($0, in: .window(.root)) }, push: { [weak self] in self?.push($0) }))
    }
}
