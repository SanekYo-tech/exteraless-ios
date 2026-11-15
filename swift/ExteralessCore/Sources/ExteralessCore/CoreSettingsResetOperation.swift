import Foundation

/// Main composition owns the parent; a page owns a child. An admitted store
/// mutation may finish, but invalidation prevents subsequent reset steps.
public final class CoreSettingsResetAuthority: @unchecked Sendable {
    public let id = UUID()
    private let lock = NSLock()
    private var valid = true
    private let parent: CoreSettingsResetAuthority?

    public init() { self.parent = nil }
    private init(parent: CoreSettingsResetAuthority) { self.parent = parent }
    public func child() -> CoreSettingsResetAuthority { CoreSettingsResetAuthority(parent: self) }
    public var isValid: Bool {
        self.lock.lock()
        let valid = self.valid
        self.lock.unlock()
        return valid && (self.parent?.isValid ?? true)
    }
    public func invalidate() {
        self.lock.lock()
        self.valid = false
        self.lock.unlock()
    }
}

/// Shared by the native registry action and loginless admission fixtures. A saved
/// action cannot construct or present a page for a retired AccountContext.
@MainActor
public enum CoreSettingsResetActionGate {
    @discardableResult
    public static func open<Context: AnyObject, Page>(requested: Context, current: Context?,
                                                      authority: CoreSettingsResetAuthority?,
                                                      make: (CoreSettingsResetAuthority) -> Page,
                                                      present: (Page) -> Void) -> Bool {
        guard requested === current, let authority, authority.isValid else { return false }
        let page = make(authority)
        guard authority.isValid else { return false }
        present(page)
        return true
    }
}

public enum CoreSettingsResetError: Error, Equatable, LocalizedError, Sendable {
    case contextChanged
    case scopeChanged
    case settingsChanged
    case noNativeSettings
    case operationInProgress
    case unavailableState
    case storage(ClientSettingsError)
    case nativeFailure

    public var errorDescription: String? {
        switch self {
        case .contextChanged: return "The account or reset page changed. Open Reset settings again."
        case .scopeChanged: return "The registered reset scope changed. Refresh the preview before continuing."
        case .settingsChanged: return "Settings changed after the preview. Review a new preview; those edits have been preserved."
        case .noNativeSettings: return "This Original scope has no registered native settings to reset."
        case .operationInProgress: return "A reset is already running. Wait for its result."
        case .unavailableState: return "The selected settings could not be read. Repair or reload storage before resetting them."
        case let .storage(error): return error.errorDescription
        case .nativeFailure: return "A native settings reset failed. Completed steps are shown; remaining values are preserved."
        }
    }
}

public struct CoreSettingsResetEntry: Equatable, Sendable {
    public let definition: ClientSettingDefinition
    public let sources: [CoreSettingsResetSourceField]
    public let hasOverride: Bool
    public var key: String { self.definition.key }
}

public struct CoreSettingsResetUnavailable: Equatable, Sendable {
    public let source: CoreSettingsResetSourceField
    public let reason: String
}

public struct CoreSettingsResetPreview: Sendable {
    public let scope: CoreSettingsResetScope
    public let entries: [CoreSettingsResetEntry]
    public let unavailable: [CoreSettingsResetUnavailable]
    public let storageError: ClientSettingsError?
    public var publicKeys: Set<String> { Set(self.entries.filter { !$0.definition.isSecret }.map(\.key)) }
    public var credentialKeys: Set<String> { Set(self.entries.filter { $0.definition.isSecret }.map(\.key)) }
    public var keys: Set<String> { Set(self.entries.map(\.key)) }

