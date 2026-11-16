import ExteralessCore
import Foundation
import HarnessAppContext
import SwiftSignalKit
import TelegramCore

/// Only fixed stage names escape startup; underlying errors may contain paths or API data.
enum HarnessStartupFailure: String, Error, Sendable, CustomStringConvertible, LocalizedError {
    case applicationIdentity = "application-identity"
    case bootstrapRequired = "bootstrap-required"
    case directory = "private-directory"
    case settings = "settings-configuration"
    case registration = "feature-registration"
    case values = "feature-values"
    case retentionConfiguration = "retention-configuration"
    case apiConfiguration = "api-configuration"
    case accountAPIAdmission = "account-api-admission"
    case accountCompletedWithoutValue = "account-completed-without-value"
    case retentionUnavailable = "account-retention-unavailable"
    case retentionArchive = "account-retention-archive"
    case retentionCancelled = "account-retention-cancelled"
    case retentionTimedOut = "account-retention-timed-out"

    static func retention(_ failure: ExteralessRetentionReadinessFailure) -> Self {
        switch failure {
        case .configurationUnavailable: return .retentionUnavailable
        case .archive: return .retentionArchive
        case .cancelled: return .retentionCancelled
        case .timedOut: return .retentionTimedOut
        }
    }

    var description: String { "composer-harness: startup failed at " + self.rawValue }
    var errorDescription: String? { self.description }
}

/// Process-private synthetic secrets. Every read/write and insert-if-absent shares one lock.
/// This instance is never used as a cross-process or production Keychain implementation.
private final class HarnessBootstrapPrivateStore: ClientSecretStore, ClientAPISecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for key: String) throws -> Data? { try self.read(key) }
    func set(_ data: Data?, for key: String) throws { try self.write(data, key: key) }

    func read(_ key: String) throws -> Data? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.values[key]
    }

    func write(_ data: Data?, key: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        self.values[key] = data
    }

    func insertIfAbsent(_ data: Data, key: String) throws -> Data {
        self.lock.lock(); defer { self.lock.unlock() }
        if let current = self.values[key] { return current }
        self.values[key] = data
        return data
    }
}

/// The scene prepares this once, before constructing/loading its root controller.
/// The main-actor singleton retains the owned directory and both stores until process exit.
@MainActor
final class HarnessBootstrap {
    static let shared = HarnessBootstrap()

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("composer-harness-bootstrap-" + UUID().uuidString, isDirectory: true)
    private let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private let privateStore = HarnessBootstrapPrivateStore()
    private var apiConfiguration: ClientAPIConfigurationStore?
    private var preparation: Result<Void, HarnessStartupFailure>?

    private init() {}

    func prepare() -> Result<Void, HarnessStartupFailure> {
        if let preparation { return preparation }
        // A reentrant consumer cannot open an account in a partially configured process.
        self.preparation = .failure(.bootstrapRequired)
        let result = self.configure()
        self.preparation = result
        return result
    }

    func requirePrepared() throws {
        guard let preparation = self.preparation else { throw HarnessStartupFailure.bootstrapRequired }
        try preparation.get()
    }

    private func configure() -> Result<Void, HarnessStartupFailure> {
        var stage = HarnessStartupFailure.applicationIdentity
        do {
            guard Bundle.main.bundleIdentifier == "org.telegram.ComposerHarness" else { throw stage }
            stage = .directory
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            stage = .settings
            try ClientSettings.shared.configure(storageURL: self.directory.appendingPathComponent("native-client-settings.json"),
                secretStore: self.privateStore, durabilityRootURL: self.container)
            stage = .registration
            try ClientSettings.shared.register(RetentionFeatures.definitions + ChatFeatures.definitions)
            stage = .values
            try ClientSettings.shared.applyPublic([
                "chats.showTextCreateDate": .bool(true),
                "chats.stripTrackingOnPaste": .bool(true),
                "chats.disableMarkdown": .bool(false)
            ], expected: ClientSettings.shared.readSnapshot())
            stage = .retentionConfiguration
            let retention = try ExteralessRetentionProcessConfiguration(role: .mainApplication,
                snapshot: ClientSettings.shared.readSnapshot(), durabilityRootURL: self.container)
            try ExteralessAccountRetentionEnvironment.shared.configure(retention)
            stage = .apiConfiguration
            let configuration = ClientAPIConfigurationStore(settings: .shared, settingsSecrets: self.privateStore,
                vault: ClientAPIVault(storage: self.privateStore))
            self.apiConfiguration = configuration
            // The same synthetic identity as ClientHarnessBootstrap; never a user's tuple.
            try ExteralessClientAPIEnvironment.shared.configure(builtinApiId: 1,
                builtinApiHash: "11111111111111111111111111111111", configuration: configuration)
            return .success(())
        } catch {
            return .failure(stage)
        }
    }
}

/// Observe the real two-pass producer's failure channels before it can open either Postbox.
/// Account/manager/logger retention and worker-affine disposal stay in HarnessAccount.make().
func composerHarnessAccountWithReadiness() -> Signal<HarnessAccount, HarnessStartupFailure> {
    Signal { subscriber in
        let finished = Atomic(value: false)
        let account = MetaDisposable()
        let recovery = MetaDisposable()
        let api = MetaDisposable()
        func fail(_ failure: HarnessStartupFailure) {
            guard !finished.swap(true) else { return }
            subscriber.putError(failure)
            account.dispose()
            recovery.dispose()
            api.dispose()
        }
        recovery.set(ExteralessAccountRecoveryCenter.shared.pending.start(next: { entries in
            for entry in entries where !entry.recovery.isDisposed {
                if case let .failed(failure) = entry.recovery.currentStatus {
                    entry.recovery.dispose()
                    fail(.retention(failure))
                    break
                }
            }
        }))
        api.set(ExteralessClientAPIEnvironment.shared.errors.start(next: { error in
            if error != nil { fail(.accountAPIAdmission) }
        }))
        if ExteralessAccountRetentionEnvironment.shared.current.configuration == nil {
            fail(.retentionUnavailable)
        } else if !finished.with({ $0 }) {
            account.set(HarnessAccount.make().start(next: { value in
                guard ExteralessAccountRetentionEnvironment.shared.current.configuration != nil else {
                    fail(.retentionUnavailable)
                    return
                }
                guard !finished.swap(true) else { return }
                subscriber.putNext(value)
                subscriber.putCompletion()
                recovery.dispose()
                api.dispose()
            }, completed: {
                fail(.accountCompletedWithoutValue)
            }))
        }
        return ActionDisposable {
            _ = finished.swap(true)
            account.dispose()
            recovery.dispose()
            api.dispose()
        }
    }
}
