import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

/// Provenance survives the stock text-processing screen. A missing Copy callback
/// is a UI choice, not permission to export. The engine rechecks every message.
// Postbox's ID aliases are immutable integer values but do not declare Sendable.
public struct ExteralessAIProcessingCapability: Equatable, @unchecked Sendable {
    public let messageId: EngineMessage.Id?
    public let expectedStableVersion: UInt32?
    public let peerId: EnginePeer.Id?
    public let threadId: Int64?
    public let allowsExternalProcessing: Bool
    public let allowsCopy: Bool

    public init(messageId: EngineMessage.Id? = nil, expectedStableVersion: UInt32? = nil, peerId: EnginePeer.Id? = nil, threadId: Int64? = nil, allowsExternalProcessing: Bool, allowsCopy: Bool) {
        self.messageId = messageId
        self.expectedStableVersion = expectedStableVersion
        self.peerId = peerId ?? messageId?.peerId
        self.threadId = threadId
        self.allowsExternalProcessing = allowsExternalProcessing
        self.allowsCopy = allowsCopy
    }

    public static let userInput = ExteralessAIProcessingCapability(allowsExternalProcessing: true, allowsCopy: true)
    public static let nativeOnly = ExteralessAIProcessingCapability(allowsExternalProcessing: false, allowsCopy: false)

    public static func message(_ message: EngineMessage, canCopy: Bool) -> ExteralessAIProcessingCapability {
        return ExteralessAIProcessingCapability(messageId: message.id, expectedStableVersion: message.stableVersion, peerId: message.id.peerId, threadId: message.threadId, allowsExternalProcessing: canCopy, allowsCopy: canCopy)
    }
}

/// A source/context snapshot plus a cancellable account-bound lease.
/// Only a successful commit may advance the source version, using the version
/// actually read back from Postbox (never an assumed +1).
public final class ExteralessAIScope: @unchecked Sendable {
    private var sourceValue: EngineMessage?
    public let contextMessages: [EngineMessage]
    public let capability: ExteralessAIProcessingCapability
    public let allowsExternalProcessing: Bool
    public let allowsCopy: Bool
    public let lease: AINativeOperationLease
    let accountId: Int64
    private let lock = NSLock()
    private var versions: [EngineMessage.Id: UInt32]
    private var committedSourceVersion: UInt32?

    public var source: EngineMessage? { lock.lock(); defer { lock.unlock() }; return sourceValue }

    init(accountId: Int64, source: EngineMessage?, contextMessages: [EngineMessage], capability: ExteralessAIProcessingCapability, allowsExternalProcessing: Bool, allowsCopy: Bool, lease: AINativeOperationLease) {
        self.accountId = accountId
        self.sourceValue = source
        self.contextMessages = contextMessages
        self.capability = capability
        self.allowsExternalProcessing = allowsExternalProcessing
        self.allowsCopy = allowsCopy
        self.lease = lease
        var versions: [EngineMessage.Id: UInt32] = [:]
        if let source { versions[source.id] = source.stableVersion }
        for message in contextMessages { versions[message.id] = message.stableVersion }
        self.versions = versions
    }

    var expectedVersions: [EngineMessage.Id: UInt32] {
        lock.lock(); defer { lock.unlock() }; return versions
    }
    func didCommit(_ message: Message, expectedVersion: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard message.id == sourceValue?.id, versions[message.id] == expectedVersion else { return }
        sourceValue = EngineMessage(message)
        versions[message.id] = message.stableVersion
        if message.stableVersion != expectedVersion { committedSourceVersion = message.stableVersion }
    }

    /// Only an actual engine commit can mint this acquisition capability. UI
    /// completion callbacks cannot advance versions, and external edits still fail
    /// the next transaction's equality check.
    public var committedRetryCapability: ExteralessAIProcessingCapability? {
        lock.lock(); defer { lock.unlock() }
        guard let source = sourceValue, let version = committedSourceVersion, versions[source.id] == version else { return nil }
        return ExteralessAIProcessingCapability(messageId: source.id, expectedStableVersion: version, peerId: capability.peerId, threadId: capability.threadId, allowsExternalProcessing: capability.allowsExternalProcessing, allowsCopy: capability.allowsCopy)
    }
    /// Retaining a Latest Result retains provenance, not a permanently granted
    /// capability. Reopening it must validate this independent lease again.
    public func renewed(lease: AINativeOperationLease) -> ExteralessAIScope {
        lock.lock(); defer { lock.unlock() }
        let value = ExteralessAIScope(accountId: accountId, source: sourceValue, contextMessages: contextMessages, capability: capability, allowsExternalProcessing: allowsExternalProcessing, allowsCopy: allowsCopy, lease: lease)
        value.versions = versions
        value.committedSourceVersion = committedSourceVersion
        return value
    }
}

