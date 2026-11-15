# Final app composition — applied source receipt

App/Cloud/Tools composition, canonical Chat migration and the assigned
PR03/PR05/PR14 consumer/process fixes are applied. **2026-11-15 follow-up:
PFR01–PFR04 App bindings, SDK01 and the handed-off PFR05 coding registration are
applied; App-owned source is frozen for coordinator/native handoff.** This receipt describes source
wiring, not a Swift, UIKit, APNs, storage-fault or visual execution pass.

## MainRoot and startup readiness

`TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift` now retains and
updates Sticker, Identity, Retention and Cloud alongside the existing domains:

- `StickerFeatures.definitions` / `ExteralessStickerIntegration()`.
- `IdentityFeatures.definitions` / `ExteralessIdentityIntegration()`;
  **accountDefinitions are not registered globally**.
- `RetentionFeatures.definitions` / `ExteralessRetentionIntegration()`.
- `NewCloudFeatures.definitions`, `ClientAPIFeatures.definitions` /
  `ExteralessCloudIntegration(clientAPI: preparedConfiguration)`.

Feed updates before Appearance; Privacy Extras updates before Dialogs. Existing
AI hooks, Player gallery definitions, Pills, Network and Maps remain composed.
Ordinary domains clear on context replacement. Privacy Extras keeps its instance
and expected hidden-account continuation until genuine teardown/logout.

### Serial preparation, then account factory

`ExteralessClientSettingsWorker` owns a serial DispatchQueue. Initial preparation:

1. Select the actual shared settings file, with the **caller-provided OS container**
   as `durabilityRootURL`; the metadata path is not substituted as that root.
2. Register the complete public definition set.
3. Run `ChatFeatures.migrateSettings(in: ClientSettings.shared)` atomically, then
   load `ChatTrackingRulesStore` from the real root's override/bundled rules.
4. Publish a fully validated main-process retention configuration.
5. Prepare the native private settings store using the configured PasscodeEnvironment.
6. Configure the launch API resolver with supplied BuildConfig credentials and an
   account-pin vault in the actual entitled `sharedAccessGroup()`.
7. On main, install Network/Maps and UI entry points, then publish `.ready`.

AppDelegate's `sharedContextSignal` begins with `clientSettingsReady.get() |> take(1)`;
the existing presentation-data/SharedAccountContext/AppLock/account factory is
inside the following lazy pipeline. The test-login branch has the same gate.
Foreground tasks, notification wakeup and ordinary URL routes continue through
these prepared shared/authorized-context signals.

No semaphore or synchronous worker wait was added to main. Root update(context:)
does not reconfigure/register the store on every account. Reload runs on the same
worker, preserving the launch API selection. Prepared path/container/API inputs are
pinned, and completion checks the preparation generation and termination state.

Failure publishes a non-secret recovery message and a working native **Retry**
action; scene attachment retries presentation if the window was not attached yet.
The initial readiness promise is never emitted for failure. An invalid tracking
override is preserved and participates in recovery rather than being silently
accepted. Existing loaded settings are not replaced with defaults during reload.

AppDelegate still publishes `accountPresentationDidBecomeReady` only after installing
the matching ready root. The hidden-account wait therefore retains its actual UI
readiness boundary, separately from settings readiness and PIN authorization.

### SDK01 — actual global compatibility registration

Both hunks of `sdk-config-binding-root.patch` are applied:
`ExteralessClientSettingsWorker.definitions` appends
`ExteraConfigCompatibility.definitions`, and `ExteralessSettingsController`
excludes `ExteraConfigCompatibility.keys` from generic feature rows. The **22
global Core keys / 44 SDK storage overloads** consequently use the prepared
global catalog. The provider remains a validator/reader/writer of that catalog;
registration is performed by the Root before `.ready`.

