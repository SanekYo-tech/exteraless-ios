import Foundation
import MtProtoKit
import Postbox
import SwiftSignalKit
internal import TelegramApi

public struct ExteralessTLRequestOrigin: Equatable, Sendable {
    public let rootId: String
    public let pluginIds: [String]
    public init(rootId: String, pluginIds: [String]) throws {
        guard !rootId.isEmpty, rootId.utf8.count <= 128, pluginIds.count <= 32,
              Set(pluginIds).count == pluginIds.count, pluginIds.allSatisfy({ id in
                  guard id.utf8.count >= 2, id.utf8.count <= 32, let first = id.first, first.isASCII, first.isLetter else { return false }
                  return id.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
              }) else {
            throw ExteralessTLError(.malformed, "Invalid TL request ancestry")
        }
        self.rootId = rootId
        self.pluginIds = pluginIds
    }
}

struct TLResolvedRequestOrigin {
    let origin: ExteralessTLRequestOrigin?
    let correlations: [Int64]
}

final class TLRequestOrigins: @unchecked Sendable {
    static let shared = TLRequestOrigins()
    private final class NetworkEntry {
        weak var network: AnyObject?
        var pending: [Int64: ExteralessTLRequestOrigin] = [:]
        var observers: [Int64: Disposable] = [:]
        init(_ network: AnyObject) { self.network = network }
        deinit { for observer in self.observers.values { observer.dispose() } }
    }
    private final class DescriptorEntry {
        weak var network: Network?
        weak var description: FunctionDescription?
        var origin: ExteralessTLRequestOrigin?
        var execution: (@Sendable () -> Bool)?
        init(_ network: Network, _ description: FunctionDescription, origin: ExteralessTLRequestOrigin?, execution: (@Sendable () -> Bool)? = nil) {
            self.network = network; self.description = description; self.origin = origin
            self.execution = execution
        }
    }
    private let lock = NSLock()
    private var networks: [ObjectIdentifier: NetworkEntry] = [:]
    private var descriptions: [ObjectIdentifier: DescriptorEntry] = [:]

    func bind(_ origin: ExteralessTLRequestOrigin, network: Network, description: FunctionDescription) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.descriptions = self.descriptions.filter { $0.value.network != nil && $0.value.description != nil }
        if let entry = self.descriptions[ObjectIdentifier(description)], entry.network === network, entry.description === description {
            entry.origin = origin
        } else {
            self.descriptions[ObjectIdentifier(description)] = DescriptorEntry(network, description, origin: origin)
        }
    }

    func bindExecution(_ execution: @escaping @Sendable () -> Bool, network: Network, description: FunctionDescription) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.descriptions = self.descriptions.filter { $0.value.network != nil && $0.value.description != nil }
        if let entry = self.descriptions[ObjectIdentifier(description)], entry.network === network, entry.description === description {
            entry.execution = execution
        } else {
            self.descriptions[ObjectIdentifier(description)] = DescriptorEntry(network, description, origin: nil, execution: execution)
        }
    }

    func execution(network: Network, description: FunctionDescription) -> (@Sendable () -> Bool)? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.descriptions[ObjectIdentifier(description)], entry.network === network, entry.description === description else { return nil }
        return entry.execution
    }

    func direct(network: Network, description: FunctionDescription) -> ExteralessTLRequestOrigin? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.descriptions[ObjectIdentifier(description)], entry.network === network,
              entry.description === description else { return nil }
        return entry.origin
    }

    func register(network: AnyObject, origin: ExteralessTLRequestOrigin) throws -> Int64 {
        self.lock.lock(); defer { self.lock.unlock() }
        self.networks = self.networks.filter { $0.value.network != nil }
        let entry = self.networks[ObjectIdentifier(network)] ?? NetworkEntry(network)
        guard entry.pending.count < 1024 else { throw ExteralessTLError(.limit, "TL pending origin quota exceeded") }
        var id = Int64.random(in: 1 ... Int64.max)
        while entry.pending[id] != nil { id = Int64.random(in: 1 ... Int64.max) }
        entry.pending[id] = origin
        self.networks[ObjectIdentifier(network)] = entry
        return id
    }

    func pending(network: AnyObject) -> [Int64: ExteralessTLRequestOrigin] {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.networks[ObjectIdentifier(network)], entry.network === network else { return [:] }
        return entry.pending
    }

    func hasPending(network: AnyObject) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.networks[ObjectIdentifier(network)], entry.network === network else { return false }
        return !entry.pending.isEmpty
    }

    func remove(network: AnyObject, correlations: [Int64]) {
        self.lock.lock()
        guard let entry = self.networks[ObjectIdentifier(network)], entry.network === network else { self.lock.unlock(); return }
        var removed: [Disposable] = []
        for id in correlations {
            entry.pending.removeValue(forKey: id)
            if let observer = entry.observers.removeValue(forKey: id) { removed.append(observer) }
        }
        if entry.pending.isEmpty { self.networks.removeValue(forKey: ObjectIdentifier(network)) }
        self.lock.unlock()
        for observer in removed { observer.dispose() }
    }

    func observe(network: AnyObject, correlation: Int64, disposable: Disposable) {
        self.lock.lock()
        guard let entry = self.networks[ObjectIdentifier(network)], entry.network === network,
              entry.pending[correlation] != nil else {
            self.lock.unlock()
            disposable.dispose()
            return
        }
        let previous = entry.observers.updateValue(disposable, forKey: correlation)
        self.lock.unlock()
        previous?.dispose()
    }

    func retire(network: Network) {
        self.lock.lock()
        let removed = self.networks.removeValue(forKey: ObjectIdentifier(network))
        self.descriptions = self.descriptions.filter { $0.value.network != nil && $0.value.description != nil }
        for (key, entry) in Array(self.descriptions) where entry.network === network {
            if entry.execution != nil {
                // A still-retained descriptor must remain denied after account
                // retirement, not turn into the unguarded native default path.
                entry.origin = nil
                entry.execution = { false }
            } else {
                self.descriptions.removeValue(forKey: key)
            }
        }
        self.lock.unlock()
        // Dispose native observations after unlocking; no account/database is pinned
        // past the Account's managed-operations lease.
        withExtendedLifetime(removed) {}
    }
}

