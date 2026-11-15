import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

public func exteralessPrivacyExtrasIdentity(_ account: Account) -> PrivacyExtrasAccountIdentity {
    PrivacyExtrasAccountIdentity(recordId: account.id.int64, userId: account.peerId.id._internalGetInt64Value(), testingEnvironment: account.testingEnvironment)
}

// Shares the existing privacy collection, with a disjoint key. This is in each
// account's encrypted Postbox, not in global ClientSettings or another account.
private let extrasBlockedEntry = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.exteralessLocalState, key: ValueBoxKey("exteraless.privacyExtras.blocked.v1"))
private struct ExteralessBlockedSnapshot: Codable {
    var ids: Set<Int64>
    var complete: Bool
}

private final class ExteralessFilteringChanges: @unchecked Sendable {
    let promise = ValuePromise<UInt32>(0, ignoreRepeated: true)
    func publish(_ revision: UInt64) { promise.set(UInt32(truncatingIfNeeded: revision)) }
}

public final class ExteralessFilteringRuntime: @unchecked Sendable {
    public static let shared = ExteralessFilteringRuntime()
    private let lock: HiddenAccountPresentationLock
    private let settings: ClientSettings
    private var policies: [PrivacyExtrasAccountIdentity: FilteringPolicy] = [:]
    private var blockedComplete: [PrivacyExtrasAccountIdentity: Bool] = [:]
    private var errors: Set<PrivacyExtrasAccountIdentity> = []
    private let presentationChanges: ExteralessFilteringChanges
    private var observation: ClientSettingsObservation?

    private convenience init() { self.init(settings: .shared) }

    // Native fixtures use the actual RMW writer with an isolated settings file.
    init(settings: ClientSettings) {
        self.settings = settings
        let changes = ExteralessFilteringChanges()
        self.presentationChanges = changes
        self.lock = HiddenAccountPresentationLock { changes.publish($0) }
        observation = settings.observe { [weak self] keys in
            guard keys.isEmpty || !keys.isDisjoint(with: PrivacyExtrasFeatures.filteringKeys) else { return }
            self?.reload()
        }
    }
    public var changes: Signal<UInt32, NoError> { presentationChanges.promise.get() }
    public var generation: UInt32 { UInt32(truncatingIfNeeded: lock.presentationRevision) }
    public var revision: UInt64 { lock.presentationRevision }

    public func invalidatePresentations() {
        lock.invalidatePresentations()
    }

    private func reload() {
        lock.lock(); defer { lock.unlock() }
        for (identity, previous) in policies { policies[identity] = build(identity, blocked: previous.blockedPeers) }
        lock.invalidatePresentations()
    }

    private func build(_ identity: PrivacyExtrasAccountIdentity, blocked: Set<Int64>) -> FilteringPolicy {
        do {
            let configuration = try FilteringConfiguration(account: identity, values: settings.snapshot())
            errors.remove(identity)
            return FilteringPolicy(account: identity, configuration: configuration, blockedPeers: blocked)
        } catch {
            errors.insert(identity)
            // Preserve the previous valid policy until a malformed edit is repaired.
            return FilteringPolicy(account: identity, configuration: policies[identity]?.configuration ?? FilteringConfiguration(), blockedPeers: blocked)
        }
    }

    public func policy(_ identity: PrivacyExtrasAccountIdentity) -> FilteringPolicy {
        lock.lock(); defer { lock.unlock() }
        if let value = policies[identity] { return value }
        let value = build(identity, blocked: [])
        if policies.count < HiddenAccountPolicy.maximumAccounts { policies[identity] = value }
        return value
    }

