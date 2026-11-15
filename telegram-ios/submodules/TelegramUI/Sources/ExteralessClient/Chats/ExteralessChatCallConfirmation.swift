import AccountContext
import AlertComponent
import Display
import ExteralessCore
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore

func exteralessRequestOutgoingCall(context: AccountContext, peerId: EnginePeer.Id, isVideo: Bool, completion: @escaping () -> Void) {
    let validity = combineLatest(context.sharedContext.activeAccountContexts, context.sharedContext.applicationBindings.applicationInForeground)
        |> map { accounts, foreground in accounts.primary === context && foreground }
    let flow = ExteralessChatCallFlow<EnginePeer>(targetId: peerId,
        ask: ClientSettings.shared.bool("chats.askBeforeCall", default: true), validity: validity,
        load: { currentId in
            let signal: Signal<(EnginePeer?, EnginePeer?), NoError>
            if let currentId {
                signal = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId), TelegramEngine.EngineData.Item.Peer.Peer(id: currentId))
            } else {
                signal = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> map { ($0, nil) }
            }
            return signal |> timeout(8.0, queue: .mainQueue(), alternate: .single((nil, nil))) |> map { (target: $0.0, current: $0.1) }
        }, request: { replace in
            guard let result = context.sharedContext.callManager?.requestCall(context: context, peerId: peerId, isVideo: isVideo, endCurrentIfAny: replace) else { return .unavailable }
            if case let .alreadyInProgress(current) = result {
                if case let .peer(id) = current { return .alreadyInProgress(id) }
                return .alreadyInProgress(nil)
            }
            return .started
        }, present: { prompt, peers, proceed, cancel in
            guard context.sharedContext.mainWindow != nil else { return nil }
            let data = context.sharedContext.currentPresentationData.with { $0 }
            let strings = data.strings
            let title: String
            let text: String
            switch prompt {
            case .initial:
                title = isVideo ? "Start video call?" : "Start voice call?"
                text = peers.target?.displayTitle(strings: strings, displayOrder: data.nameDisplayOrder) ?? "this person"
            case .replace:
                let target = peers.target?.compactDisplayTitle ?? ""
                if case let .channel(channel)? = peers.current, case .broadcast = channel.info {
                    title = strings.Call_VoiceChatInProgressTitle
                    text = strings.Call_LiveStreamInProgressCallMessage(channel.title, target).string
                } else if case .channel? = peers.current {
                    title = strings.Call_VoiceChatInProgressTitle
                    text = strings.Call_VoiceChatInProgressCallMessage(peers.current?.compactDisplayTitle ?? "", target).string
                } else if case .legacyGroup? = peers.current {
                    title = strings.Call_VoiceChatInProgressTitle
                    text = strings.Call_VoiceChatInProgressCallMessage(peers.current?.compactDisplayTitle ?? "", target).string
                } else {
                    title = strings.Call_CallInProgressTitle
                    text = strings.Call_CallInProgressMessage(peers.current?.compactDisplayTitle ?? "", target).string
                }
            case .external:
                title = strings.Call_CallInProgressTitle
                text = strings.Call_ExternalCallInProgressMessage
            }
            var actions: [TextAlertAction] = []
            if prompt != .external { actions.append(TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: cancel)) }
            actions.append(TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: proceed))
            guard let controller = textAlertController(context: context, title: title, text: text, actions: actions) as? AlertScreen else { cancel(); return nil }
            // CallFlow presents only after its peer read delivers on main.
            MainActor.assumeIsolated {
                controller.dismissed = { _ in cancel() }
                context.sharedContext.presentGlobalController(controller, nil)
            }
            return ActionDisposable { [weak controller] in
                Queue.mainQueue().async { MainActor.assumeIsolated { controller?.dismiss() } }
            }
        }, completion: completion, navigate: { context.sharedContext.navigateToCurrentCall() })
    flow.start()
}
