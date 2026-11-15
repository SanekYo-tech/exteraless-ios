import CryptoKit
import ExteralessCore
import Foundation
import Postbox
import Security
import SwiftSignalKit

public enum ExteralessHiddenAccountError: Error {
    case unavailable, staleAccount, authenticationRequired, invalidCode, duplicateCode, recoveryUnavailable, capacity
}

public enum ExteralessPrivateCodeKind: String, Codable, Sendable {
    case digits4, digits6, alphanumeric
    fileprivate func normalize(_ code: String) -> String {
        if self == .alphanumeric { return code.precomposedStringWithCanonicalMapping }
        return String(code.map { character in
            if let number = character.wholeNumberValue, number < 10 { return Character(String(number)) }
            return character
        })
    }
}

/// Implemented by the TelegramUI/PasscodeCore adapter using a real settings
/// PasscodeSession. TelegramCore cannot import PasscodeCore (the reverse edge
/// already exists). No implementation is installed by the plugin bridge.
public protocol ExteralessHiddenSettingsAuthorization: Sendable {
    var isValidForHiddenSettings: Bool { get }
    func validateHiddenSettings() throws -> ExteralessPrivateCodeKind
}

private struct ExteralessAccountCode: Codable {
    let kind: ExteralessPrivateCodeKind
    let salt: Data
    let hash: Data

    init(code: String, kind: ExteralessPrivateCodeKind) throws {
        let code = kind.normalize(code)
        guard !code.isEmpty, code.utf8.count <= 256,
              kind == .alphanumeric || (code.allSatisfy { $0.isASCII && $0.isNumber } && code.count == (kind == .digits6 ? 6 : 4)) else { throw ExteralessHiddenAccountError.invalidCode }
        self.kind = kind
        self.salt = try extrasRandomData(count: 16)
        self.hash = Self.digest(code: code, salt: salt)
    }
    func matches(_ code: String) -> Bool {
        guard salt.count == 16, hash.count == 32, code.utf8.count <= 256 else { return false }
        return extrasConstantTimeEqual(Self.digest(code: kind.normalize(code), salt: salt), hash)
    }
    private static func digest(code: String, salt: Data) -> Data {
        // Exact original salt || UTF-8 code || salt SHA-256 shape. The verifier is
        // held in device-only Keychain, never a plaintext preference or export.
        var input = salt + Data(code.utf8) + salt
        defer { input.resetBytes(in: 0 ..< input.count) }
        return Data(SHA256.hash(data: input))
    }
}

private func extrasRandomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    guard status == errSecSuccess else { throw ExteralessHiddenAccountError.unavailable }
    return data
}

private func extrasConstantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0
}

/// ValuePromise already serializes its value/subscribers. The box is the narrow
/// Sendable crossing from the Foundation publication drain into SwiftSignalKit.
private final class ExteralessHiddenPresentationChanges: @unchecked Sendable {
    let promise = ValuePromise<UInt64>(0, ignoreRepeated: true)
    func publish(_ revision: UInt64) { promise.set(revision) }
}

/// Native-only private configuration. The generic ClientSettings singleton and
/// plugin bridge never receive these definitions, values, codes or recovery key.
public final class ExteralessHiddenAccounts: @unchecked Sendable {
    public static let shared = ExteralessHiddenAccounts()
    public let policy: HiddenAccountPolicy
    private let lock: HiddenAccountPresentationLock
    private var storage: ClientSettings?
    private var storageURL: URL?
    private var storageDurabilityRootURL: URL?
    private var storageKeychainScope: String?
    private var accounts: [PrivacyExtrasAccountIdentity: Account] = [:]
    private var accountSnapshot = HiddenAccountSnapshot()
    private var orderedIdentities: [PrivacyExtrasAccountIdentity] { accountSnapshot.identities }
    private var current: PrivacyExtrasAccountIdentity?
    private var foreground = false
    private var locked = true
    private var configurationRevision: UInt64 = 0
    private var failed = true
    private var isMainApp = false
    private var keychainGroup: String?
    private let presentationChanges: ExteralessHiddenPresentationChanges
    private let makeStorage: (URL, String, String?, URL?) throws -> ClientSettings
    private var operations: [UUID: Disposable] = [:]

