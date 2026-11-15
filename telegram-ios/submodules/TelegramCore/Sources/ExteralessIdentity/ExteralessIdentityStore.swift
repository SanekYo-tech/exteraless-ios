import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

// Durable preferences, not an evictable item cache. This one namespaced row is
// inside the account's encrypted Postbox. No shared preferences / contact dump.
private let exteralessIdentityStateKey = ValueBoxKey("exteraless.identity.state.v1")

public func exteralessIdentityAccountId(_ account: Account) -> IdentityAccountId {
    IdentityAccountId(recordId: account.id.int64, userId: account.peerId.id._internalGetInt64Value(), testingEnvironment: account.testingEnvironment)
}

private func exteralessReadIdentity(_ entry: PreferencesEntry?, owner: IdentityAccountId) throws -> IdentityAccountState {
    guard let entry else { return IdentityAccountState(ownerUserId: owner.userId, testingEnvironment: owner.testingEnvironment) }
    return try IdentityArchive.decode(entry.data, owner: owner)
}

func exteralessIdentityState(account: Account) -> Signal<Result<IdentityAccountState, IdentityError>, NoError> {
    let owner = exteralessIdentityAccountId(account)
    return account.postbox.preferencesView(keys: [exteralessIdentityStateKey])
    |> map { view -> Result<IdentityAccountState, IdentityError> in
        do { return .success(try exteralessReadIdentity(view.values[exteralessIdentityStateKey], owner: owner)) }
        catch { return .failure((error as? IdentityError) ?? .invalidData) }
    }
    |> distinctUntilChanged
}

/// A read-only native preference view; subscribing does not resolve peers or
/// start network requests. Errors remain values so an explicit reset can heal it.
public func exteralessIdentityState(engine: TelegramEngine) -> Signal<Result<IdentityAccountState, IdentityError>, NoError> {
    exteralessIdentityState(account: engine.account)
}

/// All local writes use this transaction, never updatePeers / accountData name,
/// color or emoji-status RPC wrappers. Repeated equal writes are deduplicated.
public func exteralessUpdateIdentity(engine: TelegramEngine, mutation: IdentityMutation, permit: IdentityEditPermit, emojiFiles: [TelegramMediaFile] = []) -> Signal<Bool, IdentityError> {
    let owner = exteralessIdentityAccountId(engine.account)
    return engine.account.postbox.transaction { transaction -> Result<Bool, IdentityError> in
        do {
            try permit.check(owner: owner)
            guard emojiFiles.count <= 3 else { throw IdentityError.quotaExceeded }
            let entry = transaction.getPreferencesEntry(key: exteralessIdentityStateKey)
            if case .resetAll = mutation {
                // Can clear a corrupt own row without decoding it. Never erase a
                // collection or another domain's settings as a "reset" shortcut.
                if entry != nil { transaction.updatePreferencesEntry(key: exteralessIdentityStateKey, { _ in nil }) }
                return .success(entry != nil)
            }
            let previous = try exteralessReadIdentity(entry, owner: owner)
            let updated = try mutation.applying(to: previous)
            try updated.validate(owner: owner)
            let referencedIds = Set([updated.emojiStatus?.documentId, updated.colors?.emojiId, updated.colors?.profileEmojiId].compactMap { $0 })
            var stored = Set<Int64>()
            for file in emojiFiles where referencedIds.contains(file.fileId.id) && stored.insert(file.fileId.id).inserted {
                transaction.storeMediaIfNotPresent(media: file)
            }
            guard previous != updated else { return .success(false) }
            let data = try IdentityArchive.encode(updated)
            transaction.updatePreferencesEntry(key: exteralessIdentityStateKey, { _ in PreferencesEntry(data: data) })
            return .success(true)
        } catch { return .failure((error as? IdentityError) ?? .invalidData) }
    }
    |> castError(IdentityError.self)
    |> mapToSignal { result in
        switch result {
        case let .success(changed): return .single(changed)
        case let .failure(error): return .fail(error)
        }
    }
}

public func exteralessIdentityPeerKey(_ peer: EnginePeer) -> IdentityPeerKey? {
    if case let .secretChat(chat) = peer {
        let id = chat.regularPeerId.id._internalGetInt64Value()
        return id > 0 ? IdentityPeerKey(kind: .user, id: id) : nil
    }
    let id = peer.id.id._internalGetInt64Value()
    guard id > 0 else { return nil }
    switch peer {
    case .user: return peer.id.namespace == Namespaces.Peer.CloudUser ? IdentityPeerKey(kind: .user, id: id) : nil
    case .legacyGroup: return peer.id.namespace == Namespaces.Peer.CloudGroup ? IdentityPeerKey(kind: .group, id: id) : nil
    case .channel: return peer.id.namespace == Namespaces.Peer.CloudChannel ? IdentityPeerKey(kind: .channel, id: id) : nil
    case .community: return peer.id.namespace == Namespaces.Peer.CloudChannel ? IdentityPeerKey(kind: .community, id: id) : nil
    case .secretChat: return nil
    }
}

/// Resolve only aliases already present in this account's local database. The UI
/// can list stale/unavailable peer IDs without making a network discovery request.
public func exteralessIdentityAliasPeers(engine: TelegramEngine, keys: [IdentityPeerKey]) -> Signal<[String: EnginePeer], NoError> {
    engine.account.postbox.transaction { transaction in
        var result: [String: EnginePeer] = [:]
        for key in keys.prefix(IdentityAccountState.maximumAliases) {
            let namespace: PeerId.Namespace
            switch key.kind {
            case .user: namespace = Namespaces.Peer.CloudUser
            case .group: namespace = Namespaces.Peer.CloudGroup
            case .channel: namespace = Namespaces.Peer.CloudChannel
            case .community: namespace = Namespaces.Peer.CloudChannel
            }
            let id = PeerId(namespace: namespace, id: ._internalFromInt64Value(key.id))
            if let peer = transaction.getPeer(id) { result[key.storageKey] = EnginePeer(peer) }
        }
        return result
    }
}
