# Tools / backup / updater / camera — wave 2

**Phase 2 supersedes the backup API/schema and portable-tail status below:** see
`tools-phase-2.md`, `tools-ready-contract.md`, `tools-gallery-hooks.md`,
`tools-favorites-hooks.md` and `tools-retention-handoff.md`.

Source implementation handoff. **No Swift compiler, Apple SDK or XcodeBuildMCP is
available in this Windows session. No runtime, visual or IPA pass is claimed.**
Mergeable evidence: `docs/wave-2/tools-parity.json`; original IDs are taken from
`docs/parity/client-features.json`, not invented from shim getter names.

Owner scope: `swift/ExteralessCore/Sources/ExteralessCore/Tools*.swift`, unique
`Tools*Tests.swift`, `TelegramUI/Sources/ExteralessClient/Tools/**`, camera and
`ApplicationShortcutItem.swift` insertion sites. Other domains were not edited.

## Composition contract (coordinator / core-settings / build handoff)

- `ExteralessToolsIntegration.init(backupBindings: ExteralessToolsBackupBindings? = nil,
  shortcutBindings: ExteralessToolsShortcutBindings? = nil)`; `update(context:)` and
  `clearContext()` run on main. Default construction supports updates, diagnostics,
  file utilities and configuration export. Plugin data comes exclusively from the
  injected plugin-settings directory, never the account/database root.
- Core source directory uses the ordinary SwiftPM layout:
  `swift/ExteralessCore/Sources/ExteralessCore`. Please include its `Tools*.swift`
  files in ExteralessCore. UIKit sources are in TelegramUI's existing source glob.
- **Atomic client settings API still needed from core-settings/coordinator:**
  `ClientSettings.applyPublic(_ values: [String: ClientSettingValue]) throws` must validate
  the whole patch, reject secret keys for backup, persist one atomic JSON write,
  and publish one notification after success, reporting any post-rename durability
  error so the restorer can roll back the whole attempted batch.
  Tools accepts this as an injected closure, so it does not assume an undefined
  singleton or an unpublished API. A rollback uses the same atomic closure.
- Plugin restore must hold a runtime maintenance lease from before snapshot/staging
  until commit/rollback completes. Pause must drain plugin callbacks/settings writes
  without changing persisted enabled flags. Inspection/export never imports or runs
  Python. Coordinator supplies that lease, the root and a non-secret key allowlist.
- **ExteralessCore dependencies required** (BUILD changes belong to build agent):
  `//submodules/Camera:Camera`, `//submodules/Camera/CameraLegacy:CameraLegacy`,
  `//submodules/Camera/CameraNeo:CameraNeo`,
  `//submodules/TelegramUI/Components/CameraScreen:CameraScreen`,
  `//submodules/TelegramUI/Components/VideoMessageCameraScreen:VideoMessageCameraScreen`,
  `//submodules/TelegramUI:TelegramUI`.
  `Camera/Sources/CameraZoomState.swift` and `ExteralessCameraZoomControl.swift` are
  in Camera's existing glob. Tools UI uses UIKit, AVFoundation, AVKit, ImageIO,
  UniformTypeIdentifiers, TextFormat and MetricKit. Core uses CryptoKit on Apple
  and a fallback with published-vector tests on platforms without it. No new package/dependency
  download is needed. Check framework autolinking in the full app build.

No commit/push/CI dispatch or real-network tests are performed by this owner.
Native build and labelled simulator/device frames remain external verification gates.

## Implemented source and effects

### Backup

- `ToolsBackupArchive`: version-1 envelope
  `{"format":"exteraless.settings","version":1,"payload":"<base64 JSON>","sha256":"<hex>"}`.
  The digest covers the **exact embedded bytes**. Embedded payload contains
  `createdAt`, `appVersion`, `clientSettings`, `pluginSettings` (`path`, `values`).
  It is self-contained and is an integrity-checked configuration archive, not encryption.
- Limits: 24 MiB outer file, 16 MiB decoded payload, JSON nesting 24 / 100,000
  non-string separators, 4096 client
  settings, 256 plugin files, 1 MiB per plugin file. Preflight happens before JSON
  materialization. Plugin paths are a single ASCII `.json` filename, never an
  archive-controlled absolute path; case aliases, traversal, separators, NUL,
  symlinks, nonregular files and non-JSON destinations are refused.
