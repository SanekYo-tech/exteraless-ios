import AccountContext
import Foundation
import PluginHost
import SwiftSignalKit
import TelegramCore

/// Account-owned cache. Reads are lock-only; a first referenced peer starts a
/// bounded native view asynchronously and immediately reports ready:false.
final class NativeServiceControllerSnapshots: @unchecked Sendable {
    typealias Peer = NativeServiceSnapshots.Peer
    typealias Scope = NativeServiceSnapshots.Scope
    typealias Publisher = NativeServiceSnapshots.Publisher
    let values = NativeServiceSnapshots()
    private final class Context {
        let context: AccountContext
        let scope: Scope
        let lifetime = DisposableSet()
        var peers: [Peer: (Publisher, DisposableSet)] = [:]
        var root: Set<Peer> = []
        var archive: Set<Peer> = []
        init(context: AccountContext, scope: Scope) { self.context = context; self.scope = scope }
        deinit { lifetime.dispose(); for (_, disposable) in peers.values { disposable.dispose() } }
    }
    // Main only; the synchronous getter never reads this dictionary.
    private var contexts: [Int64: Context] = [:]
    private let bindLock = NSLock()
    private var dirtyAccounts: Set<Int64> = []
    private var bindScheduled = false

    @MainActor func attach(_ context: AccountContext) -> Scope {
        let recordId = context.account.id.int64
        if let current = contexts[recordId], current.context === context { return current.scope }
        detach(recordId)
        let scope = values.begin(recordId: recordId, userId: context.account.peerId.id._internalGetInt64Value())
        let state = Context(context: context, scope: scope)
        contexts[recordId] = state
        if let peer = try? Peer(kind: .user, id: scope.userId) { reference(peer, scope: scope, pinned: true) }
        for (group, count, archive) in [(EngineChatList.Group.root, 64, false), (.archive, 16, true)] {
            state.lifetime.add((context.engine.messages.chatList(group: group, count: count)
            |> deliverOnMainQueue).start(next: { [weak self, weak state] list in
                guard let self, let state, self.values.isCurrent(scope) else { return }
                let peers = Set(list.items.compactMap { item -> Peer? in
                    guard let reference = nativeServicePeerReference(item.renderedPeer.peerId) else { return nil }
                    return self.cachePeer(reference)
                })
                if archive { state.archive = peers } else { state.root = peers }
                var pinned = state.root.union(state.archive)
                if let peer = try? Peer(kind: .user, id: scope.userId) { pinned.insert(peer) }
                self.values.pin(pinned, scope: scope)
                for peer in pinned { self.reference(peer, scope: scope, pinned: true) }
                self.seed(list.items.compactMap { $0.renderedPeer.peer }.map {
                    nativeServicePeerHeader($0, accountUserId: scope.userId)
                }, scope: scope)
            }))
        }
        return scope
    }

    @MainActor func detach(_ recordId: Int64) {
        guard let state = contexts.removeValue(forKey: recordId) else { return }
        values.end(state.scope)
        state.lifetime.dispose()
        for (_, disposable) in state.peers.values { disposable.dispose() }
    }

    @MainActor func clear() { for id in Array(contexts.keys) { detach(id) } }

    func cachePeer(_ reference: ExteralessTLPeerReference) -> Peer? {
        guard let kind = Peer.Kind(rawValue: reference.kind.rawValue) else { return nil }
        return try? Peer(kind: kind, id: reference.id)
    }

    func reference(_ peer: Peer, scope: Scope, pinned: Bool = false) {
        guard let reservation = values.reference(peer, scope: scope, pinned: pinned) else { return }
        guard reservation.start || !reservation.evicted.isEmpty else { return }
        scheduleBindings(scope.recordId)
    }

