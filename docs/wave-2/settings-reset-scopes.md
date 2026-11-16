# Original aggregate settings reset — native handoff

## Source boundary and native routes

Implemented in new files only:

- `swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetCatalog.swift`
- `swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetOperation.swift`
- `swift/ExteralessCore/Tests/ExteralessCoreTests/CoreSettingsResetTests.swift`
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetIntegration.swift`
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift`

The reset worker, UI and provider are implemented. Coordinator applies the shared
registration/fingerprint hunks below; current app/CI execution is not claimed.
The existing ClientSettings writer, SCF/SCR recovery, per-key reset and SDK manifest
were not edited. `docs/wave-2/module-routes/general.json` remains coordinator-owned.

| Original | Exact source scope | Native route |
|---|---|---|
| `GeneralConfig.reset`, `GeneralConfig.kt:155–163` | Its 7 `ConfigItem`s only | Reset page → **General settings** → provider `.general` |
| `GeneralHelper.resetSettings`, `GeneralHelper.java:130–151` | OpenExtera, General, Appearance, Chats, IconPacks, PillStack, Utils config lists, plus the 13 explicit Neko/Na fields | Reset page → **Exteraless settings** → provider `.exteraless` |
| `GeneralHelper.resetAllSettings`, `GeneralHelper.java:153–160` | Above, then `nekocloud`, `nekox_config`, and all `nkmrcfg`; `LegacyDefaults.keepPinned` | Reset page → **All Original preference scopes** → provider `.allOriginal` |

The seven config groups contain **141** source fields; the selected operation adds
13 external fields, for **154**. General has 6 actual native counterparts in the
current Privacy/Tools definitions; `showNagramSettings` is reported unavailable.
The all-scopes catalogue additionally enumerates the source-pinned Neko/Na fields,
Glyph, cloud/API preferences and known dynamic/legacy `nkmrcfg` producers. Its
**512** records are source identities, not newly registered controls. The five
non-ConfigItem migration keys are All-only: `OEAppearanceTitleTextMigrated`,
`IgnoreFolderCount`, `IgnoreMutedCount`, `SpringAnimation`, `SendHighQualityPhoto`.

Read-only inspection of the current native declarations gives **148 distinct
public keys** for the selected scope, with six unavailable Original fields:

| Original group | Source fields | Native keys | Unavailable Original fields |
|---|---:|---:|---|
| OpenExtera | 4 | 4 | — |
| General | 7 | 6 | `showNagramSettings` |
| Appearance | 62 | 60 | `centerTitle`, `iosChatHeader` |
| Chats | 42 | 40 | `cameraType`, `unmuteWithVolumeButtons` |
| IconPacks | 5 | 4 | `customNotificationIcon` |
| PillStack | 20 | 20 | — |
| Utils | 1 | 1 | — |
| Explicit Neko/Na fields | 13 | 13 | — |

This includes Player/gallery, Feed and `AINativeVisibilityPolicy.definitions` at
their real registrations. In particular, ChatFeatures' three pill-layout keys are
native reset targets even though the narrower SDK Config projection omits them.
Runtime availability is still resolved from that store's registered definitions;
the 148-key source result is not a claimed running-app measurement.

The explicit selected Neko/Na list is:
`disableNumberRounding`, `showSeconds`, `disableVibration`, `zalgoFilter`,
`translationProvider`, `translateToLang`, `uploadBoost`, `customSavePath`,
`hidePhone`, `idDcType`, `hideArchive`, `openArchiveOnPull`, `doNotUnarchiveBySwipe`.

Those map respectively to `appearance.disableNumberRounding`,
`appearance.showSeconds`, `appearance.disableVibration`, `privacy.zalgoFilter`,
`ai.translationProvider`, `ai.translateToLang`, `tools.uploadBoost`,
`tools.customSavePath`, `privacy.hidePhone`, `identity.idDcType`,
`appearance.hideArchive`, `chats.openArchiveOnPull`, `chats.doNotUnarchiveBySwipe`.

### Mapping and exclusions

The catalogue joins exact Original field symbols to the **actual**
`ClientSettingsSnapshot.definitions`. It recognizes only documented migration
aliases and the exact AIFeatures bare-field/key pairs. It does not use a domain-name
prefix as permission to reset arbitrary native settings. One native key matching
several Original fields is reset once. The page reports every unmatched source
field and shows the concrete matched native keys/titles before confirmation.