func exteralessTLBindRequestOrigin(_ origin: ExteralessTLRequestOrigin?, network: Network, description: FunctionDescription) {
    if let origin { TLRequestOrigins.shared.bind(origin, network: network, description: description) }
}

func exteralessTLBindRequestExecution(network: Network, description: FunctionDescription, permits: @escaping @Sendable () -> Bool) {
    TLRequestOrigins.shared.bindExecution(permits, network: network, description: description)
}

/// Read the predicate under the association lock, evaluate it AFTER unlocking.
/// Missing metadata is the native/non-plugin path, not a captured revoked scope.
func exteralessTLCanExecuteRequest(network: Network, description: FunctionDescription) -> Bool {
    let permits = TLRequestOrigins.shared.execution(network: network, description: description)
    return permits?() ?? true
}

func exteralessTLRegisterEnqueueOrigin(_ origin: ExteralessTLRequestOrigin?, network: Network) throws -> Int64? {
    return try origin.map { try TLRequestOrigins.shared.register(network: network, origin: $0) }
}

func exteralessTLReleaseEnqueueOrigin(network: Network, correlations: [Int64]) {
    TLRequestOrigins.shared.remove(network: network, correlations: correlations)
}

func exteralessTLRetireRequestOrigins(network: Network) {
    TLRequestOrigins.shared.retire(network: network)
}

/// A local Postbox view retires ancestry even if all request-hook subscriptions
/// were disabled before delivery. Failed messages retain it for native retries.
func exteralessTLTrackEnqueueOrigin(network: Network, postbox: Postbox, correlation: Int64, messageId: MessageId) {
    exteralessTLTrackEnqueueOrigin(store: .shared, owner: network, postbox: postbox, correlation: correlation, messageId: messageId)
}

/// The same native tracker accepts an isolated owner/store in loginless fixtures.
/// Production callers use the existing Network-keyed shared registry above.
func exteralessTLTrackEnqueueOrigin(store: TLRequestOrigins, owner: AnyObject, postbox: Postbox, correlation: Int64, messageId: MessageId) {
    let disposable = postbox.messageView(messageId).start(next: { [weak owner] view in
        guard let owner else { return }
        if let message = view.message,
           message.attributes.compactMap({ $0 as? OutgoingMessageInfoAttribute }).first?.correlationId == correlation,
           !message.flags.intersection([.Unsent, .Sending, .Failed]).isEmpty { return }
        store.remove(network: owner, correlations: [correlation])
    })
    store.observe(network: owner, correlation: correlation, disposable: disposable)
}

