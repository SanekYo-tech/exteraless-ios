"""Bounded, offline source contracts; these do not execute Swift or a user account."""

import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
IOS = ROOT / "telegram-ios"
RUNTIME = "submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift"
APP = "submodules/TelegramUI/Sources/AppDelegate.swift"
ACCOUNT = "submodules/TelegramCore/Sources/Account/Account.swift"

spec = importlib.util.spec_from_file_location(
    "final_composition_swift_lexer", IOS / "build-system/Make/PostboxImportCheck.py"
)
lexer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lexer)


def source(path):
    return (IOS / path).read_text(encoding="utf-8")


def body(text, marker):
    start = text.index(marker)
    code = lexer.strip_comments_and_strings(text)
    begin = code.index("{", start)
    depth = 1
    for end in range(begin + 1, len(code)):
        depth += (code[end] == "{") - (code[end] == "}")
        if depth == 0:
            return text[begin + 1:end]
    raise AssertionError("Unterminated Swift body: " + marker)


class FinalAppCompositionContracts(unittest.TestCase):
    def test_worker_loads_complete_schemas_migration_and_private_state_before_ready(self):
        text = source(RUNTIME)
        worker = body(text, "private final class ExteralessClientSettingsWorker")
        prepare = body(worker, "func prepare(")
        self.assertIn("queue.async {", prepare)
        positions = [prepare.index(value) for value in (
            "ClientSettings.shared.configure(storageURL: file, durabilityRootURL: input.durabilityRootURL)",
            "ClientSettings.shared.register(Self.definitions)",
            "ChatFeatures.migrateSettings(in: ClientSettings.shared)",
            "ChatTrackingRulesStore.shared.configure(",
            "exteralessPrivacyExtrasConfigure(rootPath: input.rootPath, durabilityRootURL: input.durabilityRootURL)",
            "ExteralessClientAPIEnvironment.shared.configure(",
            "self.configuration = configuration",
        )]
        self.assertEqual(positions, sorted(positions))
        for family in ("StickerFeatures", "IdentityFeatures", "RetentionFeatures", "NewCloudFeatures", "ClientAPIFeatures", "DialogFeatures", "NewNetworkFeatures", "MapFeatures", "ExteraConfigCompatibility"):
            self.assertIn(family + ".definitions", worker)
        self.assertIn("PlayerFeatures.galleryDefinitions", worker)
        self.assertNotIn("IdentityFeatures.accountDefinitions", text)
        self.assertNotIn("PrivacyExtrasFeatures.privateDefinitions", text)
        actor = body(text, "final class ExteralessClientRuntime {")
        for operation in ("ClientSettings.shared.configure(", "ClientSettings.shared.register(", "ClientSettings.shared.reload(", "ExteralessHiddenAccounts.shared.reload("):
            self.assertNotIn(operation, actor)
        self.assertNotIn("DispatchSemaphore", text)
        self.assertNotIn(".sync {", text)

    def test_no_account_factory_or_test_login_before_successful_settings_signal(self):
        app = source(APP)
        gate = app.index("let sharedContextSignal = self.clientSettingsReady.get()")
        factory = app.index("let sharedContext = SharedAccountContextImpl(", gate)
        self.assertIn("|> take(1)", app[gate:factory])
        self.assertIn("|> mapToSignal", app[gate:factory])
        self.assertLess(app.index("prepareClientSettings(rootPath: rootPath"), gate)
        ready = body(app, "private func prepareClientSettings(")
        self.assertEqual(app.count("clientSettingsReady.set("), 1)
        self.assertLess(ready.index("case .ready:"), ready.index("clientSettingsReady.set(.single(()))"))
        self.assertNotIn("clientSettingsReady.set", ready.split("case let .failed", 1)[1])
        test_login = app.index("let _ = test_loginAndDeleteAccount(")
        self.assertIn("self.clientSettingsReady.get()", app[test_login - 220:test_login])
        root = source(RUNTIME)
        preparation = body(root, "private func beginPreparation(")
        self.assertLess(preparation.index("case let .success(configuration)"), preparation.index("self.preparationValue.set(.ready)"))
        self.assertLess(preparation.index("ExteralessNetworkIntegration()"), preparation.index("self.preparationValue.set(.ready)"))
        self.assertLess(preparation.index("ExteralessMapIntegration()"), preparation.index("self.preparationValue.set(.ready)"))

    def test_retry_and_retired_completion_do_not_publish_stale_context(self):
        root = source(RUNTIME)
        preparation = body(root, "private func beginPreparation(")
        self.assertIn("!self.terminated", preparation)
        self.assertIn("self.preparationGeneration == generation", preparation)
        self.assertIn("self.preparationInput == input", preparation)
        self.assertLess(preparation.index("self.preparationGeneration == generation"), preparation.index("switch result"))
        self.assertIn("beginPreparation(reload: isPrepared)", body(root, "func retryPreparation()"))
        self.assertIn("preparationGeneration &+= 1", body(root, "func cancelPreparation()"))
        update = body(root, "func update(context:")
        self.assertIn("guard !terminated, isPrepared", update)
        self.assertNotIn("configure(rootPath:", update)
        self.assertLess(update.index("feed?.update"), update.index("appearance?.update"))
        self.assertLess(update.index("privacyExtras?.update"), update.index("dialogs?.update"))
        self.assertNotIn("privacyExtras", body(root, "private func clearAccountDomains()"))
        self.assertIn("privacyExtras.clearContext()", body(root, "func clearContext()"))
        self.assertIn("ExteralessClientRuntime.shared.retryPreparation()", source(APP))

    def test_one_native_tools_capability_is_shared_with_cloud_and_real_shortcuts(self):
        root = source(RUNTIME)
        binding = body(root, "func bindPluginRuntime(context:")
        self.assertEqual(root.count(".toolsBackupBindings(context: context)"), 1)
        self.assertIn("if let current = backupBindings", binding)
        self.assertIn("tools?.configure(backupBindings: bindings", binding)
        self.assertIn("cloud?.configure(backupBindings: bindings)", binding)
        self.assertIn(".managerControls()", binding)
        self.assertIn("guard let initialState = controls.snapshot()", binding)
        self.assertIn("try await controls.safeMode(!before.safeMode)", binding)
        self.assertIn("return after.safeMode", binding)
        self.assertNotIn("PluginHost(", root)
        self.assertNotIn(".host", root)
        self.assertNotIn("managerPreferences", root)
        ghost = body(root, "func toggleGhost(context:")
        self.assertEqual(ghost.count("ClientSettings.shared.applyPublic("), 1)
        self.assertIn("expected: before", ghost)
        self.assertIn('before.values[key + "Locked"]', ghost)
        self.assertIn("changes[key] == nil", ghost)
        self.assertNotIn("ClientSettings.shared.set(", ghost)
        self.assertGreaterEqual(ghost.count("context.isValid, operation.isValid"), 2)

    def test_api_selection_uses_native_authorization_and_blocks_auth_hash_hooks(self):
        account = source(ACCOUNT)
        factory = body(account, "public func accountWithId(")
        selected = factory.index("ExteralessClientAPIEnvironment.shared.arguments(")
        self.assertLess(selected, factory.index("makeExclusiveKeychain("))
        self.assertIn("existingAuthorization: accountState is AuthorizedAccountState", factory)
        self.assertIn("state.isTestingEnvironment", factory)
        self.assertEqual(factory.count("arguments: networkArguments"), 3)
        standalone = body(account, "public func standaloneStateManager(")
        self.assertIn("existingAuthorization: true", standalone)
        self.assertLess(standalone.index("ExteralessClientAPIEnvironment.shared.arguments("), standalone.index("initializedNetwork("))
        self.assertIn("UnauthorizedApplicationContext(apiId: account.networkArguments.apiId, apiHash: account.networkArguments.apiHash", source(APP))
        network = source("submodules/TelegramCore/Sources/Network/Network.swift")
        self.assertEqual(network.count("let hasPluginRequestSubscribers = !exteralessClientAPIRequestContainsIdentity(data.0)"), 2)
        self.assertEqual(network.count("metadata: exteralessClientAPIRequestLogMetadata(data.0)"), 2)
        self.assertEqual(network.count("exteralessPrivacyRequestError(network: self, description: data.0, body: requestPayload)"), 2)
        for entry in ("func requestWithAdditionalInfo<T>", "func request<T>"):
            request = body(network, entry)
            self.assertLess(request.index("let requestPayload = data.1.makeData()"), request.index("exteralessPrivacyRequestError("))
            self.assertEqual(request.count("let requestPayload ="), 1)
        tl = source("submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift")
        entry = body(tl, "private func tlTransformedRequestEvents<T>")
        self.assertIn("let permitsPluginEvents = !exteralessClientAPIRequestContainsIdentity(data.0) && tlRequestTransformsEnabled()", entry)
        self.assertIn("reserveIfNeeded(accountRecordId: network.accountRecordId, transformsEnabled: permitsPluginEvents)", entry)
        self.assertIn("submission: submission, permitsPluginEvents: permitsPluginEvents", entry)
        prepare = body(tl, "private func prepare()")
        private_request = body(prepare, "if exteralessClientAPIRequestContainsIdentity(self.data.0)")
        self.assertIn("observePre: false, allowPostTransform: false", private_request)
        self.assertIn("return", private_request)
        self.assertNotIn("decodeRequest", private_request)
        self.assertLess(prepare.index("exteralessClientAPIRequestContainsIdentity"), prepare.index("codec.decodeRequest"))
        self.assertIn("metadata: exteralessClientAPIRequestLogMetadata(description)", tl)
        self.assertIn("exteralessPrivacyRequestError(network: network, description: description, body: body)", tl)

    def test_extension_bootstraps_preserve_supplied_identity_and_os_container(self):
        sites = {
            "Telegram/NotificationService/Sources/NotificationService.swift": ("standaloneStateManager(", ".notificationService"),
            "Telegram/Share/ShareRootController.swift": ("ShareRootControllerImpl(initializationData:", ".shareExtension"),
            "Telegram/NotificationContent/NotificationViewController.swift": ("NotificationViewControllerImpl(initializationData:", ".shareExtension"),
            "Telegram/SiriIntents/IntentHandler.swift": ("return currentAccount(", ".shareExtension"),
        }
        for path, (factory, role) in sites.items():
            with self.subTest(path=path):
                text = source(path)
                self.assertLess(text.index("PasscodeEnvironment.shared.configure"), text.index("ExteralessClientAPIEnvironment.shared.configure"))
                self.assertLess(text.index("RetentionFeatures.definitions"), text.index("ExteralessRetentionProcessConfiguration("))
                self.assertLess(text.index("ExteralessRetentionProcessConfiguration("), text.index(factory))
                self.assertIn("role: " + role, text)
                self.assertIn("durabilityRootURL: appGroupUrl", text)
                self.assertIn("ClientAPIKeychain.storage(accessGroup: try PasscodeEnvironment.shared.sharedAccessGroup())", text)
                self.assertIn("settingsSecrets: ClientSecrets.systemStore()", text)
                self.assertIn("ChatFeatures.migrateSettings(in: ClientSettings.shared)", text)
                self.assertLess(text.index("ExteralessClientAPIEnvironment.shared.configure"), text.index(factory))
                self.assertIn("ExteralessAccountRetentionEnvironment.shared.setUnavailable()", text)

    def test_retention_is_writer_owned_configured_and_ready_before_replay(self):
        text = source(ACCOUNT)
        unauthorized = body(text, "public class UnauthorizedAccount")
        self.assertNotIn("exteralessRetentionAccount", unauthorized)
        factory = body(text, "public func accountWithId(")
        positions = [factory.index(value) for value in (
            "let retentionScope = ExteralessAccountRetentionScope(",
            "let recovery = ExteralessAccountRetentionRecovery(",
            "return exteralessAccountRetentionStartup(recovery:",
            "guard startup.admitTransfer",
            "return Account(",
        )]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("retentionScope.account.isReadinessCurrent(readiness) && retentionScope.transferToWriter()", factory)
        self.assertNotIn("exteralessRetentionReady", text)
        account = body(text, "public class Account {")
        self.assertIn("self.exteralessRetentionScope = retentionScope", account)
        self.assertIn("auxiliaryMethods: auxiliaryMethods, retentionScope: retentionScope", account)
        standalone = body(text, "public func standaloneStateManager(")
        self.assertLess(standalone.index("ExteralessAccountRetentionScope("), standalone.index("retentionScope.account.awaitReadiness()"))
        self.assertLess(standalone.index("retentionScope.account.awaitReadiness()"), standalone.index("initializedNetwork("))
        self.assertIn("case let .failure(error): return .single(.failure(error))", standalone)
        self.assertIn("retentionScope.account.isReadinessCurrent(readiness) && retentionScope.transferToWriter()", standalone)
        self.assertIn("retentionScope: retentionScope", standalone)
        self.assertIn("afterDisposed { retentionScope.cancelBeforeTransfer() }", standalone)
        state = source("submodules/TelegramCore/Sources/State/AccountStateManager.swift")
        self.assertIn("private let retentionScope: Disposable?", state)
        self.assertLess(state.index("self.operationDisposable.dispose()"), state.index("self.retentionScope?.dispose()"))
        configuration = source("submodules/TelegramCore/Sources/ExteralessRetention/RetentionProcessScope.swift")
        self.assertIn("snapshot.lastError == nil", configuration)
        self.assertIn("keys.isSubset(of: Set(snapshot.definitions.map", configuration)
        self.assertIn("self.role == .mainApplication", configuration)

    def test_pfr01_every_environment_transition_reaches_the_shared_writer_scope(self):
        text = source(ACCOUNT)
        snapshot = body(text, "public struct ExteralessAccountRetentionSnapshot")
        self.assertIn("public let version: UInt64", snapshot)
        self.assertIn("Result<ExteralessRetentionProcessConfiguration, ExteralessRetentionError>", snapshot)
        self.assertIn("version: self.version", snapshot)
        self.assertIn("?? .unavailable", snapshot)
        binding = body(text, "func exteralessObserveRetentionConfiguration(")
        self.assertIn("environment.updates.start(next: { receive($0.configurationState) })", binding)
        self.assertNotIn("guard let", binding)
        scope = body(text, "final class ExteralessAccountRetentionScope")
        self.assertIn("exteralessObserveRetentionConfiguration(environment: environment", scope)
        self.assertIn("account?.updateConfiguration(state)", scope)
        self.assertNotIn("deliverOn", scope)
        for marker in ("public func accountWithId(", "public func standaloneStateManager("):
            self.assertIn("ExteralessAccountRetentionScope(", body(text, marker))
        worker = body(source(RUNTIME), "func prepare(")
        self.assertEqual(worker.count("ExteralessAccountRetentionEnvironment.shared.setUnavailable()"), 2)

    def test_pfr02_publication_has_one_versioned_state_and_reentrant_monotonic_drain(self):
        text = source(ACCOUNT)
        environment = body(text, "public final class ExteralessAccountRetentionEnvironment")
        self.assertNotIn("ValuePromise<", environment)
        self.assertNotIn("snapshot = nil", environment)
        self.assertIn("result: .failure(.unavailable)", environment)
        self.assertIn("observer.offer(current)", environment)
        self.assertIn("self.stateSignal(writer: true)", environment)
        store = body(environment, "private func store(")
        self.assertIn("self.version &+= 1", store)
        self.assertIn("self.snapshot = snapshot", store)
        self.assertIn("Array(self.writerObservers.values) + Array(self.observers.values)", store)
        unavailable = body(environment, "public func setUnavailable(")
        self.assertLess(unavailable.index("self.lock.unlock()"), unavailable.index("self.publish(publication)"))
        configure = body(environment, "public func configure(")
        self.assertLess(configure.index("self.observeSettings"), configure.index("snapshot: self.readSnapshot()"))
        self.assertIn("self.readSnapshot().lastError != nil || self.current.error != nil", configure)
        observer = body(text, "private final class ExteralessRetentionStateObserver")
        self.assertIn("guard !self.emitting else", observer)
        self.assertIn("state.version > $0", observer)
        self.assertIn("state.version > $0.version", observer)
        self.assertIn("self.lock.unlock()\n            self.next(pending)\n            self.lock.lock()", observer)

    def test_pfr03_real_notification_caller_owns_startup_before_transfer(self):
        service = source("Telegram/NotificationService/Sources/NotificationService.swift")
        handler = body(service, "private final class NotificationServiceHandler")
        self.assertIn("private let startup: ExteralessStateManagerStartupLifetime", handler)
        self.assertIn("self.startup.start({ _ in combineLatest", handler)
        self.assertIn("strongSelf.startup.start({ token in standaloneStateManager(", handler)
        self.assertIn("startupToken: token", handler)
        self.assertNotIn("let _ = (standaloneStateManager", handler)
        self.assertIn("case let .failure(error):", handler)
        self.assertIn("self.startup.dispose()", body(handler, "deinit"))
        delivery = body(service, "private final class ExteralessNotificationDelivery")
        finish = body(delivery, "func finish(")
        self.assertLess(finish.index("self.startup.dispose()"), finish.index("self.isFinished.swap(true)"))
        caller = body(service, "final class NotificationService: UNNotificationServiceExtension")
        receive = body(caller, "override func didReceive(")
        self.assertLess(receive.index("self.currentDelivery.swap(delivery)?.finish()"), receive.index("self.impl.swap(nil)"))
        for marker in ("deinit", "override func serviceExtensionTimeWillExpire()"):
            operation = body(caller, marker)
            self.assertLess(operation.index("startup.dispose()"), operation.index("self.impl.swap(nil)"))
        lease = body(source(ACCOUNT), "final class ExteralessRetentionWriterLease")
        self.assertIn("self.disposeImpl != nil, !self.transferred", lease)
        self.assertIn("let dispose = self.transferred ? nil : self.disposeImpl", lease)
        lifetime = body(source(ACCOUNT), "public final class ExteralessStateManagerStartupLifetime")
        self.assertIn("self.subscription = holder", lifetime)
        self.assertIn("previous?.dispose()", lifetime)
        self.assertIn("holder.set(signal.start", lifetime)
        self.assertIn("deinit { self.dispose() }", lifetime)

    def test_pfr04_recovery_is_finite_pre_account_and_does_not_become_record_removal(self):
        text = source(ACCOUNT)
        recovery = body(text, "public final class ExteralessAccountRetentionRecovery")
        self.assertIn("owner.awaitReadiness(timeout: 5)", recovery)
        self.assertIn("owner.retryReadiness(timeout: 5)", recovery)
        self.assertIn("owner.resetArchiveForRecovery()", recovery)
        continuation = body(recovery, "func continueStartup<")
        self.assertGreaterEqual(continuation.count("self.isCurrent(token)"), 2)
        self.assertIn("guard self.isCurrent(token) else { self.fail(.configurationUnavailable); return }\n                guard let writer = construct(prepared, startup)", continuation)
        self.assertIn("self.attempt == attempt", continuation)
        self.assertIn("self.finished = true", continuation)
        funnel = body(text, "func exteralessAccountRetentionStartup<")
        self.assertIn("subscriber.putNext(.recovery(recovery))", funnel)
        self.assertIn("recovery.continueStartup", funnel)
        self.assertIn("recovery.dispose()", funnel)
        loader = source("submodules/TelegramUI/Sources/SharedAccountContext.swift")
        self.assertIn("case .retentionRecovery:\n                                return .single(.retentionRecovery(id))", loader)
        self.assertIn("return .ready(readyAccounts, recovering: recoveringAccountIds)", loader)
        self.assertIn("&& recoveringAccountIds.isEmpty && !authRecovery", loader)
        self.assertIn("accounts.contains(where: { $0.1.account === account })", loader)
        self.assertIn("!ExteralessHiddenAccounts.shared.isHidden(exteralessPrivacyExtrasIdentity($0.1.account))", loader)
        self.assertIn("self.accountDifferenceDisposable.dispose()", loader)
        app = source(APP)
        prepare = body(app, "private func prepareClientSettings(")
        self.assertLess(prepare.index("ExteralessAccountRecoveryCenter.shared.pending"), prepare.index("ExteralessClientRuntime.shared.prepare("))
        presenter = body(app, "private func presentClientRetentionRecoveryIfNeeded()")
        self.assertIn("self.clientSettingsPrepared, !self.clientSettingsPreparing", presenter)
        self.assertIn("entry.recovery.currentStatus == entry.status", presenter)
        self.assertIn("retryAccountRetention(recovery)", presenter)
        self.assertIn("retryAccountRetention(recovery, resetArchive: true)", presenter)
        self.assertNotIn("beginNewAuth", presenter)
        root = source(RUNTIME)
        retry = body(root, "func retryAccountRetention(")
        self.assertIn("beginPreparation(reload: true)", retry)
        preparation = body(root, "private func beginPreparation(")
        self.assertLess(preparation.index("case let .success(configuration)"), preparation.index("recovery.retry()"))

    def test_pfr_native_fixtures_use_actual_publication_scope_and_factory_seams(self):
        fixture = source("submodules/TelegramCore/Tests/PFRAppIntegrationTests.swift")
        fast = body(fixture, "final class PFRAppIntegrationTests")
        self.assertIn("ExteralessAccountRetentionEnvironment(readSnapshot:", fast)
        self.assertIn("environment.errors.start", fast)
        self.assertIn("environment.states.start", fast)
        self.assertIn("releaseError.wait(timeout: .now() + 0.5)", fast)
        self.assertIn("ExteralessStateManagerStartupLifetime()", fast)
        self.assertIn("ExteralessRetentionWriterLease(dispose:", fast)
        native = body(fixture, "final class PFRNativeAccountStartupTests")
        self.assertIn("ProcessInfo.processInfo.systemUptime + 25", native)
        self.assertIn("openPostbox(", native)
        self.assertIn("afterFileReplace: { try fault.check() }", native)
        self.assertIn("ExteralessAccountRetentionScope(account: owner, environment: environment)", native)
        self.assertIn("postbox.setCanBeginTransactions(false", native)
        self.assertIn("owner.operationScope.makeWork()", native)
        self.assertIn("exteralessAccountRetentionStartup(recovery:", native)
        self.assertIn("ExteralessAccountRecoveryCenter.shared.pending", native)
        self.assertIn("recovery.resetRetainedArchive()", native)
        self.assertIn("self.assertCounters(transaction)", native)
        self.assertNotRegex(fixture, r"\b(?:Account|Network)\(")

    def test_final_notification_effects_keep_the_same_admission_after_async_hops(self):
        text = source("submodules/TelegramUI/Sources/ApplicationContext.swift")
        begin = text.index("self.notificationMessagesDisposable.set((exteralessPrivacyExtrasNotifications")
        end = text.index("self.termsOfServiceUpdatesDisposable.set", begin)
        consumer = text[begin:end]
        self.assertIn("let admission = delivery.admission", consumer)
        self.assertIn("return (filtered, admission)", consumer)
        self.assertIn("messageList, admission in", consumer)
        for effect, operation in (("sound", "serviceSoundManager.playIncomingMessageSound()"), ("vibration", "serviceSoundManager.playVibrationSound()"), ("enqueue", "strongSelf.notificationController.enqueue(")):
            guarded = body(consumer, "admission.performIfCurrent(account: strongSelf.context.account, effect: ." + effect + ")")
            self.assertIn(operation, guarded)
        self.assertNotIn("ExteralessNotificationAdmission.capture", consumer)
        fixture = source("submodules/TelegramCore/Tests/FinalAppNotificationAdmissionTests.swift")
        self.assertEqual(len(re.findall(r"    func test\w+", fixture)), 4)
        self.assertIn("exteralessAdmittedNotificationStream", fixture)
        self.assertNotRegex(fixture, r"\b(?:Account|Network)\(")
        self.assertNotIn("openPostbox(", fixture)

    def test_native_editor_ownership_and_deferred_tracking_keep_raw_boundaries(self):
        settings = source("submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift")
        self.assertIn("!ClientAPIFeatures.requiresNativeEditor(definition.key)", settings)
        self.assertIn("!ExteraConfigCompatibility.keys.contains(definition.key)", settings)
        bridge = source("submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift")
        self.assertIn("ClientSettingValue.decodeJSON(json)", bridge)
        self.assertIn('ClientAPIFeatures.requiresNativeEditor($0) || $0 == "cloud.includeApiKeys"', bridge)
        self.assertIn('!ClientAPIFeatures.requiresNativeEditor(key), key != "cloud.includeApiKeys"', bridge)
        self.assertIn("ExteraConfigCompatibility.applyPublicJSON(json, to: settings)", bridge)
        app = source(APP)
        clean = body(app, "private func clientCleanOpeningURL(")
        self.assertIn("guard self.clientSettingsPrepared", clean)
        self.assertIn("!exteralessPrivacyExtrasIsRecoveryRoute(url)", clean)
        self.assertGreaterEqual(app.count("clientCleanOpeningURL(url)"), 5)
        share = source("submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift")
        self.assertIn(".text(exteralessCleanIncomingLinkText(text))", share)
        self.assertIn("let additionalText = exteralessCleanIncomingLinkText(additionalText)", share)
        self.assertIn("requireStars: requireStars, items: contents, silently: silently, additionalText: additionalText", share)


if __name__ == "__main__":
    unittest.main()
