import ExteralessCore
import Foundation
import SwiftSignalKit

/// Explicitly scoped presentation publication, shared by text/layout consumers.
/// No active-account singleton and no mutations of EnginePeer / TelegramUser.
public final class ExteralessIdentityPresentation: @unchecked Sendable {
    public static let shared = ExteralessIdentityPresentation()
    fileprivate let cache = IdentityPresentationCache()
    private let lock = NSLock()
    private var policyValue = IdentityDisplayPolicy()
    private var zalgoFilterValue = false
    private var revisionValue: UInt64 = 0
    private let changesPromise = ValuePromise<UInt64>(0, ignoreRepeated: true)
    private var observation: ClientSettingsObservation?

    private init() {
        self.observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || keys.contains("privacy.zalgoFilter") || keys.contains(where: { $0.hasPrefix("identity.") }) else { return }
            self?.reloadDisplayPolicy()
        }
        self.reloadDisplayPolicy()
    }

    public var changes: Signal<UInt64, NoError> { changesPromise.get() }
    public var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return revisionValue }
    public var policy: IdentityDisplayPolicy { lock.lock(); defer { lock.unlock() }; return policyValue }
    public var formattingSnapshot: (calendar: IdentityDatePolicy, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (policyValue.calendar, revisionValue)
    }

    public func state(account: Account) -> IdentityAccountState? {
        cache.snapshot(account: exteralessIdentityAccountId(account))
    }

    public func reloadDisplayPolicy() {
        lock.lock()
        // Serialize the read with publication, so two setting-observer threads
        // cannot publish an older snapshot after the newer one.
        let values = ClientSettings.shared.snapshot()
        let value = IdentityDisplayPolicy(values: values)
        let zalgoFilter: Bool
        if case let .bool(enabled)? = values["privacy.zalgoFilter"] { zalgoFilter = enabled } else { zalgoFilter = false }
        // Zalgo is a final display policy, not an IdentityDisplayPolicy field.
        // Its semantic value must advance the same revision even when `value`
        // compares equal, including reset back to the absent/default false.
        let changed = policyValue != value || zalgoFilterValue != zalgoFilter
        policyValue = value
        zalgoFilterValue = zalgoFilter
        lock.unlock()
        if changed { invalidate() }
    }

    public func invalidate() {
        lock.lock(); revisionValue &+= 1; lock.unlock()
        // Publication is ordered on main; listeners never run under a store lock.
        Queue.mainQueue().async { [weak self] in
            guard let self else { return }
            self.changesPromise.set(self.revision)
            NotificationCenter.default.post(name: IdentityFeatures.presentationChanged, object: nil)
        }
    }
}

/// One retained lease per account in the application integration. Reads and
/// expiry timers are serialized; begin/end tokens reject late callbacks at logout.
public final class ExteralessIdentityAccountLease {
    private let cache: IdentityPresentationCache
    private let presentationChanged: () -> Void
    private let token: IdentityPresentationCache.Lease
    private let disposable = MetaDisposable()
    private var sequence: UInt64 = 0
    private let expiry: IdentityExpiryTimer

