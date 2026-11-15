import AccountContext
import AvatarNode
import DirectMediaImageCache
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

func clientHarnessAvatarPeer(_ id: Int64, forum: Bool = false, photo: Bool = true) -> EnginePeer {
    let representations = photo ? [ClientHarnessLocalImages.representation(id)] : []
    if forum {
        return .channel(TelegramChannel(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(id)),
            accessHash: .personal(1), title: "AB", username: nil, photo: representations, creationDate: 0, version: 0,
            participationStatus: .member, info: .group(TelegramChannelGroupInfo(flags: [])), flags: [.isForum],
            restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [],
            storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
            sendPaidMessageStars: nil, linkedMonoforumId: nil))
    }
    return .user(TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)),
        accessHash: .personal(1), firstName: "A", lastName: "B", username: nil, phone: nil, photo: representations,
        botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil))
}

/// Actual DirectMediaImageCache over complete local MediaBox PNGs. Only delivery
/// scheduling is controllable, as in the AF native fixtures; no bitmap is painted.
final class ClientHarnessAvatarCache: AvatarNodeImageCache {
    let native: DirectMediaImageCache
    var delivery: ClientHarnessAvatarDelivery?
    var delayed = false
    private(set) var requests: [[String: Any]] = []

    init(context: AccountContext) { self.native = DirectMediaImageCache(account: context.account) }

    @MainActor
    func warm(_ id: Int64, size: Int) async throws -> UIImage {
        let peer = clientHarnessAvatarPeer(id)
        guard let reference = PeerReference(peer), let result = self.native.getAvatarImage(peer: reference,
            resource: .avatar(peer: reference, resource: ClientHarnessLocalImages.resource(id)),
            immediateThumbnail: nil, size: size, synchronous: true) else {
            throw ClientHarnessFailure(description: "real Avatar cache refused the local PNG")
        }
        if result.image == nil, let signal = result.loadSignal {
            _ = try await clientHarnessFirst(signal |> filter { $0 != nil }, name: "DirectMediaImageCache local decode")
        }
        guard let hit = self.native.getAvatarImage(peer: reference,
            resource: .avatar(peer: reference, resource: ClientHarnessLocalImages.resource(id)),
            immediateThumbnail: nil, size: size, synchronous: true), let image = hit.image, hit.loadSignal == nil else {
            throw ClientHarnessFailure(description: "Avatar cache did not become a genuine synchronous hit")
        }
        return image
    }

    func avatarImage(peer: PeerReference, resource: MediaResourceReference, immediateThumbnail: Data?, size: Int,
        synchronous: Bool) -> (image: UIImage?, loadSignal: Signal<UIImage?, NoError>?)? {
        precondition(Thread.isMainThread)
        guard let local = resource.resource as? LocalFileMediaResource,
              [ClientHarnessLocalImages.redId, ClientHarnessLocalImages.greenId].contains(local.fileId),
              let hit = self.native.getAvatarImage(peer: peer, resource: resource, immediateThumbnail: nil, size: size, synchronous: true),
              let image = hit.image, hit.loadSignal == nil else {
            fatalError("client-ui-harness: Avatar cache accepts prewarmed owned PNG hits only")
        }
        self.requests.append(["resource": local.id.stringRepresentation, "size": size, "nativeCacheHit": true, "delayed": self.delayed])
        return (self.delayed ? nil : image, self.delivery?.signal())
    }
}

final class ClientHarnessAvatarDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriber: Subscriber<UIImage?, NoError>?
    private var starts = 0
    private var cancellations = 0

    func signal() -> Signal<UIImage?, NoError> {
        Signal { subscriber in
            self.lock.lock(); self.starts += 1; self.subscriber = subscriber; self.lock.unlock()
            return ActionDisposable {
                self.lock.lock(); self.cancellations += 1; self.lock.unlock()
            }
        }
    }

    /// Queue a real subscriber emission before the main-thread semantic reset.
    /// Only the background handoff is waited for (<=1s); the main delivery stays queued.
    func enqueue(_ image: UIImage) throws {
        self.lock.lock(); let subscriber = self.subscriber; self.lock.unlock()
        try clientHarnessRequire(subscriber != nil, "Avatar delivery has no actual subscription")
        let queued = DispatchSemaphore(value: 0)
        Queue.concurrentDefaultQueue().async { subscriber?.putNext(image); queued.signal() }
        try clientHarnessRequire(queued.wait(timeout: .now() + 1) == .success, "Avatar delivery handoff exceeded 1s")
    }

    var counts: [String: Int] {
        self.lock.lock(); defer { self.lock.unlock() }
        return ["starts": self.starts, "cancellations": self.cancellations]
    }
}