The extension roots declare partial Privacy/Chat/Retention/API catalogs. The
compatibility group belongs to the full MainRoot catalog. Native-editor API gates,
the coordinator-applied Tools four-mode definitions and Appearance three-section
definitions retain their actual definition chains. SDK's native registration probe
must consume this Root set and exercise the real bridge; no native overload pass
is claimed by the source checks below.

## Tools / Cloud: one native binding value

After ClientRuntime updates the account and PluginRuntime publishes that same
context, AppDelegate calls `bindPluginRuntime(context:)`.

- Exactly one call per context to
  `ExteralessPluginRuntime.shared.toolsBackupBindings(context:)` supplies the cached
  `ExteralessToolsBackupBindings` value to **both** Tools and Cloud. This type is a
  struct; its same native settings/maintenance closures are reused, not rebuilt by
  another Host or independent storage manager.
- Shortcuts bind only after `managerControls().snapshot()` is available. Safe-mode
  state comes from that native snapshot, with the last confirmed snapshot retained
  for display; changes call `controls.safeMode(...)` and return the confirmed result.
  No fake Core safe-mode setting, private Runtime field or terminal stop/start is used.
- Ghost uses one immutable snapshot, `PrivacyPolicy.ghostModeChanges`, and one
  `applyPublic(..., expected: before)`. Both the locked flags and unchanged packet
  fields used to choose direction participate in CAS. There is no loop of `set`.
- Queued work checks context/operation tokens before the atomic write; completion
  rechecks context and Task cancellation. Cancellation never holds a main-thread
  lock across disk I/O. A write already admitted may finish, but retired UI cannot
  announce success. Native presence/read policies consume the published settings.
- Clearing a context drops both bindings and shortcut admission. An admitted Tools
  maintenance transaction retains its own lease to finish through the existing
  manager-aware recovery protocol. Startup recovery remains before `host.start` in
  Runtime; this integrator did not edit Runtime or introduce a second recovery owner.
- Cloud's existing opaque, origin-bound AI credential envelope/restore implementation
  is passed through its existing archive host; this wiring does not decode or rebuild it.

## Cloud C1–C6

| Contract | Actual applied sites |
| --- | --- |
| C1 | MainRoot definitions, prepared `ClientAPIConfigurationStore`, Cloud lifetime and same Tools bindings. |
| C2 main | Serial Root worker configures API before readiness. AppDelegate subscribes to typed `errors` before starting preparation/accounts; no underlying tuple/hash is logged. |
| C2 processes | NotificationService handler, ShareRootController, NotificationViewController and Siri DefaultIntentHandler configure the same boundary before their account-producing paths. Each uses its actual BuildConfig (or supplied initialization tuple), OS `appGroupUrl`, and already-configured Passcode group. Errors stop construction/cancel the extension or emit nil for Siri. |
| C3 | `Account.accountWithId`: determine environment and existing authorization from actual Postbox state, resolve one local `networkArguments` shadow before keychain/network construction, and feed all three branches plus Account constructors. `standaloneStateManager` resolves its authorized tuple before its network. |
| C4 | AppDelegate creates `UnauthorizedApplicationContext` with `account.networkArguments.apiId/apiHash`, not the latest global draft or BuildConfig fallback. DC/auth transfer continues to use stored arguments. |
| C5 | Both Network builders disable generic request snapshots for hash-bearing auth methods and use name-only metadata. The coordinator-applied TLN04 shared entry uses `reserveIfNeeded` with `permitsPluginEvents = false` for private methods; queued private requests bypass the decoder and submit their original body with both observation and post-transform disabled. Request log metadata retains the helper. |
| C6 | Generic native settings omit API-owned fields. ClientSettingsBridgeExtension refuses API fields and `cloud.includeApiKeys` through both single and bulk writes. Bulk validation uses the strict codec and forwards the original opaque JSON to the existing atomic implementation. |

The settings-secret reader uses the same `ClientSecrets.systemStore()` backend as
the existing shared settings store; only the **pin vault** selects the common access
group. No secret backend migration or new entitlement was introduced. API hashes
come from existing BuildConfig/secure storage, never repository secret values copied
into source. Missing/invalid selection does not construct a fallback network.

