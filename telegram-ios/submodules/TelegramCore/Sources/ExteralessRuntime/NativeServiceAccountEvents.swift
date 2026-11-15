import Foundation
import Postbox
import SwiftSignalKit

public enum NativeServiceCoreEvent {
    case messages(arguments: [ExteralessTLValue], peers: [ExteralessTLValue])
    case fileLoaded(key: String, path: String)
    case fileLoadFailed(key: String, reason: Int32)
    /// A critical event could not be represented. Consumers retire subscriptions
    /// rather than pretending an empty payload or silently maintaining a gapped feed.
    case gap(String)
}

/// One explicit native account lifetime. Old in-flight fetches retain this epoch,
/// not a mutable account-id lookup. close() removes it even if a fetch retains it.
public final class NativeServiceAccountEventSource: @unchecked Sendable {
    public let recordId: Int64
    public let accountUserId: Int64
    fileprivate let observesMessages: Bool
    fileprivate let observesFiles: Bool
    fileprivate let postboxIdentity: ObjectIdentifier
    fileprivate let mediaBoxIdentity: ObjectIdentifier
    private let lock = NSLock()
    private var active = true
    private var completedReads: [UUID: MetaDisposable] = [:]
    private let pipe = ValuePipe<NativeServiceCoreEvent>()

    public init(account: Account, messages: Bool = true, files: Bool = true) {
        self.recordId = account.id.int64
        self.accountUserId = account.peerId.id._internalGetInt64Value()
        self.observesMessages = messages
        self.observesFiles = files
        self.postboxIdentity = ObjectIdentifier(account.postbox)
        self.mediaBoxIdentity = ObjectIdentifier(account.postbox.mediaBox)
        NativeServiceEventSources.shared.add(self)
    }
    public var signal: Signal<NativeServiceCoreEvent, NoError> { pipe.signal() }
    fileprivate func emit(_ event: NativeServiceCoreEvent) {
        lock.lock()
        let active = self.active
        lock.unlock()
        if active { pipe.putNext(event) }
    }
    public func close() {
        lock.lock()
        active = false
        let reads = Array(completedReads.values)
        completedReads.removeAll()
        lock.unlock()
        for read in reads { read.dispose() }
        NativeServiceEventSources.shared.remove(self)
    }
    fileprivate func completedFile(mediaBox: MediaBox, reference: MediaResourceReference, key: String) {
        let id = UUID()
        let disposable = MetaDisposable()
        lock.lock()
        guard active, completedReads.count < 128 else {
            lock.unlock()
            emit(.gap("FILE_COMPLETION_READ_BUDGET"))
            return
        }
        completedReads[id] = disposable
        lock.unlock()
        disposable.set((mediaBox.resourceData(reference.resource) |> take(1)
        |> timeout(2.0, queue: Queue.concurrentDefaultQueue(), alternate: .complete())).start(next: { [weak self] data in
            guard let self else { return }
            if data.complete { self.emit(.fileLoaded(key: key, path: data.path)) }
            self.finishRead(id)
        }, completed: { [weak self] in
            if self?.finishRead(id) == true { self?.emit(.gap("FILE_COMPLETION_UNAVAILABLE")) }
        }))
    }
    @discardableResult private func finishRead(_ id: UUID) -> Bool {
        lock.lock()
        let value = completedReads.removeValue(forKey: id)
        lock.unlock()
        value?.dispose()
        return value != nil
    }
    deinit {
        for read in completedReads.values { read.dispose() }
        NativeServiceEventSources.shared.remove(self)
    }
}

private final class NativeServiceEventSources: @unchecked Sendable {
    static let shared = NativeServiceEventSources()
    private final class WeakSource {
        weak var value: NativeServiceAccountEventSource?
        init(_ value: NativeServiceAccountEventSource) { self.value = value }
    }
    private let lock = NSLock()
    private var sources: [ObjectIdentifier: WeakSource] = [:]
    func add(_ source: NativeServiceAccountEventSource) {
        lock.lock(); defer { lock.unlock() }
        sources[ObjectIdentifier(source)] = WeakSource(source)
    }
    func remove(_ source: NativeServiceAccountEventSource) {
        lock.lock(); defer { lock.unlock() }
        sources.removeValue(forKey: ObjectIdentifier(source))
    }
    func forPostbox(_ postbox: Postbox) -> [NativeServiceAccountEventSource] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.compactMap(\.value).filter { $0.observesMessages && $0.postboxIdentity == ObjectIdentifier(postbox) }
    }
    func forMediaBox(_ mediaBox: MediaBox) -> [NativeServiceAccountEventSource] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.compactMap(\.value).filter { $0.observesFiles && $0.mediaBoxIdentity == ObjectIdentifier(mediaBox) }
    }
}