    /// A source symbol is evidence only for a real registered definition. Unknown
    /// Android fields are reported, never registered merely to make reset succeed.
    public static func resolve(scope: CoreSettingsResetScope, snapshot: ClientSettingsSnapshot) throws -> CoreSettingsResetPreview {
        var definitions: [String: ClientSettingDefinition] = [:]
        var sources: [String: [CoreSettingsResetSourceField]] = [:]
        var unavailable: [CoreSettingsResetUnavailable] = []
        for source in CoreSettingsResetCatalog.fields(for: scope) {
            let candidates = snapshot.definitions.filter { CoreSettingsResetCatalog.matches($0, source: source) }
            if candidates.isEmpty {
                unavailable.append(CoreSettingsResetUnavailable(source: source, reason: CoreSettingsResetCatalog.unavailableReason(for: source)))
            }
            for definition in candidates {
                guard !CoreSettingsResetCatalog.retainedOriginalMarkers.contains(definition.key) else { continue }
                if snapshot.secretKeys.contains(definition.key) && !definition.isSecret {
                    unavailable.append(CoreSettingsResetUnavailable(source: source, reason: "This field requires completion of its native credential migration."))
                    continue
                }
                if let previous = definitions[definition.key], previous != definition { throw CoreSettingsResetError.scopeChanged }
                definitions[definition.key] = definition
                sources[definition.key, default: []].append(source)
            }
        }
        let entries = definitions.keys.sorted().compactMap { key -> CoreSettingsResetEntry? in
            guard let definition = definitions[key] else { return nil }
            return CoreSettingsResetEntry(definition: definition, sources: sources[key] ?? [], hasOverride: snapshot.storedKeys.contains(key))
        }
        return CoreSettingsResetPreview(scope: scope, entries: entries, unavailable: unavailable, storageError: snapshot.lastError)
    }
}

fileprivate struct CoreSettingsResetCredentialState: Sendable, CustomReflectable {
    let value: ClientSettingValue?
    let stored: Bool
    var customMirror: Mirror { Mirror(self, children: ["stored": self.stored, "typedValueAvailable": self.value != nil]) }

    static func capture(_ key: String, settings: ClientSettings, snapshot: ClientSettingsSnapshot) throws -> CoreSettingsResetCredentialState {
        let value = settings.value(key)
        let after = settings.readSnapshot()
        // The public snapshot redacts values, but still pins presence and typed
        // availability. Do not assemble those facts from different generations.
        guard snapshot.storedKeys.contains(key) == after.storedKeys.contains(key),
              snapshot.values[key] == after.values[key],
              (snapshot.values[key] != nil) == (value != nil) else {
            throw CoreSettingsResetError.settingsChanged
        }
        return CoreSettingsResetCredentialState(value: value, stored: snapshot.storedKeys.contains(key))
    }

    func matches(_ other: CoreSettingsResetCredentialState) -> Bool {
        guard self.stored == other.stored else { return false }
        switch (self.value, other.value) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isSameJSONValue(as: rhs)
        default: return false
        }
    }
}

public struct CoreSettingsResetPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public let preview: CoreSettingsResetPreview
    fileprivate let before: ClientSettingsSnapshot
    fileprivate let providerID: UUID
    fileprivate let authorityID: UUID
    fileprivate let credentials: [String: CoreSettingsResetCredentialState]
    public var description: String { "Settings reset \(self.preview.scope.rawValue): \(self.preview.entries.count) native entries" }
    public var debugDescription: String { self.description }
    public var customMirror: Mirror { Mirror(self, children: ["scope": self.preview.scope.rawValue as Any, "entries": self.preview.entries.count as Any]) }
}

public struct CoreSettingsResetReport: Sendable {
    public let scope: CoreSettingsResetScope
    /// Confirmed reset steps. A later user edit is never reset again on retry.
    public let confirmedKeys: Set<String>
    /// Actual currently-default/absent overrides, including a write that threw
    /// after commit. Observation alone does not turn a durability error into success.
    public let observedResetKeys: Set<String>
    public let remainingKeys: Set<String>
    public let error: CoreSettingsResetError?
    /// A failed reply may follow a committed reset and a later edit. Keep the
    /// original typed error while separately withdrawing this session's retry.
    public let requiresNewPreview: Bool
    public var isComplete: Bool { self.error == nil && self.remainingKeys.isEmpty && !self.requiresNewPreview }
}

/// Used by the native page and bounded provider fixtures. Its only persistence
/// authority is the injected, already-configured ClientSettings instance.
public final class CoreSettingsResetProvider: Sendable {
    private let settings: ClientSettings
    private let id = UUID()

    public init(settings: ClientSettings = .shared) { self.settings = settings }

