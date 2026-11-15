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