- Public export uses **one `ClientSettings.readSnapshot()`**. Both declared
  `isSecret` and learned `snapshot.secretKeys` are omitted, including their JSON
  keys. No backup calls `ClientSettings.value` or a secret typed getter. Plugin
  export additionally requires an explicit per-file non-secret key allowlist;
  nested credential dictionaries are filtered, credential-bearing arrays omitted.
  Restoration rejects replacements which would erase local credential subtrees.
- `ToolsBackupRestorer` stages/validates a complete directory, retains an independent
  complete original, atomically replaces the plugin settings directory, applies a
  batch of public client settings and writes the commit marker. A failed commit
  restores the original directory and previous settings. Rollback itself uses a
  copy so the retained original survives a second failure. Uncommitted journals
  are rolled back on recovery; missing/corrupt recovery data fails closed.
  This is a **source-level transaction design**, with Darwin filesystem/fault and
  process-interruption tests supplied, not an already-run storage proof.
- Restoration overlays selected public fields; it preserves unrelated values,
  plugin credentials, code, enabled flags, permission grants and all account data.
  Only a caller-supplied directory whose basename is `settings` is admitted.
  `PluginServiceStorage.settingsDirectory()` returns the correct canonical path.
- The UIKit picker uses security-scoped access + `NSFileCoordinator`, bounded
  reads, data-only preview, an explicit Apply action and native share/export.
  Inspection never calls PluginHost, Python import, `get_settings`, a shell or
  an executable archive extractor. All heavy archive work runs off main.
- `.extera` import/export implements the original base-11 Unicode wrapper and
  common identity fields plus explicit flash-percent, inverted haptics, folder
  title/counter, proxy-condition and common double-tap mappings. Legacy pill strings
  are validated. Unsupported/composite fields are reported as ignored; unsupported
  enum values are not guessed. Legacy files have **no checksum**, stated in preview.

### Updater

- `ToolsReleaseClient`: unauthenticated public GitHub Releases API;
  default repository is `SanekYo-tech/exteraless-ios`. Configurable repository is
  a typed initializer dependency, not a token/URL field. No PAT, cookies or URL
  credentials are accepted/forwarded. There was no live request in this work.
- Stable/prerelease filtering, IPA/architecture selection, bounded 2 MiB metadata,
  restricted HTTPS redirects, streaming download to a new private partial file,
  exact size + GitHub SHA-256 digest verification, cancellation and partial cleanup.
  A missing published digest points the user to the release page instead of
  claiming a verified download. The asset cap is 1 GiB.
- Numeric marketing version and **numeric CFBundleVersion/build** comparison;
  tags `v13.1.1+123` / `v13.1.1-beta.2+123` carry build metadata. Missing comparable
  metadata is `unknown`, not a fabricated “latest”. Release publishing remains a
  coordinator/user distribution step; private/no-IPA/404/rate-limit cases are visible.
- UI states: checking, available/not newer/unknown, byte/percent progress, error,
  cancelled, **Ready for manual signing**. Export uses `UIActivityViewController`;
  guidance names the user's external signing tool. There is no installed state,
  installer bypass, signing identity, publication or in-app Apple/GitHub credential.
- Automatic checks are opt-in, at most every six hours (attempts included), with
  explicit channel changes initiating a fresh check. Results feed the settings
  action title and the actual update screen. Skip-version suppresses that notice;
  manual review remains available.

### Camera and native utilities

- `CameraProtocol.zoomState` is implemented by both LegacyCamera and CameraNeo.
  KVO follows the **active capture device**, min/max/actual zoom and format; stops
  come from real virtual-camera switchovers/native-resolution factors. No model-name
  lens table is used by the new control. CameraScreen and VideoMessageCameraScreen
  instantiate the same native segmented/continuous control and call `rampZoom`.
  Slider updates are coalesced to display frames. There is no fake 0.5× on a
  single-lens/front/multicam device. Hidden/detached views release pending updates.