Constructor audit found the main AppDelegate, NotificationService, Siri,
NotificationContentContext (reached from its prepared outer controller), and
ShareExtensionContext (reached from prepared ShareRootController). The native API
argument-copy helper is a copier, not a separate process bootstrap.

## PR05 / PR14 — retention belongs to each actual writer

All five process roots register the complete Retention definitions before creating
`ExteralessRetentionProcessConfiguration` from a successful cached snapshot and the
actual OS durability root. Roles are `.mainApplication`, `.notificationService`,
and the contract's non-maintenance `.shareExtension` role for Share and other
non-service extensions (Siri/notification content).

`ExteralessAccountRetentionEnvironment` in Account.swift is the consumer-side
publication boundary. It accepts only the same role/root for a process, revalidates
the current memory snapshot under its state lock, and publishes one versioned
success/unavailable state. The PFR contract below supersedes the original
unversioned-nil and Bool-only consumer wiring.

- The authorized factory creates `ExteralessAccountRetentionScope` on its actual
  Postbox **before Network and Account construction**. The same scope, owner and
  configuration subscription transfer into Account and its StateManager.
- `standaloneStateManager` creates that scope for its distinct writing Postbox,
  awaits typed retention readiness, then constructs its network/state manager.
- Both paths pass the optional Disposable scope into `AccountStateManager.Impl`.
  Impl disposes it after native operation subscriptions. Account no longer disposes
  retention ahead of the queued writer teardown. UnauthorizedAccount has no owner.
- Both cache-eviction setup paths consume typed readiness and revalidate its token
  at their final callback, including the main-queue hop.
- Cancellation before transfer disposes the scope even if the returned Signal is
  retained; the writer lease accepts one transfer and one disposal only.
- The helper's real role/cross-process media lock/journal implementation remains with
  the Retention owner. The app does not substitute projected state, alter replay
  PTS/QTS/sequence values, or create a second service for the same Postbox/MediaBox.

## PFR01–PFR04 — exact applied consumer contracts

The owner API is the frozen `retention-process-scope-contract.md` PFR addition.
The following App-side interfaces are implemented in `Account.swift`:

| Boundary | Exact contract |
| --- | --- |
| `ExteralessAccountRetentionSnapshot` | `version: UInt64`, `result: Result<ExteralessRetentionProcessConfiguration, ExteralessRetentionError>`; `configurationState` maps the **same version** to `.available(configuration)` or `.unavailable`. |
| Environment | `current` is a non-optional snapshot; `states: Signal<ExteralessAccountRetentionSnapshot, NoError>` replays current state; `errors` is the failure-filtered projection of that stream. `setUnavailable(_ error: ExteralessRetentionError = .unavailable)` publishes a new version. |
| Writer binding | `exteralessObserveRetentionConfiguration(environment:receive:) -> Disposable` forwards every `configurationState` directly to `owner.updateConfiguration(_:)`. Both factories use `ExteralessAccountRetentionScope`; no nil filter or main-queue delivery sits between publication and the owner. |
| Authorized result | `AccountResult.retentionRecovery(ExteralessAccountRetentionRecovery)` is a value distinct from unauthorized/nil. Failure is emitted before a full Account; the subscription remains available for explicit retry. |
| Standalone result | `ExteralessStandaloneStateManagerResult = Result<AccountStateManager?, ExteralessRetentionReadinessFailure>`; `standaloneStateManager(..., startupToken: ExteralessStateManagerStartupToken? = nil)` returns `Signal<ExteralessStandaloneStateManagerResult, NoError>`. Retention failure is terminal; ordinary unavailable/non-authorized cases retain `.success(nil)`. |
| Recovery | `retry()`, `resetRetainedArchive()`, `dispose()` and `currentStatus`; status is `.checking`, `.failed(ExteralessRetentionReadinessFailure)`, `.ready` or `.cancelled`. `ExteralessAccountRecoveryCenter.shared.pending` publishes `[ExteralessAccountRecoveryEntry]`, each containing a handle and an immutable status snapshot. |