    public func configurationHasError(_ identity: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }; return errors.contains(identity)
    }

    public func snapshot(_ identity: PrivacyExtrasAccountIdentity) -> (policy: FilteringPolicy, generation: UInt32) {
        lock.lock(); defer { lock.unlock() }; return (policy(identity), generation)
    }

    public func blockedListIsComplete(_ identity: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }; return blockedComplete[identity] ?? false
    }

    public func updateBlocked(_ identity: PrivacyExtrasAccountIdentity, peerIds: Set<Int64>, complete: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        let previous = policies[identity]
        guard previous?.blockedPeers != peerIds || (complete != nil && blockedComplete[identity] != complete) else { return }
        if let complete { blockedComplete[identity] = complete }
        policies[identity] = build(identity, blocked: peerIds)
        lock.invalidatePresentations()
    }

    public func remove(_ identity: PrivacyExtrasAccountIdentity) {
        lock.lock(); defer { lock.unlock() }
        let previousPolicy = policies.removeValue(forKey: identity)
        let previousBlocked = blockedComplete.removeValue(forKey: identity)
        let previousError = errors.remove(identity)
        if previousPolicy != nil || previousBlocked != nil || previousError != nil { lock.invalidatePresentations() }
    }

    /// All native collection edits use this one writer. Validate the complete
    /// account configuration before persisting, including the aggregate rule cap.
    public func setCollection(_ field: String, account: PrivacyExtrasAccountIdentity, value: ClientSettingValue) throws {
        lock.lock(); defer { lock.unlock() }
        guard ["blockedChannelsData", "customFilteredUsersData", "regexFiltersData", "regexChatFiltersData", "regexFiltersExcludedDialogs"].contains(field) else { throw FilteringConfigurationError.invalidCollection }
        let key = "privacy." + field
        var values = settings.snapshot()
        var accounts: [String: ClientSettingValue] = [:]
        if case let .object(previous)? = values[key] { accounts = previous }
        accounts[account.storageKey] = value
        values[key] = .object(accounts)
        let candidate = try FilteringConfiguration(account: account, values: values)
        for rule in candidate.sharedRules + candidate.chatRules.values.flatMap({ $0 }) {
            _ = try FilteringRegex(rule.regex, caseInsensitive: rule.caseInsensitive)
        }
        try settings.set(.object(accounts), for: key)
    }

    public func setPeer(_ peerId: EnginePeer.Id, account: PrivacyExtrasAccountIdentity, filtered: Bool) throws {
        let field: String
        switch peerId.namespace {
        case Namespaces.Peer.CloudUser: field = "customFilteredUsersData"
        case Namespaces.Peer.CloudChannel, Namespaces.Peer.CloudGroup: field = "blockedChannelsData"
        default: throw FilteringConfigurationError.invalidPeer
        }
        lock.lock(); defer { lock.unlock() }
        var peers = try FilteringConfiguration.peers(FilteringConfiguration.scoped(field, account: account, values: settings.snapshot()))
        if filtered { peers.insert(peerId.toInt64()) } else { peers.remove(peerId.toInt64()) }
        try setCollection(field, account: account, value: FilteringConfiguration.value(for: peers))
    }
}

/// Own this lease for EVERY live account, not just the selected one. Paging uses
/// Telegram's native contacts.getBlocked context and stops on a stalled page.
@MainActor
public final class ExteralessFilteringAccountLease {
    private let account: Account
    private var context: BlockedPeersContext?
    private let disposable = MetaDisposable()
    private let persistence = MetaDisposable()
    private var observation: ClientSettingsObservation?
    private var previousCount = -1
    private var pageCount = 0

    public func isForAccount(_ account: Account) -> Bool { self.account === account }