/// Insertion site: AccountStateManager.processEvents' existing transaction, AFTER
/// replay has committed, BEFORE messagesForNotification filters mute/read state.
/// Callers pass the real applied ids; this function does not poll help.test or pts.
func nativeServicePublishCommittedMessages(postbox: Postbox, transaction: Transaction,
                                                  messageIds: [EngineMessage.Id], scheduled: Bool = false) {
    let sources = NativeServiceEventSources.shared.forPostbox(postbox)
    guard !sources.isEmpty, !messageIds.isEmpty else { return }
    for source in sources {
        var batch: [ExteralessTLValue] = []
        var headers: [PeerId: ExteralessTLValue] = [:]
        var dialog: Int64?
        var batchScheduled = scheduled
        var byteCount = 0
        func flush() {
            guard let id = dialog, !batch.isEmpty else { return }
            // ChatActivity.MODE_DEFAULT is 0; this source is ordinary applied
            // messages, not Android quick replies. No transport pts is invented.
            source.emit(.messages(arguments: [.integer(id), .array(batch), .bool(batchScheduled), .integer(0)], peers: Array(headers.values)))
            batch.removeAll(keepingCapacity: true)
            headers.removeAll(keepingCapacity: true)
            byteCount = 0
        }
        for id in messageIds {
            guard id.namespace == Namespaces.Message.Cloud || id.namespace == Namespaces.Message.Local || Namespaces.Message.allScheduled.contains(id.namespace) else { continue }
            guard let message = transaction.getMessage(id) else { continue }
            // This portable family explicitly covers cloud peers. Secret-chat /
            // community dialog encodings require their own SDK model, not fake ids.
            guard let peer = nativeServicePeerReference(message.id.peerId) else { continue }
            do {
                let value = try nativeServiceMessageValue(message, accountUserId: source.accountUserId, transaction: transaction)
                let nextDialog = peer.kind == .user ? peer.id : -peer.id
                let nextScheduled = scheduled || Namespaces.Message.allScheduled.contains(id.namespace)
                let size = try value.jsonString().utf8.count
                guard size <= 262_144 else { source.emit(.gap("MESSAGE_EVENT_TOO_LARGE")); continue }
                if dialog != nextDialog || batchScheduled != nextScheduled || batch.count >= 16 || byteCount + size > 524_288 { flush() }
                dialog = nextDialog
                batchScheduled = nextScheduled
                batch.append(value)
                byteCount += size
                if let author = message.author {
                    headers[author.id] = nativeServicePeerHeader(EnginePeer(author), accountUserId: source.accountUserId)
                }
                if let peer = message.peers[message.id.peerId] {
                    headers[peer.id] = nativeServicePeerHeader(EnginePeer(peer), accountUserId: source.accountUserId)
                }
            } catch { source.emit(.gap("MESSAGE_EVENT_PROJECTION_FAILED")) }
        }
        flush()
    }
}

/// Called from the enqueue Signal's post-transaction stage, so local outgoing
/// events observe committed records too. Empty/uninstalled paths do no extra read.
func nativeServicePublishEnqueuedMessages(account: Account, messageIds: [EngineMessage.Id?]) -> Signal<[EngineMessage.Id?], NoError> {
    guard !NativeServiceEventSources.shared.forPostbox(account.postbox).isEmpty else { return .single(messageIds) }
    let ids = messageIds.compactMap { $0 }
    guard !ids.isEmpty else { return .single(messageIds) }
    return account.postbox.transaction { transaction -> [EngineMessage.Id?] in
        nativeServicePublishCommittedMessages(postbox: account.postbox, transaction: transaction, messageIds: ids)
        return messageIds
    }
}

/// Insertion site: the real full-range/ranged fetchedMediaResource implementation.
/// The original signal is subscribed once and passed through without changing its
/// timing/result. Successful RANGE fetches are not reported as completed files.
func nativeServiceTrackMediaFetch(mediaBox: MediaBox, reference: MediaResourceReference,
                                         signal: Signal<FetchResourceSourceType, FetchResourceError>) -> Signal<FetchResourceSourceType, FetchResourceError> {
    return Signal { subscriber in
        let sources = NativeServiceEventSources.shared.forMediaBox(mediaBox)
        guard !sources.isEmpty else { return signal.start(next: subscriber.putNext, error: subscriber.putError, completed: subscriber.putCompletion) }
        let key = reference.resource.id.stringRepresentation
        return signal.start(next: subscriber.putNext, error: { error in
            // FileLoadOperation.onFail(..., 0) is its generic failure reason. A
            // disposed refcounted native subscriber is NOT a global cancellation.
            for source in sources { source.emit(.fileLoadFailed(key: key, reason: 0)) }
            subscriber.putError(error)
        }, completed: {
            // One cache read of the actual completed file, no new fetch or polling.
            for source in sources { source.completedFile(mediaBox: mediaBox, reference: reference, key: key) }
            subscriber.putCompletion()
        })
    }
}
