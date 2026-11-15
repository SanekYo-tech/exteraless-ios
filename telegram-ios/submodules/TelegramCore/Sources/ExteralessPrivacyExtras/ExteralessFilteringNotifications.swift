import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public typealias ExteralessNotificationMessageBatch = [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)]

/// The original state-manager signal still performs all native ingestion/finalizers.
/// Only its presentation consumer receives the filtered, account-scoped batch.
public func exteralessPrivacyExtrasNotifications(account: Account, source: Signal<ExteralessNotificationMessageBatch, NoError>) -> Signal<ExteralessAdmittedNotificationBatch, NoError> {
    let identity = exteralessPrivacyExtrasIdentity(account)
    return exteralessAdmittedNotificationStream(source: source, prepare: { batch, batchId in
        account.postbox.transaction { transaction -> ExteralessAdmittedNotificationBatch? in
            // Hydrate the native block snapshot before binding the evaluated epoch.
            _ = exteralessFilteringPolicy(account: identity, transaction: transaction)
            guard let admission = ExteralessNotificationAdmission.capture(account: account, batchId: batchId) else { return nil }
            let visibleBatch: ExteralessNotificationMessageBatch = batch.compactMap { messages, group, notify, thread in
                let visible = exteralessFilterNotificationMessages(account: identity, transaction: transaction, messages: messages)
                return visible.isEmpty ? nil : (visible, group, notify, thread)
            }
            guard !visibleBatch.isEmpty, admission.isCurrent(account: account) else { admission.cancel(); return nil }
            return ExteralessAdmittedNotificationBatch(messages: visibleBatch, admission: admission)
        }
    })
}

public typealias ExteralessFilteredNotificationDecision = FilteringNotificationDisposition

/// One object per native service-extension delivery. Pending and expired unknown
/// decisions expose no payload text, attachment, sender intent or sound.
public final class ExteralessPrivacyExtrasNotificationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var account: PrivacyExtrasAccountIdentity?
    private var decision: ExteralessFilteredNotificationDecision = .awaitMessage
    private var generation: UInt32?
    private var invalidated = false
    private let currentGeneration: () -> UInt32
    private let accountAllowsNotifications: (PrivacyExtrasAccountIdentity) -> Bool

    public convenience init() {
        self.init(currentGeneration: { ExteralessFilteringRuntime.shared.generation },
            accountAllowsNotifications: { ExteralessHiddenAccounts.shared.shouldNotify($0) })
    }

    // Internal fixture seam: tests drive this real gate without opening Keychain
    // or creating/logging out a user Account.
    init(currentGeneration: @escaping () -> UInt32, accountAllowsNotifications: @escaping (PrivacyExtrasAccountIdentity) -> Bool) {
        self.currentGeneration = currentGeneration
        self.accountAllowsNotifications = accountAllowsNotifications
    }
    public func bind(account: PrivacyExtrasAccountIdentity) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, self.account == nil || self.account == account else { invalidated = true; decision = .suppress; generation = nil; return }
        self.account = account
    }
    public func update(_ decision: ExteralessFilteredNotificationDecision, generation: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return }
        self.decision = decision; self.generation = generation
    }
    public var canPresent: Bool {
        lock.lock(); let account = account; let decision = decision; let generation = generation; lock.unlock()
        guard let account, decision == .allow, generation == currentGeneration() else { return false }
        return accountAllowsNotifications(account)
    }
}

public func exteralessPrivacyExtrasEvaluateNotification(gate: ExteralessPrivacyExtrasNotificationGate, account: PrivacyExtrasAccountIdentity, transaction: Transaction, peerId: PeerId, messageId: MessageId?, actorId: PeerId? = nil, oauthNotification: Bool = false) {
    gate.bind(account: account)
    _ = exteralessFilteringPolicy(account: account, transaction: transaction)
    let generation = ExteralessFilteringRuntime.shared.generation
    let decision = exteralessPrivacyExtrasNotificationDecision(account: account, transaction: transaction, peerId: peerId, messageId: messageId, actorId: actorId, oauthNotification: oauthNotification)
    gate.update(decision, generation: generation)
}

/// NotificationService uses this on both its cached and post-poll transactions.
/// A payload fragment is insufficient to decide a reversed rule. Await the actual
/// message, or finish with empty content at the existing extension deadline.
public func exteralessPrivacyExtrasNotificationDecision(account: PrivacyExtrasAccountIdentity, transaction: Transaction, peerId: PeerId, messageId: MessageId?, actorId: PeerId? = nil, oauthNotification: Bool = false) -> ExteralessFilteredNotificationDecision {
    guard ExteralessHiddenAccounts.shared.shouldNotify(account) else { return .suppress }
    let policy = exteralessFilteringPolicy(account: account, transaction: transaction)
    if policy.hidesSender(actorId?.toInt64()) { return .suppress }
    if policy.configuration.ignoreBlocked && !ExteralessFilteringRuntime.shared.blockedListIsComplete(account) { return .awaitMessage }
    if let messageId, let message = transaction.getMessage(messageId) {
        var budget = FilteringWorkBudget()
        let group = exteralessFilteringAlbum(message: message, messages: transaction.getMessageGroup(message.id) ?? [])
        return exteralessNotificationMessageDecision(policy: policy, message: message, group: group, oauthNotification: oauthNotification, budget: &budget)
    }
    let configuration = policy.configuration
    let privateChat = peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.SecretChat
    let hasTextRules = configuration.regexFiltersEnabled && !configuration.excludedDialogs.contains(peerId.toInt64()) && !oauthNotification
        && (!(configuration.chatRules[peerId.toInt64()] ?? []).isEmpty || ((!privateChat || configuration.regexFiltersEnableInChats) && !configuration.sharedRules.isEmpty))
    if hasTextRules || (policy.hasSenderFilters && actorId == nil) { return .awaitMessage }
    return .allow
}

/// Single-message service-extension evaluation and main-app batch evaluation use
/// the same three-state result. Unknown is not the absence of a hide decision.
func exteralessNotificationMessageDecision(policy: FilteringPolicy, message: Message, group: [Message], oauthNotification: Bool = false, budget: inout FilteringWorkBudget) -> ExteralessFilteredNotificationDecision {
    let input = exteralessFilteringMessage(account: policy.account, message: message, group: group,
        oauthNotification: oauthNotification, regexFiltersEnabled: policy.configuration.regexFiltersEnabled)
    return policy.decision(input, surface: .notification, budget: &budget).notificationDisposition
}
