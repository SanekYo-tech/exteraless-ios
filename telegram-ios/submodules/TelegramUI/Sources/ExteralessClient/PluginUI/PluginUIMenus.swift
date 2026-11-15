import AccountContext
import ContextUI
import Display
import Foundation
import TelegramCore
import UIKit

extension PluginUIBridgeExtension {
    /// Called by the real message/chat/profile menu builder, on main. Registration
    /// alone inserts nothing: common call-site hunks are in the handoff document.
    @MainActor public func menuItems(context: AccountContext, placement: PluginUIMenuPlacement,
                                     peer: EnginePeer? = nil, message: EngineMessage? = nil,
                                     source: ViewController) -> [ContextMenuItem] {
        guard let scope = self.leases.currentScope, self.accountContext === context,
              let account = self.accountIndex(context.account.id.int64) else { return [] }
        let sourceContext = pluginUIScreenContextKey(source)
        let payload = pluginUIMenuContext(context: context, account: account, placement: placement, peer: peer, message: message, source: source, fragmentId: self.screenId(source, scope: scope), scope: scope)
        return self.matchingMenus(placement, payload: payload).compactMap { entry in
            guard case let .menu(model) = entry.content else { return nil }
            let image: UIImage?
            do { image = try model.icon.map { try PluginUIResources.image($0) } }
            catch let failure as PluginUIFailure {
                return .action(ContextMenuActionItem(text: "\(failure.kind): \(failure.message)", textColor: .disabled,
                    textLayout: .multiline, icon: { _ in nil }, action: nil as ((ContextMenuActionItem.Action) -> Void)?))
            } catch {
                return .action(ContextMenuActionItem(text: "ResourceUnavailable: \(model.icon ?? "image")", textColor: .disabled,
                    textLayout: .multiline, icon: { _ in nil }, action: nil as ((ContextMenuActionItem.Action) -> Void)?))
            }
            let layout: ContextMenuActionItemTextLayout = model.subtext.map { .secondLineWithValue($0) } ?? .multiline
            return .action(ContextMenuActionItem(id: entry.state.id.uuidString, text: model.text, textLayout: layout, icon: { theme in
                return image?.withTintColor(theme.contextMenu.primaryColor, renderingMode: .alwaysOriginal)
            }, action: { [weak self, weak source] controller, completion in
                // ContextController's completion runs after dismissal. Recheck
                // the source then: opening another chat during the animation
                // must not redirect this old menu's callback/navigation.
                let invoke = { [weak self, weak source] in
                    guard let self, let source, self.menuSourceIsCurrent(context: context, source: source, contextKey: sourceContext),
                          self.isCurrent(owner: entry.owner, scope: scope) else { return }
                    self.invokeMenu(entry: entry, payload: payload)
                }
                if let controller { controller.dismiss(completion: invoke) }
                else { completion(.default); invoke() }
            }))
        }
    }

    /// iOS's native main/drawer adaptation uses the existing grouped list rows.
    /// MAIN_MENU includes DRAWER_MENU, as Android's mainMenuItems does.
    @MainActor func menuRows(context: AccountContext, placement: PluginUIMenuPlacement,
                            peer: EnginePeer? = nil, message: EngineMessage? = nil,
                            source: ViewController) -> [PluginListRow] {
        guard self.accountContext === context, let scope = self.leases.currentScope, let account = self.accountIndex(context.account.id.int64) else { return [] }
        let sourceContext = pluginUIScreenContextKey(source)
        let payload = pluginUIMenuContext(context: context, account: account, placement: placement, peer: peer, message: message, source: source, fragmentId: self.screenId(source, scope: scope), scope: scope)
        return self.matchingMenus(placement, payload: payload).compactMap { entry in
            guard case let .menu(model) = entry.content else { return nil }
            var row = PluginListRow(id: "plugin-menu:\(entry.state.id.uuidString)", title: model.text, detail: model.subtext)
            row.action = { [weak self, weak source] in
                guard let self, let source, self.menuSourceIsCurrent(context: context, source: source, contextKey: sourceContext) else { return }
                self.invokeMenu(entry: entry, payload: payload)
            }
            return row
        }
    }

