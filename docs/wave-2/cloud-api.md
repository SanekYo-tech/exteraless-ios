# Cloud / Client API — implementation handoff

Owner: `P-cloud-sync` + `P-client-api`, exactly six inventory IDs. Native source and
55 bounded XCTest methods are authored (51 Core + 4 TelegramCore). **Shared wiring
below is pending coordinator application. Swift/Xcode and UI frames were not run.**
Receipts: [cloud-api-parity.json](cloud-api-parity.json). These six records stay
`partial`; this handoff is not an end-to-end or independent-review pass.

Android legacy import and AI-04/13 credential-origin follow-up are implemented in
[cloud-legacy-remediation.md](cloud-legacy-remediation.md). That contract supersedes
the original legacy-import limitation and raw credential assumptions below.

## Original source findings (read, not inferred from logs)

- `CloudStorageHelper.java:17–18,39–118`: account-scoped
  `bots.invokeWebViewCustomMethod`, bot `exteralesscloudbot` / `8856509355`, methods
  `saveStorageValue`, `getStorageValues`, `getStorageKeys`, `deleteStorageValues`.
- `CloudSettingsHelper.java:58–68,290–433`: defaults false/false/-1,
  1200 ms debounce, `neko_settings[_N]`, `gzip_base64_v1`, 3000-character chunks,
  50-key restore batches. Gzip/Base64 is **not payload encryption**. Original source
  has no E2E key, recovery-key mechanism, ETag or server compare-and-swap.
- `SettingsBackupHelper.java:130–140,150–170`: cloud backs up configuration;
  `aiConfig` (except history) is conditional on include-keys. `nekox_config` is not
  exported: the custom Telegram App hash must not enter our cloud credential list.
- `NekoXConfig.java:40–62,147–211`: selector 0/3, built-in fallback, ID/hash validation,
  restart. Consumers: `ConnectionsManager.java:293`, `LoginActivity.java:3249–3250,
  8573–8574`, `PasskeysController.java:190–193`. Also read NekoConfig Java and NaConfig
  Kotlin preference/CloudSettings listener and credential declarations.

## Implemented source behavior

| Original ID | Native consumer / default |
|---|---|
| `cloudsettingshelper.autoSync` | `cloud.autoSync = false`; `CloudAutoSync` observes real preferences, debounces 1200 ms, admits work only in the foreground for its captured account. A failure alone never schedules a retry. |
| `cloudsettingshelper.includeApiKeys` | `cloud.includeApiKeys = false`; `CloudCredentials.export` does zero Keychain reads when off. When on, it reads the typed AI/translation/transcription whitelist directly from native Keychain, not the redacted snapshot. |
| `cloudsettingshelper.localSyncedDate` | `CloudLocalState.lastSuccessfulSyncMilliseconds = -1`; read-only account/server-scoped metadata, advanced after verified upload or completed restore, never an attempt or an unchanged-content check. |
| `nekox.customApi` | `clientAPI.customApi = 0`, custom = 3; next-launch selection, with immutable per-account authorization pins. |
| `nekox.customAppId` | `clientAPI.customAppId = 0`; validated positive Int32 at native save/admission; built-in ID comes only from supplied BuildConfig. |
| `nekox.customAppHash` | `clientAPI.customAppHash = ""`, native Keychain; fresh secure read at launch, opaque tuple passed to the environment/auth factory, never a cloud/export field. |

### Cloud protocol, conflicts and protection

- `CloudBotStorageTransport` is the actual serializer used by
  `ExteralessCloudTransport`: original four method names, 3000-character values,
  50-key batches, account-owned `bots.invokeWebViewCustomMethod` request. Bot
  resolution checks the immutable ID and bot flag. No bot token or HTTP credential
  is required or embedded. Test-server use fails explicitly: that production bot
  is not assumed to exist in another Telegram environment.
- Native revisions use `neko_ios_v1.r.<uuid>` and immutable
  `neko_ios_v1.c.<uuid>.<index>` chunks. They do not overwrite Android's
  `neko_settings` keys. Envelope version 1 carries the shared Tools archive v2 and
  a separate typed credential collection. Actual native `MTGzip` produces
  `gzip_base64_v1`; inflated data is capped at 1 MiB, with 256 chunks, 1024 total
  storage keys, 128 revision records and up to eight merge parents.
