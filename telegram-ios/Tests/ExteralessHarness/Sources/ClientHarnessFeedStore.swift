import AccountContext
import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// Writes only the six messages supplied by the native offline fixture and one
/// same-number Local-namespace exclusion sentinel into our disposable Postbox.
/// Projection reads use the shipping native transaction/dependency implementation.
@MainActor
final class ClientHarnessFeedStore {
    let context: AccountContext
    let permit: ExteralessFeedOfflineFixture
    private(set) var ids: Set<EngineMessage.Id> = []
    private(set) var shadowId: EngineMessage.Id?

    init(context: AccountContext) throws {
        guard let permit = ExteralessFeedOfflineFixture(engine: context.engine) else {
            throw ClientHarnessFailure(description: "native Feed offline permit rejected account/transport")
        }
        self.context = context
        self.permit = permit
    }

    func seed(edited: Bool) async throws -> [EngineMessage.Id: ExteralessFeedMessageProjection] {
        // The actual smoke renderer already populated this local media resource.
        // Read those bytes, rather than making a second image/canvas for the test.
        let resource = LocalFileMediaResource(fileId: 9_100_001)
        let data = try await clientHarnessFirst(self.context.engine.resources.data(resource: EngineMediaResource(resource))
            |> filter { $0.complete }, name: "Feed fixture local PNG")
        let png = try Data(contentsOf: URL(fileURLWithPath: data.path))
        let messages = self.permit.messages(png: png, edited: edited)
        try clientHarnessRequire(messages.count == 6, "native Feed fixture must supply six messages")
        self.ids = Set(messages.map(\.id))
        guard let reference = messages.first(where: { $0.groupingKey != nil }) else {
            throw ClientHarnessFailure(description: "native Feed fixture has no album")
        }
        let shadow = EngineMessage.Id(peerId: reference.id.peerId, namespace: Namespaces.Message.Local, id: reference.id.id)
        self.shadowId = shadow
        _ = try await clientHarnessFirst(self.context.account.postbox.transaction { transaction -> Bool in
            var peers: [PeerId: Peer] = [:]
            for message in messages { for (id, peer) in message.peers { peers[id] = peer } }
            updatePeersCustom(transaction: transaction, peers: Array(peers.values), update: { _, value in value })
            for id in peers.keys {
                transaction.updatePeerChatListInclusion(id, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            }
            let stores = messages.map { message -> StoreMessage in
                let raw = message._asMessage()
                return StoreMessage(id: .Id(raw.id), customStableId: raw.stableId, globallyUniqueId: nil,
                    groupingKey: raw.groupingKey, threadId: raw.threadId, timestamp: raw.timestamp,
                    flags: [.Incoming], tags: raw.tags, globalTags: raw.globalTags, localTags: raw.localTags,
                    forwardInfo: raw.forwardInfo.map(StoreMessageForwardInfo.init), authorId: raw.author?.id,
                    text: raw.text, attributes: raw.attributes, media: raw.media)
            }
            _ = transaction.addMessages(stores, location: .Random)
            _ = transaction.addMessages([StoreMessage(id: .Id(shadow), customStableId: nil, globallyUniqueId: nil,
                groupingKey: nil, threadId: nil, timestamp: reference.timestamp, flags: [.Incoming], tags: [],
                globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
                text: "LOCAL NAMESPACE MUST NOT ENTER FEED", attributes: [], media: [])], location: .Random)
            return true
        }, name: "owned Feed Postbox seed")
        let projected = try await clientHarnessFirst(exteralessFeedFreshMessages(engine: self.context.engine,
            ids: self.ids.union([shadow])), name: "native Feed fresh projection")
        try clientHarnessRequire(projected.count == 6 && projected[shadow] == nil, "Feed admitted the wrong message namespace")
        try clientHarnessRequire(projected.values.allSatisfy { $0.isEligible && $0.peer != nil && $0.group == .root }, "Feed projection lost current membership/peers")
        let editedMessage = projected.values.first { $0.message.id.id == 2 }
        try clientHarnessRequire(editedMessage?.message.text.contains(edited ? "edited" : "spoiler") == true, "native projection did not read the fixture revision")
        return projected
    }

    static func key(_ id: EngineMessage.Id) -> String { "\(id.peerId.toInt64()):\(id.namespace):\(id.id)" }
}