    public init(account: Account) {
        self.account = account
        observation = ClientSettings.shared.observe { [weak self] keys in
            if keys.isEmpty || keys.contains("privacy.ignoreBlocked") {
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        let identity = exteralessPrivacyExtrasIdentity(account)
        persistence.set((account.postbox.transaction { transaction -> ExteralessBlockedSnapshot in
            transaction.retrieveItemCacheEntry(id: extrasBlockedEntry)?.get(ExteralessBlockedSnapshot.self) ?? ExteralessBlockedSnapshot(ids: [], complete: false)
        } |> deliverOnMainQueue).start(next: { snapshot in ExteralessFilteringRuntime.shared.updateBlocked(identity, peerIds: snapshot.ids, complete: snapshot.complete) }))
        refresh()
    }

    public func refresh() {
        disposable.set(nil); context = nil; previousCount = -1; pageCount = 0
        guard ClientSettings.shared.bool("privacy.ignoreBlocked") else { return }
        let context = BlockedPeersContext(account: account, subject: .blocked)
        self.context = context
        disposable.set((context.state |> deliverOnMainQueue).start(next: { [weak self, weak context] state in
            guard let self, let context, self.context === context, !state.isLoadingMore else { return }
            let ids = Set(state.peers.prefix(FilteringConfiguration.maximumPeers).map { $0.peerId.toInt64() })
            let identity = exteralessPrivacyExtrasIdentity(self.account)
            let complete = !state.canLoadMore
            ExteralessFilteringRuntime.shared.updateBlocked(identity, peerIds: ids, complete: complete)
            self.persistence.set(self.account.postbox.transaction { transaction in
                if let entry = CodableEntry(ExteralessBlockedSnapshot(ids: ids, complete: complete)) { transaction.putItemCacheEntry(id: extrasBlockedEntry, entry: entry) }
            }.start())
            if state.canLoadMore, state.peers.count > self.previousCount, state.peers.count < FilteringConfiguration.maximumPeers, self.pageCount < 40 {
                self.previousCount = state.peers.count; self.pageCount += 1
                // Avoid synchronous recursion through the native state promise.
                Queue.mainQueue().async { [weak self, weak context] in
                    guard let self, let context, self.context === context else { return }
                    context.loadMore()
                }
            }
        }))
    }
    deinit { disposable.dispose(); persistence.dispose(); observation?.cancel() }
}

/// Call after a successful native block/unblock mutation, in its owning transaction.
public func exteralessFilterBlockedPeerChanged(transaction: Transaction, account: Account, peerId: PeerId, blocked: Bool) {
    var snapshot = transaction.retrieveItemCacheEntry(id: extrasBlockedEntry)?.get(ExteralessBlockedSnapshot.self) ?? ExteralessBlockedSnapshot(ids: [], complete: false)
    if blocked { snapshot.ids.insert(peerId.toInt64()) } else { snapshot.ids.remove(peerId.toInt64()) }
    if let entry = CodableEntry(snapshot) { transaction.putItemCacheEntry(id: extrasBlockedEntry, entry: entry) }
    ExteralessFilteringRuntime.shared.updateBlocked(exteralessPrivacyExtrasIdentity(account), peerIds: snapshot.ids, complete: snapshot.complete)
}

private func extrasIsMegagroup(_ peer: Peer?) -> Bool {
    if let channel = peer as? TelegramChannel, case .group = channel.info { return true }
    return false
}

private func extrasPlainText(_ message: Message) -> String {
    if let poll = message.media.compactMap({ $0 as? TelegramMediaPoll }).first {
        var result = extrasLimitedText(poll.text) + "\n"
        for option in poll.options.prefix(100) {
            let remaining = FilteringRegex.maximumInputScalars + 1 - result.unicodeScalars.count
            guard remaining > 0 else { break }
            result += extrasLimitedText("\n🔘 " + extrasLimitedText(option.text, limit: remaining), limit: remaining)
        }
        return result
    }
    if let transcription = message.attributes.compactMap({ $0 as? AudioTranscriptionMessageAttribute }).first, !transcription.text.isEmpty { return extrasLimitedText(transcription.text) }
    return extrasLimitedText(message.text)
}

private func extrasLimitedText(_ text: String, limit: Int = FilteringRegex.maximumInputScalars + 1) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, limit))))
}

