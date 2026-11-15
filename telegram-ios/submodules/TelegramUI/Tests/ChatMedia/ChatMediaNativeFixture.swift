import AccountContext
import ExteralessCore
import Foundation
import GalleryUI
import SwiftSignalKit
import UIKit
import XCTest
@testable import Postbox
@testable import TelegramCore
@testable import TelegramUI

/// Two 2px native resources and one twenty-second video. No Account, Network,
/// TelegramEngine, plugin, real image file, pasteboard, Photos or upload is used.
final class ChatMediaNativeFixture: @unchecked Sendable {
    let queue = Queue(name: "CMC.NativeFixture")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmc-" + UUID().uuidString)
    let accountId: Int64 = 9400
    let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(9401))
    var id: MessageId { MessageId(peerId: self.peer, namespace: Namespaces.Message.Cloud, id: 1) }
    let imageA = ChatMediaNativeFixture.image(11, resource: 101)
    let imageB = ChatMediaNativeFixture.image(12, resource: 102)
    let video = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 13), partialReference: nil, resource: LocalFileMediaResource(fileId: 103), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: 4, attributes: [.Video(duration: 20, size: PixelDimensions(width: 2, height: 2), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)], alternativeRepresentations: [])
    private var valueBox: SqliteValueBox?
    private(set) var postbox: Postbox!

    static func image(_ id: Int64, resource: Int64) -> TelegramMediaImage {
        TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: id), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 2, height: 2), resource: LocalFileMediaResource(fileId: resource), progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }

    init() throws {
        initializeAccountManagement()
        queue.sync {
            self.valueBox = SqliteValueBox(basePath: self.root.path + "/db", queue: self.queue, isTemporary: true, isReadOnly: false, useCaches: true, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true)
        }
        postbox = Postbox(queue: queue, basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration, valueBox: try XCTUnwrap(valueBox), timestampForAbsoluteTimeBasedOperations: 1000, isMainProcess: false, isTemporary: true, tempDir: nil, useCaches: true)
        postbox.mediaBox.fetchResource = { _, _, _ in XCTFail("CMC fixture attempted network/media fetch"); return .fail(.generic) }
        try transaction { transaction in
            let user = TelegramUser(id: self.peer, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
            transaction.updatePeersInternal([user], update: { _, value in value })
            transaction.updatePeerCachedData(peerIds: [self.peer]) { _, _ in CachedUserData() }
            _ = transaction.addMessages([self.stored()], location: .Random)
        }
    }

    func stored(id: Int32 = 1, text: String = "fixture", media: [Media] = [], attributes: [MessageAttribute] = [], thread: Int64? = nil) -> StoreMessage {
        StoreMessage(id: MessageId(peerId: self.peer, namespace: Namespaces.Message.Cloud, id: id), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: thread, timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: self.peer, text: text, attributes: attributes, media: media)
    }

    func rich(_ media: [Media]) -> RichTextMessageAttribute {
        let caption = InstantPageCaption(text: .plain("caption"), credit: .empty)
        let blocks: [InstantPageBlock] = media.compactMap { medium in
            guard let id = medium.id else { return nil }
            if medium is TelegramMediaFile { return .video(id: id, caption: caption, autoplay: false, loop: false, spoiler: false) }
            return .image(id: id, caption: caption, url: nil, webpageId: nil, spoiler: false)
        }
        return RichTextMessageAttribute(instantPage: InstantPage(blocks: [.paragraph(.plain("rich body"))] + blocks, media: Dictionary(uniqueKeysWithValues: media.compactMap { medium in medium.id.map { ($0, EngineMedia(medium)) } }), isComplete: true, rtl: false, url: "", views: nil), fullInstantPage: nil)
    }

    func setRich(_ media: [Media]) throws {
        try self.transaction { $0.updateMessage(self.id, update: { _ in .update(self.stored(text: "", attributes: [self.rich(media)])) }) }
    }

    func protect(_ flags: CachedUserFlags) throws {
        try self.transaction { $0.updatePeerCachedData(peerIds: [self.peer]) { _, _ in CachedUserData().withUpdatedFlags(flags) } }
    }

    func message() throws -> EngineMessage { try self.transaction { EngineMessage($0.getMessage(self.id)!) } }

    @discardableResult func transaction<T>(_ body: @escaping (Transaction) -> T) throws -> T {
        let completed = DispatchSemaphore(value: 0)
        var value: T?
        let disposable = self.postbox.transaction(body).start(next: { value = $0; completed.signal() })
        defer { disposable.dispose() }
        guard completed.wait(timeout: .now() + 1) == .success else { throw FixtureError.timeout }
        return try XCTUnwrap(value)
    }

    var source: ExteralessChatExportSource {
        ExteralessChatExportSource(read: { ids, lease in
            do {
                let scopes: [ExteralessAIScope]? = try self.transaction { transaction in
                    let messages = ids.sorted().compactMap { transaction.getMessage($0) }
                    guard messages.count == ids.count else { return nil }
                    let scopes = messages.compactMap { message in
                        exteralessAIResolveScope(transaction: transaction, accountId: self.accountId, capability: .init(messageId: message.id, expectedStableVersion: message.stableVersion, peerId: message.id.peerId, threadId: message.threadId, allowsExternalProcessing: false, allowsCopy: true), contextMessageIds: [], followReplyChain: false, contextLimit: 0, lease: lease)
                    }
                    return scopes.count == ids.count ? scopes : nil
                }
                return .single(scopes)
            } catch { XCTFail("Native read: \(error)"); return .single(nil) }
        }, validate: { scopes in
            do {
                return .single(try self.transaction { transaction in
                    scopes.allSatisfy { scope in
                        guard exteralessAIValidateScope(transaction: transaction, accountId: self.accountId, scope: scope), let previous = scope.source, let current = transaction.getMessage(previous.id) else { return false }
                        return exteralessChatExportSourceEqual(previous, EngineMessage(current))
                    }
                })
            } catch { XCTFail("Native validate: \(error)"); return .single(false) }
        }, observe: { scopes in
            combineLatest(scopes.map { exteralessAIObserveScopeValidity(postbox: self.postbox, accountId: self.accountId, scope: $0) }) |> map { $0.allSatisfy { $0 } }
        })
    }

    @MainActor func access(ids: Set<EngineMessage.Id>? = nil, expected: [EngineMessage]? = nil, permit: ExteralessContentExportPermit? = nil, account: Signal<Bool, NoError> = .single(true), validity: Signal<Bool, NoError> = .single(true), sourceView: UIView? = nil, current: @escaping () -> Bool = { true }, copyAllowed: @escaping () -> Bool = { true }) -> ExteralessChatExportAccess {
        ExteralessChatExportAccess(accountId: self.accountId, ids: ids ?? [self.id], expected: expected, permit: permit, source: self.source, accountIsCurrent: account, presentationValidity: validity, sourceWindow: sourceView?.window, sourceView: sourceView, current: current, copyAllowed: copyAllowed)
    }

    @MainActor func session(_ access: ExteralessChatExportAccess) -> ExteralessSelectionActionSession {
        ExteralessSelectionActionSession(access: access, actions: { _ in .single(ChatAvailableMessageActions(options: [.forward, .externalShare], banAuthor: nil, banAuthors: [], disableDelete: false, isCopyProtected: false, setTag: false, editTags: [])) })
    }

    func close() {
        let ready = DispatchSemaphore(value: 0)
        let disposable = postbox.mediaBox.storageBox.totalSize().start(next: { _ in ready.signal() })
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
        disposable.dispose()
        postbox = nil
        queue.sync { self.valueBox = nil }
        try? FileManager.default.removeItem(at: root)
    }

    enum FixtureError: Error { case timeout }
}