    private convenience init() {
        self.init(makeStorage: { url, accessGroup, keychainScope, durabilityRootURL in
            let secrets = ClientKeychainSecretStore(service: "org.exteraless.privacy-extras.v1." + accessGroup + (keychainScope.map { "." + $0 } ?? ""), accessGroup: accessGroup)
            return try ClientSettings(storageURL: url, secretStore: secrets, durabilityRootURL: durabilityRootURL)
        })
    }

    /// Native fixtures inject a temporary ClientSettings + secret backend here;
    /// no production Keychain, Account, network or logout is used by those tests.
    init(makeStorage: @escaping (URL, String, String?, URL?) throws -> ClientSettings) {
        let changes = ExteralessHiddenPresentationChanges()
        let lock = HiddenAccountPresentationLock { value in changes.publish(value) }
        self.presentationChanges = changes
        self.lock = lock
        self.policy = HiddenAccountPolicy(presentationChanged: { lock.invalidatePresentations() })
        self.makeStorage = makeStorage
    }
    public var changes: Signal<UInt64, NoError> { presentationChanges.promise.get() }
    public func invalidatePresentations() { lock.invalidatePresentations() }

    /// Bootstrap on the existing application's worker, before presenting account
    /// pickers/AppLock. durabilityRootURL is the actual OS-provisioned container,
    /// not its telegram-data child. nil retains Core's OS-temp/home inference for fixtures.
    public func configure(basePath: String, accessGroup: String, isMainApp: Bool, keychainScope: String? = nil, durabilityRootURL: URL? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !accessGroup.isEmpty, keychainGroup == nil || keychainGroup == accessGroup else { throw ExteralessHiddenAccountError.unavailable }
        let url = URL(fileURLWithPath: basePath, isDirectory: true).appendingPathComponent("exteraless", isDirectory: true).appendingPathComponent("privacy-extras-private.json")
        if storageURL == url, storage != nil, storageDurabilityRootURL == durabilityRootURL,
           storageKeychainScope == keychainScope, self.isMainApp == isMainApp {
            if failed { try reload() }
            return
        }
        guard storageURL == nil || storageURL == url else { throw ExteralessHiddenAccountError.unavailable }
        do {
            let store = try makeStorage(url, accessGroup, keychainScope, durabilityRootURL)
            try store.register(PrivacyExtrasFeatures.privateDefinitions)
            storage = store; storageURL = url
            self.isMainApp = isMainApp; self.keychainGroup = accessGroup
            try validateStoredConfiguration()
            storageDurabilityRootURL = durabilityRootURL
            storageKeychainScope = keychainScope
            failed = false
            publish()
        } catch {
            failed = true; updatePolicy()
            throw ExteralessHiddenAccountError.unavailable
        }
    }

    public func reload() throws {
        lock.lock(); defer { lock.unlock() }
        guard let storage else { throw ExteralessHiddenAccountError.unavailable }
        do { try storage.reload(); try validateStoredConfiguration(); failed = false; publish() }
        catch { failed = true; updatePolicy(); throw ExteralessHiddenAccountError.unavailable }
    }

    public func update(accounts: [Account], current: Account?, foreground: Bool, locked: Bool) {
        lock.lock(); defer { lock.unlock() }
        let hadAccountSnapshot = accountSnapshot.hasAccountSnapshot
        let replaced = accountSnapshot.update(accounts.prefix(HiddenAccountPolicy.maximumAccounts).map {
            HiddenAccountSnapshot.Entry(identity: exteralessPrivacyExtrasIdentity($0), object: ObjectIdentifier($0))
        })
        if replaced { policy.cancel(nil) }
        self.accounts = Dictionary(accounts.prefix(HiddenAccountPolicy.maximumAccounts).map { (exteralessPrivacyExtrasIdentity($0), $0) }, uniquingKeysWith: { first, _ in first })
        self.current = current.map(exteralessPrivacyExtrasIdentity)
        self.foreground = foreground; self.locked = locked
        updatePolicy()
        if replaced || !hadAccountSnapshot { lock.invalidatePresentations() }
    }

