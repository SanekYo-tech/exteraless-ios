import AccountContext
import ChatScheduleTimeController
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore

/// Shared-file Forward hunks call these at destination/payment/schedule and final
/// enqueue/draft boundaries. They preserve the native forwarding implementation.
@MainActor
func exteralessForwardAdmission(context: AccountContext, access: ExteralessChatExportAccess?, operation: ExteralessContentExportPermit.Operation, _ body: @escaping () -> Void) {
    guard let access else { body(); return }
    access.add((context.sharedContext.chatAvailableMessageActions(engine: context.engine, accountPeerId: context.account.peerId, messageIds: access.ids, keepUpdated: false) |> take(1) |> deliverOnMainQueue).start(next: { available in
        guard available.options.contains(.forward), !available.isCopyProtected else { access.invalidate(); return }
        access.perform(operation: operation) { _ in body() }
    }))
}

@MainActor
func exteralessForwardExportSignal<Value, Failure>(context: AccountContext, access: ExteralessChatExportAccess?, _ source: @escaping () -> Signal<Value, Failure>) -> Signal<Value, Failure> {
    guard let access else { return source() }
    return Signal { subscriber in
        let cancelled = Atomic(value: false)
        let pending = MetaDisposable()
        let revoked = access.permit.onRevocation { pending.dispose(); subscriber.putCompletion() }
        Queue.mainQueue().async {
            MainActor.assumeIsolated {
                guard !cancelled.with({ $0 }) else { return }
                exteralessForwardAdmission(context: context, access: access, operation: .exportEffect) {
                    guard !cancelled.with({ $0 }) else { return }
                    pending.set(access.permit.guardSignal(accountId: context.account.id.int64, messageIds: access.ids, operation: .exportEffect, source).start(next: subscriber.putNext, error: subscriber.putError, completed: subscriber.putCompletion))
                }
            }
        }
        return ActionDisposable { _ = cancelled.swap(true); pending.dispose(); revoked.dispose() }
    }
}

@MainActor
func exteralessPresentForwardController(context: AccountContext, access: ExteralessChatExportAccess?, controller: ViewController, from source: ViewController, push: Bool = false) {
    let source = source.viewIfLoaded?.window != nil ? source : (access?.presentationController ?? source)
    let present: (ViewController) -> Void = { controller in
        if push {
            let navigation = (source as? ChatControllerImpl)?.effectiveNavigationController ?? (source.navigationController as? NavigationController)
            navigation?.pushViewController(controller)
        }
        else { source.present(controller, in: .window(.root)) }
    }
    guard let access else { present(controller); return }
    exteralessForwardAdmission(context: context, access: access, operation: .exportPreparation) {
        guard access.own(controller) else { return }
        access.permit.presentWhenReady(controller, accountId: context.account.id.int64, from: source, requiresExport: true, present: { controller in
            exteralessForwardAdmission(context: context, access: access, operation: .presentation) {
                guard access.own(controller, presented: true) else { return }
                if push && !access.coverSource(with: controller) { return }
                present(controller)
            }
        })
    }
}

extension ChatControllerImpl {
    /// Same native schedule screen and defaults; the Forward flow additionally
    /// owns the picker and reauthorizes both its delayed peer read and completion.
    func exteralessForwardSchedulePicker(access: ExteralessChatExportAccess?, silentPosting: Bool? = nil, completion: @escaping (ChatScheduleTimeScreen.Result) -> Void) {
        guard let access else { self.presentScheduleTimePicker(silentPosting: silentPosting, completion: completion); return }
        guard let peerId = self.chatLocation.peerId else { return }
        let context = self.context
        access.add((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId), TelegramEngine.EngineData.Item.Peer.Presence(id: peerId)) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] peer, presence in
            guard let self, let peer else { return }
            exteralessForwardAdmission(context: context, access: access, operation: .exportPreparation) {
                var sendWhenOnline = false
                if let presence, case .present = presence.status { sendWhenOnline = true }
                if peer.id.namespace == Namespaces.Peer.CloudUser && peer.id.id._internalGetInt64Value() == 777000 { sendWhenOnline = false }
                let mode: ChatScheduleTimeScreen.Mode = peerId == context.account.peerId ? .reminders : .scheduledMessages(peerId: peer.id, sendWhenOnlineAvailable: sendWhenOnline)
                let controller = ChatScheduleTimeScreen(context: context, mode: mode, currentTime: nil, currentRepeatPeriod: nil, minimalTime: self.presentationInterfaceState.slowmodeState?.timeout, silentPosting: ExteralessChatSendOptions.scheduleSilent(nativeSilent: self.presentationInterfaceState.interfaceState.silentPosting, defaultSilent: ClientSettings.shared.bool("chats.silentMessageByDefault"), explicit: silentPosting), isDark: false, completion: { result in
                    access.expectCoverDismissal()
                    exteralessForwardAdmission(context: context, access: access, operation: .exportPreparation) { completion(result) }
                })
                self.chatDisplayNode.dismissInput()
                exteralessPresentForwardController(context: context, access: access, controller: controller, from: self, push: self.videoRecorderValue == nil)
            }
        }))
    }
}
