import Foundation

public struct HiddenAccountState: Equatable, Sendable {
    public var hasPasscode: Bool
    public var hidden: Bool
    public var allowPanic: Bool
    public init(hasPasscode: Bool = false, hidden: Bool = false, allowPanic: Bool = true) {
        self.hasPasscode = hasPasscode; self.hidden = hidden; self.allowPanic = allowPanic
    }
    public var isHidden: Bool { hasPasscode && hidden }
}

public struct HiddenAccountConfiguration: Equatable, Sendable {
    public var accounts: [PrivacyExtrasAccountIdentity: HiddenAccountState]
    public var panicConfigured: Bool
    public var settingsHidden: Bool
    public var revision: UInt64
    public init(accounts: [PrivacyExtrasAccountIdentity: HiddenAccountState] = [:], panicConfigured: Bool = false, settingsHidden: Bool = false, revision: UInt64 = 0) {
        self.accounts = accounts; self.panicConfigured = panicConfigured
        self.settingsHidden = settingsHidden; self.revision = revision
    }
}

/// Proof categories never carry plaintext codes. Native authentication must check
/// the ordinary PIN first; a valid ordinary PIN cannot be interpreted as panic.
public enum HiddenAccountAuthentication: Sendable {
    case ordinaryPin, biometry, accountCode(PrivacyExtrasAccountIdentity), panicCode
    case wrongPin, cancelled, unavailable
}

public enum HiddenAccountEffectPlan: Equatable, Sendable {
    case unlock(account: PrivacyExtrasAccountIdentity, reveal: Bool)
    case panic(accounts: [PrivacyExtrasAccountIdentity])
}

public final class HiddenAccountAttempt: Sendable {
    fileprivate let id: UUID
    fileprivate let generation: UInt64
    fileprivate let deadline: TimeInterval
    fileprivate let acceptsPanic: Bool
    fileprivate init(generation: UInt64, deadline: TimeInterval, acceptsPanic: Bool) {
        id = UUID(); self.generation = generation; self.deadline = deadline; self.acceptsPanic = acceptsPanic
    }
}

public final class HiddenAccountAuthorization: Sendable {
    fileprivate let attempt: HiddenAccountAttempt
    fileprivate let plan: HiddenAccountEffectPlan
    fileprivate init(attempt: HiddenAccountAttempt, plan: HiddenAccountEffectPlan) { self.attempt = attempt; self.plan = plan }
}

/// Local app-lock admission, not a replacement for PasscodeCore's credential
/// sessions. Alternate codes cannot authorize settings, wallet or share sessions.
public final class HiddenAccountPolicy: @unchecked Sendable {
    public static let maximumAccounts = 32
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var configuration = HiddenAccountConfiguration()
    private var accounts: [PrivacyExtrasAccountIdentity] = []
    private var current: PrivacyExtrasAccountIdentity?
    private var foreground = false
    private var locked = true
    private var available = false
    private var pending: UUID?
    private var revealed: PrivacyExtrasAccountIdentity?
    private var unlockContinuation: HiddenAccountAuthorization?
    private let presentationChanged: @Sendable () -> Void

    public init(presentationChanged: @escaping @Sendable () -> Void = {}) {
        self.presentationChanged = presentationChanged
    }

    public func update(configuration: HiddenAccountConfiguration, accounts: [PrivacyExtrasAccountIdentity], current: PrivacyExtrasAccountIdentity?, foreground: Bool, locked: Bool, available: Bool) {
        var changed = false
        lock.lock(); defer { lock.unlock(); if changed { presentationChanged() } }
        let accounts = Array(accounts.prefix(Self.maximumAccounts))
        if let continuation = unlockContinuation, case let .unlock(target, _) = continuation.plan {
            if self.configuration != configuration || self.accounts != accounts || !foreground || !available || (self.current != current && current != target) || (!self.locked && locked) {
                unlockContinuation = nil
            }
        }
        if self.configuration != configuration || self.accounts != accounts || self.current != current || self.foreground != foreground || self.locked != locked || self.available != available {
            generation &+= 1; pending = nil
            changed = true
        }
        if !foreground || !available || (!self.locked && locked) || (self.current != current && current != revealed) || self.configuration != configuration {
            revealed = nil
        }
        self.configuration = configuration; self.accounts = accounts; self.current = current
        self.foreground = foreground; self.locked = locked; self.available = available
    }

    public func isVisible(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return available && accounts.contains(account) && !(configuration.accounts[account]?.isHidden ?? false)
    }

    public func canUse(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available, foreground, !locked, accounts.contains(account) else { return false }
        return !(configuration.accounts[account]?.isHidden ?? false) || (current == account && revealed == account)
    }

    /// Also admits the one account selected by an already-consumed unlock grant
    /// while the app-lock cover is still up and the account switch is completing.
    public func canSelect(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available, foreground, accounts.contains(account) else { return false }
        return !(configuration.accounts[account]?.isHidden ?? false) || (revealed == account && (!locked || unlockContinuation != nil))
    }

    public func shouldNotify(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        // Android suppresses hidden-account alerts even while that account is open.
        isVisible(account)
    }

    public func beginAttempt(now: TimeInterval, explicitPasscodeEntry: Bool) -> HiddenAccountAttempt? {
        var changed = false
        lock.lock(); defer { lock.unlock(); if changed { presentationChanged() } }
        guard available, foreground, locked, now.isFinite, !accounts.isEmpty else { return nil }
        changed = unlockContinuation != nil || revealed != nil
        unlockContinuation = nil; revealed = nil
        let attempt = HiddenAccountAttempt(generation: generation, deadline: now + 15, acceptsPanic: explicitPasscodeEntry)
        pending = attempt.id
        return attempt
    }