    @MainActor private func matchingMenus(_ placement: PluginUIMenuPlacement, payload: [String: PluginUIJSON]) -> [Store.Entry] {
        return self.leases.menus().filter { entry in
            guard case let .menu(model) = entry.content, self.isCurrent(owner: entry.owner, scope: entry.state.scope),
                  model.placement == placement || (placement == .main && model.placement == .drawer) else { return false }
            return model.condition.matches(payload)
        }
    }

    @MainActor private func menuSourceIsCurrent(context: AccountContext, source: ViewController, contextKey: String?) -> Bool {
        guard self.accountContext === context, source.viewIfLoaded?.window != nil else { return false }
        return self.currentPresenter(context) === source && pluginUIScreenContextKey(source) == contextKey
    }

    @MainActor private func invokeMenu(entry: Store.Entry, payload: [String: PluginUIJSON]) {
        guard self.isCurrent(owner: entry.owner, scope: entry.state.scope) else { return }
        let decision = self.leases.action(id: entry.state.id, revision: entry.state.revision, scope: entry.state.scope, name: "click", payload: [:])
        guard decision.accepted, let delivery = decision.delivery else { return }
        // Menu callbacks take the original SDK context dictionary, not the UI
        // presentation event wrapper. The handle still belongs to this lease.
        var context = payload
        for (key, value) in entry.state.callbackMetadata { context[key] = value }
        if !self.deliver(Store.Delivery(owner: delivery.owner, handle: delivery.handle, arguments: .array([.object(context)]))),
           let account = self.accountContext, let presenter = self.currentPresenter(account), presenter.viewIfLoaded?.window != nil {
            let alert = UIAlertController(title: "ServiceUnavailable", message: "The plugin callback queue could not accept this menu action. Try again after the running callback finishes.", preferredStyle: .alert)
            alert.overrideUserInterfaceStyle = account.sharedContext.currentPresentationData.with { $0.theme.overallDarkAppearance } ? .dark : .light
            alert.addAction(UIAlertAction(title: pluginText("Common.Close", "Close"), style: .cancel))
            presenter.present(alert, animated: true)
        }
    }
}

