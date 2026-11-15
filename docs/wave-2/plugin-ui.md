# PluginUI phase 2 / Runtime composition — handoff

Owner: native-plugin-ui-runtime-composition. Updated 2026-11-15.
**Source implementation is integrated in the owned files; native compilation,
execution and recorded-frame acceptance remain pending.** This supersedes the
phase-1 handoff and its unapplied Runtime/Host/settings examples.

## Applied bindings

`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`
constructs each registered provider once, retains it, and installs this composite
before the first real `host.start(safeMode:)`:

```swift
ui, ClientSettingsBridgeExtension(permits: { callbacks.hasPermission($0, $1) }),
tl, native, pills
```

- UI, TL, NativeServices and PluginPill all receive the latest AccountContext
  before startup and update/clear with the root. Termination clears them before
  terminal Host stop. Native provider convenience initializers retain their
  acknowledged, bounded cleanup transports.
- `PluginPillBridgeExtension(services:callbacks:identityURL:)` uses
  `context.sharedContext.basePath/exteraless/pills/plugin-identities.json` exactly
  as `pills-wire.md` specifies. Root Client Pill update precedes Plugin Runtime
  update; identity archive I/O remains in the provider's off-main implementation.
- `NativeServiceOpenHooks.shared.install(provider: native)` is installed before
  startup with `.chatDocument`, `.externalURL`, `.applicationURL`. The coordinator
  has applied all three opener insertion groups. Both owned UI URL paths
  (`Runtime.openURL` and clickable message links) use this barrier and repeat
  captured owner, account, UI visibility/revision and intents checks in the
  continuation before `UIApplication.open`.
- NativeServices phase-2 `publisherSites: [.committedMessages, .mediaFetch]` is
  **applied** after confirming the coordinator's three real Core producers:
  `AccountStateManager.swift:1240` reads added messages before notification
  filtering, `EnqueueMessage.swift:990` publishes returned ids after commit, and
  `FetchedMediaResource.swift:84-130` wraps only the ranges overload, subscribing
  once to the original fetch. The provider's 12-event/10-ready-cache availability
  contract remains authoritative; this binding does not fabricate ready values.
- TL observational payloads retain the deep codec. `tlTransforms` is installed
  after `installHooks`, updated at the start of `refreshSubscriptions`, disabled
  on account clear and detached/nil before Host stop. Its payload type is supplied
  by the TL/Host owner; no substitute type is declared here.
- `onOwnedCallback(pluginId, ownerToken, handle, method, json, delayMs) -> Bool`
  synchronously captures the actual `CallbackOwner` and compares its exact
  `wireToken` before the main hop. Delay retains that owner. Rejection returns
  false without releasing transaction-ledger-owned C handles.
- Startup now calls `ExteralessToolsHostMaintenance.recoverBeforeStart` with
  **the same `services.serviceStorage.settingsDirectory()`** before Host starts.
  It uses a real fresh-Host lease and blocks startup on failed journal recovery.
- The existing AI message-menu insertion and Manager AI review row are retained.
  Tools toggle tracing records the actual enable operation, with success assigned
  only after Host/load-error checks.

### UI owner / admission / cleanup contract

`PluginUIBridgeExtension` publishes `exportedMethods`. Its request parser accepts
the C-injected root `ownerToken` and `value:null`. Present/update/dismiss/menu
replace/remove revalidate the originating token against the captured current
owner **inside the lease-store admission lock**. A newer owner is never substituted
for an old request by looking up the plugin id after a delay.

The actual constructor is wired to:

```swift
callback: { owner, handle, method, json in
    callbacks.callback(owner, handle, method, json,
        shouldExecute: { uiGate.permits(owner: owner, argumentsJSON: json) },
        guaranteed: PluginUICallbackGate.isTerminal(argumentsJSON: json))
},
release: { callbacks.release($0, $1) } // Bool, not Void
```