    public func prepare(scope: CoreSettingsResetScope, authority: CoreSettingsResetAuthority) throws -> CoreSettingsResetPlan {
        guard authority.isValid else { throw CoreSettingsResetError.contextChanged }
        // Preview/cancel must not run ClientSettings' load-time migrations. Public
        // CAS revalidates this native cache snapshot against disk on confirmation.
        let before = self.settings.readSnapshot()
        let preview = try CoreSettingsResetPreview.resolve(scope: scope, snapshot: before)
        // lastError describes a past operation, not the next write's authority.
        // Keep it visible, while permitting an explicit retry after disk repair;
        // the writer must still parse, validate and CAS the actual current file.
        guard preview.publicKeys.allSatisfy({ before.values[$0] != nil }) else { throw CoreSettingsResetError.unavailableState }
        var credentials: [String: CoreSettingsResetCredentialState] = [:]
        for key in preview.credentialKeys.sorted() {
            guard authority.isValid else { throw CoreSettingsResetError.contextChanged }
            credentials[key] = try CoreSettingsResetCredentialState.capture(key, settings: self.settings, snapshot: before)
        }
        guard authority.isValid else { throw CoreSettingsResetError.contextChanged }
        return CoreSettingsResetPlan(id: UUID(), preview: preview, before: before, providerID: self.id,
                                     authorityID: authority.id, credentials: credentials)
    }

    public func begin(_ plan: CoreSettingsResetPlan, authority: CoreSettingsResetAuthority) throws -> CoreSettingsResetSession {
        guard self.id == plan.providerID, authority.id == plan.authorityID, authority.isValid else {
            throw CoreSettingsResetError.contextChanged
        }
        guard !plan.preview.entries.isEmpty else { throw CoreSettingsResetError.noNativeSettings }
        return try CoreSettingsResetSession(settings: self.settings, plan: plan, authority: authority)
    }

    fileprivate static func isCredentialFailure(_ error: ClientSettingsError, secretKeys: Set<String>) -> Bool {
        switch error {
        case .invalidSecret, .secretStorageFailure, .secretStorageUnavailable: return true
        case let .invalidValue(key, _): return secretKeys.contains(key)
        default: return false
        }
    }
}

/// One user-confirmed scope, resumable in the current page/context. The public
/// portion is one disk CAS reset. Credentials use ordinary explicit native reset
/// semantics with per-key rechecks; these are not a cross-backend transaction or
/// a claimed atomic credential CAS. Secret baselines never enter reports/export.
public final class CoreSettingsResetSession: @unchecked Sendable, CustomReflectable {
    public let plan: CoreSettingsResetPlan
    private let settings: ClientSettings
    private let authority: CoreSettingsResetAuthority
    private let executionLock = NSLock()
    private var executing = false
    private var publicConfirmed = false
    private var credentialConfirmed: Set<String> = []
    private var credentialExpected: [String: CoreSettingsResetCredentialState]
    private var publicExpected: ClientSettingsSnapshot
    private let resetExpected: ClientSettingsSnapshot
    private var requiresNewPreview: CoreSettingsResetError?
    public var customMirror: Mirror { Mirror(self, children: ["plan": self.plan.description]) }

    fileprivate init(settings: ClientSettings, plan: CoreSettingsResetPlan, authority: CoreSettingsResetAuthority) throws {
        self.settings = settings
        self.plan = plan
        self.authority = authority
        self.publicExpected = plan.before
        self.credentialExpected = plan.credentials
        var resetValues = plan.before.values
        var resetStored = plan.before.storedKeys
        for entry in plan.preview.entries where !entry.definition.isSecret {
            resetValues[entry.key] = try entry.definition.validatedValue(entry.definition.defaultValue)
            resetStored.remove(entry.key)
        }
        self.resetExpected = ClientSettingsSnapshot(definitions: plan.before.definitions, values: resetValues,
                                                   storedKeys: resetStored, secretKeys: plan.before.secretKeys)
        try self.checkScope()
        guard authority.isValid else { throw CoreSettingsResetError.contextChanged }
    }