    public convenience init(account: Account) throws {
        let runtime = ExteralessIdentityPresentation.shared
        try self.init(accountId: exteralessIdentityAccountId(account), states: exteralessIdentityState(account: account),
            cache: runtime.cache, wallTime: { Date().timeIntervalSince1970 }, schedule: { delay, callback in
                let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: callback, queue: Queue.mainQueue())
                timer.start()
                return { timer.invalidate() }
            }, presentationChanged: { runtime.invalidate() })
    }

    /// Dependency-injected native lease for a supplied account identity/state
    /// stream. Fixtures use a fresh cache and independent wall/monotonic clocks,
    /// so they execute this same publication path without an Account or Postbox.
    public init(accountId: IdentityAccountId, states: Signal<Result<IdentityAccountState, IdentityError>, NoError>,
                cache: IdentityPresentationCache, wallTime: @escaping () -> TimeInterval,
                schedule: @escaping IdentityExpiryTimer.Schedule, presentationChanged: @escaping () -> Void) throws {
        self.cache = cache
        self.presentationChanged = presentationChanged
        let token = try cache.begin(account: accountId)
        self.token = token
        self.expiry = IdentityExpiryTimer(wallTime: wallTime, schedule: schedule,
            isCurrent: { cache.isCurrent(token) }, availabilityChanged: presentationChanged)
        self.disposable.set((states |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else { return }
            let state: IdentityAccountState
            switch result {
            case let .success(value): state = value
            case .failure: state = IdentityAccountState(ownerUserId: self.token.account.userId, testingEnvironment: self.token.account.testingEnvironment)
            }
            self.sequence &+= 1
            guard let changed = try? self.cache.publish(state, lease: self.token, sequence: self.sequence) else {
                self.expiry.updateDeadline(nil)
                return
            }
            if changed { self.presentationChanged() }
            self.expiry.updateDeadline(state.localPremium ? state.emojiStatus?.until : nil)
        }))
    }

    /// Main-queue lifecycle entry; also re-arms a future expiry after clock jumps.
    public func refreshExpiration() { self.expiry.refresh() }

    deinit {
        disposable.dispose()
        expiry.invalidate()
        if cache.end(token) { presentationChanged() }
    }
}

public struct ExteralessPeerIdentityPresentation {
    public let localAlias: String?
    public let localNameOrder: IdentityNameOrder?
    public let name: String?
    public let compactName: String?
    public let letters: [String]?
    public let emojiStatus: PeerEmojiStatus?
    public let nameColor: PeerColor?
    public let backgroundEmojiId: Int64?
    public let profileColor: PeerNameColor?
    public let profileBackgroundEmojiId: Int64?
    public let premiumBadge: Bool
}

public enum ExteralessIdentitySurface: Equatable {
    case peer, messageAuthor, reply
}

public func exteralessIdentityPresentation(account: Account, peer: EnginePeer, surface: ExteralessIdentitySurface = .peer, now: Int64 = Int64(Date().timeIntervalSince1970)) -> ExteralessPeerIdentityPresentation {
    let runtime = ExteralessIdentityPresentation.shared
    return exteralessIdentityProjection(peer: peer, owner: exteralessIdentityAccountId(account), state: runtime.state(account: account), policy: runtime.policy, surface: surface, now: now)
}