### PFR01 / PFR02: revocation and ordered publication

Every invalid configuration, role/root mismatch and explicit preparation failure
gets its own version. Successful recovery gets a newer version. The owner rejects
older/equal versions and synchronously revokes policy, work epoch and readiness for
unavailable states through its supplied API.

Environment memory commits happen under its lock; callbacks run after unlock.
Writer subscriptions are offered before presentation/error subscriptions. Each
observer has an independent monotonic drain with a pending newer state and a
reentry guard. A held old error observer cannot publish an unversioned nil after a
new success, block another producer's recovery, or change a new subscriber's replay
back to stale state. Initial observation is installed before the first cache sample.
Settings errors, including an unrelated-key commit failure, participate in
revalidation; successful reload republishes the actual coherent cached policy.

Main worker and all four extension preparation catches explicitly publish
unavailable. The owner-side epoch/media/readiness implementation remains the
Retention author's frozen code.

### PFR03: the real NotificationService caller owns startup

`NotificationServiceHandler` and its delivery share an
`ExteralessStateManagerStartupLifetime`. It retains the initial account-manager
subscription and replaces it with the actual standalone startup subscription.
Replacement, expiry, completion, handler deinit and extension deinit dispose it
before dropping the queue-local handler. Delivery `finish` revokes startup first.

A generation token is checked after readiness and immediately before metadata
transfer. The token's transfer mutex covers only the lease claim: network
construction, observers and disposal run outside it. A cancelled generation cannot
transfer a late scope. `ExteralessRetentionWriterLease` cancels an untransferred
owner exactly once; after transfer the StateManager lifetime controls disposal.
This uses explicit disposal, not `NativeActionDisposable.deinit` behavior.

### PFR04: bounded failure and pre-Account UI recovery

`exteralessAccountRetentionStartup` is the actual authorized-factory pipeline.
`awaitReadiness(timeout: 5)` produces typed success/failure. A corrupt/unsupported
index reaches the factory and recovery center before its network producer is
started. Retry replaces both the readiness and pending network subscription; a
superseded attempt cannot construct an Account. Readiness and lifetime are checked
after the phone-number hop and again at final transfer. Empty preparation also
produces a recovery result. The API-pin argument selection remains before this
pipeline and supplies its original authorized tuple.

`SharedAccountContext` treats recovery as a processed-but-unavailable record,
allowing healthy factories to finish. It excludes recovery records from the
nil-account deletion path and from `beginNewAuth`. A recovering primary falls back
only to a visible available account. Later `combineLatest` emissions reuse the
already installed Account object rather than resetting its context. Loader
subscriptions now have explicit ownership/disposal. `currentAccount` forwards the
new result; Siri produces nil and the debug test-login path produces its typed
generic error. Cleanup's recovery branch retains its pending record.

AppDelegate subscribes to recovery before preparation starts and can present the
native alert without an AuthorizedApplicationContext. Messages contain no account
names/numbers. **Retry** and the explicit main-role **Reset retained archive** action
go through `ExteralessClientRuntime.retryAccountRetention`: the serial Root worker
must successfully reload public/private settings before resuming that handle once.
Alert actions recheck handle/status identity. **Later** leaves healthy accounts
usable; pending recovery is offered again on foreground. No archive reset, login
transition or Postbox removal is performed merely because readiness failed.

The standalone factory returns its typed failure to the actual service handler,
which completes through the existing empty/privacy-filtered notification path.

### PFR05 handed-off coding insertion

The one-line `retention-followup-coding-hunk.patch` is applied in
`AccountManager.swift`: `registerExteralessRetentionResourceCoding()` immediately
follows the existing `LocalFileMediaResource` declaration in the once-only coding
initialization. Retired-resource routing and its native tests remain the
Retention owner's implementation; this is the common-bootstrap insertion only.