/// Caps assembly as well as matching. Oversized input keeps the sentinel scalar
/// beyond the limit so a reversed rule cannot treat a truncated prefix as complete.
private func extrasFilterText(_ message: Message, group: [Message], translated: Bool) -> String {
    var parts: [String] = []
    var remaining = FilteringRegex.maximumInputScalars + 1
    func append(_ value: String) {
        guard !value.isEmpty, remaining > 0 else { return }
        if !parts.isEmpty { parts.append("\n"); remaining -= 1 }
        let scalars = value.unicodeScalars.prefix(max(0, remaining))
        parts.append(String(String.UnicodeScalarView(scalars))); remaining -= scalars.count
    }
    let sticker = message.media.contains { ($0 as? TelegramMediaFile)?.isSticker == true }
    let restricted = message.restrictedContentAttribute != nil && !ClientSettings.shared.bool("privacy.ignoreContentRestrictions", default: true)
    if !sticker && !translated && !restricted {
        var text = ""
        // AyuFilter's full-text helper appends the selected message after the
        // album text as well; preserve that find() input, with bounded assembly.
        for item in Array(group.prefix(100)) + [message] {
            let remaining = FilteringRegex.maximumInputScalars + 1 - text.unicodeScalars.count
            if remaining <= 0 { break }
            text += extrasLimitedText(extrasPlainText(item), limit: remaining)
        }
        // Emoji-only messages are excluded in AyuFilter. Unicode emoji modifiers,
        // joiners and variation selectors do not turn an emoji into regular text.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let emojiOnly = text.unicodeScalars.count <= FilteringRegex.maximumInputScalars && !trimmed.isEmpty && trimmed.allSatisfy { character in
            let scalars = character.unicodeScalars.filter { $0.value != 0xfe0f && $0.value != 0x200d }
            if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { return true }
            if scalars.contains(where: { $0.value == 0x20e3 }) { return scalars.allSatisfy { $0.value == 0x20e3 || $0.value == 35 || $0.value == 42 || (48 ... 57).contains($0.value) } }
            return !scalars.isEmpty && scalars.allSatisfy { $0.properties.isEmoji && ($0.value > 127 || $0.properties.isEmojiPresentation) }
        }
        if !emojiOnly { append(text) }
    }
    for markup in message.attributes.compactMap({ $0 as? ReplyMarkupMessageAttribute }).prefix(4) {
        for row in markup.rows.prefix(100) { for button in row.buttons.prefix(100) { append(button.title) } }
    }
    var urls = Set<String>()
    for item in (group.isEmpty ? [message] : group).prefix(100) {
        for attribute in item.attributes.compactMap({ $0 as? TextEntitiesMessageAttribute }).prefix(4) {
            for entity in attribute.entities.prefix(1_024) {
                if case let .TextUrl(url) = entity.type, urls.insert(url).inserted { append(url) }
            }
        }
        for page in item.media.compactMap({ $0 as? TelegramMediaWebpage }).prefix(4) {
            if let url = page.content.url, urls.insert(url).inserted { append(url) }
        }
    }
    return parts.joined()
}

public func exteralessFilteringMessage(account: PrivacyExtrasAccountIdentity, message: Message, group: [Message] = [], translated: Bool = false, oauthNotification: Bool = false, regexFiltersEnabled: Bool? = nil) -> FilteringMessage {
    var replySenderId: Int64?
    if let reply = message.attributes.compactMap({ $0 as? ReplyMessageAttribute }).first {
        replySenderId = message.associatedMessages[reply.messageId]?.author?.id.toInt64()
    }
    return FilteringMessage(account: account, peerId: message.id.peerId.toInt64(), senderId: (message.author?.id ?? message.id.peerId).toInt64(), replySenderId: replySenderId, isMegagroup: extrasIsMegagroup(message.peers[message.id.peerId]), isPrivateChat: message.id.peerId.namespace == Namespaces.Peer.CloudUser || message.id.peerId.namespace == Namespaces.Peer.SecretChat, isOutgoing: !message.flags.contains(.Incoming), text: (regexFiltersEnabled ?? ClientSettings.shared.bool("privacy.regexFiltersEnabled")) ? extrasFilterText(message, group: group, translated: translated) : "", isOAuthNotification: oauthNotification)
}

private func extrasReactionKey(_ value: MessageReaction.Reaction) -> String {
    switch value {
    case let .builtin(value): return "emoji:" + value
    case let .custom(value): return "custom:\(value)"
    case .stars: return "paid"
    }
}