@MainActor final class ChatMediaExportSpy {
    let decode = ValuePipe<UIImage?>()
    let fetch = ValuePipe<URL?>()
    let profile = ValuePipe<(() -> Void)?>()
    var holdFetch = false
    var holdProfile = false
    var references: [AnyMediaReference] = []
    var timestamps: [Double] = []
    var imageDecodes = 0
    var effects = 0
    var notices: [String] = []
    var copyQR: (() -> Void)?
    var openQR: (() -> Void)?
    var confirmProfile: (() -> Void)?
    var cancelPrompt: (() -> Void)?
    var preparedProfile = 0

    var services: ExteralessImageActionServices {
        ExteralessImageActionServices(fetch: { reference in
            self.references.append(reference)
            return self.holdFetch ? self.fetch.signal() : .single(URL(fileURLWithPath: "/synthetic-not-read"))
        }, decodeImage: { _ in self.imageDecodes += 1; return self.decode.signal() }, decodeFrame: { _, time in self.timestamps.append(time); return self.decode.signal() }, scanQR: { _ in "https://fixture.invalid/qr" }, copy: { _, _ in self.effects += 1 }, createSticker: { _, commit in commit { self.effects += 1 } }, qrPrompt: { _, copy, open, cancel in self.copyQR = copy; self.openQR = open; self.cancelPrompt = cancel }, copyText: { _ in self.effects += 1 }, openURL: { _ in self.effects += 1 }, profilePrompt: { confirm, cancel in self.confirmProfile = confirm; self.cancelPrompt = cancel }, prepareProfile: { _ in
            self.preparedProfile += 1
            return self.holdProfile ? self.profile.signal() : .single({ self.effects += 1 })
        }, notice: { self.notices.append($0) })
    }

    func clear() { self.copyQR = nil; self.openQR = nil; self.confirmProfile = nil; self.cancelPrompt = nil }
}