- Camera settings have live callsites: stabilization, supported single-camera FPS,
  front preview/photo/video mirroring, real ultrawide start, round-video pinch reset,
  remembered front/back camera, screen-flash color and intensity. Existing camera
  focus/torch/dual lifecycle are retained as native equivalents. Legacy and Neo
  round output is 512×512 (Android `AppUtils` minimum). Video/mirror/output/pressure
  behavior still requires native capture tests, especially both pipelines and dual mode.
- `ToolsUtilityModels` + native Files screen: bounded read-only UTF-8 source/
  Markdown preview, existing TextFormat/libprisma syntax highlighter, exact JPEG
  header heuristic, ImageIO pixel re-encode into a new JPEG preserving orientation
  while omitting EXIF/XMP/GPS source metadata. The original photo is not modified.
- `ToolsSubtitleTrack` + `ExteralessToolsVideoController`: real local AVPlayer playback,
  SRT/WebVTT picker, 1 MiB/10,000-cue limits, seek-correct overlapping cue lookup,
  subtitle overlay, per-local-video sidecar and Clear. This is an **iOS Files-player
  adaptation**; the shared Telegram gallery's external-subtitle insertion is not
  claimed. AVPlayer pause/observer/security-scope cleanup is explicit.
- Diagnostics: 20-second CADisplayLink callback-gap capture, actual getrusage CPU/RSS,
  thermal/low-power/battery readings, manual file export. Optional `tools.crashReports`
  caches at most four 1-MiB MetricKit payloads locally. No automatic upload. Android
  /proc, wake-lock hooks and Java/GIL stack sampling are not misrepresented as iOS metrics.

## Original defaults → actual iOS keys

| Original feature ID | Original default | iOS key / adaptation |
|---|---:|---|
| `nagram.autoUpdateChannel` | 1 (stable) | `tools.autoUpdateChannel`, **0/manual** on iOS; 1 stable, 2 prereleases |
| `chats.cameraMirrorMode` | true | `tools.cameraMirrorMode` |
| `chats.cameraStabilization` | false | `tools.cameraStabilization` |
| `chats.extendedFramesPerSecond` | false | `tools.extendedFramesPerSecond`; up to supported 60 FPS, multicam keeps budget |
| `chats.startWithWideAngleCamera` | false | `tools.startWithWideAngleCamera`; virtual rear camera only |
| `chats.zoomSlider` | true | `tools.zoomSlider`; native optical stops + slider |
| `chats.staticZoom` | false | `tools.staticZoom`; round-video pinch release/reset |
| `chats.rememberLastUsedCamera` | false | `tools.rememberLastUsedCamera`; round front/back selection |
| `chats.flashWarmth` | 50 (%) | `tools.flashWarmth`; exact blue/white/warm endpoints from `FlashViews.getColor` |
| `chats.flashIntensity` | 100 (%) | `tools.flashIntensity`; brightness + overlay opacity |
| `general.crashReports` | false | `tools.crashReports`; **local MetricKit/manual export** rather than Crashlytics upload |
| QuickToggleActivity actions (module, not ConfigItem) | — | `tools.quickToggles=false` is an explicitly new iOS launcher preference |

Updater `last_check` and `skipped_tag` are **state**, not dummy settings rows:
`ExteralessToolsLastUpdateAttempt` / `ExteralessToolsSkippedUpdate` UserDefaults
drive the actual schedule and notice. Round last-camera state is
`ExteralessRoundCameraUseFrontPosition`; it is not an account credential.

## Complete original-file mapping (29 files)

All paths below are under `TMessagesProj/src/main/`; `java/app/exteraless/` is
abbreviated as `java/`. Full pinned paths are in the parity inventory.