### Prepared native regressions

`TelegramCore/Tests/PFRAppIntegrationTests.swift` contains **10 unexecuted XCTest
methods in two classes**:

- `PFRAppIntegrationTests` (**7**): two-producer held-error publication and reentrant
  recovery; cancellation at ready/network waits; successful writer transfer;
  replacement/deinit; superseded retry; readiness revoked at the network hop.
  Controlled waits are at most **0.5 s**. The lifetime and transfer lease are the
  production implementations, with injected producers and disposal recorders.
- `PFRNativeAccountStartupTests` (**3**): both writer roles against a real encrypted
  disposable Postbox and the real ClientSettings post-rename failure hook; actual
  factory/presenter corrupt-index failure followed by fixture repair; unsupported
  index followed by explicit reset. These check the 60-day row, committed 90-day
  cache/error, invalidated work/readiness, version recovery, no pre-ready network
  construction, exactly one continuation and unchanged PTS/QTS/seq.
  Each native test uses a **25 s budget**; the external class process limit is **30 s**.

Build-owner handoff: add this file to `ExteralessNativeCoreTestsLib` and the required
source map for `//submodules/TelegramCore:ExteralessNativeCoreTests`; retain both
XCTest classes in the planner. It imports `@testable ExteralessCore` to exercise the
existing internal `afterFileReplace` hook, so the test configuration must build
that module with testing enabled. Core/Postbox/SwiftSignalKit dependencies already
exist on that native target. No test graph or CI invocation was changed here.

## PR03 — final notification effect admission

ApplicationContext carries `delivery.admission` with its filtered messages through
the EngineData and lock-state hops. Empty results cancel it. The final callback
checks active application/root presentation, and each immediate **sound**,
**vibration**, and **enqueue** separately calls `performIfCurrent` using
`strongSelf.context.account`. Enqueue and ChatMessageNotificationItem construction
are inside the synchronous guarded action. No admission is recaptured on main.

The native muted/imported/service-message/chat-visible/restriction/preview conditions
remain. The helper rejects changed filter/hidden revisions, stale account objects,
disposed/superseded batches and repeated effects. A sound already admitted is not
pretended undone; later effects still require their own fresh admission.

`TelegramCore/Tests/FinalAppNotificationAdmissionTests.swift` supplies four tiny
controlled-hop/recorder fixtures using the real admission and stream helpers:
filter/hidden changes, disposal/supersession, replacement object with identical IDs,
and exactly-once unchanged-policy effects. They allocate synthetic Message/identity
objects only; no Account, network, Keychain or UIKit is created. **Not run here.**

## Final Chat insertions

The canonical migration runs after full registration and before domain/account
construction; it also runs in the extension roots where Chat definitions are now
registered. Explicit canonical values retain the migration helper's precedence.

AppDelegate handleOpenURL/openUrl/openUrlWhenReady use the cached rule cleaner.
An unprepared launch URL retains its original bytes and is cleaned again after the
actual context-ready hop. Recovery URLs bypass cleaning and remain local/exact.
Share configures the tracking override at its real root after migration; its
existing preparation-error path handles failure. ShareExtensionContext cleans only
incoming `.text` and `additionalText`, retaining media, entities, Stars, destinations
and silent-send arguments.

## Checks and owner handback

- `python -B docs/wave-2/tests/test_final_app_composition.py -v`:
  **14 source contracts passed (final run: 0.086 s)**. They cover worker/startup ordering, no
  account/test-login factory before readiness, retry/retired completions, one binding
  value, native API tuple/log gates, extension roots, writer lifetime, PR03 effect
  guards, strict JSON, deferred tracking, SDK01 registration/UI exclusion and
  PFR01–PFR04 environment/factory/caller/UI contracts.