- Every chunk is read back and checksummed before publishing its immutable
  manifest. Publication checks the expected head set before writing and reads it
  back afterwards. Concurrent children remain **two heads**, not last-writer-wins
  destruction. Preview/Restore/Use this device acknowledge a captured head set;
  any intervening remote edit rejects the operation. Historical revisions remain
  selectable. Explicit deletion is namespace-limited, including a separate repair
  action for incomplete uploads/deletions.
- This is revision conflict detection over the original API, **not server CAS**.
  The original service has no conditional write/ETag method. A simultaneous writer
  can commit just after another device's final read; both immutable revisions
  survive and the next read reports the fork. No linearizable remote lock is claimed.
- Protection intentionally matches the original: MTProto transport encryption,
  **no additional end-to-end payload encryption**. Gzip, Base64 and SHA-256 are not
  called encryption. There is no device-only encryption key that would prevent
  another signed-in device from restoring. The UI says this before key inclusion.
  Included keys become local `AfterFirstUnlockThisDeviceOnly`, non-synchronizable
  Keychain entries on restoration. Turning inclusion off does not erase old
  revisions; the native delete action does.
- The whitelist admits assistant keys only for validated service records/default,
  named LLM presets and the enumerated translation/transcription credentials.
  It excludes Telegram App hashes, auth/session/passcode keys, GitHub tokens,
  private history, prompts/roles and arbitrary Keychain services. Portable public
  configuration excludes cloud controls, API identity, account maps, unregistered
  values and dynamic per-chat state. Service URLs reject embedded credentials.
- Credential-bearing cloud calls use the **same native request service/engine**
  with name-only metadata, a redacted reply wrapper and no plugin request/response
  snapshot. They have a 12-second cancellable RPC deadline and no flood/server-error
  retry loop. Cancellation and an inclusion-policy recheck precede later chunks.

### Shared archive / journal / maintenance binding

`ExteralessCloudArchiveHost` consumes the real
`ExteralessToolsBackupBindings`; it does not own a plugin archive, directory journal
or replacement lease. Export calls `ToolsBackupArchive.export(..., plugins: nil)`.
Restore calls `ToolsBackupRestorer.restore` with the existing settings access,
location and maintenance lease. `CloudRestorePlan.verifyLocalPreview` is a no-op
affected-value/presence CAS in `beforeSettingsCommit`; the Tools forward CAS then
catches an edit between that guard and commit. Its recovery journal remains owned
by Tools. Startup recovery/admission remains the Tools/Host coordinator contract.

The native restore callback is:

```swift
CloudSyncSession.Restore
// @MainActor (CloudRestorePlan, Bool, CloudRestoreAdmission)
//     async throws -> CloudRestoreResult
```

`admission.beginCommit()` is called **after** obtaining maintenance. The wait can
be cancelled; an admitted journal transaction finishes even if its screen/account
context closes. Lease completion is once-only. A Tools durability/rollback failure
finishes `needsRecovery`, not a fabricated rollback/resume.

After the public transaction commits, credential import is **add-only SecItemAdd**:
an existing/concurrently changed local key is retained. A key-phase failure reports
`restorePartiallyApplied`, finishes the already committed public transaction and
does not advance the successful-sync date. Retry can add remaining missing keys.
This is not an atomic transaction across the settings file and multiple Keychain
items. Key values never enter Tools' public archive/journal. No plugin get_settings,
Python execution, personal-document search or automatic restore occurs.

### Client API lifecycle and native storage

- `ClientAPILaunchResolver` freezes production and test drafts independently.
  `makeEnvironment` delivers one validated ID/hash tuple to the injected native
  factory. Existing active accounts and already-started authorization flows keep
  their pinned tuple/generation across edits, DC changes, account switches and
  relaunch. A pre-feature authorized account starts from the supplied built-in pair.
- Pins use atomic `SecItemAdd` in `exteraless.client-api`, keyed by
  `pin.v1.<production|test>.<AccountRecordId>`. The public
  `clientAPI.accountIdentity.<environment>.<recordId>` marker records only
  ID/mode/generation. A missing previously pinned Keychain item is an error, **not**
  permission to silently adopt built-in credentials. Already-admitted in-memory
  pins may continue while protected data is unavailable.
- The native editor serializes save operations and writes a recoverable Keychain
  pending draft before updating the hash and public ID/mode CAS. An interrupted
  save blocks a new authorization, while existing pins remain usable. Retrying
  the editor can reuse that pending draft. Disabling preserves the draft; blank
  hash input reuses a key only for the same ID. Input requires positive Int32/32
  hexadecimal characters; the latter is stricter than Android's length-only check.
