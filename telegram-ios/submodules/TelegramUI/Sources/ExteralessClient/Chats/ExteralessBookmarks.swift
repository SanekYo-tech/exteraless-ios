import AccountContext
import Display
import ExteralessCore
import Foundation
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit

func exteralessBookmarkStore(_ context: AccountContext) -> ChatBookmarkStore {
    ChatBookmarkStore(directory: URL(fileURLWithPath: context.sharedContext.basePath, isDirectory: true).appendingPathComponent("exteraless/chat-bookmarks", isDirectory: true))
}

extension ChatControllerImpl {
    func exteralessToggleBookmark(_ message: EngineRawMessage) {
        guard message.id.namespace == Namespaces.Message.Cloud, message.id.peerId.namespace != Namespaces.Peer.SecretChat else { return }
        do {
            let added = try exteralessBookmarkStore(context).toggle(.init(peerKey: message.id.peerId.toInt64(), namespace: message.id.namespace, messageId: message.id.id, timestamp: message.timestamp), account: context.account.id.int64)
            self.controllerInteraction?.displayMessageTooltip(message.id, added ? "Bookmarked" : "Bookmark removed", false, nil, nil)
        } catch {
            self.present(textAlertController(context: context, title: "Bookmarks", text: "The bookmark could not be saved.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
        }
    }
}

final class ExteralessBookmarksController: ExteralessChatTableController {
    init(context: AccountContext) {
        super.init(context: context, title: "Bookmarks")
        do {
            let records = try exteralessBookmarkStore(context).list(account: context.account.id.int64).reversed()
            self.sections = [ExteralessChatSection(footer: "Bookmarks store message references for this account. Opening one uses the original chat.", rows: records.map { record in
                let id = EngineMessage.Id(peerId: EnginePeer.Id(record.peerKey), namespace: record.namespace, id: record.messageId)
                return ExteralessChatRow(id: "\(record.peerKey).\(record.messageId)", title: "Message \(record.messageId)", detail: Date(timeIntervalSince1970: TimeInterval(record.timestamp)).description, action: { [weak self] in
                    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id.peerId)) |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                        guard let self, let peer, let navigation = self.navigationController as? NavigationController else { return }
                        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: .peer(peer), subject: .message(id: .id(id), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false, cachedAnchor: true), keepStack: .always))
                    })
                })
            })]
        } catch {
            self.sections = [ExteralessChatSection(footer: "Bookmarks could not be read. The saved file has been preserved.", rows: [])]
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
