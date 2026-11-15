import AccountContext
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Native I/O boundaries, injected by the small accountless regression fixtures.
/// The production operation below owns admission; spies never touch the system
/// pasteboard, Photos, profile upload, or a Telegram RPC.
struct ExteralessImageActionServices {
    let fetch: (AnyMediaReference) -> Signal<URL?, NoError>
    let decodeImage: (URL) -> Signal<UIImage?, NoError>
    let decodeFrame: (URL, Double) -> Signal<UIImage?, NoError>
    let scanQR: (UIImage) -> String?
    let copy: (UIImage, Bool) -> Void
    let createSticker: (UIImage, @escaping (@escaping () -> Void) -> Void) -> Void
    let qrPrompt: (String, @escaping () -> Void, @escaping () -> Void, @escaping () -> Void) -> Void
    let copyText: (String) -> Void
    let openURL: (String) -> Void
    let profilePrompt: (@escaping () -> Void, @escaping () -> Void) -> Void
    let prepareProfile: (UIImage) -> Signal<(() -> Void)?, NoError>
    let notice: (String) -> Void
}

@MainActor
final class ExteralessImageActionOperation {
    private let access: ExteralessChatExportAccess
    private let action: ExteralessChatImageAction
    private let reference: (EngineMessage) -> AnyMediaReference?
    private let timestamp: Double?
    private let services: ExteralessImageActionServices
    private let work = DisposableSet()
    private var started = false
    private var finished = false

    init(access: ExteralessChatExportAccess, action: ExteralessChatImageAction, reference: @escaping (EngineMessage) -> AnyMediaReference?, timestamp: Double?, services: ExteralessImageActionServices) {
        self.access = access
        self.action = action
        self.reference = reference
        self.timestamp = timestamp
        self.services = services
        self.access.add(self.work)
    }

    deinit { self.work.dispose() }

    func start() {
        guard !self.started else { return }
        self.started = true
        self.authorize(.exportPreparation) { reference in
            let video = (reference.media as? TelegramMediaFile)?.isVideo == true
            if video {
                guard let timestamp = self.timestamp, timestamp.isFinite, timestamp >= 0 else {
                    self.services.notice("Playback position is unavailable. Try again after playback is ready.")
                    return
                }
            }
            self.work.add((self.services.fetch(reference) |> take(1) |> deliverOnMainQueue).start(next: { url in
                self.authorize(.exportPreparation) { _ in
                    guard let url else { self.services.notice("The media could not be loaded."); return }
                    let decoded: Signal<UIImage?, NoError>
                    if video, let timestamp = self.timestamp { decoded = self.services.decodeFrame(url, timestamp) }
                    else { decoded = self.services.decodeImage(url) }
                    self.work.add((decoded |> take(1) |> timeout(10, queue: .mainQueue(), alternate: .single(nil)) |> deliverOnMainQueue).start(next: { image in
                        self.authorize(.exportPreparation) { _ in
                            guard let image else { self.services.notice("The image could not be decoded."); return }
                            self.deliver(image)
                        }
                    }))
                }
            }))
        }
    }

    private func authorize(_ operation: ExteralessContentExportPermit.Operation, _ body: @escaping (AnyMediaReference) -> Void) {
        guard !self.finished else { return }
        self.access.perform(operation: operation) { snapshot in
            guard !self.finished, let message = snapshot.messages.first, snapshot.messages.count == 1 else { return }
            let raw = message._asMessage()
            // Source-defined media-action policy, stricter than text Copy in a
            // secret chat. No AI/native capability can weaken these exclusions.
            guard raw.id.peerId.namespace != Namespaces.Peer.SecretChat, !raw.containsSecretMedia,
                  !raw.isCopyProtected(), raw.paidContent == nil, raw.adAttribute == nil else { self.access.invalidate(); return }
            guard let reference = self.reference(message) else {
                self.finished = true
                self.services.notice("The selected attachment is unavailable.")
                return
            }
            body(reference)
        }
    }

    private func finalEffect(endAccess: Bool = true, _ body: @escaping () -> Void) {
        self.authorize(.exportEffect) { _ in
            guard !self.finished else { return }
            self.finished = true
            body()
            if endAccess { self.access.cancel() }
        }
    }

    private func deliver(_ image: UIImage) {
        switch self.action {
        case .copy, .copySticker:
            self.finalEffect { self.services.copy(image, self.action == .copySticker) }
        case .createSticker:
            self.authorize(.presentation) { _ in
                self.services.createSticker(image, { commit in self.finalEffect(commit) })
            }
        case .scanQR:
            guard let code = self.services.scanQR(image), code.utf16.count <= 8192 else { self.services.notice("No QR code found."); return }
            self.authorize(.presentation) { _ in
                self.services.qrPrompt(code, { self.finalEffect { self.services.copyText(code) } }, { self.finalEffect { self.services.openURL(code) } }, { self.cancel() })
            }
        case .profile:
            self.authorize(.presentation) { _ in
                self.services.profilePrompt({
                    self.authorize(.exportPreparation) { _ in
                        self.work.add((self.services.prepareProfile(image) |> take(1) |> timeout(5, queue: .mainQueue(), alternate: .single(nil)) |> deliverOnMainQueue).start(next: { apply in
                            guard let apply else { return }
                            self.finalEffect(endAccess: false, apply)
                        }))
                    }
                }, { self.cancel() })
            }
        }
    }

    func cancel() {
        self.finished = true
        self.work.dispose()
        self.access.cancel()
    }

    var disposable: Disposable {
        // The retained operation is the lifetime of a held fetch/decode/prompt.
        ActionDisposable {
            if Thread.isMainThread { MainActor.assumeIsolated { self.cancel() } }
            else { DispatchQueue.main.async { self.cancel() } }
        }
    }
}