    private func scheduleBindings(_ recordId: Int64) {
        bindLock.lock()
        dirtyAccounts.insert(recordId)
        let schedule = !bindScheduled
        bindScheduled = true
        bindLock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in self?.drainBindings() } }
    }

    @MainActor private func drainBindings() {
        bindLock.lock()
        let records = dirtyAccounts
        dirtyAccounts.removeAll()
        bindScheduled = false
        bindLock.unlock()
        for recordId in records {
            guard let state = contexts[recordId] else { continue }
            for peer in Array(state.peers.keys) {
                if let entry = state.peers[peer], !values.isCurrent(entry.0) { state.peers.removeValue(forKey: peer)?.1.dispose() }
            }
            for publisher in values.publishers(scope: state.scope) where state.peers[publisher.peer]?.0 != publisher {
                bind(publisher)
            }
        }
    }

    @MainActor private func bind(_ publisher: Publisher) {
        guard let state = contexts[publisher.scope.recordId], state.scope == publisher.scope else { return }
        guard values.isCurrent(publisher) else { return }
        let kind: ExteralessTLPeerReference.Kind
        switch publisher.peer.kind { case .user: kind = .user; case .group: kind = .group; case .channel: kind = .channel }
        guard let peer = try? ExteralessTLPeerReference(kind: kind, id: publisher.peer.id) else { return }
        let id: EnginePeer.Id
        switch publisher.peer.kind {
        case .user: id = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(peer.id))
        case .group: id = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(peer.id))
        case .channel: id = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(peer.id))
        }
        let disposables = DisposableSet()
        state.peers[publisher.peer]?.1.dispose()
        state.peers[publisher.peer] = (publisher, disposables)
        let values = self.values
        disposables.add(state.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: id)).start(next: { value in
            let header = value.map { nativeServicePeerHeader($0, accountUserId: publisher.scope.userId) } ?? .null
            if let value = try? PluginJSONValue(jsonObject: header.jsonObject) {
                do { _ = try values.publishPeer(value, publisher: publisher, source: "Postbox.peerView/EnginePeer") }
                catch { _ = try? values.publishPeer(.null, publisher: publisher, source: "snapshotUnavailable") }
            }
        }))
        disposables.add(nativeServiceObservePeerDetails(account: state.context.account, peer: peer).start(next: { value in
            if let value = try? PluginJSONValue(jsonObject: value.jsonObject) {
                do { _ = try values.publishPeer(value, full: true, publisher: publisher, source: "Postbox.cachedPeerData") }
                catch { _ = try? values.publishPeer(.null, full: true, publisher: publisher, source: "snapshotUnavailable") }
            }
        }))
    }

    /// Used before a committed-message event reaches Python, so its real sender/
    /// dialog headers are already available to synchronous controller consumers.
    func seed(_ headers: [ExteralessTLValue], scope: Scope) {
        for header in headers {
            guard let kindName = header["peer"]?["type"]?.stringValue, let kind = Peer.Kind(rawValue: kindName),
                  let id = header["peer"]?["id"]?.integerValue, let peer = try? Peer(kind: kind, id: id),
                  let value = try? PluginJSONValue(jsonObject: header.jsonObject),
                  let reservation = values.reference(peer, scope: scope) else { continue }
            // Seeds only fill an unobserved slot; a delayed main-list snapshot
            // cannot overwrite a newer live Peer view publication.
            if !values.wasObserved(peer, scope: scope) {
                do { _ = try values.publishPeer(value, publisher: reservation.publisher, source: "native-referenced-peers") }
                catch { _ = try? values.publishPeer(.null, publisher: reservation.publisher, source: "snapshotUnavailable") }
            }
            if reservation.start || !reservation.evicted.isEmpty { scheduleBindings(scope.recordId) }
        }
    }

    func publish(_ value: PluginJSONValue, key: String, scope: Scope, source: String) {
        do { _ = try values.publish(value, key: key, scope: scope, source: source) }
        catch { _ = try? values.publish(.null, key: key, scope: scope, source: "snapshotUnavailable") }
    }

    func peer(account: PluginServiceAccount, id: Int64, kind: Peer.Kind, full: Bool = false) throws -> PluginJSONValue {
        let method = full ? "fullPeer" : "peer"
        guard let scope = values.scope(recordId: account.recordId) else { return NativeServiceSnapshots.notReady(method) }
        let peer = try Peer(kind: kind, id: kind == .user && id == 0 ? account.userId : id)
        reference(peer, scope: scope)
        return values.read(key: (full ? "full:" : "") + peer.key, scope: scope, kind: method)
    }

    func chat(account: PluginServiceAccount, id: Int64, full: Bool = false) throws -> PluginJSONValue {
        guard let scope = values.scope(recordId: account.recordId) else { return NativeServiceSnapshots.notReady("chat") }
        let group = try Peer(kind: .group, id: id)
        let channel = try Peer(kind: .channel, id: id)
        reference(group, scope: scope)
        reference(channel, scope: scope)
        guard values.wasObserved(group, scope: scope), values.wasObserved(channel, scope: scope) else { return NativeServiceSnapshots.notReady("chat") }
        let groupReady = values.readyValue(key: group.key, scope: scope) != nil
        let channelReady = values.readyValue(key: channel.key, scope: scope) != nil
        if groupReady && channelReady { throw BridgeFailure.malformed("AMBIGUOUS_CHAT_ID_REQUIRES_PEER_TYPE") }
        guard groupReady || channelReady else { return NativeServiceSnapshots.notReady("chat") }
        let peer = groupReady ? group : channel
        return values.read(key: (full ? "full:" : "") + peer.key, scope: scope, kind: full ? "fullChat" : "chat")
    }

    deinit {
        // Terminal callbacks can outlive their native lease/provider. Their
        // lock-only guard retains values, so explicitly retire account epochs.
        for state in contexts.values { values.end(state.scope) }
    }
}
