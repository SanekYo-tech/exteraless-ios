import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import UIKit

/// Native share/save/profile/queue routes. The message or media reference crosses
/// the boundary intact; ShareController owns recipient permissions, entities,
/// forwarding, scheduling and Stars confirmation/enqueue semantics.
@MainActor
final class ExteralessPlayerActions {
    private let session: ExteralessPlayerSession
    private let controller: () -> ViewController?
    private let dismiss: () -> Void
    private let disposable = MetaDisposable()
    private weak var alert: UIAlertController?
    var lyrics: (() -> Void)?
    var chooseLyrics: (() -> Void)?

    init(session: ExteralessPlayerSession, controller: @escaping () -> ViewController?, dismiss: @escaping () -> Void) {
        self.session = session
        self.controller = controller
        self.dismiss = dismiss
    }

    deinit { disposable.dispose() }

    func cancel() {
        disposable.set(nil)
        alert?.dismiss(animated: false)
        alert = nil
    }

    func menu(from source: UIView) {
        guard session.accountIsValid, let controller = controller() else { return }
        let identity = session.identity
        let menu = UIAlertController(title: session.titleAndArtist.0, message: nil, preferredStyle: .actionSheet)
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let item = UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self, self.session.accepts(identity) else { return }
                action()
            }
            item.isEnabled = enabled
            menu.addAction(item)
        }
        add(session.isSavedToProfile ? "Remove from My Profile" : "Save to My Profile", enabled: session.canSaveToProfile) { [weak self] in self?.session.toggleProfileSave() }
        add("Save to Saved Messages", enabled: session.canShare) { [weak self] in self?.share(toSavedMessages: true) }
        add("Forward / Share", enabled: session.canShare) { [weak self] in self?.share() }
        add("Share File", enabled: session.canShare) { [weak self] in self?.share(external: true) }
        add("Save to Files", enabled: session.canShare) { [weak self] in self?.saveFile() }
        add("Show source", enabled: session.sourceMessageId != nil || self.savedMusicPeerId != nil) { [weak self] in self?.showSource() }
        add("Lyrics", enabled: session.type == .music) { [weak self] in self?.lyrics?() }
        add("Choose lyrics / timing", enabled: session.type == .music) { [weak self] in self?.chooseLyrics?() }
        add("Queue") { [weak self] in self?.openQueue() }
        add("Playback speed · \(session.state?.status.baseRate ?? 1)×") { [weak self] in self?.session.cycleSpeed() }
        add("Playback order", enabled: session.type != .voice) { [weak self] in self?.session.cycleOrder() }
        add("Repeat", enabled: session.type != .voice) { [weak self] in self?.session.cycleRepeat() }
        add("Player settings") { [weak self] in
            guard let self, let controller = self.controller() else { return }
            controller.push(exteralessSettingsController(context: self.session.context))
        }
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        menu.popoverPresentationController?.sourceView = source
        menu.popoverPresentationController?.sourceRect = source.bounds
        alert = menu
        controller.present(menu, animated: true)
    }

    func share(toSavedMessages: Bool = false, external: Bool = false) {
        guard session.canShare, let file = session.file, let identity = session.identity else { return }
        let subject: Signal<ShareControllerSubject?, NoError>
        if let id = session.sourceMessageId {
            subject = session.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: id)) |> map { message in
                // Do not turn a missing/deleted message into a file-only forward.
                guard let message, !message._asMessage().isCopyProtected() else { return nil }
                return .messages([message._asMessage()])
            }
        } else {
            subject = .single(.media(file.abstract, nil))
        }
        disposable.set((subject |> deliverOnMainQueue).start(next: { [weak self] subject in
            guard let self, self.session.accepts(identity), self.session.canShare, let subject, let controller = self.controller() else { return }
            let context = self.session.context
            let screen = context.sharedContext.makeShareScreen(context: context, params: ShareControllerParams(
                subject: subject,
                showInChat: { [weak self] message in
                    guard let self, self.session.accepts(identity) else { return }
                    context.sharedContext.navigateToChat(accountId: context.account.id, peerId: message.id.peerId, messageId: message.id)
                    self.dismiss()
                },
                externalShare: true,
                immediateExternalShare: external,
                immediatePeerId: toSavedMessages ? context.account.peerId : nil,
                parentNavigationController: controller.navigationController as? NavigationController
            ))
            controller.present(screen, in: .window(.root))
        }))
    }

    func saveFile() {
        guard session.canShare, let file = session.file, let identity = session.identity else { return }
        disposable.set(saveMediaToFiles(context: session.context, fileReference: file, present: { [weak self] controller, arguments in
            guard let self, self.session.accepts(identity), self.session.canShare else { return }
            self.controller()?.present(controller, in: .window(.root), with: arguments)
        }))
    }

    private var savedMusicPeerId: EnginePeer.Id? {
        session.profileMusicPeerId
    }

    func showSource() {
        guard session.accepts(session.identity) else { return }
        if let id = session.sourceMessageId {
            session.context.sharedContext.navigateToChat(accountId: session.context.account.id, peerId: id.peerId, messageId: id)
            dismiss()
        } else if let peerId = savedMusicPeerId {
            let identity = session.identity
            disposable.set((session.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
                guard let self, self.session.accepts(identity), let peer, let parent = self.controller() else { return }
                let context = self.session.context
                if let screen = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: peerId == context.account.peerId ? .myProfile : .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) { parent.push(screen) }
            }))
        }
    }

    func openQueue() {
        guard session.accepts(session.identity), let state = session.state, let type = session.type, let parent = controller() else { return }
        if let screen = Self.nativePlayer(context: session.context, state: state, type: type, parent: parent, forceClassic: true) {
            parent.push(screen)
        } else {
            // An Instant View/single-message playlist has its own actual item
            // source rather than a music-tagged chat history.
            parent.push(ExteralessPlayerQueueController(context: session.context, initial: state, type: type))
        }
    }

    static func nativePlayer(context: AccountContext, state: SharedMediaPlayerItemPlaybackState, type: MediaManagerPlayerType, parent: ViewController, forceClassic: Bool) -> ViewController? {
        let navigation = parent.navigationController as? NavigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController
        let location = state.playlistLocation
        let chatLocation: ChatLocation
        let messageId: EngineMessage.Id
        if let instant = location as? InstantPagePlaylistLocation, let id = instant.messageId,
           let item = state.item.id as? InstantPagePlaylistItemIndexProviding {
            chatLocation = .peer(id: id.peerId)
            messageId = EngineMessage.Id(peerId: id.peerId, namespace: Namespaces.Message.Local, id: Int32(clamping: item.instantPageMediaIndex))
        } else if let item = state.item.id as? PeerMessagesMediaPlaylistItemId, let peerLocation = location as? PeerMessagesPlaylistLocation {
            switch peerLocation {
            case let .messages(chat, _, _): chatLocation = chat
            case .custom, .savedMusic: chatLocation = .peer(id: item.messageId.peerId)
            case .singleMessage, .recentActions: return nil
            }
            messageId = item.messageId
        } else { return nil }
        let controller = OverlayAudioPlayerControllerImpl(context: context, chatLocation: chatLocation, type: type, initialMessageId: messageId, initialOrder: state.order, playlistLocation: location, parentNavigationController: navigation, forceClassic: forceClassic)
        controller.navigationPresentation = .flatModal
        return controller
    }

    static func openMyMusic(context: AccountContext, parent: ViewController) {
        let saved = ProfileSavedMusicContext(account: context.account, peerId: context.account.peerId)
        let id = EngineMessage.Id(peerId: context.account.peerId, namespace: Namespaces.Message.Local, id: 0)
        let controller = OverlayAudioPlayerControllerImpl(context: context, chatLocation: .peer(id: context.account.peerId), type: .music, initialMessageId: id, initialOrder: .regular, playlistLocation: PeerMessagesPlaylistLocation.savedMusic(context: saved, at: 0, canReorder: true), parentNavigationController: parent.navigationController as? NavigationController, forceClassic: true)
        controller.navigationPresentation = .flatModal
        parent.push(controller)
    }
}