public func exteralessFilterReactions(_ attribute: ReactionsMessageAttribute, policy: FilteringPolicy, isMegagroup: Bool) -> ReactionsMessageAttribute {
    let counts = attribute.reactions.map { FilteringReactionCount(value: extrasReactionKey($0.value), count: Int($0.count), isChosen: $0.isSelected) }
    let recent = attribute.recentPeers.map { FilteringRecentReaction(value: extrasReactionKey($0.value), peerId: $0.peerId.toInt64(), unread: $0.isUnseen, isOwn: $0.isMy) }
    let projection = policy.reactionProjection(counts, recent: recent, isMegagroup: isMegagroup)
    let mapped = Dictionary(uniqueKeysWithValues: projection.counts.map { ($0.value, $0.count) })
    let reactions = attribute.reactions.compactMap { item -> MessageReaction? in
        guard let count = mapped[extrasReactionKey(item.value)] else { return nil }
        return MessageReaction(value: item.value, count: Int32(clamping: count), chosenOrder: item.chosenOrder)
    }
    let visible = Set(projection.recent)
    let peers = zip(attribute.recentPeers, recent).compactMap { visible.contains($0.1) ? $0.0 : nil }
    // Paid top-peer counts are not a complete list of individual reactions.
    let top = isMegagroup ? attribute.topPeers.filter { $0.isMy || $0.isAnonymous || !policy.hidesSender($0.peerId?.toInt64()) } : attribute.topPeers
    return ReactionsMessageAttribute(canViewList: attribute.canViewList, isTags: attribute.isTags, reactions: reactions, recentPeers: peers, topPeers: top)
}

public func exteralessFilterHistoryEntries(account: Account, entries: [MessageHistoryEntry], translated: Bool = false) -> [MessageHistoryEntry] {
    let identity = exteralessPrivacyExtrasIdentity(account)
    let (policy, generation) = ExteralessFilteringRuntime.shared.snapshot(identity)
    let groups = Dictionary(grouping: entries.compactMap { $0.message.groupingKey == nil ? nil : $0.message }, by: { ExteralessFilterGroupKey(peerId: $0.id.peerId, namespace: $0.id.namespace, threadId: $0.threadId, group: $0.groupingKey!) })
    var groupDecisions: [ExteralessFilterGroupKey: FilteringDecision] = [:]
    var budget = FilteringWorkBudget(operations: 1_000_000)
    return entries.compactMap { entry in
        let message = entry.message
        let key = message.groupingKey.map { ExteralessFilterGroupKey(peerId: message.id.peerId, namespace: message.id.namespace, threadId: message.threadId, group: $0) }
        let group = key.flatMap { groups[$0] } ?? []
        let input = exteralessFilteringMessage(account: identity, message: message, group: group, translated: translated)
        if input.isMegagroup && (policy.hidesSender(input.senderId) || policy.hidesSender(input.replySenderId)) { return nil }
        let decision: FilteringDecision
        if let key, let previous = groupDecisions[key] { decision = previous }
        else {
            decision = policy.decision(input, surface: .automaticDownload, budget: &budget)
            if let key { groupDecisions[key] = decision }
        }
        guard !decision.isHidden else { return nil }
        let attributes: [MessageAttribute] = message.attributes.map { attribute in
            guard let reactions = attribute as? ReactionsMessageAttribute else { return attribute }
            return exteralessFilterReactions(reactions, policy: policy, isMegagroup: input.isMegagroup)
        }
        let projected = message.withUpdatedAttributes(attributes).withUpdatedStableVersion(stableVersion: message.stableVersion &+ generation)
        return MessageHistoryEntry(message: projected, isRead: entry.isRead, location: entry.location, monthLocation: entry.monthLocation, attributes: entry.attributes)
    }
}

public func exteralessFilteringPolicy(account: PrivacyExtrasAccountIdentity, transaction: Transaction, runtime: ExteralessFilteringRuntime = .shared) -> FilteringPolicy {
    if let snapshot = transaction.retrieveItemCacheEntry(id: extrasBlockedEntry)?.get(ExteralessBlockedSnapshot.self) {
        runtime.updateBlocked(account, peerIds: snapshot.ids, complete: snapshot.complete)
    }
    return runtime.policy(account)
}