    public func clearContext() {
        lock.lock(); defer { lock.unlock() }
        let hadAccountSnapshot = accountSnapshot.hasAccountSnapshot
        accountSnapshot.confirmEmpty()
        accounts = [:]; current = nil; foreground = false; locked = true
        policy.cancel(nil); updatePolicy()
        if !hadAccountSnapshot { lock.invalidatePresentations() }
    }

    private func values(_ field: String) -> [String: ClientSettingValue] {
        if case let .object(values)? = storage?.value("privacy." + field) { return values }
        return [:]
    }
    private func decodeCode(_ value: ClientSettingValue?) -> ExteralessAccountCode? {
        guard let value, case let .object(object) = value, !object.isEmpty,
              let data = try? JSONEncoder().encode(value), data.count <= 2_048,
              let code = try? JSONDecoder().decode(ExteralessAccountCode.self, from: data), code.salt.count == 16, code.hash.count == 32 else { return nil }
        return code
    }
    private func codeValue(_ code: ExteralessAccountCode) throws -> ClientSettingValue {
        try JSONDecoder().decode(ClientSettingValue.self, from: JSONEncoder().encode(code))
    }
    private func validateStoredConfiguration() throws {
        for field in ["accountHidden", "accountAllowPanic", "passcodeHash"] {
            guard case let .object(items)? = storage?.value("privacy." + field), items.count <= 1_024 else { throw ExteralessHiddenAccountError.unavailable }
            for (key, item) in items {
                let parts = key.split(separator: ":")
                guard parts.count == 3, ["production", "test"].contains(String(parts[0])), Int64(parts[1]) != nil, Int64(parts[2]) != nil else { throw ExteralessHiddenAccountError.unavailable }
                if field == "passcodeHash" {
                    guard decodeCode(item) != nil else { throw ExteralessHiddenAccountError.unavailable }
                } else if case .bool = item {} else { throw ExteralessHiddenAccountError.unavailable }
            }
        }
        if case let .object(value)? = storage?.value("privacy.panicPasscode"), !value.isEmpty, decodeCode(.object(value)) == nil { throw ExteralessHiddenAccountError.unavailable }
        let key = storage?.string("privacy.settingsKey") ?? ""
        guard key.count <= 64, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw ExteralessHiddenAccountError.unavailable }
    }
    public func state(_ account: PrivacyExtrasAccountIdentity) -> HiddenAccountState {
        lock.lock(); defer { lock.unlock() }
        return HiddenAccountState(hasPasscode: decodeCode(values("passcodeHash")[account.storageKey]) != nil, hidden: values("accountHidden")[account.storageKey] == .bool(true), allowPanic: values("accountAllowPanic")[account.storageKey] != .bool(false))
    }
    public var settingsHidden: Bool {
        lock.lock(); defer { lock.unlock() }; return failed || storage?.bool("privacy.settingsHidden") == true
    }
    public var hasPanicCode: Bool {
        lock.lock(); defer { lock.unlock() }; return decodeCode(storage?.value("privacy.panicPasscode")) != nil
    }
    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }; return !failed && storage != nil
    }
    public var requiresUnlockRouting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accountSnapshot.requiresUnlockRouting(available: !failed && storage != nil,
            panicConfigured: hasPanicCode, accountCodeKeys: Set(values("passcodeHash").keys))
    }
    public func isHidden(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed || storage == nil || state(account).isHidden
    }
    public func shouldNotify(_ account: PrivacyExtrasAccountIdentity) -> Bool { !isHidden(account) }

    /// Main-app notification admission additionally binds the live Account object.
    /// Extensions keep their separate identity-only delivery gate and store scope.
    func mainNotificationRevision(account: Account) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        let identity = exteralessPrivacyExtrasIdentity(account)
        guard isMainApp, !failed, storage != nil, accounts[identity] === account,
              !state(identity).isHidden else { return nil }
        return lock.presentationRevision
    }

    public func permitsCurrentAccountAction(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !failed && foreground && !locked && current == account && accounts[account] != nil
    }

    /// Selection gate also protects URL/bot/account shortcuts that bypass a picker.
    public func canSelect(_ account: PrivacyExtrasAccountIdentity) -> Bool {
        !isHidden(account) || policy.canSelect(account)
    }

    private func updatePolicy() {
        let configuration = HiddenAccountConfiguration(accounts: Dictionary(orderedIdentities.map { ($0, state($0)) }, uniquingKeysWith: { first, _ in first }), panicConfigured: hasPanicCode, settingsHidden: settingsHidden, revision: configurationRevision)
        policy.update(configuration: configuration, accounts: orderedIdentities, current: current, foreground: foreground, locked: locked, available: !failed && storage != nil)
    }
    private func publish() {
        configurationRevision &+= 1; updatePolicy()
    }

    private func requireManagement(_ session: any ExteralessHiddenSettingsAuthorization, owner: PrivacyExtrasAccountIdentity) throws -> ClientSettings {
        guard isMainApp, !failed, foreground, !locked, session.isValidForHiddenSettings,
              owner == current, accounts[owner] != nil, let storage else { throw ExteralessHiddenAccountError.authenticationRequired }
        return storage
    }
    private func setAccountField(_ field: String, value: ClientSettingValue?, target: PrivacyExtrasAccountIdentity, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        let store = try requireManagement(session, owner: owner)
        guard accounts[target] != nil else { throw ExteralessHiddenAccountError.staleAccount }
        var values = values(field)
        values[target.storageKey] = value
        try store.set(.object(values), for: "privacy." + field)
        publish()
    }

    public func setHidden(_ hidden: Bool, target: PrivacyExtrasAccountIdentity, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        _ = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        _ = try requireManagement(session, owner: owner)
        guard !hidden || state(target).hasPasscode else { throw ExteralessHiddenAccountError.invalidCode }
        try setAccountField("accountHidden", value: .bool(hidden), target: target, owner: owner, session: session)
    }
    public func setAllowPanic(_ allowed: Bool, target: PrivacyExtrasAccountIdentity, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        _ = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        try setAccountField("accountAllowPanic", value: .bool(allowed), target: target, owner: owner, session: session)
    }
    public func setAccountCode(_ code: String, kind: ExteralessPrivateCodeKind, target: PrivacyExtrasAccountIdentity, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        let validatedKind = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        _ = try requireManagement(session, owner: owner)
        guard validatedKind == kind else { throw ExteralessHiddenAccountError.invalidCode }
        if decodeCode(storage?.value("privacy.panicPasscode"))?.matches(code) == true { throw ExteralessHiddenAccountError.duplicateCode }
        for (key, value) in values("passcodeHash") where key != target.storageKey {
            if decodeCode(value)?.matches(code) == true { throw ExteralessHiddenAccountError.duplicateCode }
        }
        try setAccountField("passcodeHash", value: codeValue(ExteralessAccountCode(code: code, kind: kind)), target: target, owner: owner, session: session)
    }
    public func removeAccountCode(target: PrivacyExtrasAccountIdentity, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        _ = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        // Clearing the hide flag first means a failed Keychain removal cannot
        // strand an account with no route. Original removal also removes hide.
        try setAccountField("accountHidden", value: nil, target: target, owner: owner, session: session)
        try setAccountField("passcodeHash", value: nil, target: target, owner: owner, session: session)
    }
    public func setPanicCode(_ code: String?, kind: ExteralessPrivateCodeKind, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        let validatedKind = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        let store = try requireManagement(session, owner: owner)
        if let code {
            guard validatedKind == kind else { throw ExteralessHiddenAccountError.invalidCode }
            for value in values("passcodeHash").values where decodeCode(value)?.matches(code) == true { throw ExteralessHiddenAccountError.duplicateCode }
            try store.set(codeValue(ExteralessAccountCode(code: code, kind: kind)), for: "privacy.panicPasscode")
        } else { try store.reset("privacy.panicPasscode") }
        publish()
    }
    public func recoveryURL(owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws -> URL {
        _ = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        let store = try requireManagement(session, owner: owner)
        return try recoveryURL(store: store)
    }
    private func recoveryURL(store: ClientSettings) throws -> URL {
        var key = store.string("privacy.settingsKey")
        if key.isEmpty {
            key = try extrasRandomData(count: 16).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            try store.set(.string(key), for: "privacy.settingsKey")
        }
        guard let url = URL(string: "https://t.me/nasettings/" + key) else { throw ExteralessHiddenAccountError.recoveryUnavailable }
        return url
    }
    public func setSettingsHidden(_ hidden: Bool, owner: PrivacyExtrasAccountIdentity, session: any ExteralessHiddenSettingsAuthorization) throws {
        _ = try session.validateHiddenSettings()
        lock.lock(); defer { lock.unlock() }
        let store = try requireManagement(session, owner: owner)
        if hidden { _ = try recoveryURL(store: store) }
        try store.set(.bool(hidden), for: "privacy.settingsHidden"); publish()
    }
    public func acceptsRecoveryURL(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failed, let storage, url.scheme?.lowercased() == "https", url.host?.lowercased() == "t.me", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let path = url.pathComponents
        let key = storage.string("privacy.settingsKey")
        return !key.isEmpty && path.count == 3 && path[1] == "nasettings" && extrasConstantTimeEqual(Data(path[2].utf8), Data(key.utf8))
    }

    public func beginAppUnlockAttempt(explicitPasscodeEntry: Bool) -> HiddenAccountAttempt? {
        lock.lock(); defer { lock.unlock() }
        guard isMainApp else { return nil }
        return policy.beginAttempt(now: ProcessInfo.processInfo.systemUptime, explicitPasscodeEntry: explicitPasscodeEntry)
    }

    public func authorizeBiometricUnlock(attempt: HiddenAccountAttempt) -> HiddenAccountAuthorization? {
        policy.authorize(.biometry, attempt: attempt, now: ProcessInfo.processInfo.systemUptime)
    }

    /// PasscodeCore's verifyAppUnlock continuation calls this after the ordinary
    /// verifier failed but BEFORE recording a failed attempt. No effect occurs here.
    public func authorizeAlternativeAppUnlock(attempt: HiddenAccountAttempt, code: String) -> HiddenAccountAuthorization? {
        lock.lock(); defer { lock.unlock() }
        guard isMainApp, !failed, code.utf8.count <= 256 else { return nil }
        let proof: HiddenAccountAuthentication
        if decodeCode(storage?.value("privacy.panicPasscode"))?.matches(code) == true { proof = .panicCode }
        else {
            let matches = orderedIdentities.filter { decodeCode(values("passcodeHash")[$0.storageKey])?.matches(code) == true }
            guard matches.count == 1 else { return nil }
            proof = .accountCode(matches[0])
        }
        return policy.authorize(proof, attempt: attempt, now: ProcessInfo.processInfo.systemUptime)
    }

    public func authorizeOrdinaryAppUnlock(attempt: HiddenAccountAttempt) -> HiddenAccountAuthorization? {
        policy.authorize(.ordinaryPin, attempt: attempt, now: ProcessInfo.processInfo.systemUptime)
    }

    private func clearPrivateConfigurationAfterAdmittedPanic(_ identity: PrivacyExtrasAccountIdentity) {
        lock.lock(); defer { lock.unlock() }
        guard let storage else { failed = true; updatePolicy(); return }
        do {
            for field in ["passcodeHash", "accountHidden", "accountAllowPanic"] {
                var values = values(field)
                values.removeValue(forKey: identity.storageKey)
                try storage.set(.object(values), for: "privacy." + field)
            }
            publish()
        } catch {
            // Keep a recoverable error state. Never expand a failed per-identity
            // Keychain cleanup to another identity, the panic code, or all settings.
            failed = true
            updatePolicy()
        }
    }

    /// Called only from a consumed explicit panic plan. Native account objects
    /// are rechecked by full identity; logout is scoped to those exact record IDs.
    /// The stock managedCleanupAccounts owns database/cache and remote-session work.
    fileprivate func performPanic(_ plan: HiddenAccountEffectPlan, accountManager: AccountManager<TelegramAccountManagerTypes>, didAdmit: @escaping (PrivacyExtrasAccountIdentity) -> Void, completion: @escaping () -> Void) {
        lock.lock()
        guard case let .panic(targets) = plan, isMainApp else { lock.unlock(); completion(); return }
        var seen = Set<PrivacyExtrasAccountIdentity>()
        let native = targets.prefix(HiddenAccountPolicy.maximumAccounts).compactMap { target -> Account? in
            guard seen.insert(target).inserted, let account = accounts[target], exteralessPrivacyExtrasIdentity(account) == target else { return nil }
            return account
        }
        lock.unlock()
        let id = UUID()
        let holder = MetaDisposable()
        lock.lock(); operations[id] = holder; lock.unlock()
        var sequence: Signal<Void, NoError> = .single(())
        for account in native {
            let identity = exteralessPrivacyExtrasIdentity(account)
            sequence = sequence |> mapToSignal { _ -> Signal<Void, NoError> in
                // The account-manager record can change after the UI snapshot.
                // Validate and mark in the SAME native transaction. This is the
                // stock logoutFromAccount(false) transition, with identity CAS.
                return accountManager.transaction { transaction -> ExteralessAdmittedPanicIdentity? in
                    var admission: ExteralessAdmittedPanicIdentity?
                    transaction.updateRecord(account.id, { record in
                        let transition = exteralessPanicRecordTransition(record: record, expected: identity)
                        admission = transition.admission
                        return transition.record
                    })
                    return admission
                } |> map { admission in
                    exteralessWithAdmittedPanicIdentity(admission) { identity in
                        ExteralessPrivacyExtrasTemporaryFiles.shared.clear(account: identity)
                        self.clearPrivateConfigurationAfterAdmittedPanic(identity)
                    }
                    return admission
                }
                |> deliverOnMainQueue
                |> map { admission in
                    exteralessWithAdmittedPanicIdentity(admission, didAdmit)
                    return ()
                }
            }
        }
        holder.set((sequence |> deliverOnMainQueue).start(completed: { [weak self] in
            if let self { self.lock.lock(); self.operations.removeValue(forKey: id); self.lock.unlock() }
            completion()
        }))
    }
}

