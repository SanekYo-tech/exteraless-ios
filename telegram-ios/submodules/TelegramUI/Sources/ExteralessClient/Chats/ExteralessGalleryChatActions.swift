import AccountContext
import ChatPresentationInterfaceState
import Display
import ExteralessCore
import Foundation
import GalleryUI
import PeerSelectionController
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor enum ExteralessGalleryChatActions {
    static func install() {
        ExteralessGalleryMessageActions.present = { request in
            guard request.isCurrent(), let presenter = request.interaction.controller() else { return true }
            if let selection = request.selection, !selection.isImage && !selection.isVideo { return false }
            let context = request.context
            let access = ExteralessChatExportAccess(context: context, ids: [request.message.id], expected: [request.message], permit: request.exportPermit, presentationValidity: request.itemValidity, sourceWindow: presenter.viewIfLoaded?.window, current: request.isCurrent, presentationCurrent: { [weak presenter] in presenter?.viewIfLoaded?.window != nil })
            let lifetime = DisposableSet()
            lifetime.add(access.disposable)
            request.setDisposable(lifetime)
            let session = ExteralessSelectionActionSession(access: access, actions: { keepUpdated in context.sharedContext.chatAvailableMessageActions(engine: context.engine, accountPeerId: context.account.peerId, messageIds: [request.message.id], keepUpdated: keepUpdated) })
            session.read(requiresCopy: false, operation: .presentation) { snapshot, available in
                @MainActor func notice(_ text: String) {
                    let controller = textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: { access.cancel() })])
                    guard access.own(controller) else { return }
                    access.permit.presentWhenReady(controller, accountId: access.accountId, from: presenter, present: { request.interaction.presentController($0, nil) })
                }
                guard let selection = request.selection, selection.itemGeneration == request.itemGeneration,
                      let message = snapshot.messages.first, selection.reference(in: message) != nil else {
                    notice("The selected attachment is unavailable.")
                    return
                }
                let raw = message._asMessage()
                guard snapshot.canCopy, !available.isCopyProtected, raw.id.peerId.namespace != Namespaces.Peer.SecretChat,
                      !raw.containsSecretMedia, raw.paidContent == nil, raw.adAttribute == nil,
                      access.permit.allows(accountId: access.accountId, messageIds: access.ids) else {
                    notice("This media action is unavailable.")
                    return
                }
                let presentation = context.sharedContext.currentPresentationData.with { $0 }
                let sheet = ActionSheetController(presentationData: presentation)
                sheet.dismissed = { _ in request.setInteracting(false) }
                var items: [ActionSheetItem] = []
                @MainActor func add(_ field: String?, _ title: String, allowed: Bool = true, _ action: @escaping @MainActor () -> Void) {
                    guard allowed, field.map({ ChatMenuPolicy.enabled($0) }) ?? true else { return }
                    let perform = session.action(requiresCopy: true, operation: .exportPreparation, allowed: { snapshot, _ in
                        guard field.map({ ChatMenuPolicy.enabled($0) }) ?? true, let current = snapshot.messages.first else { return false }
                        return selection.reference(in: current) != nil
                    }, { _, _ in action() })
                    items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in sheet?.dismissAnimated(); perform() }))
                }
                @MainActor func imageAction(_ action: ExteralessChatImageAction) {
                    let timestamp: Double?
                    if selection.isVideo {
                        guard let sample = request.playbackSample() else { notice("Playback position is unavailable. Try again after playback is ready."); return }
                        timestamp = sample.timestamp
                    } else { timestamp = nil }
                    lifetime.add(exteralessMessageImageAction(context: context, access: access, action: action, reference: selection.reference(in:), timestamp: timestamp, presenter: presenter, present: { request.interaction.presentController($0, nil) }, push: request.interaction.pushController))
                }
                if selection.isImage { add("mediaViewerMenuItemCopyPhoto", "Copy photo") { imageAction(.copy) } }
                if selection.isVideo { add("mediaViewerMenuItemCopyFrame", "Copy current frame") { imageAction(.copy) } }
                add("mediaViewerMenuItemScanQRCode", "Scan QR code") { imageAction(.scanQR) }
                add("mediaViewerMenuItemSetProfilePhoto", "Set profile photo") { imageAction(.profile) }
                add("mediaViewerMenuItemForward", "Forward", allowed: available.options.contains(.forward)) { chooseForwardDestination(request, session: session, hideNames: false) }
                add("mediaViewerMenuItemNoQuoteForward", "Forward without sender", allowed: available.options.contains(.forward)) { chooseForwardDestination(request, session: session, hideNames: true) }
                add(nil, "Share / Save") { request.nativeShare(access.permit, { access.handoffNativeExport(to: $0) }) }
                sheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentation.strings.Common_Cancel, color: .accent, action: { [weak sheet] in access.cancel(); sheet?.dismissAnimated() })])])
                guard access.own(sheet) else { return }
                request.setInteracting(true)
                access.permit.presentWhenReady(sheet, accountId: access.accountId, from: presenter, requiresExport: true, present: { request.interaction.presentController($0, nil) })
            }
            return true
        }
    }

    private static func chooseForwardDestination(_ request: ExteralessGalleryMessageActionRequest, session: ExteralessSelectionActionSession, hideNames: Bool) {
        let context = request.context
        let access = session.access
        session.read(requiresCopy: true, operation: .exportPreparation) { _, available in
            guard available.options.contains(.forward), let presenter = request.interaction.controller() else { access.invalidate(); return }
            let picker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled, .doNotSearchMessages], hasFilters: true, forwardedMessageIds: [request.message.id], selectForumThreads: false))
            picker.peerSelected = { [weak picker] peer, _ in
                session.read(requiresCopy: true, operation: .exportPreparation) { _, available in
                    guard available.options.contains(.forward) else { access.invalidate(); return }
                    let controller = context.sharedContext.makeChatController(context: context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.default), params: nil)
                    guard access.own(controller) else { return }
                    access.permit.presentWhenReady(controller, accountId: access.accountId, from: presenter, requiresExport: true, present: { controller in
                        session.read(requiresCopy: true, operation: .exportEffect) { snapshot, available in
                            guard available.options.contains(.forward), let current = snapshot.messages.first, request.selection?.reference(in: current) != nil,
                                  let chat = controller as? ChatControllerImpl, access.handoff(to: controller) else { return }
                            chat.updateChatPresentationInterfaceState(animated: false, interactive: false, { state in
                                state.updatedInterfaceState { $0.withUpdatedForwardMessageIds([current.id]).withUpdatedForwardOptionsState(ChatInterfaceForwardOptionsState(hideNames: hideNames, hideCaptions: false, unhideNamesOnCaptionChange: false)) }
                            })
                            picker?.dismiss()
                            request.interaction.pushController(controller)
                        }
                    })
                }
            }
            guard access.own(picker) else { return }
            access.permit.presentWhenReady(picker, accountId: access.accountId, from: presenter, requiresExport: true, present: { request.interaction.presentController($0, nil) })
        }
    }
}