/// Main app and NotificationService call this AFTER normal protocol ingestion,
/// before constructing alert content. No notification/read markers are advanced.
public func exteralessFilterNotificationMessages(account: PrivacyExtrasAccountIdentity, transaction: Transaction, messages: [Message], oauthNotification: Bool = false) -> [Message] {
    guard ExteralessHiddenAccounts.shared.shouldNotify(account) else { return [] }
    let policy = exteralessFilteringPolicy(account: account, transaction: transaction)
    if policy.configuration.ignoreBlocked && !ExteralessFilteringRuntime.shared.blockedListIsComplete(account) { return [] }
    var budget = FilteringWorkBudget(operations: 1_000_000)
    return exteralessFilterNotificationMessages(policy: policy, messages: messages, oauthNotification: oauthNotification, budget: &budget)
}

/// Shared by the actual main-app consumer and bounded native fixtures. Admission
/// by account/Keychain/block-list state remains in the public transaction wrapper.
func exteralessFilterNotificationMessages(policy: FilteringPolicy, messages: [Message], oauthNotification: Bool = false, budget: inout FilteringWorkBudget) -> [Message] {
    return messages.filter { message in
        let group = exteralessFilteringAlbum(message: message, messages: messages)
        return exteralessNotificationMessageDecision(policy: policy, message: message, group: group, oauthNotification: oauthNotification, budget: &budget) == .allow
    }
}

func exteralessFilteringAlbum(message: Message, messages: [Message]) -> [Message] {
    guard let group = message.groupingKey else { return [] }
    let key = ExteralessFilterGroupKey(peerId: message.id.peerId, namespace: message.id.namespace, threadId: message.threadId, group: group)
    return messages.filter { candidate in
        guard let candidateGroup = candidate.groupingKey else { return false }
        return key == ExteralessFilterGroupKey(peerId: candidate.id.peerId, namespace: candidate.id.namespace, threadId: candidate.threadId, group: candidateGroup)
    }
}

private struct ExteralessFilterGroupKey: Hashable {
    let peerId: PeerId
    let namespace: Int32
    let threadId: Int64?
    let group: Int64
}

/// Only the presentation notice is bypassed. Callers retain server errors,
/// banned-right checks, membership, missing messages and sensitive-content consent.
public func exteralessIgnoreLocalRestrictionNotice() -> Bool {
    ClientSettings.shared.bool("privacy.ignoreContentRestrictions", default: true)
}

public func exteralessFilterAllowsAutomaticDownload(account: Account, message: Message) -> Bool {
    let identity = exteralessPrivacyExtrasIdentity(account)
    var budget = FilteringWorkBudget()
    return !ExteralessFilteringRuntime.shared.policy(identity).decision(exteralessFilteringMessage(account: identity, message: message), surface: .automaticDownload, budget: &budget).isHidden
}

public func exteralessFilterAutomaticDownloads(account: Account, ids: [EngineMessage.Id]) -> Signal<Set<EngineMessage.Id>, NoError> {
    let identity = exteralessPrivacyExtrasIdentity(account)
    return account.postbox.transaction { transaction -> Set<EngineMessage.Id> in
        let policy = exteralessFilteringPolicy(account: identity, transaction: transaction)
        var budget = FilteringWorkBudget(operations: 1_000_000)
        return Set(ids.prefix(512).filter { id in
            guard let message = transaction.getMessage(id) else { return false }
            return !policy.decision(exteralessFilteringMessage(account: identity, message: message), surface: .automaticDownload, budget: &budget).isHidden
        })
    }
}

public func exteralessFilterReactionList(account: Account, message: EngineMessage, state: EngineMessageReactionListContext.State) -> EngineMessageReactionListContext.State {
    guard extrasIsMegagroup(message._asMessage().peers[message.id.peerId]) else { return state }
    let policy = ExteralessFilteringRuntime.shared.policy(exteralessPrivacyExtrasIdentity(account))
    let items = state.items.filter { $0.peer.id == account.peerId || !policy.hidesSender($0.peer.id.toInt64()) }
    return EngineMessageReactionListContext.State(hasOutgoingReaction: state.hasOutgoingReaction, totalCount: max(items.count, state.totalCount - (state.items.count - items.count)), items: items, canLoadMore: state.canLoadMore)
}