| Original file / main behavior | iOS effect, existing equivalent or exact remaining boundary |
|---|---|
| `java/backup/EtgBackup.java` `buildBackup/readBackup/applyBackup` | ToolsBackupArchive/ToolsLegacyBackup/ToolsBackupRestorer; versioned + legacy config data. **Apply binding pending** as specified below. Android mainconfig fields without registered native definitions stay ignored. |
| `java/backup/EtgBackupUi.java` export/confirm/file tap | ExteralessBackupController picker/share/preview/Apply; `openBackup(url:context:from:)` is the coordinator's chat-file seam. |
| `java/backup/InvisibleEncryptor.java` | ToolsInvisibleUnicode, original alphabet/prefix/base 11; described as obfuscation, not encryption. |
| `java/backup/AyuDatabaseImport.java` `merge/copyDeleted/copyEdited` | **Pending privacy/history adapter**, not a config archive. Requires a separately approved Ayu schema → local history model transaction. This domain opens no account/history DB; not claimed completed. |
| `java/updater/GitHubUpdater.java` | ToolsReleaseClient + ToolsReleaseVersion + ToolsUpdateSchedule + integration's schedule/skip state. Android `install()` becomes explicit external IPA signing/export. |
| `java/updater/UpdaterSheet.java` | ExteralessUpdateController real check/progress/error/cancel states. |
| `java/updater/UpdateSheet.java` | Same native screen, release notes, skip, download and export; UIKit frame pass pending. |
| `java/camera/CameraLensStops.java` | CameraZoomState(device:) + ToolsCameraPolicy.lensStops; actual optical/format stops, no synthetic lens. |
| `java/camera/CameraXSession.java` | LegacyCamera/CameraNeo AVFoundation sessions: focus, torch, selected lens, mirrored output, supported FPS/stabilization and dual budgets. Android backend names are not iOS selectors. |
| `java/camera/CameraZoomSliderView.java` | ExteralessCameraZoomControl UISegmentedControl/UISlider with logarithmic scale, VoiceOver, real rampZoom, frame coalescing. Native styling, not an unverified Pixel morph clone. |
| `java/camera/InstantCameraZoomSlider.java` | VideoMessageCameraScreen bind + KVO zoom state; round pinch reset/keep flag. No polling a guessed camera singleton. |
| `java/debug/JankProfiler.java` | ToolsFrameProfile + ExteralessToolsDiagnostics manual CADisplayLink session; explicitly callback cadence, not sampled Java/GPU frames. |
| `java/debug/EnergyProfiler.java` | Actual getrusage/system states and MetricKit payloads. Android background resume state, /proc threads and wake-lock hooks are unsupported on iOS. |
| `java/debug/PluginToggleTrace.java` | ToolsToggleTraceBuffer + diagnostics export; **producer hunk below pending coordinator**. No synthetic GIL/Java stack measurements. |
| `java/glyph/GlyphController.java` | **Hardware constraint**: original `supported = manufacturer == nothing`, Nothing proxy service/matrix. iPhone lacks this hardware/service. Native system LED alert settings are described, not programmatically impersonated. |
| `kotlin/app/exteraless/glyph/GlyphConfig.kt` | enabled=false; onNewMessage/onRecording/onCall=true; screenOffOnly=false. No inactive iOS toggle is registered. See separate Glyph constraint in JSON. |
| `java/shortcuts/QuickToggleActivity.java` | Real UIApplicationShortcutItems and Quick toggles screen; **app-lock routing + ghost/safe-mode closures pending coordinator**, exact seam below. |
| `java/utils/AppUtils.java` | 512 round output in both pipelines. Back gesture stock equivalent: Display/NavigationInteractivePopTracker + Navigation/NavigationContainer. General markdown-link scheme normalization is not reimplemented here; the stock external URL normalizer defaults to HTTP, so original HTTPS-normalization difference remains with chat/link owner. |
| `java/utils/FaveStickersBackup.java` | **Pending chat/account data adapter** for the original 10,000-entry, account-keyed opaque TL favorite list. `TelegramEngine/Stickers/SavedStickers.swift` supplies stock cloud favorites with server limits, not this local unlimited backup. |
| `java/utils/MarkdownUtils.java` | ToolsDocumentKind covers the source extension/special filename/MIME table; native source/Markdown reader and TextFormat syntax highlighter. Chat file-open insertion remains coordinator-owned. |
| `java/utils/MediaUtils.java` | ToolsJPEGPlatform full-prefix match; ExteralessPhotoUtilities pixel re-encode/metadata check + real Files export. |
| `java/utils/PredictiveBackAnimationHelper.java` | Stock iOS interactive navigation/transition remains live. Android M3 geometry and configurable intensity are **not** claimed ported; appearance/navigation owner. |
| `java/utils/UIUtil.java` | UIKit/native menu controls and camera controls; Android FAB shape/press choreography belongs to appearance. No global Android state-list animator was added or claimed equivalent by a getter. |
| `java/utils/VideoSubtitlesHelper.java` | ToolsSubtitleTrack + local AVPlayer screen/picker/sidecar/clear. Shared Telegram video-gallery integration remains with chat/player owner. |
| `java/utils/text/TranslatorUtils.java` | Delegated AI/SDK seam: AITranslationClient.translate/translateBatch and AITranslationLanguage. Tools does not replace provider/entity/callback implementations or claim SDK callbacks verified. |
| `kotlin/app/exteraless/utils/UtilsConfig.kt` | predictiveBackIntensity=100, 0…200 active clamp; applyMotionDefaults only without user override. iOS stock navigation exists, adjustable intensity remains **pending appearance**. |
| `java/crash/CrashLog.java` | Local bounded MetricKit crash payloads and native system readings; actual system delivery required. No Crashlytics credentials/upload or unsafe signal-handler replacement. |
| `java/crash/CrashReportDialog.java` | Native diagnostics list and share export; delivery-dependent rather than a fabricated last-crash alert. |
| `java/config/LegacyDefaults.java` | Core preserves existing overrides and supplies defaults without overwriting user settings. Android generation-2/migration markers are not meaningful iOS toggles; existing Android preference-file migration is not claimed. |