- A locked/unavailable secure read and invalid/absent build credentials fail
  explicitly. There are no invented API defaults, string-valued credential logs,
  automatic logout, account authorization mutation or publishing actions.
- Supply an **existing entitled** common access group to `ClientAPIKeychain.storage`
  when main app/extensions share pins. The settings-secret backend must match the
  actual `ClientSettings` backend. Default nil invents no entitlement. All native
  editors are main-process-only; the generic editor/SDK exclusions below are part
  of the binding contract.

### Aliases and state receipts

- `NewCloudFeatures.definitions` is canonical; `CloudFeatures` is its Swift alias.
- Explicit `NewCloudFeatures.migrateAndroidAliases(in:)` maps `auto_sync` and
  `include_api_keys`, destination-wins, in the already-selected native settings
  document. Android's global `updated_at` is not attributed to an arbitrary account.
- Explicit `ClientAPIConfigurationStore.migrateAndroidAliases()` maps `custom_api`,
  `custom_app_id`, `custom_app_hash`; the last migrates into native Keychain through
  the real Core migration API. Neither method scans Android files or user documents.
- Local Cloud state is versioned metadata at
  `<root>/exteraless/cloud/<environment>.<userId>.<recordId>.json`. It contains no
  archive or credential. A failure/cancellation leaves the last successful date.

## Exact coordinator hunks — NOT applied by this owner

### C1. MainRoot registration, lifetime and the existing Tools host

File: `TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`.
Retain its current imports/domains/context-identity guard. Add to the corresponding
class/registration/update/clear sites:

```swift
// Properties; supply the real entitled vault/backend here if the app shares pins.
let clientAPIConfiguration = ClientAPIConfigurationStore()
private var cloud: ExteralessCloudIntegration?
private var cloudBackupBindings: ExteralessToolsBackupBindings?

// Append to the connected definition list:
+ NewCloudFeatures.definitions + ClientAPIFeatures.definitions

// update(context:), after selecting/registering the settings file:
if cloud == nil {
    cloud = ExteralessCloudIntegration(clientAPI: clientAPIConfiguration)
    cloud?.configure(backupBindings: cloudBackupBindings)
}
cloud?.update(context: context)

// clearContext(), on identity replacement as well as logout:
cloud?.clearContext()

// Call with the SAME ready object also supplied to Tools, not a second host.
func configureCloud(backupBindings: ExteralessToolsBackupBindings?) {
    cloudBackupBindings = backupBindings
    cloud?.configure(backupBindings: backupBindings)
}
```

The restore button is disabled until this real maintenance binding is supplied.
Core settings, Tools archive/journal/lease and Runtime/MainRoot files were not edited.

### C2. App bootstrap and visible native API failures

File: `TelegramUI/Sources/AppDelegate.swift`, existing block after
`performAppGroupUpgrades`, before `deviceSpecificEncryptionParameters`/account startup:

```swift
do {
    try MainActor.assumeIsolated {
        ExteralessClientRuntime.shared.configure(rootPath: rootPath)
        try ExteralessClientAPIEnvironment.shared.configure(
            builtinApiId: buildConfig.apiId, builtinApiHash: buildConfig.apiHash,
            configuration: ExteralessClientRuntime.shared.clientAPIConfiguration)
    }
} catch {
    let alert = UIAlertController(title: "Client API",
        message: (error as? ClientAPIError)?.errorDescription ?? "Client API configuration failed.",
        preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
    self.mainWindow?.presentNative(alert)
    return true // No account network with an unselected/wrong identity.
}
```

Retain a `Disposable?` on AppDelegate for
`ExteralessClientAPIEnvironment.shared.errors |> deliverOnMainQueue`; present its
non-nil **typed errorDescription** with the same native alert, and dispose with the
other application subscriptions. Subscribe before starting accounts. This exposes
new-login/pin failures while an existing account can still open its API editor.
No raw underlying error, tuple or `NetworkInitializationArguments` is logged.

Every other process constructing account networks must configure the same native
boundary using its real BuildConfig and entitled vault before doing so; extensions
must fail closed rather than silently using stock credentials for a custom pin.

### C3. Resolve where the actual Postbox authorization state is known

File: `TelegramCore/Sources/Account/Account.swift`, in `accountWithId`, at the
`mapToSignal { (accountState, localizationSettings, proxySettings, networkSettings,
appConfig) -> Signal<AccountResult, NoError> in` block, before `makeExclusiveKeychain`:

```swift
let originalNetworkArguments = networkArguments
let apiTestingEnvironment: Bool
if let state = accountState as? AuthorizedAccountState {
    apiTestingEnvironment = state.isTestingEnvironment
} else if let state = accountState as? UnauthorizedAccountState {
    apiTestingEnvironment = state.isTestingEnvironment
} else {
    apiTestingEnvironment = beginWithTestingEnvironment
}
let networkArguments: NetworkInitializationArguments
do {
    networkArguments = try ExteralessClientAPIEnvironment.shared.arguments(
        originalNetworkArguments, recordId: id.int64,
        testingEnvironment: apiTestingEnvironment,
        existingAuthorization: accountState is AuthorizedAccountState)
} catch {
    // The boundary publishes a typed startup error. No fallback, logout or wipe.
    return .complete()
}
```

The local shadow intentionally feeds **all three** following initializedNetwork
calls and both Account constructors. `changedMasterDatacenterId` subsequently uses
that same `self.networkArguments`; `AuthTransfer` already reads it too.

In `standaloneStateManager`, inside the `AuthorizedAccountState` branch and before
its initializedNetwork call, use the same shadow with
`testingEnvironment: authorizedState.isTestingEnvironment, existingAuthorization: true`;
on error return `.single(nil)`. Do not start a supplementary/extension network with
another tuple. These are coordinator Account.swift insertions, not edits by this owner.

`Network.swift:initializedNetwork` already has the actual native consumer:

```swift
var apiEnvironment = MTApiEnvironment(deviceModelName: arguments.deviceModelName)
apiEnvironment.apiId = arguments.apiId
// ... MTContext(... apiEnvironment: apiEnvironment ...), before network activity
```

The ID must come from the resolved arguments above. The API hash belongs to native
auth request construction, not to a nonexistent MTApiEnvironment hash property.

### C4. Login, registration and passkey UI tuple

File: `AppDelegate.swift`, UnauthorizedApplicationContext construction:

```diff
- return UnauthorizedApplicationContext(apiId: buildConfig.apiId, apiHash: buildConfig.apiHash, sharedContext: sharedApplicationContext.sharedContext, account: account, otherAccountPhoneNumbers: otherAccountPhoneNumbers)
+ return UnauthorizedApplicationContext(apiId: account.networkArguments.apiId, apiHash: account.networkArguments.apiHash, sharedContext: sharedApplicationContext.sharedContext, account: account, otherAccountPhoneNumbers: otherAccountPhoneNumbers)
```

This feeds AuthorizationSequenceController's send-code/resend/passkey paths.
Registration uses the resulting existing network. Keep the current active-account
tuple, not the latest editable global draft.

### C5. Protect hash-bearing native requests at both Network builders

File: `TelegramCore/Sources/Network/Network.swift`, both `request` and
`requestWithAdditionalInfo`. Compose with the TL owner's transformation gates:

```diff
- let hasPluginRequestSubscribers = PluginHookRouter.hasSubscribers(.preRequest) || PluginHookRouter.hasSubscribers(.postRequest)
+ let hasPluginRequestSubscribers = !exteralessClientAPIRequestContainsIdentity(data.0)
+     && (PluginHookRouter.hasSubscribers(.preRequest) || PluginHookRouter.hasSubscribers(.postRequest))
@@
- metadata: WrappedRequestMetadata(metadata: WrappedFunctionDescription(data.0), tag: tag),
+ metadata: WrappedRequestMetadata(metadata: exteralessClientAPIRequestLogMetadata(data.0), tag: tag),
```

The helper emits method name + `appHash: set`, even with verbose logging enabled.
Exclude these same methods before a mutation-capable generic plugin boundary too.
Cloud storage already uses a separate name-only native request builder in its owned
directory. This is necessary: the inspected stock Serialization redaction table
does not protect auth `api_hash` parameters.

### C6. Native editor and explicit key-inclusion ownership

`ExteralessSettingsController.swift`, generic definition loop:

```diff
- for definition in snapshot.definitions where definition.section != "AI state" {
+ for definition in snapshot.definitions where definition.section != "AI state"
+     && !ClientAPIFeatures.requiresNativeEditor(definition.key) {
```

`ClientSettingsBridgeExtension.swift`, inside `if member == "setClientSetting"`,
before decoding/writing the value:

```swift
guard !ClientAPIFeatures.requiresNativeEditor(key), key != "cloud.includeApiKeys" else {
    throw BridgeFailure.permission("This setting is managed by the native settings screen")
}
```

The API draft/pin fields must not be individually rewritten by the generic editor
or SDK. The native API action edits the tuple together. The ordinary native Cloud
toggle remains the explicit user control for service-key inclusion.

## Files and build boundary

- Core: `CoreCloudFeatures.swift`, `Cloud*.swift`, `ClientAPI*.swift` in
  `swift/ExteralessCore/Sources/ExteralessCore/`.
- Native provider: `TelegramCore/Sources/ExteralessCloud/**` and
  `TelegramCore/Sources/ExteralessClientAPI/**`.
- Native UI/host: `TelegramUI/Sources/ExteralessClient/Cloud/**`.
- Core tests: `ClientAPITests`, `CloudArchiveTests`, `CloudRemoteTests`,
  `CloudSyncLifecycleTests`, with `CloudClientAPITestSupport`.
- Native tests: `TelegramCore/Tests/CloudTransportTests.swift` and
  `TelegramCore/Tests/ClientAPIRequestMetadataTests.swift`.

Build owner: include these new sources/tests in existing targets. Core imports only
Foundation and conditional Security. Native TelegramCore additionally uses
ExteralessCore/MtProtoKit/Postbox/SwiftSignalKit/internal TelegramApi; native UI uses
AccountContext/Display/ExteralessCore/Foundation/TelegramCore/UIKit and the existing
Tools/PluginList host. No new package/plugin, BUILD edit or generated API schema.

## Verification and remaining constraints

- Local bounded source checks cover UTF-8, whitespace, balanced Swift delimiters,
  Core/UI import boundaries, no token-pattern literals, and receipt ID/path joins.
  The whole-repository `python -B build-system/Make/PostboxImportCheck.py` also
  passed. These checks are **not Swift typechecking**.
- The 55 authored fixtures exercise original bot method serialization, null/missing
  values, chunk ordering/readback, concurrent two-device forks, checksum/size/cycle
  rejection, explicit legacy read and namespace deletion, actual public CAS/Tools
  journal hook, add-only key import, late key failure, default-off/foreground/debounce,
  no failure polling, unload cancellation, lease admission cancellation, successful
  dates, aliases, fresh native hash reads, test/account pin separation, restart,
  interrupted save and missing/locked Keychain pins. Native fixtures use actual
  MTGzip and actual auth function descriptors with synthetic credentials only.
- Python exists here; `swift`/`swiftc` and Apple SDK/XcodeBuildMCP do not. No Swift
  fixture, app build or visual frame result is claimed. Coordinator-reported
  `4b3f7064` / `43653040458` (122 Core, including 28 settings/CAS) is the **baseline**,
  not proof for these files. After a build, run the new Core fixtures with a 30s cap:

```sh
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--package-path", "swift/ExteralessCore", "--skip-build", "--filter", "Cloud|ClientAPI"], check=True, timeout=30)'
```

- **Legacy format adaptation:** the explicit original SharedPreferences importer now
  maps reviewed `nkmrcfg` and `aiConfig` fields through typed rules and reports every
  remaining preference as skipped with its original ID/reason. Stock Telegram
  preferences need a separate engine adapter. See the remediation handoff for
  immutable preview, actual CAS, native credential-origin and tiny-gzip fixtures.
- **API process/entitlement gate:** apply C2–C5 to every native account constructor,
  including extensions, and provide a common already-entitled pin access group.
  Manual re-signing that removes Keychain access is a visible storage prerequisite,
  not a reason to change account API identity. Built-in credentials come from user
  build/CI configuration. No BuildConfig source or credentials were read from logs.
- **Frame expectations before recording:** grouped native Cloud/API screens, dark
  and light, Dynamic Type/RTL, masked empty replacement hash, keyboard-visible ID/hash
  editor, busy/cancel/error rows without overlap. Verify foreground/background,
  context replacement dismissing confirmations, multiple conflict revisions, previous
  revision restore, failed key phase, and restart labels against actual account ID.
  Record and inspect timestamped frames per AGENTS.md before visual acceptance.
- No real Telegram upload/login/account test, remote URL/PAT inspection, personal
  document scan, external plugin execution, commit, push, CI or publishing action
  was performed. Unsigned IPA/manual signing/update behavior remains with Tools.