    /// Invoke on a worker. A failed attempt returns observable progress and leaves
    /// the session available for an explicit retry; it never silently rolls back
    /// a later user edit or claims that Keychain and JSON committed together.
    public func run() -> CoreSettingsResetReport {
        self.executionLock.lock()
        if self.executing {
            self.executionLock.unlock()
            return CoreSettingsResetReport(scope: self.plan.preview.scope, confirmedKeys: [],
                                           observedResetKeys: self.observedResetKeys(), remainingKeys: self.plan.preview.keys,
                                           error: .operationInProgress, requiresNewPreview: false)
        }
        self.executing = true
        self.executionLock.unlock()
        // Store callbacks may re-enter. Keep the admission flag, not a held lock,
        // across file/Keychain operations and existing domain observers.
        defer {
            self.executionLock.lock()
            self.executing = false
            self.executionLock.unlock()
        }
        do {
            if let requiresNewPreview = self.requiresNewPreview { throw requiresNewPreview }
            try self.checkScope()
            if !self.plan.preview.credentialKeys.isSubset(of: self.credentialConfirmed) {
                try self.refreshCredentialState()
                try self.checkScope()
            }
            try self.checkConfirmedSteps()
            try self.checkPendingCredentials()
            if !self.publicConfirmed {
                guard self.authority.isValid else { throw CoreSettingsResetError.contextChanged }
                do {
                    try self.settings.applyPublic([:], resetting: self.plan.preview.publicKeys, expected: self.publicExpected)
                } catch {
                    let failure = Self.safeError(error)
                    let after = self.settings.readSnapshot()
                    if Self.isDurabilityFailure(failure) {
                        if self.publicMatches(self.resetExpected, current: after) {
                            self.publicExpected = self.resetExpected
                        } else {
                            // The store delivers observers before throwing. An
                            // observer may already have restored even the exact
                            // old payload after our rename. That snapshot cannot
                            // prove non-commit or re-authorize plan.before.
                            self.requiresNewPreview = .settingsChanged
                        }
                    }
                    throw failure
                }
                self.publicConfirmed = true
                try self.checkScope()
                guard self.publicMatches(self.resetExpected, current: self.settings.readSnapshot()) else { throw CoreSettingsResetError.settingsChanged }
            }

            var remainingError: CoreSettingsResetError?
            for entry in self.plan.preview.entries where entry.definition.isSecret && !self.credentialConfirmed.contains(entry.key) {
                try self.refreshCredentialState()
                try self.checkScope()
                try self.checkConfirmedSteps()
                let before = self.settings.readSnapshot()
                let current = try CoreSettingsResetCredentialState.capture(entry.key, settings: self.settings, snapshot: before)
                guard let expected = self.credentialExpected[entry.key], current.matches(expected) else { throw CoreSettingsResetError.settingsChanged }
                guard self.authority.isValid else { throw CoreSettingsResetError.contextChanged }
                do {
                    try self.settings.reset(entry.key)
                    self.credentialConfirmed.insert(entry.key)
                    guard self.isReset(entry) else { throw CoreSettingsResetError.settingsChanged }
                } catch {
                    let failure = Self.safeError(error)
                    if self.isReset(entry) {
                        // Use the intended absent state, never a later snapshot
                        // that could include a newly saved explicit empty value.
                        self.credentialExpected[entry.key] = CoreSettingsResetCredentialState(value: entry.definition.defaultValue, stored: false)
                        guard case let .storage(error) = failure,
                              CoreSettingsResetProvider.isCredentialFailure(error, secretKeys: self.settings.readSnapshot().secretKeys) else {
                            throw failure
                        }
                        // Native repair can finish this target while reporting
                        // another unreadable credential. Continue selected keys,
                        // but observation alone is not a successful reset reply:
                        // retry must confirm this step without erasing a new edit.
                        remainingError = remainingError ?? failure
                    } else {
                        throw failure
                    }
                }
            }
            try self.checkScope()
            try self.checkConfirmedSteps()
            if let remainingError { throw remainingError }
            return self.report(error: nil)
        } catch {
            let failure = Self.safeError(error)
            switch failure {
            case .contextChanged, .scopeChanged, .settingsChanged: self.requiresNewPreview = failure
            default: break
            }
            return self.report(error: failure)
        }
    }

