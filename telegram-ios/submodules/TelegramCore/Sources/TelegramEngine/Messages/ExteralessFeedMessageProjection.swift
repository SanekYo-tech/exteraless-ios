import Foundation
import Postbox
import SwiftSignalKit

/// A native message rendered with current peer/associated data. renderToken is independent of
/// stableVersion and EngineMessage's intentionally shallow equality.
public struct ExteralessFeedMessageProjection {
    public let message: EngineMessage
    public let peer: EnginePeer?
    public let group: EngineChatList.Group?
    public let renderToken: UUID

    public init(message: EngineMessage, peer: EnginePeer?, group: EngineChatList.Group?, renderToken: UUID = UUID()) {
        var peers = message.peers
        peers[message.id.peerId] = peer?._asPeer()
        self.message = EngineMessage(message._asMessage().withUpdatedPeers(peers))
        self.peer = peer
        self.group = group
        self.renderToken = renderToken
    }

    public var isEligible: Bool { self.group != nil && exteralessFeedMessageIsEligible(self.message) }
    public var isArchived: Bool { self.group == .archive }
    public var isCopyProtected: Bool { self.peer == nil || self.message._asMessage().isCopyProtected() || self.peer?.isCopyProtectionEnabled == true }

    public func allowsMedia(contentSettings: ContentSettings) -> Bool {
        guard self.isEligible else { return false }
        if self.peer?.restrictionText(platform: "ios", contentSettings: contentSettings) != nil { return false }
        if let restricted = self.message.attributes.first(where: { $0 is RestrictedContentMessageAttribute }) as? RestrictedContentMessageAttribute,
           restricted.platformText(platform: "ios", contentSettings: contentSettings) != nil { return false }
        return true
    }

    public func allowsExport(contentSettings: ContentSettings) -> Bool {
        self.allowsMedia(contentSettings: contentSettings) && !self.isCopyProtected
    }
}

private final class ExteralessFeedProjectionDependencies {
    let message: Message
    let associated: [MessageId: Message]
    let peers: [PeerId: BasicPeerView]
    let extra: [PostboxViewKey: PostboxView]

    init(message: Message, associated: [MessageId: Message], peers: [PeerId: BasicPeerView], extra: [PostboxViewKey: PostboxView]) {
        self.message = exteralessFeedRenderSnapshot(message)
        self.associated = associated.mapValues { exteralessFeedRenderSnapshot($0) }
        self.peers = peers
        self.extra = extra
    }

    func matches(_ other: ExteralessFeedProjectionDependencies) -> Bool {
        // Resubscribing a native view decodes new objects. Compare render data, not addresses.
        guard exteralessFeedMessageRenderEqual(self.message, other.message), self.associated.count == other.associated.count,
              self.peers.count == other.peers.count, self.extra.count == other.extra.count else { return false }
        for (id, message) in self.associated {
            guard let otherMessage = other.associated[id], exteralessFeedMessageRenderEqual(message, otherMessage) else { return false }
        }
        for (id, view) in self.peers {
            guard let next = other.peers[id], view.groupId == next.groupId else { return false }
            if let peer = view.peer {
                guard let nextPeer = next.peer, peer.isEqual(nextPeer) else { return false }
            } else if next.peer != nil { return false }
        }
        for (key, view) in self.extra {
            if let view = view as? MessageHistoryThreadInfoView {
                guard let next = other.extra[key] as? MessageHistoryThreadInfoView, view.info == next.info else { return false }
            } else if let view = view as? StoryView {
                guard let next = other.extra[key] as? StoryView, view.item == next.item else { return false }
            } else { return false }
        }
        return true
    }
}

private final class ExteralessFeedProjectionCache {
    var generation: UInt64 = 0
    var dependencies: [MessageId: ExteralessFeedProjectionDependencies] = [:]
    var projections: [MessageId: ExteralessFeedMessageProjection] = [:]
    var baselines: [MessageId: Message] = [:]

    func retain(_ ids: Set<MessageId>) {
        self.dependencies = self.dependencies.filter { ids.contains($0.key) }
        self.projections = self.projections.filter { ids.contains($0.key) }
        self.baselines = self.baselines.filter { ids.contains($0.key) }
    }

