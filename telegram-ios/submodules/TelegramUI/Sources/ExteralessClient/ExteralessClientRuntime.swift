import AccountContext
import Display
import ExteralessCore
import Foundation
import PasscodeCore
import SwiftSignalKit
import TelegramCore
import UIKit

enum ExteralessClientPreparationState: Equatable {
    case preparing
    case ready
    case failed(String)
}

private enum ExteralessClientWorkError: Error, Sendable {
    case settings, fontFamilies, privateSettings, changedRoot, retiredContext
    case clientAPI(ClientAPIError)

    var message: String {
        switch self {
        case .settings: return "Client settings could not be prepared. The saved file has been preserved. Repair storage or free space, then retry."
        case .fontFamilies: return "The bundled interface fonts could not be loaded."
        case .privateSettings: return "Private account settings could not be loaded. Unlock the device, then retry."
        case .changedRoot: return "The application's settings container changed. Restart with the original provisioned container."
        case .retiredContext: return "The account context changed before the operation completed."
        case let .clientAPI(error): return error.errorDescription ?? "Client API configuration failed."
        }
    }
}

private struct ExteralessClientPreparationInput: Equatable, Sendable {
    let rootPath: String
    let durabilityRootURL: URL
    let builtinApiId: Int32
    let builtinApiHash: String
}

/// Cancellation checks never hold a lock across settings I/O or wait for that
/// I/O on main. An admitted atomic write can finish; retired UI cannot publish it.
private final class ExteralessClientContextToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