    private func refreshCredentialState() throws {
        guard self.authority.isValid else { throw CoreSettingsResetError.contextChanged }
        do { try self.settings.reload() }
        catch {
            guard let error = error as? ClientSettingsError,
                  CoreSettingsResetProvider.isCredentialFailure(error, secretKeys: self.settings.readSnapshot().secretKeys) else {
                throw Self.safeError(error)
            }
        }
        guard self.authority.isValid else { throw CoreSettingsResetError.contextChanged }
    }

    private func checkPendingCredentials() throws {
        let snapshot = self.settings.readSnapshot()
        for entry in self.plan.preview.entries where entry.definition.isSecret && !self.credentialConfirmed.contains(entry.key) {
            let current = try CoreSettingsResetCredentialState.capture(entry.key, settings: self.settings, snapshot: snapshot)
            guard let expected = self.credentialExpected[entry.key], current.matches(expected) else {
                throw CoreSettingsResetError.settingsChanged
            }
        }
    }

    private func checkScope() throws {
        guard self.authority.isValid else { throw CoreSettingsResetError.contextChanged }
        let snapshot = self.settings.readSnapshot()
        // Values/presence may change between steps; source membership depends
        // only on schema and secret classification. Avoid rebuilding the large
        // Original catalogue join for every credential in an unchanged schema.
        if snapshot.definitions == self.plan.before.definitions, snapshot.secretKeys == self.plan.before.secretKeys { return }
        let current = try CoreSettingsResetPreview.resolve(scope: self.plan.preview.scope, snapshot: snapshot)
        guard current.keys == self.plan.preview.keys,
              current.entries.map(\.definition) == self.plan.preview.entries.map(\.definition) else {
            throw CoreSettingsResetError.scopeChanged
        }
    }

    private func checkConfirmedSteps() throws {
        if self.publicConfirmed && !self.publicMatches(self.resetExpected, current: self.settings.readSnapshot()) {
            throw CoreSettingsResetError.settingsChanged
        }
        for entry in self.plan.preview.entries where self.credentialConfirmed.contains(entry.key) {
            guard self.isReset(entry) else { throw CoreSettingsResetError.settingsChanged }
        }
    }

    private func publicMatches(_ expected: ClientSettingsSnapshot, current: ClientSettingsSnapshot) -> Bool {
        return self.plan.preview.publicKeys.allSatisfy { key in
            guard let lhs = current.values[key], let rhs = expected.values[key] else { return false }
            return lhs.isSameJSONValue(as: rhs) && current.storedKeys.contains(key) == expected.storedKeys.contains(key)
        }
    }

    private func isReset(_ entry: CoreSettingsResetEntry) -> Bool {
        let snapshot = self.settings.readSnapshot()
        guard !snapshot.storedKeys.contains(entry.key) else { return false }
        let value: ClientSettingValue?
        if entry.definition.isSecret {
            guard let state = try? CoreSettingsResetCredentialState.capture(entry.key, settings: self.settings, snapshot: snapshot) else { return false }
            value = state.value
        } else {
            value = snapshot.values[entry.key]
        }
        return value?.isSameJSONValue(as: entry.definition.defaultValue) == true
    }

    private func report(error: CoreSettingsResetError?) -> CoreSettingsResetReport {
        var confirmed = self.credentialConfirmed
        if self.publicConfirmed { confirmed.formUnion(self.plan.preview.publicKeys) }
        return CoreSettingsResetReport(scope: self.plan.preview.scope, confirmedKeys: confirmed,
                                       observedResetKeys: self.observedResetKeys(), remainingKeys: self.plan.preview.keys.subtracting(confirmed),
                                       error: error, requiresNewPreview: self.requiresNewPreview != nil)
    }

    private func observedResetKeys() -> Set<String> { Set(self.plan.preview.entries.filter(self.isReset).map(\.key)) }

    private static func safeError(_ error: Error) -> CoreSettingsResetError {
        if let error = error as? CoreSettingsResetError { return error }
        if let error = error as? ClientSettingsError {
            if error == .concurrentModification { return .settingsChanged }
            return .storage(error)
        }
        return .nativeFailure
    }

    private static func isDurabilityFailure(_ error: CoreSettingsResetError) -> Bool {
        if case .storage(.storageFailure(operation: _, code: _)) = error { return true }
        return false
    }
}