- Official `PostboxImportCheck.py`: **exit 0**.
- Scoped `git diff --check` and **12-file** bounded Swift delimiter checks: passed. The delimiter
  check caught a misplaced parenthesis during standalone wiring; it was corrected
  and the check rerun successfully. These checks are not Swift compilation.
- No CI, commit, push, real account/network effect or frame recording was performed.
  The user-reported Core/Host/Hooks green snapshot is not proof for this native slice.
- PR02's three source hunks are applied: both Network fast paths serialize their
  single immutable payload before the consuming privacy check; TLNetworkRequest's
  final check receives the exact final body. Cloud C5 exclusions/redaction remain.
  PR04 was applied directly by BasePrivacy. TLN04 was subsequently applied by the
  coordinator; the source fixture now asserts `reserveIfNeeded`,
  `permitsPluginEvents` and private-request decoder bypass instead of the old two
  entry guards. The earlier **11-hunk** in-memory check remains a historical receipt.
  Retention PR06–11 and Extras
  PR01/PR12/PR13 internals remain their owners' work.
- `native-tests.md` records the coordinator's existing Siri/NotificationContent
  Core dependencies and prior notification fixture edge. The new PFR fixture edge
  above is the remaining App test-graph handoff.
- The readonly `reviews/privacy-retention.md` hash still equals
  `c5691d57b669994abbbba01a6de55064d5c13d0dc3b43ae1e0338af269eb02af`.
- `final-app-pfr-freeze.sha256` pins the **12 Swift files + source fixture** touched
  by this follow-up. These are raw working-tree file hashes, with whole-file shared
  composition captured at handoff. All **13 hashes**, receipt UTF-8/whitespace and
  final scoped diff checks passed. The old review reports were not edited.

### Exact files changed in this slice

Relative to `telegram-ios/`:

- `submodules/TelegramUI/Sources/AppDelegate.swift`
- `submodules/TelegramUI/Sources/SharedAccountContext.swift` — PFR loader result/lifetime
- `submodules/TelegramUI/Sources/ApplicationContext.swift`
- `submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`
- `submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift`
- `submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift`
- `submodules/TelegramCore/Sources/Account/Account.swift`
- `submodules/TelegramCore/Sources/Account/AccountManager.swift` — recovery cases and supplied coding insertion
- `submodules/TelegramCore/Sources/Authorization.swift` — new result's debug test-login error case
- `submodules/TelegramCore/Sources/State/AccountStateManager.swift` — initializer/lifetime only
- `submodules/TelegramCore/Sources/Network/Network.swift` — Cloud C5 plus PR02 body admission
- `submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift` — Cloud C5 plus PR02 final body admission
- `Telegram/NotificationService/Sources/NotificationService.swift` — process bootstrap
- `Telegram/Share/ShareRootController.swift`
- `Telegram/SiriIntents/IntentHandler.swift`
- `Telegram/NotificationContent/NotificationViewController.swift`
- `submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift` — text cleaning only
- `submodules/TelegramCore/Tests/FinalAppNotificationAdmissionTests.swift`
- `submodules/TelegramCore/Tests/PFRAppIntegrationTests.swift`

Repository-root files:

- `docs/wave-2/tests/test_final_app_composition.py`
- `docs/wave-2/final-app-composition.md`
- `docs/wave-2/final-app-pfr-freeze.sha256`

The follow-up's exact changed-source set is the freeze manifest. Network,
TLNetworkRequest and enqueue are the coordinator/Chat slice during PFR/SDK01;
their entries above describe the earlier composition work.

Native acceptance still needs the supported full app build and synthetic writer/
admission execution. Frames should show a pre-Account archive error with an intact
healthy account, Later/foreground recovery, explicit Retry/reset busy transitions
and exactly one recovered root installation;
no old-account reveal during hidden unlock; no stale notification effect after
filter/hide changes; correct Cloud/Tools busy/cancel states and no duplicate launch
navigation. Record indexed/timestamped frames per AGENTS.md before a visual claim.