/// Owns every root configure/register/reload and private/API Keychain preparation.
/// Only its serial queue touches the cached preparation and filesystem APIs.
private final class ExteralessClientSettingsWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.exteraless.client-settings", qos: .userInitiated)
    private var preparedInput: ExteralessClientPreparationInput?
    private var configuration: ClientAPIConfigurationStore?

    private static var definitions: [ClientSettingDefinition] {
        return AppearanceFeatures.definitions + ChatFeatures.definitions + ChatSwipeFeatures.definitions + FeedFeatures.definitions
            + PlayerFeatures.definitions + PlayerFeatures.galleryDefinitions + PillFeatures.definitions
            + PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions + DialogFeatures.definitions
            + AIFeatures.definitions + ToolsFeatures.definitions + NewNetworkFeatures.definitions + MapFeatures.definitions
            + StickerFeatures.definitions + IdentityFeatures.definitions + RetentionFeatures.definitions
            + NewCloudFeatures.definitions + ClientAPIFeatures.definitions
            + ToolsPerformancePolicy.definitions
            + ExteraConfigCompatibility.definitions
    }

    func prepare(_ input: ExteralessClientPreparationInput, reload: Bool,
                 completion: @escaping @Sendable (Result<ClientAPIConfigurationStore, ExteralessClientWorkError>) -> Void) {
        queue.async {
            var failure = ExteralessClientWorkError.settings
            do {
                if let preparedInput = self.preparedInput, preparedInput != input { throw ExteralessClientWorkError.changedRoot }
                failure = .fontFamilies
                try ExteralessFontFamily.prepare()
                failure = .settings
                if let configuration = self.configuration {
                    if reload {
                        try ClientSettings.shared.reload()
                        try ExteralessAccountRetentionEnvironment.shared.configure(ExteralessRetentionProcessConfiguration(
                            role: .mainApplication, snapshot: ClientSettings.shared.readSnapshot(), durabilityRootURL: input.durabilityRootURL))
                        failure = .privateSettings
                        try ExteralessHiddenAccounts.shared.reload()
                    }
                    completion(.success(configuration))
                    return
                }
                let file = URL(fileURLWithPath: input.rootPath, isDirectory: true)
                    .appendingPathComponent("exteraless/client-settings.json")
                try ClientSettings.shared.configure(storageURL: file, durabilityRootURL: input.durabilityRootURL)
                try ClientSettings.shared.register(Self.definitions)
                try ChatFeatures.migrateSettings(in: ClientSettings.shared)
                let exteralessDirectory = URL(fileURLWithPath: input.rootPath, isDirectory: true).appendingPathComponent("exteraless", isDirectory: true)
                try ChatTrackingRulesStore.shared.configure(overrideURL: exteralessDirectory.appendingPathComponent("adguard_url_tracking.txt"), bundledURL: Bundle.main.url(forResource: "adguard_url_tracking", withExtension: "txt"))
                try ExteralessAccountRetentionEnvironment.shared.configure(ExteralessRetentionProcessConfiguration(
                    role: .mainApplication, snapshot: ClientSettings.shared.readSnapshot(), durabilityRootURL: input.durabilityRootURL))
                failure = .privateSettings
                try exteralessPrivacyExtrasConfigure(rootPath: input.rootPath, durabilityRootURL: input.durabilityRootURL)
                let accessGroup = try PasscodeEnvironment.shared.sharedAccessGroup()
                // The settings hash reader matches ClientSettings' existing
                // system backend. Only the account-pin vault selects this group.
                let configuration = ClientAPIConfigurationStore(settings: .shared,
                    settingsSecrets: ClientSecrets.systemStore(),
                    vault: ClientAPIVault(storage: ClientAPIKeychain.storage(accessGroup: accessGroup)))
                do {
                    try ExteralessClientAPIEnvironment.shared.configure(builtinApiId: input.builtinApiId,
                        builtinApiHash: input.builtinApiHash, configuration: configuration)
                } catch {
                    throw ExteralessClientWorkError.clientAPI((error as? ClientAPIError) ?? .settingsUnavailable)
                }
                self.preparedInput = input
                self.configuration = configuration
                completion(.success(configuration))
            } catch let error as ExteralessClientWorkError {
                ExteralessAccountRetentionEnvironment.shared.setUnavailable()
                completion(.failure(error))
            } catch {
                ExteralessAccountRetentionEnvironment.shared.setUnavailable()
                completion(.failure(failure))
            }
        }
    }

    func toggleGhost(context: ExteralessClientContextToken, operation: ExteralessClientContextToken,
                     completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        queue.async {
            do {
                guard context.isValid, operation.isValid else { throw ExteralessClientWorkError.retiredContext }
                let before = ClientSettings.shared.readSnapshot()
                guard context.isValid, operation.isValid else { throw ExteralessClientWorkError.retiredContext }
                let active = try PrivacyGhostModeMutation.toggle(in: .shared, expectedBefore: before)
                completion(.success(active))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// Explicit application composition for native client features. TelegramCore
/// consumes the Foundation settings store; UIKit integrations stay in TelegramUI.
@MainActor
final class ExteralessClientRuntime {
    static let shared = ExteralessClientRuntime()
    private(set) var lastError: String?
    private(set) var isPrepared = false
    private let settingsWorker = ExteralessClientSettingsWorker()
    private let preparationValue = ValuePromise<ExteralessClientPreparationState>(.preparing, ignoreRepeated: true)
    private var preparationInput: ExteralessClientPreparationInput?
    private var preparationGeneration: UInt64 = 0
    private var preparationActive = false
    private var retentionRetries: [UUID: (ExteralessAccountRetentionRecovery, reset: Bool)] = [:]
    private var terminated = false
    private(set) var clientAPIConfiguration: ClientAPIConfigurationStore?
    private var foregroundObserver: NSObjectProtocol?
    private var pluginRuntimeObserver: NSObjectProtocol?
    private var appearance: ExteralessAppearanceIntegration?
    private var chats: ExteralessChatIntegration?
    private var feed: ExteralessFeedIntegration?
    private var player: ExteralessPlayerIntegration?
    private var pills: ExteralessPillIntegration?
    private var privacy: ExteralessPrivacyIntegration?
    private var privacyExtras: ExteralessPrivacyExtrasIntegration?
    private var dialogs: ExteralessDialogIntegration?
    private var ai: ExteralessAIIntegration?
    private var tools: ExteralessToolsIntegration?
    private var network: ExteralessNetworkIntegration?
    private var maps: ExteralessMapIntegration?
    private var stickers: ExteralessStickerIntegration?
    private var identity: ExteralessIdentityIntegration?
    private var retention: ExteralessRetentionIntegration?
    private var cloud: ExteralessCloudIntegration?
    private var settingsReset: SettingsResetIntegration?
    private var backupBindings: ExteralessToolsBackupBindings?
    private var shortcutsBound = false
    private var contextToken: ExteralessClientContextToken?
    private weak var currentContext: AccountContext?
    private let presentedAccount = ValuePromise<PrivacyExtrasAccountIdentity?>(nil, ignoreRepeated: true)

    private init() {}

    var preparationState: Signal<ExteralessClientPreparationState, NoError> { preparationValue.get() }

    func prepare(rootPath: String, durabilityRootURL: URL, builtinApiId: Int32, builtinApiHash: String) {
        guard !terminated else { return }
        let input = ExteralessClientPreparationInput(rootPath: rootPath, durabilityRootURL: durabilityRootURL,
            builtinApiId: builtinApiId, builtinApiHash: builtinApiHash)
        if let current = preparationInput, current != input {
            lastError = ExteralessClientWorkError.changedRoot.message
            preparationValue.set(.failed(ExteralessClientWorkError.changedRoot.message))
            return
        }
        preparationInput = input
        if isPrepared { return }
        beginPreparation(reload: false)
    }

    func retryPreparation() { beginPreparation(reload: isPrepared) }

    /// Retention retry/reset crosses the same public/private settings gate as
    /// startup. An admitted request is resumed once after successful preparation.
    func retryAccountRetention(_ recovery: ExteralessAccountRetentionRecovery, resetArchive: Bool = false) {
        guard !terminated, !recovery.isDisposed else { return }
        retentionRetries[recovery.id] = (recovery, resetArchive)
        beginPreparation(reload: true)
    }

    private func beginPreparation(reload: Bool) {
        guard !terminated, !preparationActive, let input = preparationInput else { return }
        preparationActive = true
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparationValue.set(.preparing)
        settingsWorker.prepare(input, reload: reload) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.terminated, self.preparationGeneration == generation,
                          self.preparationInput == input else { return }
                    self.preparationActive = false
                    switch result {
                    case let .success(configuration):
                        self.clientAPIConfiguration = configuration
                        // Resolver/UI installation follows real settings/API
                        // preparation and still precedes account construction.
                        if self.network == nil { self.network = ExteralessNetworkIntegration() }
                        if self.maps == nil { self.maps = ExteralessMapIntegration() }
                        self.installEntryPoints()
                        self.isPrepared = true
                        self.lastError = nil
                        self.preparationValue.set(.ready)
                        let retries = Array(self.retentionRetries.values)
                        self.retentionRetries.removeAll()
                        for (recovery, reset) in retries where !recovery.isDisposed {
                            if reset { recovery.resetRetainedArchive() }
                            else { recovery.retry() }
                        }
                    case let .failure(error):
                        self.retentionRetries.removeAll()
                        self.lastError = error.message
                        self.preparationValue.set(.failed(error.message))
                    }
                }
            }
        }
    }

    private func installEntryPoints() {
        ExteralessSettingsEntry.setControllerFactory { context in
            exteralessSettingsController(context: context)
        }
        ExteralessFeedEntry.install(factory: { [weak self] context in
            self?.feed?.makeController(context: context)
        }, unreadBadge: { [weak self] context in
            self?.feed?.unreadBadge(context: context) ?? .single((0, true))
        }, isTabVisible: { [weak self] in
            self?.feed?.isTabVisible ?? false
        })
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
        }
        if pluginRuntimeObserver == nil {
            pluginRuntimeObserver = NotificationCenter.default.addObserver(forName: ExteralessPluginRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.shortcutsBound, let context = self.currentContext else { return }
                    self.bindPluginRuntime(context: context)
                }
            }
        }
    }

    func update(context: AccountContext) {
        guard !terminated, isPrepared, preparationInput?.rootPath == context.sharedContext.basePath,
              let clientAPIConfiguration else {
            lastError = "Client settings must finish preparation before publishing an account."
            return
        }
        // The privacy-extras integration owns an opaque continuation across the
        // expected hidden-account switch. Its update validates that transition.
        if currentContext !== context {
            clearAccountDomains()
            contextToken = ExteralessClientContextToken()
        }
        currentContext = context
        // Domain initializers may register dynamic keys or read secure storage.
        // Construct them only after the application's shared file was selected.
        if appearance == nil { appearance = ExteralessAppearanceIntegration() }
        if chats == nil { chats = ExteralessChatIntegration() }
        if feed == nil { feed = ExteralessFeedIntegration() }
        if player == nil { player = ExteralessPlayerIntegration() }
        if pills == nil { pills = ExteralessPillIntegration() }
        if privacy == nil { privacy = ExteralessPrivacyIntegration() }
        if privacyExtras == nil { privacyExtras = ExteralessPrivacyExtrasIntegration() }
        if dialogs == nil { dialogs = ExteralessDialogIntegration() }
        if ai == nil { ai = ExteralessAIIntegration() }
        if tools == nil { tools = ExteralessToolsIntegration() }
        if stickers == nil { stickers = ExteralessStickerIntegration() }
        if identity == nil { identity = ExteralessIdentityIntegration() }
        if retention == nil { retention = ExteralessRetentionIntegration() }
        if cloud == nil { cloud = ExteralessCloudIntegration(clientAPI: clientAPIConfiguration) }
        feed?.update(context: context)
        appearance?.update(context: context)
        chats?.update(context: context)
        player?.update(context: context)
        pills?.update(context: context)
        privacy?.update(context: context)
        privacyExtras?.update(context: context)
        dialogs?.update(context: context)
        ai?.update(context: context)
        ExteralessAIHooks.install(ai?.nativeAdapter)
        tools?.update(context: context)
        network?.update(context: context)
        maps?.update(context: context)
        stickers?.update(context: context)
        identity?.update(context: context)
        retention?.update(context: context)
        cloud?.update(context: context)
        if settingsReset == nil { settingsReset = SettingsResetIntegration() }
        settingsReset?.update(context: context)
        ExteralessSettingsSearch.install(context: context, isCurrent: { [weak self, weak context] in
            guard let self, let context else { return false }
            return !self.terminated && self.isPrepared && self.currentContext === context
        })
    }

    /// AppDelegate calls after Runtime publishes this context. The returned
    /// bindings are lazy native capabilities; they never create another Host.
    func bindPluginRuntime(context: AccountContext) {
        guard !terminated, currentContext === context, let token = contextToken, token.isValid else { return }
        let bindings: ExteralessToolsBackupBindings
        if let current = backupBindings {
            bindings = current
        } else {
            bindings = ExteralessPluginRuntime.shared.toolsBackupBindings(context: context)
            backupBindings = bindings
            tools?.configure(backupBindings: bindings, shortcutBindings: nil)
            cloud?.configure(backupBindings: bindings)
        }
        guard !shortcutsBound else { return }
        let controls = ExteralessPluginRuntime.shared.managerControls()
        guard let initialState = controls.snapshot() else { return }
        var confirmedSafeMode = initialState.safeMode
        let worker = settingsWorker
        let shortcuts = ExteralessToolsShortcutBindings(ghostMode: { PrivacyPolicy.current.ghostModeActive }, safeMode: {
            if let state = controls.snapshot() { confirmedSafeMode = state.safeMode }
            return confirmedSafeMode
        }, toggleGhostMode: { [weak self, weak context] in
            guard let self, let context, self.currentContext === context, token.isValid, !Task.isCancelled else {
                throw ExteralessClientWorkError.retiredContext
            }
            let operation = ExteralessClientContextToken()
            let value = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    worker.toggleGhost(context: token, operation: operation) { continuation.resume(with: $0) }
                }
            }, onCancel: { operation.invalidate() })
            guard self.currentContext === context, token.isValid, !Task.isCancelled else { throw ExteralessClientWorkError.retiredContext }
            return value
        }, toggleSafeMode: { [weak self, weak context] in
            guard let self, let context, self.currentContext === context, token.isValid, !Task.isCancelled,
                  let before = controls.snapshot() else { throw ExteralessClientWorkError.retiredContext }
            try await controls.safeMode(!before.safeMode)
            guard self.currentContext === context, token.isValid, !Task.isCancelled,
                  let after = controls.snapshot() else { throw ExteralessClientWorkError.retiredContext }
            confirmedSafeMode = after.safeMode
            return after.safeMode
        })
        shortcutsBound = true
        tools?.configure(backupBindings: bindings, shortcutBindings: shortcuts)
    }

    func clearContext() {
        clearAccountDomains()
        if let privacyExtras {
            privacyExtras.clearContext()
        } else {
            ExteralessHiddenAccounts.shared.clearContext()
        }
    }

    private func clearAccountDomains() {
        settingsReset?.clearContext()
        ExteralessSettingsSearch.retire()
        contextToken?.invalidate()
        contextToken = nil
        backupBindings = nil
        shortcutsBound = false
        currentContext = nil
        presentedAccount.set(nil)
        ExteralessAIHooks.install(nil)
        appearance?.clearContext()
        chats?.clearContext()
        feed?.clearContext()
        player?.clearContext()
        pills?.clearContext()
        privacy?.clearContext()
        dialogs?.clearContext()
        ai?.clearContext()
        tools?.clearContext()
        network?.clearContext()
        maps?.clearContext()
        stickers?.clearContext()
        identity?.clearContext()
        retention?.clearContext()
        cloud?.clearContext()
        tools?.configure(backupBindings: nil, shortcutBindings: nil)
        cloud?.configure(backupBindings: nil)
    }

    /// Published only after AppDelegate installs the ready root behind AppLock.
    /// The hidden-unlock continuation must observe this in addition to raw primary.
    func accountPresentationReady(for identity: PrivacyExtrasAccountIdentity) -> Signal<Bool, NoError> {
        return presentedAccount.get() |> map { $0 == identity }
    }

    func accountPresentationDidBecomeReady(context: AccountContext) {
        guard currentContext === context else { return }
        appearance?.rootDidBecomeReady(context: context)
        presentedAccount.set(exteralessPrivacyExtrasIdentity(context.account))
    }

    func handleToolsShortcut(type: String, context: AccountContext, completion: @escaping (Bool) -> Void) {
        guard currentContext === context, let tools else {
            completion(false)
            return
        }
        if !tools.handleShortcut(type: type, completion: completion) { completion(false) }
    }

    private func reload() {
        guard isPrepared else { return }
        beginPreparation(reload: true)
    }

    func cancelPreparation() {
        terminated = true
        preparationGeneration &+= 1
        preparationActive = false
        retentionRetries.removeAll()
        clearContext()
    }
}