    func adopt(_ values: [MessageId: ExteralessFeedMessageProjection], retaining ids: Set<MessageId>) -> [MessageId: ExteralessFeedMessageProjection] {
        var result: [MessageId: ExteralessFeedMessageProjection] = [:]
        var baselines: [MessageId: Message] = [:]
        for (id, value) in values where ids.contains(id) {
            if let old = self.projections[id], let baseline = self.baselines[id], old.group == value.group, old.peer == value.peer,
               exteralessFeedMessageRenderEqual(baseline, value.message._asMessage()) {
                result[id] = old
                baselines[id] = baseline
            } else {
                if self.projections[id]?.renderToken == value.renderToken {
                    result[id] = ExteralessFeedMessageProjection(message: value.message, peer: value.peer, group: value.group)
                } else { result[id] = value }
                baselines[id] = exteralessFeedRenderSnapshot(value.message._asMessage())
            }
        }
        self.projections = result
        self.baselines = baselines
        return result
    }
}

private func exteralessFeedRenderSnapshot(_ message: Message, depth: Int = 0) -> Message {
    var result = message
    if message.attributes.contains(where: { $0 is RichTextMessageAttribute }) {
        result = result.withUpdatedAttributes(message.attributes.map { attribute in
            // fullInstantPage is mutable on the native attribute. Freeze its reference for
            // comparison only; the rendered/exported message remains the original native one.
            if let rich = attribute as? RichTextMessageAttribute { return RichTextMessageAttribute(instantPage: rich.instantPage, fullInstantPage: rich.fullInstantPage) }
            return attribute
        })
    }
    if depth < 4 {
        var associated = message.associatedMessages
        var changed = false
        for (id, value) in message.associatedMessages {
            let snapshot = exteralessFeedRenderSnapshot(value, depth: depth + 1)
            if snapshot !== value { associated[id] = snapshot; changed = true }
        }
        if changed { result = result.withUpdatedAssociatedMessages(associated) }
    }
    return result
}

private func exteralessFeedMessageRenderEqual(_ lhs: Message, _ rhs: Message, depth: Int = 0) -> Bool {
    if lhs === rhs { return true }
    guard depth <= 4, lhs.stableId == rhs.stableId, EngineMessage(lhs) == EngineMessage(rhs),
          lhs.customTags == rhs.customTags, lhs.associatedMessageIds == rhs.associatedMessageIds,
          lhs.peers.count == rhs.peers.count, lhs.associatedMessages.count == rhs.associatedMessages.count,
          lhs.associatedMedia.count == rhs.associatedMedia.count, lhs.associatedStories == rhs.associatedStories else { return false }
    for (id, peer) in lhs.peers {
        guard let other = rhs.peers[id], peer.isEqual(other) else { return false }
    }
    for (id, message) in lhs.associatedMessages {
        guard let other = rhs.associatedMessages[id], exteralessFeedMessageRenderEqual(message, other, depth: depth + 1) else { return false }
    }
    for (id, media) in lhs.associatedMedia {
        guard let other = rhs.associatedMedia[id], media.isEqual(to: other) else { return false }
    }
    for (a, b) in zip(lhs.attributes, rhs.attributes) where a !== b {
        if let a = a as? RichTextMessageAttribute {
            guard let b = b as? RichTextMessageAttribute, a == b else { return false }
            continue // Native page equality compares media by key, independent of encode order.
        }
        let first = PostboxEncoder(), second = PostboxEncoder()
        first.encodeRootObject(a)
        second.encodeRootObject(b)
        if first.makeData() != second.makeData() { return false }
    }
    return true
}

