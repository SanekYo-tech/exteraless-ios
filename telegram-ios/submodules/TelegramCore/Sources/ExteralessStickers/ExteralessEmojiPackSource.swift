import ExteralessCore
import Foundation
import SwiftSignalKit

private func emojiMetadataPeer(engine: TelegramEngine) -> Signal<EnginePeer, EmojiPackError> {
    guard StickerPolicy().downloadEmojiPacks else { return .fail(.downloadsDisabled) }
    return engine.peers.resolvePeerByName(name: EmojiCatalog.source, referrer: nil, ageLimit: 0)
    |> castError(EmojiPackError.self)
    |> mapToSignal { result -> Signal<EnginePeer, EmojiPackError> in
        guard case let .result(peer) = result else { return .complete() }
        guard let peer, peer.id.namespace == Namespaces.Peer.CloudChannel,
              peer.id.id._internalGetInt64Value() == EmojiCatalog.channelId else { return .fail(.sourceUnavailable) }
        return .single(peer)
    }
    |> take(1)
    |> timeout(20, queue: .concurrentDefaultQueue(), alternate: .fail(.sourceUnavailable))
}

/// Resolves the original public metadata channel and searches exactly #emojiv2.
/// No join/subscription or raw UI-layer Postbox/TelegramApi access is involved.
public func exteralessLoadEmojiCatalog(engine: TelegramEngine) -> Signal<EmojiCatalog, EmojiPackError> {
    return emojiMetadataPeer(engine: engine)
    |> mapToSignal { peer -> Signal<EmojiCatalog, EmojiPackError> in
        return engine.messages.searchMessages(location: .peer(peerId: peer.id, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: "#emojiv2", state: nil, limit: 10)
        |> take(1)
        |> castError(EmojiPackError.self)
        |> mapToSignal { result, _ -> Signal<EmojiCatalog, EmojiPackError> in
            guard StickerPolicy().downloadEmojiPacks else { return .fail(.downloadsDisabled) }
            guard let message = result.messages.filter({ $0.id.peerId == peer.id && $0.text.hasPrefix("#emojiv2") }).max(by: { $0.id.id < $1.id.id }) else { return .fail(.sourceUnavailable) }
            do { return .single(try EmojiCatalog.parse(message: message.text)) }
            catch { return .fail(.invalidCatalog) }
        }
    }
    |> timeout(25, queue: .concurrentDefaultQueue(), alternate: .fail(.sourceUnavailable))
}

public func exteralessEmojiFontDocument(engine: TelegramEngine, entry: EmojiCatalogEntry) -> Signal<FileMediaReference, EmojiPackError> {
    do { try entry.validate() } catch { return .fail(.invalidCatalog) }
    return emojiMetadataPeer(engine: engine)
    |> mapToSignal { peer -> Signal<FileMediaReference, EmojiPackError> in
        let id = EngineMessage.Id(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: entry.file)
        return engine.messages.getMessagesLoadIfNecessary([id], strategy: .cloud(skipLocal: true))
        |> mapError { _ in EmojiPackError.sourceUnavailable }
        |> mapToSignal { result -> Signal<FileMediaReference, EmojiPackError> in
            guard case let .result(messages) = result else { return .complete() }
            guard StickerPolicy().downloadEmojiPacks else { return .fail(.downloadsDisabled) }
            guard let message = messages.first(where: { $0.id == id }),
                  let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first,
                  let name = file.fileName, ["ttf", "otf"].contains((name as NSString).pathExtension.lowercased()),
                  let size = file.size, size > 0, size <= Int64(EmojiPackLimits.fontBytes) else { return .fail(.incompatibleFont) }
            return .single(.message(message: MessageReference(message), media: file))
        }
        |> take(1)
    }
    |> timeout(25, queue: .concurrentDefaultQueue(), alternate: .fail(.sourceUnavailable))
}

/// Uses Telegram's resource fetch/reference-refresh API. Disposing the returned
/// signal cancels its fetch and observation; a deadline bounds missing data.
public func exteralessStickerResourceData(engine: TelegramEngine, file: FileMediaReference, maximumBytes: Int) -> Signal<Data, EmojiPackError> {
    guard let declared = file.media.size, declared > 0, declared <= Int64(maximumBytes) else { return .fail(.tooLarge) }
    return Signal { subscriber in
        let disposed = Atomic(value: false)
        let disposables = DisposableSet()
        disposables.add(engine.resources.fetch(reference: file.resourceReference(file.media.resource), userLocation: .other, userContentType: .other).start(error: { _ in subscriber.putError(.network) }))
        disposables.add((engine.resources.data(resource: EngineMediaResource(file.media.resource))
        |> filter { $0.isComplete }
        |> take(1)
        |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { resource in
            guard !disposed.with({ $0 }) else { return }
            do {
                let data = try EmojiFontInspection.readFile(URL(fileURLWithPath: resource.path), maximumBytes: maximumBytes)
                guard data.count == Int(declared), !disposed.with({ $0 }) else { throw EmojiPackError.invalidMedia }
                subscriber.putNext(data)
                subscriber.putCompletion()
            } catch { subscriber.putError((error as? EmojiPackError) ?? .storage) }
        }))
        return ActionDisposable { _ = disposed.swap(true); disposables.dispose() }
    }
    |> timeout(25, queue: .concurrentDefaultQueue(), alternate: .fail(.network))
}