/// PasscodeUI depends on TelegramCore already; the composition root installs the
/// switch/unlock continuation without a TelegramCore -> TelegramUI dependency.
@MainActor
public enum ExteralessHiddenAccountUnlock {
    private static var handler: ((HiddenAccountEffectPlan, @escaping (Bool) -> Void) -> Void)?
    private static var accountManager: AccountManager<TelegramAccountManagerTypes>?
    private static var panicDidAdmit: ((PrivacyExtrasAccountIdentity) -> Void)?
    public static func install(accountManager: AccountManager<TelegramAccountManagerTypes>, panicDidAdmit: @escaping (PrivacyExtrasAccountIdentity) -> Void, switchAccount: @escaping (HiddenAccountEffectPlan, @escaping (Bool) -> Void) -> Void) {
        self.accountManager = accountManager; self.panicDidAdmit = panicDidAdmit; self.handler = switchAccount
    }
    public static func clear() { handler = nil; accountManager = nil; panicDidAdmit = nil; ExteralessHiddenAccounts.shared.policy.cancel(nil) }
    public static func complete(_ authorization: HiddenAccountAuthorization, completion: @escaping (Bool) -> Void) {
        guard let handler, let accountManager, let plan = ExteralessHiddenAccounts.shared.policy.consume(authorization, now: ProcessInfo.processInfo.systemUptime) else { completion(false); return }
        if case .panic = plan {
            let didAdmit = panicDidAdmit
            ExteralessHiddenAccounts.shared.performPanic(plan, accountManager: accountManager, didAdmit: { didAdmit?($0) }, completion: { completion(false) })
        } else {
            handler(plan) { success in
                if success { completion(ExteralessHiddenAccounts.shared.policy.finishUnlock(authorization, now: ProcessInfo.processInfo.systemUptime)) }
                else { ExteralessHiddenAccounts.shared.policy.abandonUnlock(authorization); completion(false) }
            }
        }
    }
}