public extension TelegramEngine.Messages {
    /// Local-only acquisition. Reply traversal, cached-user protection and source
    /// version are sampled in one transaction, without fetching peers or history.
    func resolveExteralessAIScope(capability: ExteralessAIProcessingCapability, contextMessageIds: [EngineMessage.Id] = [], followReplyChain: Bool = false, contextLimit: Int = 0, lease: AINativeOperationLease) -> Signal<ExteralessAIScope?, NoError> {
        let accountId = self.account.id.int64
        return self.account.postbox.transaction { transaction in
            exteralessAIResolveScope(transaction: transaction, accountId: accountId, capability: capability, contextMessageIds: contextMessageIds, followReplyChain: followReplyChain, contextLimit: contextLimit, lease: lease)
        }
    }

    func validateExteralessAIScope(_ scope: ExteralessAIScope) -> Signal<Bool, NoError> {
        let accountId = self.account.id.int64
        return self.account.postbox.transaction { transaction in
            exteralessAIValidateScope(transaction: transaction, accountId: accountId, scope: scope)
        }
    }

    /// Used by copyable result UIs to revoke an already visible result when any
    /// participating source/context or its effective peer protection changes.
    func exteralessAIScopeValidity(_ scope: ExteralessAIScope) -> Signal<Bool, NoError> {
        exteralessAIObserveScopeValidity(postbox: self.account.postbox, accountId: self.account.id.int64, scope: scope)
    }
}

/// Shared by the real engine facade and accountless native ResultAccess fixtures.
func exteralessAIObserveScopeValidity(postbox: Postbox, accountId: Int64, scope: ExteralessAIScope) -> Signal<Bool, NoError> {
    var keys: [PostboxViewKey] = [.messages(Set(scope.expectedVersions.keys))]
    var peers = Set(scope.expectedVersions.keys.map(\.peerId))
    if let peerId = scope.capability.peerId { peers.insert(peerId) }
    for peerId in peers { keys.append(.peer(peerId: peerId, components: [.cachedData])) }
    return postbox.combinedView(keys: keys)
    |> mapToSignal { _ in
        postbox.transaction { transaction in
            exteralessAIValidateScope(transaction: transaction, accountId: accountId, scope: scope)
        }
    }
    |> distinctUntilChanged
}

/// Same effective cached-data peer and two-flag predicate used by the Chat UI.
/// Checking Message.isCopyProtected alone omits private-chat copy protection.
func exteralessAIPeerCopyProtected(transaction: Transaction, peerId: PeerId) -> Bool {
    guard let peer = transaction.getPeer(peerId) else { return true }
    let effectiveId = peer.associatedPeerOverridesIdentity ? (peer.associatedPeerId ?? peerId) : peerId
    if let cached = transaction.getPeerCachedData(peerId: effectiveId) as? CachedUserData,
       cached.flags.contains(.copyProtectionEnabled) || cached.flags.contains(.myCopyProtectionEnabled) { return true }
    let effectivePeer = transaction.getPeer(effectiveId) ?? peer
    if let group = effectivePeer as? TelegramGroup { return group.flags.contains(.copyProtectionEnabled) }
    if let channel = effectivePeer as? TelegramChannel { return channel.flags.contains(.copyProtectionEnabled) }
    return false
}

func exteralessAIMessageExportable(transaction: Transaction, message: Message) -> Bool {
    return message.id.peerId.namespace != Namespaces.Peer.SecretChat
        && !message.isCopyProtected()
        && !message.containsSecretMedia
        && !exteralessAIPeerCopyProtected(transaction: transaction, peerId: message.id.peerId)
}

func exteralessAISameContextScope(source: Message, candidate: Message) -> Bool {
    guard candidate.id.peerId == source.id.peerId, candidate.id.namespace == source.id.namespace else { return false }
    if candidate.threadId == source.threadId { return true }
    // The root of a reply thread can be stored outside the thread's own history.
    return source.threadId == Int64(candidate.id.id) && candidate.threadId == nil
}