- All seven selected groups use `NekoConfig.getPreferences()` → **`nkmrcfg`**
  (`NekoConfig.java:65–69`). Full clearing also covers `NaConfig` and `GlyphConfig`.
- `NekoXConfig.java:43–47` explicitly puts custom API mode/ID/hash in
  **`nekox_config`**. Therefore All includes registered production/test API draft
  counterparts. Existing account API pins, authorization, already-started login
  identities and native pending-save journals live elsewhere and are retained.
  Disabling public API mode/ID precedes the ordinary native hash reset.
  A retained pending journal still requires repair in the Client API editor; a
  successful report covers the listed ClientSettings keys, not that separate
  journal. A fixture verifies the actual vault pin and editor summary remain so.
- Translation/transcription credentials actually stored by Neko/Na are included
  only in All. Native-only experimental/Lingo keys and voice controls have no such
  source field and are preserved.
- All also includes the actual Neko DNS/IPv6 preferences; `network.customDoH`
  uses native credential reset because saved endpoints may contain credentials.
- **`aiConfig`** is separate (`AiConfig.java:48–50`): Assistant providers, roles,
  history and their `Service.key` entries are not part of these reset scopes.
  The compatibility shim's **`exteraconfig`** file is separate too.
- Cloud reset includes the two registered policy fields. Original `updated_at`
  is reported unavailable because native sync timestamps are account-owned state.
  It does not delete the remote backup or initiate a network operation itself.
- Account-local identity names/Premium/name order, retained-message exceptions in
  Postbox, native private hidden-account settings, authorization/database contents,
  installed plugin/pack/font files and unknown native keys are not erased. Where
  Original has a corresponding `nkmrcfg` field but the native counterpart is not a
  registered client setting, the UI reports that unavailable mapping.
- Original raw namespace `clear()` is broader than any finite known-field list.
  Unknown/unregistered keys are preserved by the native store and are not claimed
  reset. Missing Original fields never create inert replacement settings.
- `LegacyDefaults.keepPinned` (`LegacyDefaults.java:64–67`) writes **only**
  `OELegacyDefaultsPinned=true` and `OELegacyDefaultsGeneration=2`. It does not keep
  `BOOL_KEYS` values or the old double-tap selections. Native resets remove real
  overrides, do not seed those legacy values, and do not invent Android marker keys.
- `NekoConfig.disableInstantCamera` is unavailable rather than an alias for
  `ChatsConfig.hideCameraTile`: `ChatAttachAlertPhotoLayout.java:147–159` explicitly
  separates the live preview inside a tile from whether the tile is shown.

The full Original SHA-256 pin table is in `CoreSettingsResetCatalog.sourcePins`,
including GeneralHelper/GeneralConfig/reset groups, Neko/Na, NekoX/cloud,
LegacyDefaults, dynamic preference producers, AiConfig, ExteraConfig and the
Original confirmation caller and attachment-camera distinction. The field/raw-key lists were compared read-only with
`python/exteraless_runtime/_config_manifest.py` (SHA-256
`3e0b56a5a75a634b383b04c579c08ac982dee9012e24daa11d0320c0144b699c`).
The generated manifest was not imported into the app, regenerated or edited.

## Stable native API / operation semantics

```swift
CoreSettingsResetPreview.resolve(scope: CoreSettingsResetScope, snapshot: ClientSettingsSnapshot) throws
CoreSettingsResetProvider(settings: ClientSettings = .shared)
provider.prepare(scope: authority:) throws -> CoreSettingsResetPlan
provider.begin(plan, authority: authority) throws -> CoreSettingsResetSession
session.run() -> CoreSettingsResetReport
CoreSettingsResetAuthority() // parent context lifetime
authority.child()            // page/operation lifetime
authority.invalidate()
CoreSettingsResetActionGate.open(requested:current:authority:make:present:)
```

