import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

private struct ExteralessDialogForumPreference: Codable {
    let tabs: Bool
}

private func dialogForumEntryId(_ peerId: PeerId) -> ItemCacheEntryId {
    ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.dialog.forum.v1.\(peerId.toInt64())"))
}

/// Per-account encrypted native state. Absence inherits the server's layout;
/// explicit false means List, and must not be treated as an absent preference.
public func exteralessDialogForumLayout(account: Account, peerId: EnginePeer.Id) -> Signal<DialogForumLayout, NoError> {
    let key = PostboxViewKey.cachedItem(dialogForumEntryId(peerId))
    return account.postbox.combinedView(keys: [key])
    |> map { views -> DialogForumLayout in
        guard let view = views.views[key] as? CachedItemView, let preference = view.value?.get(ExteralessDialogForumPreference.self) else { return .inherit }
        return preference.tabs ? .tabs : .list
    }
    |> distinctUntilChanged
}

/// The result reports a local preference write, not channels.toggleForum. This
/// never changes another member's forum layout or requires administrator rights.
public func exteralessSetDialogForumLayout(account: Account, peerId: EnginePeer.Id, layout: DialogForumLayout) -> Signal<Bool, NoError> {
    return account.postbox.transaction { transaction -> Bool in
        guard let peer = transaction.getPeer(peerId) as? TelegramChannel, peer.isForum, !peer.flags.contains(.isMonoforum) else { return false }
        let id = dialogForumEntryId(peerId)
        if layout == .inherit {
            transaction.removeItemCacheEntry(id: id)
        } else {
            guard let entry = CodableEntry(ExteralessDialogForumPreference(tabs: layout == .tabs)) else { return false }
            transaction.putItemCacheEntry(id: id, entry: entry)
        }
        return true
    }
}

public func exteralessDialogUsesForumTabs(peer: EnginePeer, layout: DialogForumLayout, allForumsHaveTabs: Bool = false) -> Bool {
    guard case let .channel(channel) = peer, channel.isForum, !channel.flags.contains(.isMonoforum) else { return false }
    return layout.usesTabs(nativeDefault: allForumsHaveTabs || channel.flags.contains(.displayForumAsTabs))
}

/// Resolves the navigation mode without changing the peer, cached server flags,
/// or the native reply-thread reference later supplied to the chat controller.
public func exteralessDialogViewForumAsMessages(peer: EnginePeer, layout: DialogForumLayout, nativeViewAsMessages: Bool, allForumsHaveTabs: Bool = false) -> Bool {
    guard case let .channel(channel) = peer, channel.isForum, !channel.flags.contains(.isMonoforum) else { return nativeViewAsMessages }
    switch layout {
    case .list: return false
    case .tabs: return true
    case .inherit: return exteralessDialogUsesForumTabs(peer: peer, layout: layout, allForumsHaveTabs: allForumsHaveTabs) || nativeViewAsMessages
    }
}