func exteralessAIResolveScope(transaction: Transaction, accountId: Int64, capability: ExteralessAIProcessingCapability, contextMessageIds: [MessageId], followReplyChain: Bool, contextLimit: Int, lease: AINativeOperationLease) -> ExteralessAIScope? {
    guard !lease.isCancelled, contextMessageIds.count <= 64 else { return nil }
    let source: Message?
    if let id = capability.messageId {
        guard let message = transaction.getMessage(id), capability.peerId == id.peerId,
              capability.expectedStableVersion == nil || capability.expectedStableVersion == message.stableVersion,
              capability.threadId == nil || capability.threadId == message.threadId else { return nil }
        source = message
    } else { source = nil }
    let exportable = source.map { exteralessAIMessageExportable(transaction: transaction, message: $0) }
        ?? (capability.peerId?.namespace != Namespaces.Peer.SecretChat)
    let external = capability.allowsExternalProcessing && exportable
    let copy = capability.allowsCopy && (source.map { !exteralessAIPeerCopyProtected(transaction: transaction, peerId: $0.id.peerId) && !$0.isCopyProtected() && !$0.containsSecretMedia } ?? true)
    var contexts: [Message] = []
    if external, let source {
        let limit = AINativeContextPolicy.visitLimit(messageLimit: contextLimit)
        var visited: Set<MessageId> = [source.id]
        var visits = 0
        if followReplyChain {
            var current = source
            while visits < limit, let reply = current.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute,
                  visited.insert(reply.messageId).inserted {
                visits += 1 // Counts missing/empty/media-only parents too.
                guard !lease.isCancelled, let parent = transaction.getMessage(reply.messageId),
                      exteralessAISameContextScope(source: source, candidate: parent),
                      exteralessAIMessageExportable(transaction: transaction, message: parent) else { break }
                if !parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { contexts.append(parent) }
                current = parent
            }
        }
        // Explicit local surrounding IDs are provided only by the manual builder.
        // They cannot widen peer/thread scope or exceed the same visited-ID budget.
        for id in contextMessageIds {
            if visits >= limit { break }
            guard visited.insert(id).inserted else { continue }
            visits += 1
            guard !lease.isCancelled, let candidate = transaction.getMessage(id),
                  exteralessAISameContextScope(source: source, candidate: candidate),
                  exteralessAIMessageExportable(transaction: transaction, message: candidate),
                  !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            contexts.append(candidate)
        }
        contexts.sort { $0.index < $1.index }
    }
    guard !lease.isCancelled else { return nil }
    return ExteralessAIScope(accountId: accountId, source: source.map(EngineMessage.init), contextMessages: contexts.map(EngineMessage.init), capability: capability, allowsExternalProcessing: external, allowsCopy: copy, lease: lease)
}

func exteralessAIValidateScope(transaction: Transaction, accountId: Int64, scope: ExteralessAIScope) -> Bool {
    guard scope.accountId == accountId, !scope.lease.isCancelled else { return false }
    var source: Message?
    if let id = scope.source?.id { source = transaction.getMessage(id) }
    for (id, version) in scope.expectedVersions {
        guard let message = transaction.getMessage(id), message.stableVersion == version else { return false }
        if scope.allowsExternalProcessing && !exteralessAIMessageExportable(transaction: transaction, message: message) { return false }
        if scope.allowsCopy && (message.isCopyProtected() || message.containsSecretMedia || exteralessAIPeerCopyProtected(transaction: transaction, peerId: id.peerId)) { return false }
        if id != source?.id, let source, !exteralessAISameContextScope(source: source, candidate: message) { return false }
    }
    return !scope.lease.isCancelled
}

/// The server edit revision, including edits whose UI label is hidden. A local
/// derived-attribute commit preserves this attribute even as stableVersion advances.
func exteralessAIServerSourceRevision(_ attributes: [MessageAttribute]) -> Int32? {
    (attributes.first { $0 is EditedMessageAttribute } as? EditedMessageAttribute)?.date
}

/// Source fingerprint for server merges. Equal partial previews cannot prove
/// equality of their unseen tails across different server edit revisions.
func exteralessAITranslationSourceUnchanged(previous: Message, updated: StoreMessage) -> Bool {
    guard exteralessAIServerSourceRevision(previous.attributes) == exteralessAIServerSourceRevision(updated.attributes),
          previous.text == updated.text,
          (previous.textEntitiesAttribute?.entities ?? []) == ((updated.attributes.first { $0 is TextEntitiesMessageAttribute } as? TextEntitiesMessageAttribute)?.entities ?? []) else { return false }
    let old = previous.richText
    let new = updated.attributes.first { $0 is RichTextMessageAttribute } as? RichTextMessageAttribute
    guard old?.instantPage == new?.instantPage else { return false }
    if let fullPage = new?.fullInstantPage, old?.fullInstantPage != fullPage { return false }
    return true
}