@MainActor private func pluginUIMenuContext(context: AccountContext, account: Int32, placement: PluginUIMenuPlacement,
                                           peer: EnginePeer?, message: EngineMessage?, source: ViewController, fragmentId: UUID, scope: PluginUIScope) -> [String: PluginUIJSON] {
    var result: [String: PluginUIJSON] = [
        "account": .integer(Int64(account)), "accountRecordId": .integer(context.account.id.int64),
        "menu_type": .string(placement.rawValue), "message": .null, "user": .null, "chat": .null, "encryptedChat": .null,
        "dialog_id": .null, "userId": .null, "chatId": .null,
        "fragment": .object(["kind": .string(placement == .profile ? "profile" : (source is ChatController ? "chat" : "screen")), "title": .string(source.title ?? ""),
            "id": .string(fragmentId.uuidString), "scope": .string(scope.id.uuidString), "account": .integer(Int64(account)), "isPresented": .bool(source.viewIfLoaded?.window != nil)]),
        "context": .object(["platform": .string("ios"), "account": .integer(Int64(account))])
    ]
    let actualPeer = peer ?? message.flatMap { $0.enginePeers[$0.id.peerId] }
    if let peer = actualPeer {
        let id = peer.id.id._internalGetInt64Value()
        switch peer {
        case let .user(user):
            result["userId"] = .integer(id)
            result["dialog_id"] = .integer(id)
            result["peer"] = .object(["type": .string("user"), "id": .integer(id)])
            result["user"] = .object(["id": .integer(id), "bot": .bool(user.botInfo != nil), "first_name": .string(user.firstName ?? ""),
                "last_name": .string(user.lastName ?? ""), "username": user.username.map(PluginUIJSON.string) ?? .null, "is_self": .bool(peer.id == context.account.peerId)])
        case let .legacyGroup(group):
            result["chatId"] = .integer(id)
            result["dialog_id"] = .integer(-id)
            result["peer"] = .object(["type": .string("group"), "id": .integer(id)])
            result["chat"] = .object(["id": .integer(id), "title": .string(group.title), "username": .null, "megagroup": .bool(false), "broadcast": .bool(false), "forum": .bool(false)])
        case let .channel(channel):
            let broadcast: Bool
            if case .broadcast = channel.info { broadcast = true } else { broadcast = false }
            result["chatId"] = .integer(id)
            result["dialog_id"] = .integer(-id)
            result["peer"] = .object(["type": .string("channel"), "id": .integer(id)])
            result["chat"] = .object(["id": .integer(id), "title": .string(channel.title), "username": channel.username.map(PluginUIJSON.string) ?? .null,
                "megagroup": .bool(!broadcast), "broadcast": .bool(broadcast), "forum": .bool(channel.flags.contains(.isForum))])
        case let .community(community):
            result["peer"] = .object(["type": .string("community"), "id": .integer(id)])
            result["community"] = .object(["id": .integer(id), "title": .string(community.title)])
        case .secretChat:
            result["peer"] = .object(["type": .string("secretChat"), "id": .integer(id)])
            result["encryptedChat"] = .object(["id": .integer(id), "platform": .string("ios")])
            // Secret chats have platform-specific dialog addressing. A typed
            // native peer is supplied; no Android encrypted-dialog id is forged.
        }
    }
    if let message {
        var photo = false
        var video = false
        var voice = false
        var music = false
        var document = false
        var sticker = false
        var roundVideo = false
        var gif = false
        var animatedSticker = false
        for media in message.engineMedia {
            switch media {
            case .image: photo = true
            case let .file(file):
                let fileSticker = file.isSticker || file.isAnimatedSticker || file.isVideoSticker
                let fileVideo = file.isVideo && !file.isInstantVideo && !file.isAnimated && !file.isVideoSticker
                let fileMusic = file.isMusic && !fileVideo && !file.isInstantVideo
                document = document || (!fileVideo && !fileMusic && !file.isVoice && !fileSticker)
                video = video || fileVideo
                voice = voice || file.isVoice
                music = music || fileMusic
                sticker = sticker || fileSticker
                roundVideo = roundVideo || file.isInstantVideo
                gif = gif || (!fileSticker && (file.isAnimated || file.mimeType == "image/gif"))
                animatedSticker = animatedSticker || file.isAnimatedSticker || file.isVideoSticker
            default: break
            }
        }
        let text = String(message.text.unicodeScalars.prefix(65536))
        let out = !message.flags.contains(.Incoming)
        result["message"] = .object([
            "id": .integer(Int64(message.id.id)), "text": .string(text), "messageText": .string(text),
            "textTruncated": .bool(text != message.text), "out": .bool(out), "isOutOwner": .bool(!message.effectivelyIncoming(context.account.peerId)),
            "isPhoto": .bool(photo), "isVideo": .bool(video), "isVoice": .bool(voice), "isMusic": .bool(music),
            "isDocument": .bool(document), "isSticker": .bool(sticker), "getId": .integer(Int64(message.id.id)),
            "isRoundVideo": .bool(roundVideo), "isGif": .bool(gif), "isAnimatedSticker": .bool(animatedSticker),
            "getDialogId": result["dialog_id"] ?? .null, "date": .integer(Int64(message.timestamp)),
            "namespace": .integer(Int64(message.id.namespace)), "threadId": message.threadId.map(PluginUIJSON.integer) ?? .null
        ])
    }
    return result
}