/// Native completion is retained by commit, separately from the returned Signal's
/// subscriber. Cancelling a bot-authorization wait still cancels the actual source.
func exteralessTLRetainedEnqueue(commit: ExteralessTLEnqueueCommit, native: Signal<[MessageId?], NoError>,
                                 track: @escaping ([MessageId?]) -> Void) -> Signal<[MessageId?], ExteralessTLServiceError> {
    return Signal { subscriber in
        let disposable = native.start(next: { ids in
            var wasClaimed = false
            let deliver = commit.complete { claimed in
                wasClaimed = claimed
                track(ids)
            }
            guard deliver == true else { return }
            guard wasClaimed || ids.allSatisfy({ $0 == nil }) else {
                subscriber.putError(.local("TL_ORIGIN_COMMIT_SCOPE_MISSING"))
                return
            }
            subscriber.putNext(ids)
            subscriber.putCompletion()
        }, completed: {
            if commit.complete(track: { _ in track([]) }) == true {
                subscriber.putError(.local("EMPTY_NATIVE_ENQUEUE"))
            }
        })
        commit.bindCancellation { disposable.dispose() }
        return ActionDisposable { commit.cancelSubscriber() }
    }
}

/// Common path for TL media/text and the legacy text service. Correlations are
/// provisional until the real enqueue transaction claims commit ownership.
public func exteralessTLEnqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage],
                                       origin: ExteralessTLRequestOrigin?,
                                       isCancelled: @escaping @Sendable () -> Bool) -> Signal<[MessageId?], ExteralessTLServiceError> {
    return Signal { subscriber in
        guard !isCancelled() else { subscriber.putError(.local("MEDIA_CANCELLED")); return EmptyDisposable }
        var correlations: [Int64?] = []
        do {
            for _ in messages { correlations.append(try exteralessTLRegisterEnqueueOrigin(origin, network: account.network)) }
        } catch {
            exteralessTLReleaseEnqueueOrigin(network: account.network, correlations: correlations.compactMap { $0 })
            subscriber.putError(.local("TL_ORIGIN_QUOTA_EXCEEDED"))
            return EmptyDisposable
        }
        let reserved = correlations
        let commit = ExteralessTLEnqueueCommit(canCommit: { !isCancelled() }, cancelProvisional: {
            exteralessTLReleaseEnqueueOrigin(network: account.network, correlations: reserved.compactMap { $0 })
        })
        let outgoing = zip(messages, reserved).map { message, correlation in
            correlation.map { message.withUpdatedCorrelationId($0) } ?? message
        }
        let native = enqueueMessagesFromPlugin(account: account, peerId: peerId, messages: outgoing, tlCommit: commit)
        return exteralessTLRetainedEnqueue(commit: commit, native: native, track: { ids in
            for (index, correlation) in reserved.enumerated() {
                guard let correlation else { continue }
                if index < ids.count, let id = ids[index] {
                    exteralessTLTrackEnqueueOrigin(network: account.network, postbox: account.postbox, correlation: correlation, messageId: id)
                } else {
                    exteralessTLReleaseEnqueueOrigin(network: account.network, correlations: [correlation])
                }
            }
        }).start(next: { subscriber.putNext($0) }, error: { subscriber.putError($0) }, completed: { subscriber.putCompletion() })
    }
}

private func tlRandomIds(_ value: ExteralessTLValue) -> [Int64] {
    switch value {
    case let .object(fields):
        var result: [Int64] = []
        if let random = fields["random_id"] {
            if let id = random.integerValue { result.append(id) }
            else if case let .array(ids) = random { result.append(contentsOf: ids.compactMap(\.integerValue)) }
        }
        for (key, child) in fields where key != "random_id" { result.append(contentsOf: tlRandomIds(child)) }
        return result
    case let .array(values): return values.flatMap(tlRandomIds)
    default: return []
    }
}