/// One timeline owns one session. Native dependencies and render tokens survive old/new ID
/// intersections; removal evicts that root. The injected source exercises this same owner in
/// accountless fixtures, including newly decoded but semantically equal message objects.
public final class ExteralessFeedProjectionSession {
    private let queue = Queue(name: "Exteraless.Feed.ProjectionSession")
    private let cache = ExteralessFeedProjectionCache()
    private let engine: TelegramEngine?
    private let source: ((Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>)?
    private var binding: UInt64 = 0

    public init(engine: TelegramEngine) { self.engine = engine; self.source = nil }
    public init(source: @escaping (Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>) { self.engine = nil; self.source = source }

    public func observe(ids: Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError> {
        return Signal { subscriber in
            self.binding &+= 1
            let binding = self.binding
            guard !ids.isEmpty, ids.count <= 616 else {
                self.cache.retain([])
                subscriber.putNext([:]); subscriber.putCompletion(); return EmptyDisposable
            }
            self.cache.retain(ids)
            let signal: Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError>
            if let engine = self.engine {
                signal = exteralessFeedProjectionUpdates(engine: engine, ids: ids, queue: self.queue, cache: self.cache, current: { self.binding == binding })
            } else if let source = self.source { signal = source(ids) }
            else { signal = .single([:]) }
            let observed = signal |> deliverOn(self.queue) |> filter { _ in self.binding == binding }
            if self.engine != nil { return observed.start(next: subscriber.putNext, completed: subscriber.putCompletion) }
            return (observed |> map { self.cache.adopt($0, retaining: ids) }).start(next: subscriber.putNext, completed: subscriber.putCompletion)
        } |> runOn(self.queue)
    }

    public func clear() {
        self.queue.async {
            self.binding &+= 1
            self.cache.generation &+= 1
            self.cache.retain([])
        }
    }
}

private func exteralessFeedAssociatedIds(_ message: Message) -> Set<MessageId> {
    Set(message.associatedMessageIds + message.associatedMessages.map { $0.0 } + message.attributes.flatMap(\.associatedMessageIds))
        .filter { $0.namespace == Namespaces.Message.Cloud && $0.peerId.namespace != Namespaces.Peer.SecretChat }
}

private func exteralessFeedPeerIds(_ messages: [Message]) -> Set<PeerId> {
    var ids = Set<PeerId>()
    for message in messages {
        ids.insert(message.id.peerId)
        ids.formUnion(message.peers.map { $0.0 })
        ids.formUnion(message.attributes.flatMap(\.associatedPeerIds))
        ids.formUnion(message.media.flatMap(\.peerIds))
        if let author = message.author { ids.insert(author.id) }
        if let author = message.forwardInfo?.author { ids.insert(author.id) }
        if let source = message.forwardInfo?.source { ids.insert(source.id) }
        if let id = message.forwardInfo?.sourceMessageId { ids.insert(id.peerId) }
    }
    return ids
}

private func exteralessFeedExtraKeys(_ messages: [Message]) -> Set<PostboxViewKey> {
    var keys = Set<PostboxViewKey>()
    for message in messages {
        if let threadId = message.threadId { keys.insert(.messageHistoryThreadInfo(peerId: message.id.peerId, threadId: threadId)) }
        for id in Set(message.associatedStories.keys).union(message.attributes.flatMap(\.associatedStoryIds)).union(message.media.flatMap(\.storyIds)) {
            keys.insert(.story(id: id))
        }
    }
    return keys
}

private func exteralessFeedReadProjection(transaction: Transaction, id: MessageId) -> ExteralessFeedMessageProjection? {
    guard id.namespace == Namespaces.Message.Cloud, id.peerId.namespace == Namespaces.Peer.CloudChannel,
          let message = transaction.getMessage(id) else { return nil }
    // getMessage invokes the native full renderMessage path: current peers, author/forward,
    // associated reply messages/media, thread info and stories are reconstructed together.
    let peer = transaction.getPeer(id.peerId).map(EnginePeer.init)
    let group = transaction.getPeerChatListIndex(id.peerId).map { EngineChatList.Group($0.0) }
    return ExteralessFeedMessageProjection(message: EngineMessage(message), peer: peer, group: group)
}

private func exteralessFeedUnavailableProjections(_ messages: [MessageId: Message]) -> [MessageId: ExteralessFeedMessageProjection] {
    messages.mapValues { ExteralessFeedMessageProjection(message: EngineMessage($0), peer: nil, group: nil) }
}

/// Fresh local authorization snapshot for a user action. No network request or read receipt.
public func exteralessFeedFreshMessages(engine: TelegramEngine, ids: Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError> {
    guard !ids.isEmpty, ids.count <= 616 else { return .single([:]) }
    return engine.account.postbox.transaction { transaction in
        var result: [MessageId: ExteralessFeedMessageProjection] = [:]
        for id in ids { result[id] = exteralessFeedReadProjection(transaction: transaction, id: id) }
        return result
    }
}

/// Bounded retained-window observation. MessagesView alone omits updatedPeers and associated
/// reply changes, so explicitly observe those dependencies and re-render affected IDs through
/// one native transaction. Unchanged IDs keep their render token and native media node.
public func exteralessFeedMessageProjections(engine: TelegramEngine, ids: Set<EngineMessage.Id>) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError> {
    ExteralessFeedProjectionSession(engine: engine).observe(ids: ids)
}

private func exteralessFeedProjectionUpdates(engine: TelegramEngine, ids: Set<EngineMessage.Id>, queue: Queue, cache: ExteralessFeedProjectionCache, current: @escaping () -> Bool) -> Signal<[EngineMessage.Id: ExteralessFeedMessageProjection], NoError> {
    guard !ids.isEmpty, ids.count <= 616 else { return .single([:]) }
    return Signal { subscriber in
        let rootKey: PostboxViewKey = .messages(ids)
        return (engine.account.postbox.combinedView(keys: [rootKey]) |> deliverOn(queue)
        |> filter { _ in current() }
        |> mapToSignal { roots -> Signal<[MessageId: ExteralessFeedMessageProjection], NoError> in
            let rootMessages = (roots.views[rootKey] as? MessagesView)?.messages ?? [:]
            let relatedIds = rootMessages.values.reduce(into: Set<MessageId>()) { $0.formUnion(exteralessFeedAssociatedIds($1)) }
            // Native renderMessage populates one level of associated messages. Bound that same
            // level globally; malformed excessive dependency graphs fail closed for actions.
            guard relatedIds.count <= 1232 else { return .single(exteralessFeedUnavailableProjections(rootMessages)) }
            let relatedKey: PostboxViewKey = .messages(relatedIds)
            return engine.account.postbox.combinedView(keys: [relatedKey]) |> deliverOn(queue)
            |> filter { _ in current() }
            |> mapToSignal { relatedView -> Signal<[MessageId: ExteralessFeedMessageProjection], NoError> in
                let related = (relatedView.views[relatedKey] as? MessagesView)?.messages ?? [:]
                let allMessages = Array(rootMessages.values) + Array(related.values)
                let peerIds = exteralessFeedPeerIds(allMessages)
                let extraKeys = exteralessFeedExtraKeys(allMessages)
                guard peerIds.count <= 4096, extraKeys.count <= 1232 else { return .single(exteralessFeedUnavailableProjections(rootMessages)) }
                let keys = peerIds.map { PostboxViewKey.basicPeer($0) } + Array(extraKeys)
                return engine.account.postbox.combinedView(keys: keys) |> deliverOn(queue)
                |> filter { _ in current() }
                |> mapToSignal { views -> Signal<[MessageId: ExteralessFeedMessageProjection], NoError> in
                    cache.generation &+= 1
                    let generation = cache.generation
                    var dependencies: [MessageId: ExteralessFeedProjectionDependencies] = [:]
                    var changed = Set<MessageId>()
                    for (id, message) in rootMessages {
                        var associated: [MessageId: Message] = [:]
                        for associatedId in exteralessFeedAssociatedIds(message) { associated[associatedId] = related[associatedId] }
                        let localMessages = [message] + Array(associated.values)
                        var peers: [PeerId: BasicPeerView] = [:]
                        for peerId in exteralessFeedPeerIds(localMessages) {
                            peers[peerId] = views.views[.basicPeer(peerId)] as? BasicPeerView
                        }
                        let localExtras = exteralessFeedExtraKeys(localMessages)
                        var extra: [PostboxViewKey: PostboxView] = [:]
                        for key in localExtras { extra[key] = views.views[key] }
                        let input = ExteralessFeedProjectionDependencies(message: message, associated: associated, peers: peers, extra: extra)
                        dependencies[id] = input
                        if cache.dependencies[id]?.matches(input) != true { changed.insert(id) }
                    }
                    return exteralessFeedFreshMessages(engine: engine, ids: changed) |> deliverOn(queue)
                    |> filter { _ in current() && cache.generation == generation }
                    |> map { fresh in
                        var result = cache.projections.filter { rootMessages[$0.key] != nil }
                        for id in changed { result[id] = fresh[id] }
                        cache.dependencies = dependencies
                        return cache.adopt(result, retaining: ids)
                    }
                }
            }
        }).start(next: subscriber.putNext, completed: subscriber.putCompletion)
    }
}