`prepare` runs on a worker and captures the actual native cache snapshot, source
scope and private credential baselines. It performs **no file/Keychain I/O or
load-time migration**; cancelling the preview changes no persisted settings.
Unavailable public typed values block preparation. A recorded `lastError` stays
visible, while an explicit attempt still goes through the writer's current-file
validation/CAS, including after external storage repair. Plans and sessions have
redacted descriptions/reflection and no Codable export. The main-actor UI owns the selected scope and account identity;
the authority is invalidated on context replacement, clear, page departure or new
preview. Provider/authority IDs prevent reusing a plan under another owner.

The public portion invokes **one** existing
`applyPublic([:], resetting: selectedPublicKeys, expected: capturedSnapshot)`.
Core supplies the file lock, atomic replacement, current-disk CAS and one changed
generation for existing domain observers. No per-key default-setting loop is used.
Reset overrides become absent, so a future definition default can take effect.
A public-only operation performs no Keychain reads/writes, including with an
unrelated unavailable credential whose known stored presence must be preserved.

Credentials use the existing explicit native `reset(key)` semantics. After
confirmation, the worker reloads native credential state and checks schema, scope, context, value and presence before
each step. These checks are not advertised as an atomic secret CAS: that primitive
is not supplied by the existing writer. Public CAS is exact; the complete sequence
is not a transaction across JSON and Keychain. Normal single-page native clear
semantics apply to an already-admitted credential reset.
The existing load/repair path retains its alias/quarantine behavior. Only one
attempt per session is admitted; reentrant observers receive an in-progress
result rather than deadlocking, and no reset lock is held during store callbacks.

Errors return confirmed/observed/pending keys without values. A post-rename public
error retains the intended absent/default CAS guard for retry; it does not write
old defaults as new overrides. Completed phases are not replayed over later edits.
A native credential failure can leave earlier steps complete; the UI stays on the
page and shows progress/error. A changed value, scope or context requires a new
preview. No rollback of later user edits, Host restart, finalization, account
deletion or manual formatter/theme recreation occurs. Existing native settings
observers own resource/view regeneration; any actual competing change is reported.
An observed credential deletion after an error remains pending confirmation: a
later successful step does not retroactively turn that failed reply into success.
Its retry guard is the intended absent/default state, never a later user snapshot.
CAS/scope/context rejection latches the need for a new preview in Core itself.

## Exact shared hunks — coordinator applies

### Runtime registration

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`:

```diff
@@
     private var cloud: ExteralessCloudIntegration?
+    private var settingsReset: SettingsResetIntegration?
@@
         cloud?.update(context: context)
