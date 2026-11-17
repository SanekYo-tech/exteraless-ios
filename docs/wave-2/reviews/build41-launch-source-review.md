# Build 41: independent pre-first-UI source review

## Scope and evidence boundary

- Baseline: `79fedf4f4324bc5f8f65b573370bd03fda3daa57` (locally verified HEAD).
- Reported symptom: signed build 41, exteraless iOS 13.1.1, iOS 27.0.1, unchanged Bundle ID, persistent black screen.
- Read `telegram-ios/AGENTS.md` and `telegram-ios/CLAUDE.md`. Source-only investigation; no CI, network, artifact download, simulator/device execution, production edits, commits, or pushes.
- The coordinator's concurrent `AppDelegate.swift` diagnostic-root change was reviewed separately. All AppDelegate line numbers in baseline findings below refer to **79fed**, checked with `git show`; other reviewed production sources remained baseline-clean during review.
- Neither the reported successful build nor the supplied 33-pass runtime cohort demonstrates the production app's first launch. This review does not establish what happened on the user's device, nor infer missing capabilities from unchanged Bundle ID.

Paths below are relative to the repository. Abbreviations:

| Name | File |
|---|---|
| AppDelegate | `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift` |
| SceneDelegate | `telegram-ios/submodules/TelegramUI/Sources/SceneDelegate.swift` |
| Runtime | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift` |
| SharedContext | `telegram-ios/submodules/TelegramUI/Sources/SharedAccountContext.swift` |
| Account | `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift` |
| AccountManagerImpl | `telegram-ios/submodules/TelegramCore/Sources/AccountManager/AccountManagerImpl.swift` |
| Passcode | `telegram-ios/submodules/PasscodeCore/Sources/Passcode.swift` |
| ClientSettings | `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift` |

## Actual launch order

1. `didFinishLaunching` constructs `NativeWindow` / `WindowRootViewController` / `Window1`, assigns `window` and `nativeWindow` (AppDelegate 617–636). The window has no scene yet. Its container is explicitly white/light or black/dark (621–634).
2. Metal initialization (638–642), Passcode environment configuration (755–759), App Group URL lookup (760), BuildConfig and network-argument construction precede the App Group guard (883–886).
3. With an App Group URL, start the independent client settings worker (916–917), derive database encryption parameters (919), do a synchronous 1 MiB write probe (924–955), then create AccountManager (1231–1234).
4. **Still inside `didFinishLaunching`**, synchronously read AccountManager records (1285).
5. Install the SharedContext pipeline, gated by the first `clientSettingsReady` value (1300–1320). Install authorized/unauthorized context pipelines and their UI subscriptions (1464–1726).
6. SceneDelegate's application-role `willConnect` calls `attach` and retains the same window (SceneDelegate 15–24). `attach` binds the scene, reassigns the existing UIKit root for rotation registration, updates device metrics, and calls `makeKeyAndVisible` (AppDelegate 2141–2168).
7. Worker success installs network/map entry points and emits `.ready` (Runtime 212–228); AppDelegate publishes `clientSettingsReady` exactly once (2004–2012). Settings failures have a retained scene-aware recovery alert (2014–2018, 2065–2075).
8. Authorized root installation waits for `AuthorizedApplicationContext.isReady == true` (1611–1624). Auth UI waits for `UnauthorizedApplicationContext.isReady == true` and then presents its root (1715–1721).

An empty container is a real source state. Its exact visible color/launch-screen treatment is not established without frames and a window hierarchy.

## Findings / concrete counterexamples

### L1 — Client API account failures terminate the first account producer without a recoverable account state

**Confirmed source-level liveness defect, independent of App Group lookup.**

Prerequisite: settings preparation succeeds, AccountManager records are readable, and an account-specific Client API resolution fails.

Exact path:

1. `ClientAPILaunchResolver.init` validates the built-in tuple, but deliberately stores each environment's selection error inside `launchSelections` instead of throwing it (`swift/ExteralessCore/Sources/ExteralessCore/ClientAPILaunchResolver.swift:13–23`). Therefore `.ready` does **not** imply that a new login's API identity can resolve.
2. A concrete reachable saved state is an interrupted native Client API edit leaving a valid pending draft. `ClientAPIConfigurationStore.save` writes the pending marker before the settings update and retains it on failure (`ClientAPISettings.swift:85–95`). `selection` throws `.incompleteSave` while that marker exists (46–62); the resolver caches this failure for the launch. This requires no certificate or container failure.
3. On an unpinned unauthorized account, `resolve` reads the cached selection and throws (resolver 35–55). Independently, a malformed existing pin or public-marker/pin mismatch can fail even an authorized account (resolver 35–43, 85–98; `ClientAPIKeychain.swift:76–83,103–106`).
4. `ExteralessClientAPIEnvironment.arguments` publishes the error, then throws (`telegram-ios/submodules/TelegramCore/Sources/ExteralessClientAPI/ExteralessClientAPIEnvironment.swift:36–50`).
5. `accountWithId` catches it and returns `.complete()` without any `AccountResult` (Account 928–935).
6. SharedContext combines every added account and the added auth account before publishing state (665–733). `combineLatest` requires one value per input; completion does not supply a missing value (`telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Signal_Combine.swift:30–42,56–69`). Its subscriber has only `next`, no completion recovery (SharedContext 732–857).
7. Consequently, an existing auth record can prevent the first `activeAccountsPromise` emission. For an entirely empty installation, the initial empty arrays **do emit** (combineLatest 247–249), `beginNewAuth` creates an auth record (SharedContext 853–855,1818–1821), and that record's failing factory leaves the last empty state in place. A single failing restored account can also prevent publication of other healthy accounts at cold startup.
8. The `Client API` alert only offers `OK`; its handler clears the alert and checks retention recovery (AppDelegate 2045–2057). It does not rerun the account producer, change account records, or expose the Client API editor. Record deduplication prevents an unchanged records view from restarting the factory (SharedContext 644–658).

**Visibility qualification:** ordinarily the error should show a `Client API` alert. Closing it leaves no first account/auth UI in the counterexample. If the error arrives before scene attachment, this alert path has neither a scene guard nor attach-time retry; `presentNative` immediately calls UIKit presentation (`Display/Source/WindowContent.swift:1523–1526`). That is a conditional lost-presentation path, not proof that this scheduling happened on iOS 27.0.1. A report of black from the very first frame and no alert requires evidence of alert presentation failure, dismissal, or a different path.

Required observation: `.ready` / `clientSettingsPrepared`, exact **error enum** from `arguments`, account producer next/completion sequence, first `activeAccountContexts` tuple, and the alert's `presentingViewController` / scene state. No API hash or account payload is needed.

### L2 — Passcode file-lock contention can block main before scene attachment

**Confirmed unbounded wait chain; external lock holder is a prerequisite, not an observed fact.**

- AppDelegate 1285 calls `_internalAccountRecordsSync` while executing `didFinishLaunching`.
- AccountManager queues its implementation construction first (AccountManagerImpl 727–741). `_internalAccountRecordsSync` uses `impl.syncWith` (790–795); `QueueLocalObject.syncWith` uses the queue's synchronous dispatch (`SSignalKit/SwiftSignalKit/Source/QueueLocalObject.swift:37–45`).
- Implementation construction configures `accounts-metadata/passcode-v1.lock` and resolves the stored credential (`PasscodeCore/Sources/AccountManagerIntegration.swift:65–91`, AccountManagerImpl 154–219).
- Even a no-passcode check calls `managedReference` → `serialized` (Passcode 430–434), whose `flock(fd, LOCK_EX)` has **no nonblocking flag or deadline** (356–375).
- Another app process genuinely reaches this lock: Notification Service uses `setupAccountManager` on the same metadata path (`Telegram/NotificationService/Sources/NotificationService.swift:848`). Its temporary role does not skip `resolveAccessChallenge` (AccountManagerImpl 203–205; migration is disabled, resolution is not).

Counterexample: a live process holds `passcode-v1.lock` and stops progressing before release. App main synchronously waits for AccountManager; AccountManager waits for the lock; `didFinishLaunching` cannot return and scene attachment cannot run. The settings worker may already have queued a main-thread completion, but that completion cannot break this wait. On device, a prolonged main-thread stall may instead end in a launch-watchdog termination.

This is **not** an established in-process main↔worker deadlock. Passcode's inspected callbacks do not synchronously dispatch to main; thrown Keychain/credential errors are caught as deferred migration (AccountManagerImpl 158–161,203–219). A leftover `.lock` file alone does not hold an advisory lock after its owner's process exits.

Required observation: main stack at `_internalAccountRecordsSync` / `dispatch_sync`; AccountManager queue at `flock` in `PasscodeCredentialStore.serialized`; active holder/process lifetime; watchdog report if the process exits.

### L3 — Settings preparation can wait indefinitely on the shared settings/private file lock, without a loading/recovery UI

**Confirmed asynchronous unbounded wait; main need not be deadlocked.**

- Runtime starts work on its serial `org.exteraless.client-settings` queue (66–119).
- Configure/register/reload take `ClientSettingsFile.withLock`; its `flock(descriptor, LOCK_EX)` blocks without a deadline (ClientSettings 607,1121–1153), followed by ancestor fsyncs and file/secret operations under that lock.
- Both public and private settings use this storage implementation. Private bootstrap configures `privacy-extras-private.json` under its own recursive presentation lock (`TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessHiddenAccounts.swift:100–104,123–153`).
- Notification Service accesses the same public/private files (`Telegram/NotificationService/Sources/ExteralessNotificationPrivacy.swift:34–42`), so an external holder is a real production possibility.
- While blocked, the worker has not returned an error; Runtime stays `.preparing`, `preparationActive` stays true, SharedContext remains gated, and no first account/auth controller exists. AppDelegate's `.preparing` branch removes recovery alerts but installs no progress surface (1997–2003). `beginPreparation` has no timeout and refuses another active attempt (Runtime 206–212).

Counterexample: hold either actual settings lock indefinitely in another live process. The app can attach a responsive but empty window while its worker remains blocked. This is distinct from L2's pre-scene main-thread stall.

Required observation: attached/key/visible window, responsive main run loop, preparation state `.preparing`, and worker stack at the specific `flock`/I/O operation. No source evidence says such contention occurred in the user's launch.

### L4 — A second pre-scene early-return path mirrors the App Group alert defect

**Confirmed sibling of the coordinator's finding.**

AppDelegate 924–955 synchronously tests opening/writing a temporary file. Any open failure or short write sets `writeAbilityTestSuccess = false`; the message says insufficient space even though the code does not distinguish the underlying errno. It immediately calls `presentNative` and returns before AccountManager/SharedContext pipelines are installed (948–955). Like the baseline App Group branch, it stores no attach-time failure state.

Counterexample: valid App Group URL, successful encryption setup, failed write probe, and UIKit declines the pre-scene presentation. Later scene attachment shows the unpopulated host. Even if the settings worker subsequently succeeds, the remainder of `didFinishLaunching` was already skipped. The coordinator's missing-App-Group-only change does not cover this branch.

Required observation: write probe result/errno and the native presentation warning; do not equate this branch with proven disk exhaustion.

## Seeds checked and not established as unconditional first-launch failures

### No lazy-Promise / lost-ready cycle

- Runtime preparation is invoked explicitly at AppDelegate 2060, before SharedContext exists. Its dependencies do not await that context.
- `.ready` publishes `Promise<Void>.set(.single(()))` (2011). `Promise.set` subscribes immediately and retains the last `next`; `get` replays it (`SSignalKit/SwiftSignalKit/Source/Promise.swift:32–78`). A worker finishing before a subscriber is not a lost event.
- Promise/ValuePromise subscriber callbacks are called outside their mutexes (Promise 39–46,104–116).
- Empty `combineLatest([])` emits an empty array, so the empty-account and empty-phone-list cases are not intrinsically deadlocked (Signal_Combine 247–249).

### Font/private preparation failures have an error path

- Fonts are prepared on the worker before settings (Runtime 72–74). Missing/invalid/colliding resources produce a `.failed` state through the worker catch, rather than silently completing (112–118,235–238).
- `Display/Source/ExteralessFontFamily.swift:42–68` caches a `Result` once, including failure. Retry cannot recover a cached font-registration failure inside the same process. It should still show Settings recovery.
- Resource packaging is declared: `Display/BUILD:78–85`, main app resources in `Telegram/BUILD:1954`. The generated app plist's `UIAppFonts` lists Aremac only (`Telegram/BUILD:1800–1804`), so source does not show automatic Roboto registration duplicating the explicit call. Actual bundle contents were not inspected.
- `Font.with` may also initialize fonts and ClientSettings on an early caller (`Display/Source/Font.swift:163–176`), so “every possible font/default-singleton I/O runs only on the worker” would overstate the source. Its font cache lock is not held across registration (146–157,169–173); no inverse-lock cycle was found.
- Hidden-account configure/reload uses `HiddenAccountPresentationLock`, backed by **NSRecursiveLock**, with notification delivery after outermost unlock (`swift/ExteralessCore/Sources/ExteralessCore/HiddenAccountRuntimeState.swift:6–65`). Nested state/reload reads are not self-deadlocks.
- PasscodeEnvironment.configure only validates/stores configuration and a resolver closure; it does not resolve entitlements or perform its private Keychain lookup (`Passcode.swift:38–57`). `sharedAccessGroup()` returns the configured string (72–76); it is not an entitlement probe.

### Retention is bounded at its readiness gate

- Authorized account startup creates recovery and subscribes to its results **before** starting it (Account 953–977,498–516).
- `awaitReadiness(timeout: 5)` is the production pre-Account gate (Account 370–373); the timer runs on a concurrent queue (`TelegramCore/Sources/ExteralessRetention/RetentionReadiness.swift:140–157`).
- Failure publishes both recovery-center state and `.retentionRecovery` (Account 436–441,503–506). SharedContext excludes recovering IDs from ordinary invalid-account removal and suppresses fresh auth while recovery is pending (682–683,720–728,853–855). The AppDelegate retention alert is scene-aware and checked again on attach (2078–2127,2168).
- `continueStartup` handles a preparation signal completing without a value by publishing a failure (Account 470–472); this specifically differs from the Client API catch in L1.
- The later `initializedNetwork` stage has no overall readiness timeout, but it constructs/emits a network locally (Network/Network.swift:539–545,800–804); it does not wait for a successful remote connection, APNs registration, or recaptcha to show auth. Do not diagnose “network unavailable therefore first UI never appears” from this source.
- The unauthenticated retention-unavailable early `.complete()` (Account 916–918) is another silent outcome, but a stable successful initial settings preparation has just configured retention. Reaching it requires a later unavailable transition; it is not an unconditional fresh-launch failure.

### Readiness and rendering

- `UnauthorizedApplicationContext.isReady` follows `AuthorizationSequenceController.ready` (`TelegramUI/Sources/ApplicationContext.swift:49–65`). The first local auth state, including empty state, installs splash/phone controllers and sets ready (`AuthorizationUI/Sources/AuthorizationSequenceController.swift:88–100,1245–1261,1361–1373`). This does not require `viewDidAppear` or a remote login response.
- Authorized readiness waits for tab-bar and selected-controller readiness (`ApplicationContext.swift:251–262`). Chat list init already accesses its display node (ChatListUI/Sources/ChatListController.swift:325–342); tab selection also forces display loading (TabBarUI/Sources/TabBarController.swift:338–361). No “not attached until ready / not loaded until attached” cycle was established.
- A concrete resource-dependent stall does exist: tab-bar readiness waits indefinitely for every nonnil tab item's missing image to become nonnil (`TabBarUI/Sources/TabBarController.swift:486–527`). Chats assigns the optional result of a bundle image lookup (`ChatListUI/Sources/ChatListController.swift:350–358`). Missing icon + no subsequent nonnil assignment leaves authorized UI uninstalled. This is a conditional package/content failure, not evidence of an absent icon in build 41 and not relevant to a genuinely unauthenticated first login.
- Chat-list stories readiness follows local Postbox subscriptions, including explicit empty fallbacks, rather than successful story networking (`ChatListUI/.../ChatListController.swift:2087–2093,2190–2234`; `TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift:1104–1124`). Disabling stories returns a single empty value (`TelegramCore/Sources/ExteralessDialogs/ExteralessDialogPolicy.swift:28–32`).
- Python runtime startup is not a dependency of SharedContext or unauthorized first UI. It begins from the authorized context callback (AppDelegate 1598–1602; `Exteraless/ExteralessPluginRuntime.swift:62–90,115–145`). There is synchronous manager-file work before that callback reaches readiness subscription (runtime 718–730), so this ordering is an observation point for restored accounts, not proof that all post-account startup is off-main.
- Network entry-point installation does contain main → policy-queue `sync` before `.ready` (`ExteralessNetworkResolverRuntime.swift:33–65`). On cold launch it reads settings, installs policy/observers, and starts NWPathMonitor without awaiting a DNS result. The discovered main-queue status observer belongs to a settings controller instantiated later; no cold-start return-to-main wait cycle was established.
- The database `.error` → `.upgrading(0)` mapping exists (Account 873–876), and auth mapping ignores upgrading (SharedContext 696–697). However the main app opens as non-temporary/non-read-only owner; ordinary open/probe-unavailable paths trap rather than silently return nil (`Postbox/Sources/SqliteValueBox.swift:365,426–467,783–789`). This is not a justified generic explanation for a live persistent blank main app without the relevant DB result/stack.

## Review of coordinator's concurrent diagnostic-root hunk

Source-only queue/window review:

- Retaining launch failure and presenting after scene binding/visibility removes the baseline pre-scene presentation dependency on that branch.
- UIKit creation/root assignment executes from scene attachment on main; no new worker wait is introduced.
- AppDelegate `window`, `nativeWindow`, and SceneDelegate `window` still refer to the same NativeWindow. The new controller is retained explicitly and by UIWindow.
- The failed branch returns before settings/account subscriptions; those pipelines cannot subsequently overwrite the diagnostic root on that launch. Foreground methods use signals/optional contexts rather than requiring an initialized account.
- The remaining Window1 host still references the old container and NativeWindow's custom hit-testing/layout callbacks. This does not demonstrate that static UILabel rendering fails, but the replacement is not a complete interactive Window1-host migration. If buttons/scrolling are added later, verify their actual hit-testing rather than assume the standalone root automatically gets normal UIWindow event dispatch (`NativeWindowHostView.swift:357–358,471–473`; `WindowContent.swift:991–1032`).
- The hunk is a missing-container **silent-failure diagnostic fix**, not proof that the user lacks the App Group or that signed build 41 is fixed. Real frames are still needed for its visible result.

## Minimal decisive runtime observations for coordinator

Capture a stage sequence and, on stall, one all-thread sample plus window hierarchy:

1. `didFinishLaunching` entry; App Group lookup success/nil; return path (normal / missing container / write probe failure).
2. AccountManager construction start/end and return from `_internalAccountRecordsSync`; main run-loop liveness.
3. Scene role; `attach` entry/exit; `windowScene`, `isHidden`, `isKeyWindow`, bounds, UIKit root class and attached root view.
4. Preparation stage: fonts → public settings → tracking rules → retention configure → private settings → API configure → main entry points → `.ready` or `.failed`. Log enum/stage, not secret values.
5. First account-records view (counts and auth-present flag), each `accountWithId` result/completion, Client API error enum, retention recovery status, first active-context tuple.
6. For an existing account: context construction/update return, tabs-ready and selected-ready values, nil/non-nil tab images, `mainWindow.viewController` assignment, covering view. For auth: context exists, local auth-state kind, ready emission, root presentation.
7. Whether an error alert actually acquired a presenting controller; any UIKit “not in the window hierarchy” warning; foreground/background changes that dismissed it.
8. If the process exits, crash/watchdog report rather than treating the launch snapshot as an indefinitely running app.

These observations discriminate L1 (terminated producer, main alive), L2 (main blocked before scene), L3 (worker blocked with empty attached window), L4 (early return), and a later readiness/rendering failure. No physical root cause is assigned by this source review.