/// Normal enqueue's random_id and OutgoingMessageInfo.correlationId are real
/// native fields. Resolve before hooks, avoiding the race of binding returned
/// local message ids after PendingMessageManager has already begun its RPC.
func exteralessTLResolveRequestOrigin(network: Network, description: FunctionDescription,
                                      value: ExteralessTLValue, tag: NetworkRequestDependencyTag?) -> Signal<TLResolvedRequestOrigin, MTRpcError> {
    if let direct = TLRequestOrigins.shared.direct(network: network, description: description) {
        return .single(TLResolvedRequestOrigin(origin: direct, correlations: []))
    }
    guard TLRequestOrigins.shared.hasPending(network: network), let account = exteralessTLRegisteredAccount(network) else {
        return .single(TLResolvedRequestOrigin(origin: nil, correlations: []))
    }
    let peer = try? tlPrivacyPeer(value["to_peer"] ?? value["peer"], account: account)
    let randomIds = tlRandomIds(value)
    let explicitId = (tag as? PendingMessageRequestDependencyTag)?.messageId
    guard explicitId != nil || (peer != nil && !randomIds.isEmpty), randomIds.count <= 1000 else {
        return .single(TLResolvedRequestOrigin(origin: nil, correlations: []))
    }
    return account.postbox.transaction { transaction -> TLResolvedRequestOrigin in
        let pending = TLRequestOrigins.shared.pending(network: network)
        var ids: [MessageId] = explicitId.map { [$0] } ?? []
        if let peer { ids.append(contentsOf: randomIds.compactMap { transaction.messageIdForGloballyUniqueMessageId(peerId: peer, id: $0) }) }
        var correlations = Set<Int64>()
        for id in ids {
            if let message = transaction.getMessage(id), let correlation = message.attributes.compactMap({ $0 as? OutgoingMessageInfoAttribute }).first?.correlationId,
               pending[correlation] != nil { correlations.insert(correlation) }
        }
        let orderedCorrelations = correlations.sorted()
        let origins = orderedCorrelations.compactMap { pending[$0] }
        guard let first = origins.first else { return TLResolvedRequestOrigin(origin: nil, correlations: []) }
        let pluginIds = Array(Set(origins.flatMap(\.pluginIds))).sorted()
        let merged = try? ExteralessTLRequestOrigin(rootId: first.rootId, pluginIds: pluginIds)
        return TLResolvedRequestOrigin(origin: merged, correlations: orderedCorrelations)
    } |> castError(MTRpcError.self) |> mapToSignal { result -> Signal<TLResolvedRequestOrigin, MTRpcError> in
        guard result.origin != nil || result.correlations.isEmpty else {
            let error: MTRpcError = MTRpcError(errorCode: -1, errorDescription: "EXTERALESS_TL_ORIGIN_DEPTH_LIMIT")
            return .fail(error)
        }
        return .single(result)
    }
}

/// Exact optional seam for subordinate native requests when the upload/revalidation
/// owner knows the original MessageId. No process-wide ignore flag is involved.
func exteralessTLRequestForMessage<T>(network: Network, postbox: Postbox, messageId: MessageId?,
                                     data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>),
                                     origin: ExteralessTLRequestOrigin? = nil,
                                     isCancelled: @escaping @Sendable () -> Bool = { false }) -> Signal<T, MTRpcError> {
    exteralessTLBindRequestExecution(network: network, description: data.0, permits: { !isCancelled() })
    guard !isCancelled() else {
        let error: MTRpcError = MTRpcError(errorCode: -1, errorDescription: "EXTERALESS_EXECUTION_REVOKED")
        return .fail(error)
    }
    if let origin {
        exteralessTLBindRequestOrigin(origin, network: network, description: data.0)
        return network.request(data)
    }
    guard let messageId, TLRequestOrigins.shared.hasPending(network: network) else { return network.request(data) }
    return postbox.transaction { transaction -> ExteralessTLRequestOrigin? in
        guard let message = transaction.getMessage(messageId), let correlation = message.attributes.compactMap({ $0 as? OutgoingMessageInfoAttribute }).first?.correlationId else { return nil }
        return TLRequestOrigins.shared.pending(network: network)[correlation]
    } |> castError(MTRpcError.self) |> mapToSignal { origin in
        exteralessTLBindRequestOrigin(origin, network: network, description: data.0)
        return network.request(data)
    }
}
