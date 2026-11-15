import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

func exteralessDialogRootPinLimit(_ limits: UserLimitsConfiguration) -> Int {
    DialogPinPolicy.localRootLimit(enabled: DialogPolicy.current.unlimitedPinnedDialogs, serverRootLimit: Int(limits.maxPinnedChatCount), archiveLimit: Int(limits.maxArchivedPinnedChatCount))
}

/// Only this native sync boundary limits what is sent. Local extra pins remain
/// actual native pinned entries; no synthetic peer/index or server entitlement.
func exteralessDialogServerPinOrder(transaction: Transaction, accountPeerId: PeerId, groupId: PeerGroupId, itemIds: [PinnedItemId]) -> [PinnedItemId] {
    let cloud = itemIds.filter { item in
        if case let .peer(peerId) = item { return peerId.namespace != Namespaces.Peer.SecretChat }
        return false
    }
    guard groupId == .root else { return cloud }
    let configuration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue
    let limits = UserLimitsConfiguration(appConfiguration: configuration, isPremium: transaction.getPeer(accountPeerId)?.isPremium ?? false)
    return DialogPinPolicy.serverOrder(cloud, serverLimit: Int(limits.maxPinnedChatCount))
}

/// Initial false on reattach is significant too. Resolve the latest global value
/// inside the account transaction, so a retired UI callback cannot restore true.
public func exteralessUpdateDialogPinPolicy(account: Account) -> Signal<Bool, NoError> {
    return account.postbox.transaction { transaction -> Bool in
        exteralessUpdateDialogPinPolicy(transaction: transaction, accountPeerId: account.peerId, enabled: DialogPolicy.current.unlimitedPinnedDialogs)
    }
}