### Compatibility-storage slots (not functional controls)

`com/exteragram/messenger/ExteraConfig.java:48–51` explicitly documents its
storage-only fallback. `updateScheduleTimestamp` (1253), `sdkUpdateScheduleTimestamp`
(1261), `pluginsPySdkAutoUpdate` (1329), `pluginsPySdkBetaVersions` (1337),
`useGoogleAnalytics` (1237), and `enableAdBlock` (1245) read that fallback storage.
They are not GitHubUpdater.last_check, a working SDK updater, analytics or an
ad blocker. Their getter/setter IDs are classified `compat-storage` in the
fragment, with no fabricated iOS settings key. Camera settings and
`useGoogleCrashlytics` are mapped to real ChatsConfig/GeneralConfig fields instead.

## Exact coordinator API and insertion hunks

### 1. Public batch setter (core-settings owner; **not applied here**)

The current core store only offers per-key `setPublic`, which cannot implement an
atomic backup by looping. This minimal overload uses its existing writer/file lock,
validation, learned secret classification and single publish/write path:

```diff
@@ private enum Operation {
         case setPublic(String, ClientSettingValue)
+        case applyPublic([String: ClientSettingValue])
@@ public func setPublic(_ value: ClientSettingValue, for key: String) throws {
         try self.perform(.setPublic(key, value))
     }
+    public func applyPublic(_ values: [String: ClientSettingValue]) throws {
+        guard !values.isEmpty else { return }
+        try self.perform(.applyPublic(values))
+    }
@@ switch operation {
+            case let .applyPublic(values):
+                for (key, value) in values {
+                    let definition = try Self.definition(key, in: definitions)
+                    guard !definition.isSecret, !document.secretKeys.contains(key) else {
+                        throw ClientSettingsError.secretAccessDenied
+                    }
+                    document.values[key] = try definition.validatedValue(value)
+                }
             case let .set(key, value), let .setPublic(key, value):
```

Core already validates all candidate definitions before writing. Its post-rename
directory-sync error can mean the whole batch committed; Tools journals the old
values and rolls back an **attempted**, not merely returned-success, batch.
  Native failure/observer tests must cover that boundary before claiming verified.

### 2. Storage and runtime lease bindings

These are **actual Tools APIs** (no assumed PluginHost singleton):