`uiGate.bind(ui)` is applied. Host checks this Foundation-safe predicate in the
actual owner mailbox immediately before Python entry. Its current implementation
and limits are authoritative in `host-maintenance.md`.

The reserved lane is bounded: 16 KiB callback payload, 4 MiB outstanding payload,
1024 global / 128 per-owner controls, executing entries included. `_uiTerminal`
marks the small native retirement batch; it does not bypass account/revision
validation for user callbacks. `closed` is SDK bookkeeping only.

`PluginUIReleaseQueue` retains a refused terminal callback **and** a refused
release. It retries only the unadmitted suffix, in order, on the captured owner.
The lease store reserves retiring handles/quota before returning a retirement;
new leases for that owner are refused until cleanup is admitted or Host retires
the owner. Thus repeated show/replace/close cannot build an unlimited retry queue.
Callbacks accepted before retirement precede dismiss/error/closed and release in
the same FIFO. Native final-decision metadata remains valid under bounded history
eviction, while retaining its owner/account gate. Share/menu action admission
failures produce a named error.

Account replacement retires presentations with **no new user or closed callback**;
`release_handles_json` closes SDK bookkeeping and releases native handles. An
already-queued `closed` may finish bookkeeping across a switch; queued user actions
are denied by `_uiScope`/`_uiLease`/`_uiRevision`. Persistent menu registrations
survive account changes with a new scope/revision; old rendered rows cannot act.

## Native UI surface