+        if settingsReset == nil { settingsReset = SettingsResetIntegration() }
+        settingsReset?.update(context: context)
@@
     private func clearAccountDomains() {
+        settingsReset?.clearContext()
         ExteralessSettingsSearch.retire()
```

Constructing this integration in `update` keeps it after the existing
configure/register/readiness gate. Existing root code already renders the registry:
`ExteralessSettingsEntry` → `exteralessSettingsController` → action
`general.settingsReset` → checked current AccountContext → native reset page.
No edit to the root/per-key reset implementation is required.

### BUILD / provenance

The production Core and TelegramUI source globs already include the new files.
Coordinator adds them to the harness fingerprint sets, so a later harness run
cannot reuse a stale reset implementation:

```diff
--- a/swift/ExteralessCore/BUILD.bazel
+++ b/swift/ExteralessCore/BUILD.bazel
@@
         "Sources/ExteralessCore/ClientSecrets.swift",
+        "Sources/ExteralessCore/CoreSettingsReset*.swift",
--- a/telegram-ios/submodules/TelegramUI/BUILD
+++ b/telegram-ios/submodules/TelegramUI/BUILD
@@
         "Sources/ExteralessClient/Pills/*.swift",
+        "Sources/ExteralessClient/SettingsReset*.swift",
```

Imports are Foundation only in Core; UI uses the existing AccountContext, Display,
ExteralessCore, UIKit list infrastructure. SwiftPM auto-discovers the new Core test
file. SDK changes belong to its owner: the three Source utility names correspond
to `.general`, `.exteraless`, `.allOriginal`; presenting the page must not be
reported as an already completed Java reset call.
The Runtime insertion changes a Config source pin: its owner should refresh the
SDK metadata from the final composed Root source, after coordinator publication.

## Verification / native fixture entry

Seventeen bounded Core fixtures cover actual General/selected-scope definitions;
source overlap and the camera-preview distinction; unsupported/private fields;
one real file commit/observer/presence; unknown/unrelated data and secrets;
external CAS and changed-schema rejection; context/action admission; observer
reentrancy; unreadable Keychain with a public-only reset; credential failure,
quarantine repair and explicit-empty retry conflicts; actual API pin/journal
preservation; malformed JSON repair; and post-rename durability failure.
They invoke the same provider/session as the native page, not a named-method stub.
`testNativeActionGateRunsTheProviderOnlyForTheCurrentContext` exercises the exact
gate used by the registered UI action, then inspects real provider/file effects.
UIKit construction/frames are a separate pending native-harness check.

The loginless native harness can supply its synthetic AccountContext and a
disposable ClientSettings with fake secrets to the actual UI factory:

```swift
settingsResetController(context: fixtureContext, settings: fixtureStore,
                        authority: CoreSettingsResetAuthority(), scope: .general)
```

Drive `reset.scope.general`, `reset.scope.exteraless`, `reset.scope.allOriginal`,
`reset.apply`, `reset.result`, `reset.refresh` and `reset.unavailable` accessibility IDs. Provider
failure fixtures use real temp JSON and an injected secret store; no real account,
network, installed plugin or user data is used. A retained authority can be
invalidated during the fixture to verify that later mutations/presentations stop.

After coordinator builds the source, bounded Core execution:

```sh
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--package-path", "swift/ExteralessCore", "--skip-build", "--filter", "CoreSettingsResetTests"], check=True, timeout=30)'
```

### Frame expectations (before recording; no visual pass claimed)

- Root → Reset settings → all three previews: native push/pop follows existing
  Display navigation (~0.3s); theme/list colors have no white flash. Large type,
  RTL, iPad and reserved-corner layouts keep scope labels/counts/controls visible.
- The single confirmation names the selected scope and public/secure counts.
  Cancel changes no settings. Changing scope/refreshing invalidates the old plan.
- On success the page shows confirmed steps and absent overrides; it does not
  dismiss early. On injected failure it scrolls to an error and shows partial
  progress, including an override removed but awaiting confirmation. Retry does
  not erase a new edit to a previously reset field.
- No secret value is displayed in preview, confirmation, progress or error.
  Unavailable Original fields are explanatory rows, not toggles.
- Account switch/page departure invalidates the operation; an admitted atomic
  batch can finish, but subsequent credential steps and late UI results stop.
- A cancelled interactive pop rebuilds a usable preview when outstanding work
  finishes; it must not leave the returned page permanently empty or busy.
- Appearance/chat/pill changes re-render through existing observers. Verify those
  real surfaces after returning; there is no fabricated resource-reload success.

The prior Mac20/e16 result (680 Core plus SDK evidence) predates these files. No
query was made to the in-progress app build, and no CI/commit/push was performed.
New native compilation, execution and labelled frames remain for coordinator.

The bounded local checks passed: UTF-8/trailing whitespace, Swift delimiter balance,
Foundation-only Core imports, the **25** embedded Original SHA-256 pins, nine
ConfigItem field/raw-key tables and the actual selected native-definition join.
The seventeen new XCTest methods are supplied but not run here;
`Get-Command swift, swiftc` confirmed there is no local Swift toolchain. No
XcodeBuildMCP tools are exposed in this session; simulator recording and
labelled-frame evaluation remain for the Mac handoff.

Coordinator applied the Runtime registration/update/clear hooks and both harness
fingerprint patterns. The Original Other-page `resetSettings/resetSettingsRow`
search alias now opens the registered `general.settingsReset` preview page; the
link itself performs no reset. Native scope selection and confirmation remain on
that page. This is a source join, pending the new Core/native execution gates.

Linux43758843590/d1df6ad6 compiled and ran the cohort. Its sole failing method had
omitted `DialogFeatures.definitions` from the fixture's simulated Root registration,
so three archive-policy keys were absent (145 instead of148). The fixture now
registers that actual group; the148-key and exact unavailable-field assertions are
retained. No reset resolver or production scope was changed for this correction.

## RSR01 / RSR02 postfix — 2026-11-16 source-freeze handoff

The independent request is `reviews/settings-reset-source-closure.md` (read-only).
The accepted **148 native / 154 selected Original / 512 All Original** scopes are
retained. Coordinator's **43759513734 / 1880b663: 704 Core, including 17 reset
fixtures, passed** is prior evidence; it does not cover these new witnesses.

### RSR01 — actual Display return and completion ordering

`SettingsResetController.viewDidAppear` now handles Display's cancelled-pop return
without `viewWillAppear` (`NavigationContainer.interactivePopEnded`, ordinary and
expansion cancel branches). It renews an invalid child authority and discards the
old plan/session/result. A normal Will+Did pair prepares only once. If old work is
still busy, the fresh preview is queued, not run concurrently or substituted with
the old session.

The production base's actual finish order is important:
`operationTask = nil` → `isBusy = false` → completion → render. The stale-result
branch can therefore start its one queued preview from completion. Recovery
additionally requires `isScreenVisible`, a valid parent/child and idle state. A
reply finishing while the swipe is still in progress waits for DidAppear. An
actual pop or context retirement cannot start a replacement preparation.

The public factory and registered `general.settingsReset` action are unchanged.
The existing Original Other/General search alias remains in
`ClientSettingsSourceRoutes.swift`. Native instrumentation is internal to the
debug/testable module:

- `SettingsResetWorkHooks(afterPrepare:afterReset:)` holds **completed actual
  provider replies** in the new fixture; shipping callers supply neither hook.
- `SettingsResetController.navigationStateForTesting` exposes only authority/plan/
  session IDs, validity and queued-preview state.
- `applyConfirmedPlan(_:authorityID:)` is the real UIAlert positive-confirmation
  continuation. The lifecycle fixture invokes this same guarded continuation for
  its pending-reset cases; it does not substitute a reset result.
- The fixture's subclass records lifecycle callbacks and calls the production
  superclass. It never synthesizes callback ordering itself.

### RSR02 — withdraw an indeterminate destructive retry

Additive result API: **`CoreSettingsResetReport.requiresNewPreview: Bool`**.
The first reply retains its typed `.storage(.storageFailure(...))` and observed/
confirmed/pending progress. If a public storage failure is followed by a snapshot
different from the intended absent/default post-state, Core latches a fresh-preview
requirement. The subsequent `session.run()` returns `settingsChanged` without
calling the writer. It cannot fall back to `plan.before`, even when a synchronous
observer restored the exact previous payload **and** stored presence after rename.

| Failure observation | Permitted continuation |
|---|---|
| Complete intended reset remains observed | Retry uses only `resetExpected`; existing durability confirmation remains supported. |
| Different/indeterminate state, including restored `2 + present` | Preserve the typed storage error, set `requiresNewPreview`, disable Retry, require a newly confirmed preview. |
| Injected pre-rename error with the old file intact | Conservatively require a new preview too. This wrapper has no committed-outcome receipt and does not infer one from an error's operation label. The old file is preserved. |
| Malformed JSON before mutation | Existing parse failure/CAS behavior still preserves the file; an explicit retry after restoring it remains guarded. |

The page keeps the storage error visible, adds “Refresh the preview before
continuing”, and disables its old reset/retry row using the new result flag.
`ClientSettings`, SCF/SCR and the concurrent Search definition-version work are not
part of this patch.

### Regressions prepared

Core now has **19 reset test methods**. New real-file witnesses:

- `testRSR02PostRenameErrorAndObserverRestorationWithdrawOldRetry`: the one-shot
  post-rename hook only throws. A synchronous observer sees absence and makes a
  real CAS write restoring `tools.downloadSpeedBoost = 2` with presence. The second
  run must retain its exact file bytes, value and presence; no external-thread
  wait or hook reentry is used.
- `testRSR02PreRenameFailurePreservesFileAndRequiresFreshPreview`: the pre-replace
  fault leaves the complete old file intact; the old session is refused, while a
  newly prepared/confirmed session succeeds.
- The existing post-rename/unchanged-intent fixture now uses the actual Tools
  definition and asserts the typed error plus `requiresNewPreview == false` before
  its successful, no-extra-replacement durability retry.

New given-context native fixture:
`telegram-ios/Tests/Exteraless/SettingsResetNavigationChecks.swift`.
It mounts the shipping reset renderer in a real `Display.NavigationContainer` in
the supplied harness window. It invokes the same `interactivePopBegan/Changed/Ended`
entry points used by Display's own navigation tests and lets the actual transition
completion deliver DidAppear/DidDisappear. It asserts the observed cancelled
sequence is exactly `willDisappear, didAppear`, with no intervening WillAppear.
It checks the real mounted UIKit reset cell, plan/authority identity, actual file
bytes and provider call counts.

Ten independently selectable cases (one fresh bounded process per case):

```text
reset-ready-cancelled
reset-prepare-before-return
reset-prepare-after-return
reset-reply-before-return
reset-reply-after-return
reset-prepare-actual-pop
reset-reply-actual-pop
reset-retired-ready
reset-retired-prepare
reset-retired-reply
```

Reply gates have a **6 s** upper bound and never hold a settings/main-thread lock.
The interaction checks have an **18 s** deadline; ordinary readiness waits are
at most 2 s, cleanup waits at most 5 s, and the existing **30 s process limit** is
required. Setup uses a new private temporary settings file, actual General
definitions, a backend that rejects any secret access, and the supplied offline
AccountContext. No account construction, Keychain, network or plugin operation
belongs to the fixture.

### Coordinator BUILD / ready inputs (shared files remain coordinator-owned)

The existing production source globs and reset fingerprint patterns already
include the changed Core/controller. Add the fixture and its actual dependency
inputs:

```diff
--- a/telegram-ios/Tests/Exteraless/BUILD
+++ b/telegram-ios/Tests/Exteraless/BUILD
@@
-    ["SettingsSearchUIViewRouteChecks.swift"],
+    ["SettingsSearchUIViewRouteChecks.swift", "SettingsResetNavigationChecks.swift"],
--- a/telegram-ios/Tests/ExteralessHarness/BUILD
+++ b/telegram-ios/Tests/ExteralessHarness/BUILD
@@
-    srcs = glob(["Sources/*.swift"]) + ["//Tests/Exteraless:SettingsSearchUIViewRouteChecks.swift"],
+    srcs = glob(["Sources/*.swift"]) + [
+        "//Tests/Exteraless:SettingsSearchUIViewRouteChecks.swift",
+        "//Tests/Exteraless:SettingsResetNavigationChecks.swift",
+    ],
@@
         "//submodules/SettingsUI:ClientHarnessSettingsSearchSources",
         "//submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen:ClientHarnessSettingsSearchSources",
         "//Tests/Exteraless:SettingsSearchUIViewRouteChecks.swift",
+        "//Tests/Exteraless:SettingsResetNavigationChecks.swift",
--- a/swift/ExteralessCore/BUILD.bazel
+++ b/swift/ExteralessCore/BUILD.bazel
@@
         "Sources/ExteralessCore/CoreSettingsReset*.swift",
+        "Sources/ExteralessCore/ToolsFeatures.swift",
+        "Sources/ExteralessCore/PrivacyFeatures.swift",
--- a/telegram-ios/submodules/Display/BUILD
+++ b/telegram-ios/submodules/Display/BUILD
@@
         "Source/TransformImageNode.swift",
+        "Source/Navigation/NavigationContainer.swift",
+        "Source/NavigationTransitionCoordinator.swift",
+        "Source/NavigationTransitionSpring.swift",
+        "Source/NavigationInteractivePopTracker.swift",
```

The second Harness BUILD hunk belongs to **DomainFingerprintInputs**. Debug
`@testable import Display/TelegramUI` uses the existing rules_swift behavior:
`features_for_build_modes` enables `swift.enable_testing` for `dbg`/`fastbuild`.
These libraries are existing harness dependencies; no release/internal-symbol
export policy change is requested.

Native-gate owner: admit the ten case IDs in `ClientHarnessScenario` and the host
driver whitelist, require source evidence for them, then dispatch to the new
given-context API rather than the old `default: coreScenario()` fallback:

```swift
try self.loadDomainSourceEvidence()
guard let resetCase = SettingsResetNavigationChecks.Scenario(rawValue: self.report.scenario),
      let layout = self.navigation.validLayout,
      let manifest = self.report.facts["domainSources"] as? [String: Any],
      let files = manifest["files"] as? [String: String] else {
    throw ClientHarnessFailure(description: "Missing reset scenario/layout/source evidence")
}
try await SettingsResetNavigationChecks.run(resetCase, context: self.context,
    hostView: self.navigation.view, layout: layout, sourceHashes: files,
    probe: { name, payload in try self.probe(name, extra: payload) })
```

`requiredSources` lists **22** exact source/config paths. Pass the real verified
manifest `files`, not hand-authored revision labels. The probes are
`reset-before-swipe`, `reset-dragging`, optional `reset-old-reply-before-return`,
`reset-navigation-ended`, and either `reset-returned-ready` or `reset-retired-idle`.
The first contains the required hashes; all include actual lifecycle, authority/
plan/session IDs, worker counts, visibility and persisted fixture state. Include
these probes in the host ready/report validation and frame extraction selection.

### New frame expectations (specified before recording)

- **Ready:** the native reset page follows the finger to roughly 22% of its width
  and returns left to rest on cancellation. `isCancelled: true` uses Display's
  critically damped noninteractive cancel spring: roughly 0.5 s, no body overshoot.
  Navigation chrome and table follow their existing transition together; there is
  no bright flash, clipped row edge or duplicate title. The returned page obtains
  a new plan and one usable Reset row automatically.
- **Prepare reply before return:** the old reply is discarded while the swipe is
  still active. Replacement work begins only after the actual DidAppear ending;
  no final blank page or disabled Reset remains.
- **Prepare reply after return:** the page first rests with its ordinary busy row.
  Releasing the old reply produces exactly one fresh preview, not the old plan and
  not a second preparation from a Will+Did pair.
- **Reset reply before/after return:** the actual file is already at absent/default.
  The old session/result is not revived. After idle, the new preview shows default
  state and a fresh reset action; no old completion badge/Retry session appears,
  and navigation itself makes no additional settings write.
- **Actual pop / retired context:** the removed page stays removed, or the returned
  retired page shows its context message with reset unavailable. Late worker
  replies do not remount it, recreate a preview or perform another reset.
- **RSR02 error UI:** the typed storage error and partial progress remain visible.
  A different/indeterminate post-state disables Retry and asks for Refresh preview;
  unchanged intended post-state keeps its guarded durability retry. The Core
  injected-fault evidence is not itself a claimed UIKit frame pass.

Record with the existing `simctl io recordVideo` / ffprobe-labelled frame workflow.
The new probes locate the before/after-return races; old settings-root or Core
passes cannot be relabelled as these clips. Fresh native compilation, execution
and frame evaluation are still required; this agent has not dispatched CI.

### Current patch identities and verification boundary

Raw SHA-256 of the current source files (recompute from the final packaged source
cohort if coordinator merges further edits):

| Source | SHA-256 |
|---|---|
| `CoreSettingsResetOperation.swift` | `fd6b6d648c032e9026f8fab63448b6106200cd8488b26ce746e24db7d11eaeef` |
| `CoreSettingsResetTests.swift` | `3a31732cf54a17efe6e160a6bff76d9a8e7911afd854397d771dd86eebfb1b11` |
| `SettingsResetController.swift` | `ddf63e8843dca995003485d03df13bb112ae68e466f21aa633581a0a446a215d` |
| `SettingsResetNavigationChecks.swift` | `b8f42aedbf80a9d4b555323eefd331d1c8bf93ddfded650d8813e88f53aaeb32` |
| `SettingsResetIntegration.swift` (existing action binding) | `bbbdae624a8a00ac07bc30e5402efee0347013ade5273b2a81618bd18cb67e4d` |

Bounded local checks passed: scoped diff/whitespace and Swift delimiters, append-only
handoff prefix, 19 unique Core methods, ten distinct native cases, all 22 required
ready-source paths, accepted catalogue identity, and the actual base idle-before-
completion ordering. Swift/Swiftc are unavailable on this Windows host; **the new
Core witnesses and native fixture have not executed here**. After coordinator's
build, run the 19-case `CoreSettingsResetTests` filter under the existing 30 s
subprocess limit, then the fresh native cases/recorded frames. The supplied earlier
17-case Linux pass is not evidence for RSR01/RSR02 remediation.