```swift
let access = ToolsBackupSettingsAccess(
    snapshot: { try ToolsBackupSettingsSnapshot(ClientSettings.shared.readSnapshot()) },
    applyAtomically: { try ClientSettings.shared.applyPublic($0) } // hunk above
)
let backup = ExteralessToolsBackupBindings(
    settings: access,
    pluginLocation: readPluginSettingsLocation,
    beginMaintenance: beginPluginSettingsMaintenance
)
// Exact closure types the composition root supplies:
// @MainActor () throws -> ToolsBackupPluginLocation?
// @MainActor () async throws -> ExteralessToolsMaintenanceLease
// Lease.finish: @MainActor (Outcome) async throws -> Void
// Outcome: .committed / .rolledBack / .needsRecovery

tools.configure(backupBindings: backup, shortcutBindings: shortcutBindings)
```

`readPluginSettingsLocation` must pin `services.serviceStorage.settingsDirectory()`
and `[filename: Set<nonSecretSettingKey>]` from cached native settings-schema
metadata. Filenames are the real `PluginServiceStorage` id/UTF-8-hex components,
not display names. Unknown schema fields are deliberately not exported. Do not call
Python get_settings while inspecting a backup to populate this allowlist.
Return the canonical directory even if no plugins are installed: its parent holds
the recovery journal. Client-only restoration journals the public batch but does
not scan, copy or replace plugin data. A missing location refuses Apply before writes.

`beginPluginSettingsMaintenance` must reject new plugin operations, drain callbacks
and settings writes, and confirm no active/abandoned Python worker can mutate the
directory. Finish resumes the original enabled set only for committed/rolledBack;
needsRecovery keeps admission blocked. **`PluginHost.stop()` is terminal and may
abandon a worker (`PluginHost.swift:604–640`); `!isRunning` alone is not a quiescence
proof. Do not bind this to stop→start on the same host.** The host-specific lease
implementation belongs to coordinator. If it cannot establish quiescence it throws
before Tools stages/applies anything.

Before normal plugin startup, with that same storage binding, run
`ToolsBackupRestorer().recover(settings: access, plugins: location)` on a worker.
Failure keeps plugin startup blocked and presents recovery diagnostics. The tools
screen also recovers before a subsequent restore. Default construction deliberately
does not pretend an unbound Apply action succeeded.

### 3. Quick-toggle routing (**AppDelegate hunk pending**)

`ApplicationShortcutItemType` already contains `.toolsGhostMode` and `.toolsSafeMode`.
In `AppDelegate.handleShortcutItem`, inside the existing `context != nil` block
**after its existing app-lock gate**, add cases to the switch:

```swift
case .toolsGhostMode, .toolsSafeMode:
    ExteralessClientRuntime.shared.handleToolsShortcut(type: shortcutItem.type,
                                                       completion: completionHandler)
```

Add this exact forwarder inside coordinator-owned `ExteralessClientRuntime`:

```swift
func handleToolsShortcut(type: String, completion: @escaping (Bool) -> Void) {
    if !tools.handleShortcut(type: type, completion: completion) { completion(false) }
}
```

`ExteralessToolsShortcutBindings` takes four main-actor closures:
`ghostMode: () -> Bool`, `safeMode: () -> Bool`, and each `toggle…: () async throws -> Bool`.
The returned Bool is the **confirmed** state. Ghost changes must use the privacy
owner's `PrivacyPolicy.current.ghostModeChanges(enabled:)`, respecting locks, with
the public batch setter. Safe mode must use the coordinator's actual runtime
admission/restart logic; a stored Bool alone is not a binding. Tools does not import
or invent a privacy/plugin singleton. The iOS quick actions do not bypass app lock.

### 4. Live plugin toggle timings (**runtime hunk pending**)

In `ExteralessPluginRuntime.setEnabled(id:enabled:)`, keep the existing body but wrap
it with a duration record; add `import ExteralessCore`:

```swift
let started = ProcessInfo.processInfo.systemUptime
var succeeded = false
defer {
    ToolsToggleTraceBuffer.shared.record(pluginId: id, enabled: enabled,
        elapsed: ProcessInfo.processInfo.systemUptime - started, succeeded: succeeded)
}
// Existing ready()/setPluginEnabled/refresh/changed/loadError checks.
// Set only after those checks returned successfully:
succeeded = true
```