All files below are under
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/`.

| Source | Actual behavior |
|---|---|
| `PluginUIModel`, `PluginUIRequest`, `PluginUILifecycle` | Bounded typed DTOs, positive C handles, captured scopes/revisions, actual-appearance state, exactly-once retirement and cleanup quota |
| `PluginUIBridgeExtension`, `PluginUICallbackGate`, `PluginUIReleaseQueue` | C admission, main-only UIKit, mailbox predicates and bounded FIFO retry |
| `PluginUIContentController`, `PluginUIViews`, `PluginUIAppearanceObserver` | Alerts/loading/progress/spinners, bulletins/toasts/undo, sheets, pages, real share completion and native appearance |
| `PluginUIWidgetContainer`, `PluginUIStyleModel`, `PluginUIResources`, `PluginUILinkTextView` | Portable padding/layout/weights/margins, visibility, named images/fonts, real blur and selectable clickable text |
| `PluginUIMenuModel`, `PluginUIMenus` | Five original placements, bounded read-only conditions and native menu/list row factories |
| `PluginUISettingsDocument`, `PluginUISettingsRefresh` | Named-icon projection and real open-page refresh subscriptions |
| `PluginUINavigation`, `PluginUIShareFiles` | Source-pinned route DTOs, bounded readback, authorized regular-file resolution |

Implemented native methods: `uiPresent`, `uiUpdate`, `uiDismiss`, `uiState`,
`menuRegister`, `menuRemove`, `uiActiveFragment`, `uiNavigate`, `uiRefreshSettings`,
`addToClipboard`, `openURL`. Presentation kinds are alert, bulletin, toast,
bottomSheet, immediate menu, share, settings and page. Persistent menu registration
is distinct from an immediate menu presentation.

- `uiState.visible/isPresented` comes from actual native appearance/window state,
  never successful request admission. Terminal state/history is bounded.
- Widgets include text/header/divider, input/edittext, toggle/switch, selector,
  slider, image, row and column. Numeric layout is in **native logical points**:
  width/height `fill|wrap|-1|-2|0...8192`, padding/margins `[left,top,right,bottom]`
  or named fields `0...512`, alignment `fill|start|center|end`, weight `0...1000`.
  Invisible reserves geometry; gone collapses it. Narrow/accessibility rows become
  columns. Compatible updates preserve input drafts and selection.
- Images are named semantic aliases in `PluginUIImages.aliases`, `sf:<symbol>` or
  `bundle:<relative asset>`. Fonts are `system`, `monospace` or an installed
  PostScript face, optionally `{name,size:1...128,weight}`. UIKit resolves resources
  on main before admission. Missing names return **ResourceUnavailable**, not a
  silently empty image or substitute font.
- Alerts/sheets accept `blurredBackground`, `blurBehind`, `messageClickable` and
  actual ARGB button colors. Blur uses `UIVisualEffectView`. Clickable text is a
  real selectable UITextView and link activation passes the native URL barrier.
- Arbitrary Android View/Drawable/Typeface objects, integer drawable/Lottie ids,
  resource providers, unsupported layout units and arbitrary MVEL remain named
  unsupported surfaces. No JVM view or reflection behavior is fabricated.
- Limits include 16 presentations + 64 menus per plugin, 128 + 512 globally,
  512 widget nodes / depth 8, 256 choices, 256 KiB aggregate input values,
  512 KiB request and 256 terminal history entries. A single atomic replacement
  may temporarily retain its old cleanup reservation.

### Settings and live menus already applied

`PluginSettingsController.swift` observes refresh, preserves invalidations while
busy, pins account/interpreter lifetime and rejects late navigation. Selector and
input subcontrollers keep the same scope; invalidated input drafts remain visible.
Named icons are applied by a wrapper around the existing settings document.

The harness production seams from `Integration/production-hooks.patch:20-73` are
applied: optional `PluginManagerActions.settingsScope`, the captured predicate
passed into the settings controller, and public `@MainActor`
`exteralessPluginSettingsController(...,scopeIsCurrent:)`. Existing controls and
constructor dependencies are retained.

`ContextUI/Sources/ExteralessPluginMenuEntry.swift` is applied. Its dependency
direction is verified: ContextUI already depends on AccountContext; the reverse
path does not reach ContextUI. It reactively copies `ContextController.Items`,
including list/twoLists, preserving reaction/tip metadata.

Owned callsites are live in source:

- `Chat/ChatControllerOpenMessageContextMenu.swift`: plugin-only empty-menu check
  and final `actionsSignal` wrapping after custom-emoji replacement, retaining AI.
- `Chat/ChatControllerOpenPeer.swift`: bot/user more-menu wrapping.

## R-runtime: original 16-ID receipts

[`runtime-parity.json`](runtime-parity.json) retains all 16 original ids, kinds,
defaults, reference categories and source anchors. It currently records **8 source
implementations, 3 partials, 5 exact excluded mechanisms**, all `ported:false`.

- `PluginManagerPreferences` is an atomic installation-wide JSON store, separate
  from plugin-owned settings. Fresh engine/developer/compact/safe/pin/mute defaults
  are false. Native automatic-on upgrades are persisted once.
- Pin changes actual ordering; compact changes actual row detail. Developer mode
  enables reload/diagnostics and the real authenticated loopback server in
  `PluginDeveloperServer`, using the original `python/sdk/dev_server.py` protocol.
  Bind/operation errors are visible. Session invalidation is synchronous; source
  upload rechecks it before metadata and installation. `debugpy` attach and Elyx
  are explicitly unavailable; package presence is not debugger success.
- Engine Off / Safe Mode use actual `beginSettingsMaintenance` and
  `finish(resume:)`. Enabled plugin choices survive. Initial safe startup calls
  `host.start(safeMode:true)`; explicit exit loads intentionally omitted enabled
  plugins. CPython stop/start is not used to imitate a runtime switch. Failed
  quiescence, persistence or resume remains an error with actual Host state.
- Root maintenance reserves before its first await, including the no-Host case;
  root plugin operations cannot overlap the protected file transaction. The
  single-decision finish completes independently of caller cancellation.
- `PluginRuntimeRecovery` arms an atomic early-start journal immediately before
  Host startup. Three consecutive unclean, unattributed starts request real safe
  mode. Healthy 15-second survival, backgrounding, account clear, termination and
  caught startup failure disarm it. This is **conservative native unclean-start
  detection**, including possible foreground force-kill, not Java exception/stack
  attribution. A known-plugin native `.watchdog` marker is excluded from the global
  early-start counter. Notices persist until explicitly acknowledged.
- Mute gates a real Host not-responding alert; isolation/limits remain active.
  A crashed-plugin notice is recorded only after Host actually disables that
  previously enabled plugin. Its underlying Host marker fix is still pending below.
- `pluginSettingJson` is a per-plugin storage API receipt. Compatibility Mode and
  the four Xposed flags have exact Android ART/library exclusions; there are no
  fake JIT/debugger/hook-availability settings.

## Remaining exact owner hunks

### Coordinator: common menus and root Tools

[`plugin-ui-common-hunks.patch`](plugin-ui-common-hunks.patch) contains only the
remaining avatar, forum/channel, Saved Messages, profile and main/drawer insertion
groups. It uses current native types and constructors. Main/drawer adds a selector
observer; `PluginListController.deinit` already removes selector observers.
The applied message/bot callsites and registry are not duplicated in this patch.

Root Tools should obtain its backup argument from:

```swift
ExteralessPluginRuntime.shared.toolsBackupBindings(context: context)
```

Pass that value to the existing `tools.configure(backupBindings:shortcutBindings:)`
after the root's account identity check, retaining the coordinator's real shortcut
bindings. The same value can supply Cloud's `configure(backupBindings:)`.
Do not wrap Host directly with unconditional `finish(true)`: it would resume the
original enabled set after the user selected Engine Off / Safe Mode.

The root method returns real `ToolsBackupSettingsAccess.clientSettings` plus a
schema-restricted location on the same native storage. Only successful, already
returned settings JSON is recorded with `account:<record>:epoch:<captured token>`.
Unload/reload/context change invalidates it; failed parsing invalidates prior
permission. A frozen pre-pause location survives the native lease. Missing/current
owner-mismatched schema exports no plugin fields. Inspection starts no Python.

### SDK owner

[`plugin-ui-sdk-hunks.patch`](plugin-ui-sdk-hunks.patch) is an exact unapplied patch
for the currently read `_ui.py` and `_registrations.py`:

- portable padding/LayoutParams, named fonts/images, named item icons;
- live builder updates with stable listener wrappers and loading/spinner defaults;
- portable settings refresh with generic change/action/longAction callbacks;
- pinned Fragment navigation and native menu-context/Message snapshot projection;
- destructive button color clears an earlier explicit ARGB override.

Blur fields, clickable-message fields, visibility and ARGB setter already exist
in the SDK. The patch connects builder lifetime and does not duplicate those
implementations. `native_owned` and SDK-aware `release_handles_json` remain intact.
SDK behavioral/fixture validation remains with that owner; only in-memory syntax
validation of the proposed patch is performed here.

### Host owner: watchdog gaps keeping two receipts partial

`PluginWatchdog.recoverAfterCrash()` reads `.watchdog`, then calls
`clearMarkerNow()`, whose `persistedMarker != nil` guard is false on a fresh actor.
Set `persistedMarker = crashed` immediately before that successful-read clear.
Do **not** make every fresh `stop()` remove an unknown on-disk marker: pre-start
Tools maintenance deliberately stops services before crash recovery consumes it.

In `scheduleMarkerClear`, replace the ignored sleep cancellation with:

```swift
do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
catch { return }
guard !Task.isCancelled else { return }
await self?.clearMarkerNow()
```

The Host owner should also connect actual application backgrounding to its
`noteAppBackgrounded` / healthy-strike reset, independently of whether any plugin
subscribes to app events. These actor methods currently have no production caller.
The UI early-start journal already receives the real `app_pause` hook; it does not
pretend to clear the Host's private per-plugin strikes.

### Harness / Build owners

- `ClientHarnessRuntime.swift`'s UI `release` closure needs `return admitted`
  after its existing admission journal/check (lines 60-64 in the read version).
  The production factory/scope seams are applied; the harness file is not owned
  by this task.
- Add `PluginRuntimeRecovery.swift`, `PluginRuntimeMaintenance.swift` and
  `PluginUIReleaseQueue.swift` to `ExteralessNativeUIContractSources` beside its
  existing PluginUI Foundation files. Production already uses the recursive glob.
- Apple imports include Network for the developer transport, UIKit, Foundation,
  CoreFoundation and UniformTypeIdentifiers. No new Postbox/TelegramApi import,
  allowlist exception or cross-module stub is introduced.

## Checks and native acceptance

Local receipts for this final source slice:

| Check | Result |
|---|---|
| Native source checks | PASS — 72 dependency targets; provider/epoch/FIFO/mode/Tools bindings, scoped refresh and all 16 original-ID receipts |
| Full PostboxImportCheck | PASS — run from `telegram-ios`, no allowlist changes |
| Common and SDK patch preflight | PASS — both `git apply --check`, patches remain unapplied |
| Owned tracked diff hygiene | PASS — only Git LF/CRLF informational warnings |
| Foundation fixture | PENDING — `swiftc` unavailable; 36 scenarios authored |
| UIKit/Network/recorded frames | PENDING — native runner required |

All owned executable checks have an outer 30-second cap. The Foundation runner
has a 20-second compilation / 25-second total deadline and returns 77 without Swift.

```text
python telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_source_checks.py
python telegram-ios/build-system/Make/PostboxImportCheck.py telegram-ios
python telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_fixture.py
git apply --check docs/wave-2/plugin-ui-common-hunks.patch
git apply --check docs/wave-2/plugin-ui-sdk-hunks.patch
```

The **36 authored Foundation scenarios** include lifecycle/visibility, account and
revision races, immutable C token, FIFO refusal/retry/owner replacement, layout and
resource DTOs, source pinning, settings refresh, share-file policy, persistent
manager defaults/order/write failure, early-start recovery/notice consumption,
developer framing/auth/upload bounds and cancellation-independent maintenance.
They construct no account, UIKit window, interpreter or socket.

Native compilation, actual Host mode transitions, TCP operation and UIKit frames
remain pending. Earlier Core/Host/C probe greens are separate evidence. No CI,
external plugin, account/network effect, commit or push was run for this slice.

### Expected frames, specified before recording

Follow `telegram-ios/AGENTS.md` using variable-rate `simctl` video and labelled
`ffprobe` timestamps. The shipping controller/harness is the renderer.

- Alert/sheet text, actions and panel move together: approximately 0.20-second
  entrance (24 pt translation, alert scale 0.97), 0.18-second exit, no overshoot.
  No clipping, duplicate layer, light flash or keyboard-obscured caret. Reduce
  Motion omits the transforms/fades.
- Light/dark, narrow/large type, padding/weighted rows and live theme updates keep
  inputs/drafts/selection and usable action geometry. Named image/font failures
  show the named error rather than empty successful UI.
- Bulletin undo wins over delayed commit; share cancellation and page back remove
  their actual native surfaces. Account switch removes accepted popups and denies
  already-queued user callbacks.
- Manager pin visibly moves the row; compact shrinks detail; engine-off removes
  installed rows; safe-mode leaves diagnostics accessible with execution controls
  disabled. Preferences reflect confirmed storage, and a native mode failure is
  shown as failure. Recovery notice disappears only after acknowledgement.
- Check each menu insertion, and each terminal cleanup path, from its actual UI
  entry point. `ui-harness.md` supplies the narrow loginless SDK/settings scenario;
  it is not evidence for unrecorded persistent menus, iPad share or socket paths.

Report frame indices and timestamps for the observed transitions. A source check
or green build alone is not a visual acceptance result.