    public func authorize(_ authentication: HiddenAccountAuthentication, attempt: HiddenAccountAttempt, now: TimeInterval) -> HiddenAccountAuthorization? {
        lock.lock(); defer { lock.unlock() }
        guard accepts(attempt, now: now) else { return nil }
        let plan: HiddenAccountEffectPlan
        switch authentication {
        case .wrongPin, .cancelled, .unavailable:
            pending = nil
            return nil
        case .ordinaryPin, .biometry:
            let visible = accounts.filter { !(configuration.accounts[$0]?.isHidden ?? false) }
            guard let account = visible.first(where: { $0 == current }) ?? visible.first else { pending = nil; return nil }
            plan = .unlock(account: account, reveal: false)
        case let .accountCode(account):
            guard accounts.contains(account), configuration.accounts[account]?.hasPasscode == true else { pending = nil; return nil }
            plan = .unlock(account: account, reveal: true)
        case .panicCode:
            guard attempt.acceptsPanic, configuration.panicConfigured else { pending = nil; return nil }
            // Snapshot actual authorized identities, including visible accounts,
            // exactly like PasscodeHelper's activated && allowPanic predicate.
            plan = .panic(accounts: accounts.filter { configuration.accounts[$0]?.allowPanic ?? true })
        }
        return HiddenAccountAuthorization(attempt: attempt, plan: plan)
    }

    /// One-shot, immediately before native account-manager work on the main queue.
    /// No work may be scheduled from authorize() or from a failed/cancelled PIN.
    public func consume(_ authorization: HiddenAccountAuthorization, now: TimeInterval) -> HiddenAccountEffectPlan? {
        var changed = false
        lock.lock(); defer { lock.unlock(); if changed { presentationChanged() } }
        guard accepts(authorization.attempt, now: now) else { return nil }
        changed = true
        pending = nil
        switch authorization.plan {
        case let .unlock(account, reveal): revealed = reveal ? account : nil; unlockContinuation = authorization
        case .panic: revealed = nil; unlockContinuation = nil
        }
        return authorization.plan
    }

    /// Recheck after the asynchronous native account switch and before AppLock is
    /// allowed to uncover the window. Only the expected switch preserves this grant.
    public func finishUnlock(_ authorization: HiddenAccountAuthorization, now: TimeInterval) -> Bool {
        var finished = false
        lock.lock(); defer { lock.unlock(); if !finished { presentationChanged() } }
        guard unlockContinuation === authorization else { return false }
        unlockContinuation = nil
        guard available, foreground, locked, now.isFinite, now <= authorization.attempt.deadline else { if locked { revealed = nil }; return false }
        // The successful AppLock state emission publishes the unlocked view. Do
        // not blank the ready root during the short finish -> unlock handoff.
        finished = true
        return true
    }

    public func abandonUnlock(_ authorization: HiddenAccountAuthorization) {
        var changed = false
        lock.lock(); defer { lock.unlock(); if changed { presentationChanged() } }
        if unlockContinuation === authorization {
            changed = true
            unlockContinuation = nil
            if locked { revealed = nil }
        }
    }

    public func cancel(_ attempt: HiddenAccountAttempt?) {
        var changed = false
        lock.lock(); defer { lock.unlock(); if changed { presentationChanged() } }
        if attempt == nil || pending == attempt?.id || unlockContinuation?.attempt.id == attempt?.id {
            changed = pending != nil || unlockContinuation != nil || (locked && revealed != nil)
            pending = nil; unlockContinuation = nil; generation &+= 1
            if locked { revealed = nil }
        }
    }

    private func accepts(_ attempt: HiddenAccountAttempt, now: TimeInterval) -> Bool {
        available && foreground && locked && pending == attempt.id && generation == attempt.generation && now.isFinite && now <= attempt.deadline
    }
}

/// Unit fixtures supply a recorder; native logout is never called by Core tests.
public protocol HiddenAccountPanicEffects {
    func clearTemporaryFiles(for account: PrivacyExtrasAccountIdentity) throws
    func logout(_ account: PrivacyExtrasAccountIdentity) throws
}

public struct HiddenAccountPanicResult: Equatable, Sendable {
    public var loggedOut: [PrivacyExtrasAccountIdentity] = []
    public var failed: [PrivacyExtrasAccountIdentity] = []
    public var temporaryCleanupFailed: [PrivacyExtrasAccountIdentity] = []
}

public enum HiddenAccountPanicExecutor {
    /// Requires a consumed policy plan, deduplicates by full identity, bounds work,
    /// and does not broaden a failing cleanup into deletion of some parent folder.
    public static func execute(_ plan: HiddenAccountEffectPlan, effects: HiddenAccountPanicEffects) -> HiddenAccountPanicResult {
        guard case let .panic(accounts) = plan else { return HiddenAccountPanicResult() }
        var result = HiddenAccountPanicResult()
        var seen = Set<PrivacyExtrasAccountIdentity>()
        for account in accounts.prefix(HiddenAccountPolicy.maximumAccounts) where seen.insert(account).inserted {
            do { try effects.clearTemporaryFiles(for: account) } catch { result.temporaryCleanupFailed.append(account) }
            do { try effects.logout(account); result.loggedOut.append(account) } catch { result.failed.append(account) }
        }
        return result
    }
}