This measures the real operation, including errors, with a 40-record cap; it does
not claim to sample a GIL wait or Python stack. No telemetry leaves the device.

### 5. Optional chat file entry

The root needs this forwarder if chat/open-in integration is selected:

```swift
func openToolsBackup(url: URL, context: AccountContext, presenter: ViewController) {
    tools.openBackup(url: url, context: context, from: presenter)
}
```

Call it only after the existing native resource download has produced a local URL,
for `.exteraless-backup`/`.extera`. Keep the downloader and account/copy-protection
checks at the coordinator-owned chat callsite; there is no source/plugin execution
in this route. The Files entry already works without this optional chat insertion.

## Verification performed / supplied

- **Passed:** bounded source sanity on 31 owned/edited Swift files, 12 unique
  Tools definition keys each referenced by a consumer; no backup native secret
  accessor; balanced Swift delimiters/strings/comments. This is not typechecking.
- **Passed:** targeted `git diff --check` (only line-ending conversion notices).
- **Passed:** read-only `merge_parity` of the supplied fragment into the current
  catalog: **26 feature IDs, 9 module records, 12 compat-storage IDs, 96 source
  references checked; zero added verified claims**. The main catalog was not edited.
- **Supplied, not run here:** ToolsBackupTests (archive schema/checksum/limits,
  invalid paths/case aliases/symlinks, credential exclusion/preservation, legacy
  byte format/remaps; Darwin directory commit/rollback/interruption fixtures),
  ToolsReleaseTests (URLProtocol only: public headers, filtering, rate limits,
  tiny synthetic download, checksum failure cleanup, cancellation and numeric
  build comparison), ToolsUtilityTests (published SHA-256 vectors, real policy
  bounds/flash endpoints, source classification, subtitle seek/ranges, cadence).
  There are **32 supplied XCTest methods**; three directory replacement/recovery
  cases are Darwin-specific, while client-only journal/failure cases are portable.
- No external plugin corpus, real download, account mutation, CI dispatch,
  signing certificate or release publication was used.

After compiling Core on the coordinator's native/Linux runner:

```sh
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--package-path", "swift/ExteralessCore", "--skip-build", "--filter", "Tools"], check=True, timeout=30)'
```

Directory replacement/fault/recovery tests are guarded by `canImport(Darwin)`:
the shipping iOS filesystem operation must be exercised on macOS/iOS, not called
proven by Linux parsing. Full app build is required by Telegram's CLAUDE.md.

## Required frame/capture acceptance (pending MCP/device)

Expected frames, before recording:

1. Backup picker → static counts/integrity preview → applying row → result/error;
   table/keyboard/insets stay aligned in light/dark, large text, RTL, iPad and Duo.
   Cancel picker/inspection causes no Apply; malformed paths/checksum show readable
   errors. No preview frame executes a plugin or changes settings.
2. Updater spinner → release rows; byte count and progress advance together.
   Cancel stops the request, stale progress never returns. Digest/size error never
   shows Ready for signing. Share popover is anchored on iPad; there is no Installed UI.
3. Camera zoom stays in its parent-assigned band, does not overlap circle/record
   controls, disappears during result preview/holding/unsupported layout, and
   updates its label from actual KVO. Test pinch + slider + lens taps, front/rear,
   dual changes, detach and physical single-/multi-lens devices. New ramp is native;
   no Android morph choreography or overshoot pass is claimed.
4. Record both Legacy/Neo round outputs: verify 512×512, supported FPS, stabilization,
   actual mirroring and brightness restoration after stop/cancel/background.
   Frame/thermal/multicam budget regression tests are required after the dimension
   change. Output properties in a source file alone are not a captured-media proof.
5. Diagnostics 20-second stop and manual export, opt-in MetricKit delivery; source
   viewer remains read-only and literal HTML/source is never executed; clean photo
   keeps orientation and passes metadata inspection; AVPlayer subtitles follow seek,
   overlap and clear/close, including repeated picker cancellation.

Remaining common bindings, Ayu/local favorites/shared-gallery adapters, original
navigation-intensity/HTTPS-link differences and all native/visual verification stay
explicitly pending in the mapping. They are not hidden behind a completed module flag.