/// Pure native projector, also usable by loginless fixtures. It deliberately
/// returns presentation fields rather than a forged, serializable EnginePeer.
public func exteralessIdentityProjection(peer: EnginePeer, owner: IdentityAccountId, state: IdentityAccountState?, policy: IdentityDisplayPolicy, surface: ExteralessIdentitySurface = .peer, now: Int64) -> ExteralessPeerIdentityPresentation {
    let state = state.flatMap { value -> IdentityAccountState? in
        guard value.ownerUserId == owner.userId, value.testingEnvironment == owner.testingEnvironment else { return nil }
        return value
    }
    let alias = exteralessIdentityPeerKey(peer).flatMap { state?.alias(for: $0) }
    var name = alias
    var compactName = alias
    var letters = alias.map(IdentityNamePolicy.initials)
    var nameColor = peer.nameColor
    var backgroundEmojiId = peer.backgroundEmojiId
    var profileColor = peer.profileColor
    var profileBackgroundEmojiId = peer.profileBackgroundEmojiId
    let isOwningUser: Bool
    if case .user = peer { isOwningUser = peer.id.namespace == Namespaces.Peer.CloudUser && peer.id.id._internalGetInt64Value() == owner.userId } else { isOwningUser = false }
    let capabilities = IdentityPremiumCapabilities(actualPremium: peer.isPremium, isOwningUser: isOwningUser, localPremium: state?.localPremium ?? false)
    var serverStatus = peer.emojiStatus
    if let expiration = serverStatus?.expirationDate, Int64(expiration) <= now { serverStatus = nil }
    let selectedStatus = capabilities.emojiStatus(server: serverStatus.map { IdentityEmojiStatus(documentId: $0.fileId, until: $0.expirationDate) }, local: state?.emojiStatus, now: now)
    var emojiStatus = selectedStatus.map { value -> PeerEmojiStatus in
        if let serverStatus, serverStatus.fileId == value.documentId { return serverStatus }
        return PeerEmojiStatus(content: .emoji(fileId: value.documentId), expirationDate: value.until)
    }
    if let status = emojiStatus, case let .starGift(_, _, _, _, pattern, _, outer, _, _) = status.content {
        profileColor = .other(outer)
        profileBackgroundEmojiId = pattern
    } else if case let .user(user) = peer {
        profileBackgroundEmojiId = user.profileBackgroundEmojiId
    } else if case let .channel(channel) = peer {
        profileBackgroundEmojiId = channel.profileBackgroundEmojiId
    }
    if case let .user(user) = peer {
        if !peer.id.isReplies && !peer.id.isVerificationCodes {
            name = IdentityNamePolicy.userName(first: user.firstName, last: user.lastName, alias: alias, order: state?.nameOrder ?? .firstLast)
            compactName = IdentityNamePolicy.userName(first: user.firstName, last: user.lastName, alias: alias, order: state?.nameOrder ?? .firstLast, compact: true)
            letters = name.map(IdentityNamePolicy.initials)
        }
        if capabilities.rendersLocalIdentity {
            // Test the stored user fields, not PeerUtils.nameColor, which already
            // substitutes id % 7 and would make a local fallback unreachable.
            if user.nameColor == nil, let color = state?.colors?.colorId { nameColor = .preset(PeerNameColor(rawValue: color)) }
            if backgroundEmojiId == nil { backgroundEmojiId = state?.colors?.emojiId }
            if profileColor == nil, let color = state?.colors?.profileColorId { profileColor = PeerNameColor(rawValue: color) }
            if profileBackgroundEmojiId == nil { profileBackgroundEmojiId = state?.colors?.profileEmojiId }
        }
    }
    let showsAuthorStatus = surface != .messageAuthor || policy.premiumItemEmojiStatus
    if !showsAuthorStatus { emojiStatus = nil }
    if surface == .reply {
        if !policy.premiumItemCustomColorInReplies { nameColor = nil }
        if !policy.premiumItemEmojiInReplies { backgroundEmojiId = nil }
    }
    return ExteralessPeerIdentityPresentation(localAlias: alias, localNameOrder: state?.nameOrder, name: name, compactName: compactName, letters: letters,
        emojiStatus: emojiStatus, nameColor: nameColor, backgroundEmojiId: backgroundEmojiId,
        profileColor: profileColor, profileBackgroundEmojiId: profileBackgroundEmojiId, premiumBadge: capabilities.rendersPremiumBadge && showsAuthorStatus)
}

public func exteralessIdentityActivityBand(account: Account, peer: EnginePeer, presence: EnginePeer.Presence?, locallyOnline: Bool = false, now: Int64 = Int64(Date().timeIntervalSince1970)) -> IdentityActivityBand? {
    guard case let .user(user) = peer else { return nil }
    let until: Int32?
    if case let .present(value)? = presence?.status { until = value } else { until = nil }
    return IdentityMetadataPolicy.activityBand(enabled: ExteralessIdentityPresentation.shared.policy.showOnlineStatus,
        isSelf: peer.id == account.peerId, isBot: user.botInfo != nil, visibleUntil: until, locallyOnline: locallyOnline, now: now)
}

/// This only filters a copied display array. Server reaction records, paid
/// balances, send eligibility and receipt counts keep their original values.
public func exteralessIdentityVisibleReactions(_ reactions: [MessageReaction]) -> [MessageReaction] {
    guard !ExteralessIdentityPresentation.shared.policy.premiumItemStarInReactions else { return reactions }
    return reactions.filter { $0.value != .stars }
}
