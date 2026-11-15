# Bounded client UIKit acceptance harness

Status: **implemented source; native build/recording blocked pending cohort integration**.
This implementer has not run Swift, dispatched CI, or reviewed recorded frames.
The Core/Host results from `4b3f7064` are separate evidence; they do not establish
that this UIKit app builds or looks correct.

## What executes

`//Tests/ExteralessHarness:ClientUIHarness` is a separate loginless iOS app,
bundle `org.exteraless.ClientUIHarness`. Its uniquely named `MainApp`/delegate
do not invoke Telegram's application bootstrap. The harness uses the shipping
`Display.Window1`, `NavigationController`, Settings, Plugin Manager, Plugin
Settings and `PluginUIBridgeExtension` controllers. No SwiftUI replacement,
golden canvas, generated screenshot, or renderer/model mock supplies the pixels.

The AccountContext is an **explicit service fixture**, not proof of production
Telegram account services. `HarnessAccount.make()` from ComposerHarness creates
one disposable genuine Account/Postbox per process, supplementary mode, fixed
throwaway database encryption, and a closed `127.0.0.1:1` SOCKS5 proxy installed
before either account open. Its logger's file/console sinks remain off. The
harness supplies account identity/engine, account manager, the real Display
window and live PresentationData, plus the source-required offline inputs for the
explicit Feed renderer described below. Bazel generates other protocol members as
a named `fatalError` from the current `AccountContext.swift`; missing services
cannot quietly become zero, false, an empty account, or a successful request.
The process retainer follows ComposerHarness's queue-affine database lifetime.
Only the constructor/retainer source files are compiled into
`ClientHarnessAccount`; the unrelated Composer context conformers are not linked.
Source inspection found the existing Composer shared conformer missing the newly
added `makeShareScreen` requirement, so depending on its entire library would
break this gate before the actual UI compiled.

For `sdk-ui`, the actual `CPythonXCFrameworkEngine`, C bridge, PluginHost,
owner FIFO/callback gate, SDK loader/serializer and one bundled
`clientUIFixture.plugin` execute. The plugin directory starts empty. The source
is inspected, installed disabled, byte-compared with the bundled fixture, then
enabled with only UI/intents grants. Platform account slot **41** is explicitly
mapped to the disposable Account's id. Platform messages/network/clipboard/URL
services reject by name; URL/clipboard dispatch is also rejected before the UI
provider can schedule those effects. There are no external plugin inputs, plugin packages,
library installation from Python, user login, or real account operations.

The alert uses the existing SDK `AlertDialogBuilder` and portable EditText.
Sheet/menu use the SDK's real `Presentation` portable-model boundary; their
widgets are rendered by the production native provider. They are not claimed as
coverage of every Android builder alias. Native settings navigation goes through
`Fragment.presentFragment` → C → `uiNavigate` → the actual PluginSettings screen.
Native UI dispatch is observed by a transparent forwarder; diagnostic `uiState`
reads are counted separately from C-origin UI requests. Interpreter create/run/
destroy calls are passed unchanged to the real engine. Two distinct C/Host owner
epochs and complete interpreter destruction/finalization are required on reload.

## Scenarios and input delivery

Three scenarios run **sequentially on one newly created device**, one fresh app
process and report UUID each:

* `core-light`, `core-dark`: home button → real Settings → switch → selector →
  multiline text/keyboard → validated numeric editor, rejected `-1`, accepted `7`
  → back → persisted-store reload → isolated native secret-status rows → home.
* `sdk-ui`: home button → real Plugin Manager → plugin detail → real SDK settings
  → alert/keyboard/live dark-theme update/positive callback → sheet toggle and
  slider/action → immediate menu item → native settings route/back → zero SDK UI
  callback leases → manager disable/re-enable → fresh C epoch → shutdown.

Input is **scripted UIKit**, an option allowed by the task: `UIControl.sendActions`,
the visible UITableView's selection delegate, navigation item's actual target/
action, Display's accessibility back action, and `UITextInput.insertText` on the
visible first responder. No private renderer action or duplicated settings logic
is invoked. This is not XCUITest/HID touch-path, VoiceOver-tree, gesture-physics,
autocorrection or IME acceptance. Controls/rows must actually exist in the live
window. Row search scrolls at most four times and never manufactures cells through
the data source. Mutation assertions read the actual Core store or SDK-owned
native storage, not the requested candidate. Any missing scenario/probe fails.

## Expected recorded frames — specified BEFORE recording

All timings below are expectations from **each action**, not frame-index clocks.
Actual action/probe timestamps are in `state.json` (`wallTime`, `elapsed`); the
recording start bracket is in `timing.json`. Recorder acknowledgement has latency:
use the bracket to locate the transition, then quote the actual `ffprobe` PTS and
sheet indices. Do not assert sub-frame alignment from the host timestamp estimate.

The first 0.25 s after recording acknowledgement is still time. Navigation gets
at least 0.65 s settling; transient panels get at least 0.30–0.35 s; keyboard
focus gets 0.40 s followed by text delivery and 0.20 s. Semantic waits are bounded
to 1.5 s. The normal script should finish well under 20 s after recording starts.
There is 0.40 s of passive final still time. The app's 30 s process deadline also
includes account/Python bootstrap and waiting for the recording trigger.

| Probe / action | Expected frames and resting state |
|---|---|
| `home` → `settings-root` | The harness-labelled home gives way to the **production** grouped list. Native push moves the incoming list from right; the title/chrome follows its native morph, with coordinated phase but different travel. Roughly 0.5 s, within the 0.65 s settle. No stationary row left behind, duplicate title, blank gap or clipped leading/trailing cell edges. |
| `toggle-confirmed` | The switch shows the confirmed old value during persistence and then on. No transient permanent optimistic state. No row height jump, missing switch or title overlap. |
| `selector-open` → `selector-committed` | Plain/Ocean choices; checkmark on the confirmed choice. Selecting Ocean persists and pops using Display navigation. Root detail reads Ocean. No white frame in dark mode; no extra row oscillation. |
| `text-keyboard` | Real multiline UITextView contains `Fixture text 雪`; software keyboard is drawn, and the observed Display input height exceeds 100 pt. Text/caret must remain above the keyboard, clear of the navigation bar and rounded cell edges. No separate fake keyboard rectangle. |
| `text-committed` | Keyboard dismisses with the native transition, editor pops, root shows the complete stored value. No duplicated caret or one-frame text disappearance during handoff. |
| `number-error` | Numeric draft `-1` stays editable; a visible red **Settings error** row explains rejection. Stored value remains 0. Error text wraps; keyboard, editor and error must not hide the usable caret or Save button. No successful pop. |
| `number-committed` / `core-cleanup` | Entering `7` persists, error/editor leave, then back returns to the harness home. Persisted reload returns all four exact values. The short secret-status segment below follows; final cleanup again shows home with no retained keyboard, overlay, or extra screen. |
| `secret-availability` (both core palettes) | The real generic Settings list shows **Confirmed absent → Not set**, **Known quarantined → Stored value unavailable**, **Never observed → Secure storage unavailable** simultaneously. The native Settings error row can also explain the deliberately unreadable backend. All detail UILabels must fit/wrap without clipping, match the current light/dark palette and remain distinct after the normal initial reload. Neither `ExpectedLegacySecret` nor a false `Stored securely` status is visible. Back returns home. |
| Every `core-dark` probe | Same geometry/actions, current Telegram dark backgrounds/text/navigation/keyboard. No light-color flash between opaque native surfaces. Light case must remain light throughout its scenario. |
| `plugin-manager` → `plugin-settings` | Production manager displays the sole **Owned UI Fixture**, real running state and fixture-service runtime label. Real detail/settings route moves as one native push. Titles/details wrap without covering the switch or disclosure. |
| `alert-shown` | SDK alert panel, message/input/action animate together: ~0.20 s ease-out, scale 0.97→1 and fade, no overshoot. Dim layer covers background evenly; corners clip only their intended rounded shape, never text or buttons. |
| `alert-keyboard` / `alert-dark-draft` | `Snow 雪` and its selection/focus survive the live PresentationData dark update. Input remains visible above the actual keyboard. No second input, draft reset, misplaced caret, bright flash or intermediate zero-width rewrap. |
| `alert-closed` | Positive action reaches Python with `which=-1` and exact draft, then dismiss/closed/release FIFO. ~0.18 s fade-out, no overshoot or residual panel/dim layer. Underlying SDK settings are usable again. |
| `sheet-widgets` → `sheet-closed` | Bottom sheet enters with 24 pt vertical translation + fade over ~0.20 s; widgets/action move together. Toggle on and amount 75 are visible; Apply sends both real values. Exit ~0.18 s, ~20 pt down, no overshoot, clipped slider thumb, missing label, or dim-layer residue. |
| `menu-shown` → `menu-closed` | Immediate SDK menu renders both native actions; second action returns zero-based index 1 and dismisses with the same panel timing. No stale menu remains above the next navigation. Persistent five-placement menu injection is not part of this narrow gate. |
| `sdk-navigation` / `sdk-leases-clean` | Actual PluginSettingsController titled **SDK native settings** pushes and pops. Provider visibility follows the native window, not admission. Back exposes the original settings, and inspecting leases reports count=0, handles=0. |
| `fixture-reloaded` / `sdk-cleanup` | Manager's real switch unloads and reloads only the fixture, with Running/Disabled states coherent with Host completion. Back returns home; zero first responder/extra controllers, all three interpreters (inspector + two generations) destroyed, CPython finalized once. |

These from-rest, noninteractive Display slides use
`NavigationTransitionSpring.noninteractive` (damping ratio 1, response 0.3):
expect a critically damped approach, **zero body overshoots**, settling around
0.5 s. No expand transition or swipe release is requested. Compare incoming
content and navigation chrome together; the harness adds no animation. The SDK
panel's explicit ease-in/ease-out animations also have **zero overshoots**.
Scrutinize every `gap`/`jump` flag and its neighbors. A list refresh
can legitimately change a value at once; an isolated bright frame, clipped control,
or screen moving separately from its content cannot be approved from a metric.

This first gate does not cover iPad/landscape, accessibility text sizes, share
activities, server actions, full domain registrations, account replacement races
or persistent menu placement hooks. The fixture definitions are explicitly named
`harness.*`; their pass is acceptance of the connected Settings infrastructure.

### SCR01 secret-label follow-up — existing core scenarios

`Sources/ClientHarnessSecretAvailability.swift` adds **one probe** before
`core-cleanup` in each of `core-light` / `core-dark`. The eight-scenario **3+3+2**
selection and process counts remain explicit. Expected frames above are specified
before recording; the coordinator's Core SCR01 Mac passes do not verify these labels.

One isolated ClientSettings file and an injected synchronized dictionary/failing
ClientSecretStore provide exactly three final String-secret definitions, each
with the nonempty source default `ExpectedLegacySecret`. The initial owned file
contains legacy JSON `false` for the known key. The absent key first exercises a
real public CAS set/reload/reset, using only `readSnapshot()` results as expected
states, then receives its monotonic secret schema promotion. Native registration
rejects the wrong legacy type; native reset confirms absence and quarantines the
other key's raw `false` through the supplied backend. A selective read failure
then proves known presence survives reload, while the third key has been unreadable
since its first read. Public CAS against the promoted secret is rejected without
backend I/O. No snapshot constructor or replacement renderer supplies any state.

The existing `exteralessSettingsController(context:settings:)` mounts that separate
store. Its normal first-layout/refresh completes before inspection of the actual
visible detail UILabels. Push settles for 0.65s, readiness is bounded to 1.5s, the
three-row resting frame holds another 0.15s, and pop settles for 0.65s: typically
about **1.5s additional UI time**, at most 2.95s of explicit UI waits. Preparation
uses a finite worker sequence on its private file. The existing native alarm and
external **30s total process ceiling** still include this work; no extra process.

The `secret-availability` semantic payload contains actual label text/class/window
rect/color, redacted typed availability and known-presence bits, backend counts
and build-input fingerprints. Use its `wallTime` and the existing recording-start
bracket to find the MP4 frames, then cite **ffprobe PTS / frame indices** from the
standard sheets. Inspect the native initial reload, the settled three statuses
and the return to home in both palettes; source/semantic checks alone are not a
recorded-frame pass.

**Small build handoff:** the new helper is already selected by
`ClientUIHarnessLib.srcs = glob(["Sources/*.swift"])` and the existing
`DomainFingerprintInputs` source glob. Display/ExteralessCore/Foundation/TelegramUI/UIKit
imports use current edges; **no runtime assets** are added. The helper reads the
existing bundled `client-ui-domain-sources.json` and requires its own source,
scenario/router sources, **BUILD + Info.plist frozen configuration**, actual
Settings controller/helper, and ClientSettings/definition/value/secret-store source
pins. These are already declared in the joined fingerprint groups; preserve them
when building the new source cohort. The Python change is only the added entry in
`CORE_PROBES`; existing contract fixtures derive their list from that constant.
The original core store/data and SDK/context setup are not rebound by this segment.
Production `settingRow`, BUILD/workflow and native execution remain coordinator-owned.

Source checks for this segment: **7 driver-contract tests passed**; the inlined
Swift core sequence matches all **11 CORE_PROBES**; all **11 required source/config
fingerprint paths** and existing glob coverage were verified. The three cohorts
remain 3+3+2. These are source/driver checks; new UILabel frames remain pending.

## Coordinator production seams (apply once, before CI)

Exact source hunks are in
[`telegram-ios/Tests/ExteralessHarness/Integration/production-hooks.patch`](../../telegram-ios/Tests/ExteralessHarness/Integration/production-hooks.patch).
Integration status:

1. `Display.nativeWindowHostView(windowScene: UIWindowScene? = nil)` attaches the
    scene **before** its root controller, preserving actual keyboard ownership.
   **Applied by the coordinator**, confirmed in the current source (the scene
   assignment precedes root controller creation).
2. `PluginManagerActions.settingsScope` optionally supplies an owned lifetime
   predicate; Manager passes it when opening Plugin Settings. Existing app callers
   retain their current runtime default.
3. `exteralessPluginSettingsController(context:actions:pluginId:title:pagePath:scopeIsCurrent:)`
   exposes only the real renderer's dependency-injected factory, with an explicit
   scope. No public fake-user constructor or CallbackOwner initializer is added.

The patch remains the source-hunk reference; its Display hunk is already applied.
The UI owner/coordinator handles the remaining Settings hunks. Check/apply those
separately, excluding the completed Display hunk. If concurrent changes have moved
the initializer, preserve all current arguments and apply the same optional
dependency addition rather than replacing that file.

### Existing BUILD files — build-agent integration

This role owns only the **new** harness BUILD. Existing BUILDs/workflows are read-only.

Add to `submodules/AccountContext/BUILD`:

```starlark
filegroup(
    name = "ClientHarnessProtocolSource",
    srcs = ["Sources/AccountContext.swift"],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)
```

Add to `Tests/ComposerHarness/BUILD` (no existing source changes):

```starlark
filegroup(
    name = "DisposableAccountSources",
    srcs = [
        "AppContext/HarnessAccount.swift",
        "AppContext/HarnessProcessRetainer.swift",
    ],
    visibility = ["//Tests/ExteralessHarness:__pkg__"],
)
```

In `Telegram/BUILD`, add `visibility = ["//Tests/ExteralessHarness:__pkg__"]` to
`MtProtoKitFramework`, `SwiftSignalKitFramework`, `PostboxFramework` and
`TelegramUIFramework` (currently private). `TelegramCoreFramework` is already
public. The app's `frameworks` array uses those exact five targets. Its
`MainApp` → `ClientUIHarnessLib` has direct TelegramUI, AccountContext,
PluginHost and ExteralessCore dependencies; no cycle back from those modules is
introduced. Protocol stubs' imports have matching direct targets, following
ComposerHarness, including `MediaPlayer:UniversalMediaPlayer`.

**Debug-only is intentional.** Both existing exported-symbol rules keep every
symbol in `-c dbg`; the driver accepts only `debug_sim_arm64`. Do not run this
client against a release-filtered framework: if release harness support is later
required, add these clients to `TelegramUIFrameworkExportedSymbols.clients` and
`TelegramCoreFrameworkExportedSymbols.clients` first:

```starlark
"//Tests/ExteralessHarness:ClientUIHarnessLib",
"//Tests/ExteralessHarness:ClientHarnessAppContext",
"//Tests/ExteralessHarness:ClientHarnessAccount",
```

The harness bundles AppStringResources, generated PresentationStrings.data,
Telegram/Legacy assets and full runtime resources. `RuntimeResources` retains
`python/` and `python-stdlib/` paths. `RuntimeFrameworks` includes Python plus all
**54** CPython extension frameworks and any admitted native frameworks from the
current staging manifest. No handcrafted subset is silently substituted.
Packaging verifies resource SHA-256s, fixture bytes, arm64 **simulator** Mach-O
platform 7, executable/framework rpaths, and the actual Python load command.

## Build, run, and CI economics

New workflow: `.github/workflows/client-ui-harness.yml`, **workflow_dispatch only**,
`contents: read`, no secrets/PAT/signing identities, **xcode-27**, one job/no matrix.
Xcode is derived from `telegram-ios/versions.json`: currently
`/Applications/Xcode_27.1.app`. `DEVELOPER_DIR` selects it for this job; the native
version preflight and Make's version check both remain mandatory.
It uses the existing checked unsigned rules patch and forbids signatures/profiles
in the resulting harness app. `Main/main.m` has a process-local 30-second SIGALRM
deadline; the external driver independently enforces 30 seconds from launch.
Each scenario is short, native Host calls time out after 2 s, and the pool is capped
at two live interpreters. A hung main thread cannot disable the C deadline.
The first gate launches exactly three fixture app processes (`core-light`,
`core-dark`, `sdk-ui`) on its one fresh simulator. It needs no additional CI
secrets; the optional Feed proposal does not enlarge this default run.

The build driver reuses Make's configuration and flags and analyzes/builds both
**top-level applications together** (`//Telegram:Telegram` and the harness),
including the normal six extension packaging actions. It runs the existing full
unsigned/runtime structural validators. It never runs Make.py against a bare
Swift library. The content-addressed disk/download cache paths and restore prefix
match ios-build. The harness has a separate stable source/output root; actions
whose keys contain absolute source paths can miss across the two roots. Best
reuse requires the same Xcode, `debug_sim_arm64` configuration and source cohort.
Release/device objects do not become simulator objects through caching.
Two Bazel jobs, a 4 GiB Java heap, a 6 GiB scheduling resource budget and a 110-minute
build deadline bound this first manual build. Scheduling limits are not per-plugin
RSS claims. No simulator is booted during compilation or frame analysis.

**Runner correction:** `ios-build.yml` already uses `xcode-27` and selects Xcode
27.1 from versions.json; baseline full IPA run `43635233046` used that app build
environment. The previous harness default of macos-26/Xcode 26.6 was wrong.
Those runners belong to the Foundation/CPython component checks. Xcode 27.1 is
available for the app graph, including `UIView.reservedRegions`; no SDK API,
`#available` guard, or version preflight is bypassed. The new harness still needs
its source seams integrated and its own recorded run.

### Confirmed baseline CI provenance

The coordinator successfully retrieved the Actions job metadata after the earlier
transient connection failure:

| Field | Recorded value |
|---|---|
| Workflow | `.github/workflows/ios-build.yml` |
| Full IPA run | `43635233046` |
| Job id | `132570467870` |
| Conclusion | `success` |
| `labels` | `["xcode-27"]` |
| `runner_group_name` | `GitHub Actions` |
| `runner_name` | `GitHub Actions 1000000255` |
| Version-derived app toolchain | `/Applications/Xcode_27.1.app` |

This records the known Actions runner that successfully built the baseline full
IPA. The workflow source independently confirms its label and version-derived
Xcode selection. It establishes the app build environment's provenance; the
new harness's compile and recorded-frame acceptance remain separate evidence.

### Persistent CI source ownership and scheduling

The source is now
`/Users/Shared/exteraless-client-ui-harness/telegram-ios`; its Bazel user root is
the sibling `bazel-user-root`. The normal app's `/Users/Shared/telegram-ios` and
`/private/var/tmp/_bazel_containerhost` are separate. These are owned workflow
directories on the Actions CI runner identified above. Directory admission uses
the sentinel/generation/lock contract, with no `RUNNER_ENVIRONMENT` classification
requirement or inference about a local interactive user Mac.

`tools/runtime/client_ui_harness_workspace.py` owns the parent directory:

* Initial claim creates a **new** directory and repository/path-specific
  `.client-ui-workspace.json`. An existing unmarked, foreign or symlinked root is
  refused. There is no recursive root deletion, adoption or `sudo chown`.
* Refresh holds an OS advisory lock and runs `rsync --delete --delete-excluded`
  **only inside its `telegram-ios` child**. Git pointers and stale local
  `build/`, `build-input/`, `bazel-*` outputs are excluded there. The parent
  sentinel/lock, sibling Bazel user root and shared action/download caches remain
  outside that deletion scope.
* Staging publishes `ready=false` before sync, then the successful run/attempt
  generation. Prepare/build/record commands take the same lock and require that
  exact ready generation. A failed copy or another stage between workflow steps
  cannot silently become this run's source. The lock is held until each child
  command finishes, with a 30-second bounded acquisition wait.
* Each run uses a fresh `mktemp` diagnostics root under `RUNNER_TEMP`; leftover
  previous-job data cannot turn older build JSON or frames into this attempt's
  artifacts. Pillow is installed into that run's analysis venv. Artifact names
  include run id **and attempt**.

The workflow-level `client-ui-harness` concurrency key queues harnesses across
refs. Its job-level `ios-build-${{ github.ref }}` key matches the current normal
app workflow, providing same-ref admission coordination. The workspace file lock
protects the harness tree; the existing app workflow does not take that lock.
Shared cache restore/save and aggregate Mac RAM across **different refs** still
need the agreed build-agent scheduling change before parallel dispatches.

**Exact scheduling handoff for the build owner:** change the normal app's
workflow concurrency and this harness's **job** concurrency to
`group: exteraless-ios-app-graph`, both `cancel-in-progress: false`. This creates
one app-graph queue across refs including the cache actions. Keep this harness's
outer single-harness queue. The current normal app's `cancel-in-progress: true`
can cancel a same-ref harness if explicitly dispatched over it; the coordinator's
sequential dispatch avoids that while the common queue is agreed. No existing
workflow was edited by this role.

After applying the seams, use the workflow's stage/exec wrapper on that Mac
(`WORKSPACE_GENERATION` is the current run-id/attempt; cache envs match ios-build):

```sh
python3 tools/runtime/client_ui_harness_workspace.py stage \
  --root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" \
  --generation "$WORKSPACE_GENERATION" --source "$GITHUB_WORKSPACE/telegram-ios"
# The workflow prepares runtime inputs under the same exec wrapper first.
python3 tools/runtime/client_ui_harness_workspace.py exec \
  --root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" \
  --generation "$WORKSPACE_GENERATION" --seconds 6720 -- \
  python3 tools/runtime/client_ui_harness_build.py \
  --telegram-root "$SOURCE_DIR" --output "$CLIENT_UI_RUN_DIR/build" \
  --cache "$BAZEL_DISK_CACHE" --bazel-root "$BAZEL_USER_ROOT"
python3 tools/runtime/client_ui_harness_workspace.py exec \
  --root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" \
  --generation "$WORKSPACE_GENERATION" --seconds 600 -- \
  "$CLIENT_UI_RUN_DIR/frame-env/bin/python" tools/runtime/client_ui_harness.py \
  --telegram-root "$SOURCE_DIR" \
  --ipa "$SOURCE_DIR/bazel-bin/Tests/ExteralessHarness/ClientUIHarness.ipa" \
  --staging-manifest "$SOURCE_DIR/build-input/exteraless/runtime-staging.json" \
  --output "$CLIENT_UI_RUN_DIR/evidence"
```

Frame tools are CI-only: CPython 3.12 + SHA-256-pinned Pillow wheel, and pinned
arm64 ffmpeg/ffprobe release assets (compressed and decompressed hashes checked).
The app's Python bundle is not modified to install analysis tools. Dependency
pins live in `Tests/ExteralessHarness/Tools/`; the workflow installs them after
the app build. All execution and downloads have finite timeouts.

The device driver uses **simctl create**, never clone, reuse, erase or `booted`.
Only the randomly named `EXL-UI-<uuid>` device it just created receives this app.
Cleanup checks its exact UUID/name/type/runtime before shutdown/delete. No global
simulator shutdown, existing account/keychain export, or shared clipboard read.
The installed app is always from the fresh `.ipa`, never `archive-root`.

## Artifact and review contract

`client-ui-evidence-<run_id>-<attempt>` contains the `evidence/` tree below, plus
the narrow `build/` diagnostics and `tools/frame-tools.json`:

* `acceptance.json`, `owned-device.json`, `driver.log`, packaging/build preflights;
* per scenario: `recording.mp4`, `record.log`, `last-screen.png`, `state.json`,
  `timing.json`, app stdout/stderr, `ffprobe.json`, `animation-analysis.log`;
* `frames/sheet-NN.png`, `frames/motion.png`, `frames/frames.tsv`, and individual
  `frames/frames/NNNNN.png` from the **existing** `tools/animation_sheet.py`.

The recorder is `simctl io recordVideo --codec=h264`, with SIGINT finalization.
Variable-rate frames are decoded in order and labelled by **ffprobe PTS**, never
index÷FPS or ffmpeg's fallback decode times. Only narrow harness JSON/trace data
is copied from its fresh container. Account databases, encryption keys, settings
directories, C source strings and aquery file-write contents are not uploaded.

CI success says **recorded-awaiting-visual-review**, never visual pass. The
coordinator downloads the actual sheets and reads them end to end, opens full
frames around every flag/transition, and compares with the expectation table.
For a close inspection, rerun the existing animation-sheet tool over the actual
transition's ffprobe time range with a crop/track selected from its resting frame.
Report defects or acceptance with scenario, sheet, `#frame` and `t=...` references.
Do not promote this gate on a missing recording, model-only result, source-only
check, zero-probe execution, or build success alone.

## Local checks

Windows can run the deterministic Python driver-contract tests and source
preflight (`--phase preflight --source-only`). These verify ownership selection,
artifact provenance/deadline parsing, fail-closed evidence and current protocol
stub generation. They do not compile Swift or render UIKit. Native build and
recorded-frame review remain pending the coordinator's single bounded CI run.

Initial implementation checkpoint: **7 driver-contract tests passed**; all six
then-owned Python/plugin sources parsed, Info.plist/JSON pins parsed, manual-only
single-job workflow YAML parsed, and the production hook patch passed
`git apply --check` against the then-current sources including
`PluginManagerControls`. Source preflight reported the unapplied
factory/window/protocol-source seams and private framework visibility.

Runner/ownership correction: **8 focused tests passed** for unmarked/foreign tree
refusal, safe reuse, generation invalidation after failed sync, lock exclusion
through child execution, overlapping paths, version-derived Xcode selection and
rejection of an older SDK. These use temporary files and the host OS lock, with
rsync/native commands recorded rather than executed on Windows. Changed Python
and workflow YAML syntax/source checks passed, as did `bash -n` for all 10 workflow
command blocks. The first three UIKit scenarios
were not expanded or rerun by this correction; no native/visual pass is implied.

## Implemented explicit domain batch (after the first gate)

Implemented source entry points: `feed-render`, `player-render`, `pill-render`.
Select them with three explicit `--scenario` arguments. The unchanged default
remains the original three Settings/SDK scenarios. Mixing the two batches,
duplicates or more than three cases is rejected; one fresh simulator runs one
fixture process at a time, each with the same independent 30-second ceilings.

### Bootstrap and SDK joins

**Frozen bootstrap handoff for App/Retention:** the exact public calls, private
storage/process-role requirements and the `HarnessAccount.make()` typed-failure
adapter point are recorded in
[`Integration/bootstrap-compatibility.md`](../../telegram-ios/Tests/ExteralessHarness/Integration/bootstrap-compatibility.md).
The PFR01/PFR04 join must preserve fresh valid-archive startup through real
readiness or supply an exact coordinator-applied caller adaptation. Versioned
unavailable/failure cannot be weakened into successful readiness for this fixture.
The scenarios/driver remain frozen pending the joined cohort.

`Sources/ClientHarnessBootstrap.swift` configures the real process environments
**before `HarnessAccount.make()` and its first AccountManager/Postbox writer**:
the shared Core store has an isolated file plus injected in-memory private
storage, the complete Retention definition snapshot with `.mainApplication`
process role, and a syntactically valid synthetic API id/hash through
`ExteralessClientAPIEnvironment`. The actual native resolver owns account pin and
marker writes. The native Account factory still awaits `exteralessRetentionReady`;
no retention default, skip flag or weaker construction path substitutes for it.
The original constructor still configures closed SOCKS5 **before either Network**.
The private backend contains only our synthetic tuple; no system Keychain or real
account/API credential is used or exported.

The finalized `plugin-ui-harness-remediation.patch` has been applied to
`ClientHarnessRuntime.swift`: actual `PluginUISettingsActionAuthority` binds its
record/slot 41, the settings factory receives `actionScope`, mutation/click forward
task-local owner/account/worker predicate, stop revokes authority, and the native
release closure returns actual admission. This preserves the real CPython fixture
and HNS-04 settings execution contract; nil/default authority is not a fallback.

### Actual rendering paths

* **Feed:** `ClientHarnessFeed.swift` calls the owner's public
  `makeExteralessFeedSmoke` once, mounts its UIKit controller, uses `setEdited` and
  `dispose`, and waits for actual `ChatMessageBubbleItemNode` instances with drawn
  geometry. Six fixture messages form four rows; two albums share numbers across
  distinct peers. `ClientHarnessFeedStore` additionally seeds those native messages
  and a same-number Local-namespace exclusion sentinel into the disposable
  Postbox, then calls **`exteralessFeedFreshMessages`**. Current membership, peers,
  edited text and namespace filtering must agree. The seed reuses the PNG bytes
  already written by the real smoke fixture; no second canvas/image renderer is
  introduced. The smoke's immutable native projection snapshots and the real local
  transaction check are separately labelled in evidence. This narrow run does not
  claim the retained-window producer cache, pagination completeness or Gallery
  export revocation proven by that separate transaction.
* **Player:** `ClientHarnessPlayer.swift` uses the new production
  `ExteralessPlayerVisualSurface` / `ExteralessMiniPlayerVisualSurface` contract in
  `docs/player-remediation.md`. The same shipping Surface → LyricsView render/tick
  code receives 30 finite local plain/synced lines, a fixed paused sample, native
  theme colors and the **real monotonic clock**. No replacement MediaManager,
  playback engine, audio output or HTTP client is constructed. Native elapsed text,
  visible cell identities/colors, scroll offset and seek-intent callbacks are
  observed. The five-second manual-follow interval expires on camera before the
  palette render **and another actual same-position tick**, covering FU-04's sequence.
* **Pills:** `ClientHarnessPills.swift` uses the real `ExteralessPillIntegration`,
  independent Settings action, `ExteralessPillEntry` header and Settings table.
  It hides the final Cache pill through its row, returns to a zero-height header,
  re-enters Settings and enables Cache. Then finite native `PillPluginProvider`s
  enter the **production registry/runtime/header**: synchronous loading→ready,
  cancellation with a trailing value pending, and a new owner of the same ID.
  Late retired values must not render, and all three owned subscriptions cancel.
  This is native provider/UI evidence, not CPython PluginPill bridge evidence.

Feed and Player mount the actual mini view/publisher at bottom 64 pt then top
52 pt, sampling `ExteralessContentOcclusions.shared` for the same account/window.
Published rectangles must match the rendered native view, then clear on stop.
Placement itself is the harness's explicit docking layout; production root-tab
docking, Feed receipt admission and all export/Photos flows are outside this case.

Required context additions are source-checked stock offline inputs only:
`ContentSettings.default`, `AppConfiguration.defaultValue`, peer-name palette
defaults, `.tlottie`, `EnergyUsageSettings.default`, and automatic-download settings
with both connections/background downloads disabled. Feed alone constructs the
genuine DCT animation cache/renderer. `ClientHarnessFetchStatus` supplies the
**real MediaBox resource status** for the one owned local PNG because
`PhotoResources.chatMessagePhotoStatus` requires FetchManager even when cached;
fetch/control methods remain named traps. The other services still trap by name.

### Expected domain frames — specified before recording

Each navigation settles for 0.65 s; fixture updates get 0.2–0.55 s plus bounded
readiness checks. Mini geometry animates for 0.3 s ease-in/out with **zero intended
overshoots**; its native 64/52 pt geometry, text and controls move together. These
figures describe intended behavior, not measurements. Timestamps/frame indices
in review must come from the actual ffprobe/frame-sheet artifacts.

| Scenario / probes | Expected recorded frames and semantic rest |
|---|---|
| `feed-initial`, `feed-albums` | Real native bubbles, photo/album tiles, spoiler text, forward/reply and counts; four complete composite rows across the bounded scroll. No empty image gap, doubled album, cross-peer photo flash or clipped channel/header text. Root/peer/message identities remain distinct. |
| `feed-edited`, `feed-dark` | The owner's retained controller updates the styled text/counts with stable message IDs, then repaints with current dark PresentationData. No white table flash, incorrect reply identity or stale light text. Native transaction evidence excludes the Local-namespace sentinel; it must never be drawn. |
| `feed-bottom-player`, `feed-top-player` | Actual Player mini overlays actual bubble rows at bottom 64→top 52 pt. Recorded publisher rectangles follow the same moving view; no second bar, stale rectangle or clipped controls. This records composition/occlusion publication, not receipt eligibility. |
| `player-plain-light`, `player-plain-dark` | Paused elapsed label stays `0:13`; the same visible plain cells and offset survive light→dark, and every visible text color changes. No seek intent or reloaded/duplicated cells. |
| `player-karaoke-light`, `player-paused-scrolled`, `player-paused-dark` | Real Inline→Karaoke layout, manually scrolled far from the active cue. Hold >5 s of real time; dark update plus same-position tick must leave the same cells/offset at rest. All visible colors update together, active index remains the supplied paused cue, no automatic jump back and zero seek. |
| `player-mini-64`, `player-mini-52-top` | Real mini controls/fonts fit both heights; top/bottom transition is smooth and settles before probing. The publisher's steady rectangle equals the drawn bar, with no old geometry after retirement. |
| `pill-last-hidden`, `pill-independent-settings`, `pill-cache-enabled` | Hiding Cache removes the entire header band. Settings → Status Pills remains reachable with an empty layout; enabling Cache restores the real reading/header without a blank reserved strip. |
| `pill-dark-header`, `pill-provider-loading`, `pill-provider-ready` | Native dark colors; actual spinner/loading followed by Ready one after the registry's trailing slot (250 ms scheduling policy plus dispatch/render time). The header's 0.16 s cross-dissolve changes text together, with no stuck loading or clipped text/ring. |
| `pill-cancel-pending`, `pill-reloaded` | Cancel before owner two's ready slot; only owner three's final reading appears after reload. `RETIRED MUST NOT RENDER` never becomes visible. |
| Every `*-cleanup` | Real domain views are removed/empty; mini publication is empty, Pill registrations/subscriptions are gone and native seek count is zero. The harness home is the sole navigation root. |

Typical active sequences target Feed ~8–12 s, Player ~12–18 s including the real
five-second hold, Pills ~10–16 s; startup and all activity still fit the hard 30 s
process budget. The standard recorded still-time brackets and passive tail apply.

### Source provenance and build-owner handoff

`Tools/domain_source_manifest.py` generates `client-ui-domain-sources.json` from
**declared Bazel source inputs**. The app reports the bundled manifest and the
driver compares it with the installed-build IPA resource, validates its complete
graph/digest, and uploads `domain-source-fingerprints.json`. Missing required
native/bootstrap/renderer source edges fail before simulator creation.

Exact source groups, two DCT dependency labels, genrule/resource entry and CLI
choice are in
[`Integration/domain-build-handoff.md`](../../telegram-ios/Tests/ExteralessHarness/Integration/domain-build-handoff.md).
The existing harness BUILD/workflow and `client_ui_harness_build.py` remain with
the build owner during its NativeIntegrationTests work. Native factories remain
with the Feed/Player owners; this role changed no production renderer.

Run only after their latest FU01–04 fixes and the SDK HNS-04 account-arity join are
included in the compiled source cohort. Coordinator evidence
`43703427760` / `c7ef` (150 Host + 24 Hooks and six Feed Core regressions) remains
component evidence, not native UI execution. This implements bounded source
acceptance; no recorded frames, native run or all-feature visual pass is claimed.

Domain implementation checks on this Windows host: **5 focused domain-driver
tests passed** (selection quota/opt-in, source-digest graph, composite Feed identity,
paused/no-seek Player and pending-cancel Pill generations). Python parsing passed
for 10 harness/tool files; UTF-8/trailing-whitespace checks passed for 18 Swift
files. Current protocol generation emitted 280 named traps, and the FetchManager
adapter's requirement names were checked against its current source protocol.
The native source-manifest generator/checker accepted a live 195-file source
sample; the definitive manifest will be generated from the build owner's declared
Bazel inputs. The finalized HNS harness patch passed reverse `git apply --check`,
confirming that its complete authority/worker-bound join is present. These are
source/driver checks only; no baseline scenario, UIKit process, CI job, account,
network request, commit or push was run by this implementer.

## Final explicit visual batch — Avatar and Composer

Source entry points **`avatar-render`** and **`composer-render`** form their own
explicit batch. The baseline (3) and Feed/Player/Pills (3) invocations keep their
own ordered/count guards. The additional invocation selects exactly these two
when both are required; no mixed groups or more than three fresh processes per
driver. All use `//Telegram:ClientUIHarness`, bundle
`org.exteraless.ClientUIHarness`, from the **same joined IPA**. Each invocation
owns a new simulator, with sequential app processes bounded to 30s including
bootstrap. The default CLI cohort remains the three baseline cases.

### Source/build and bootstrap join

[`Integration/final-visual-build-handoff.md`](../../telegram-ios/Tests/ExteralessHarness/Integration/final-visual-build-handoff.md)
lists the direct module edges, exact source fingerprint groups, resource/output
handles and third recording invocation. Its companion
[`composer-native-factory.patch`](../../telegram-ios/Tests/ExteralessHarness/Integration/composer-native-factory.patch)
is an **unapplied coordinator handoff**: one DEBUG wrapper over the shipping
`inputPanelForChatPresentationIntefaceState`. It reuses the actual panel producer,
including its existing parser and MediaItemNodeView factory. This source must be
joined before compiling the same app. No production renderer is copied into the
harness and the existing ComposerHarness app is not selected implicitly.

The PFR public bootstrap constructors remain compatible. The new harness-owned
`ClientHarnessReadiness.swift` additionally observes the actual public pre-Account
recovery center/current typed failure before opening the existing constructor.
Failure terminates and disposes this run; only the native factory's authorized
result succeeds. Full Retention registration, private synthetic API storage and
closed loopback-before-Network order precede all of it. This resolves the older
NoError-wrapper adapter point without editing Account/Retention/ComposerHarness.

### Actual visual paths

**Avatar:** the same live AvatarNode survives both palette sequences. Its real
DirectMediaImageCache is warmed from two complete, read-back-verified local PNGs
in the disposable MediaBox. The thin cache adapter only holds/releases real cached
images to exercise the owner's generation seam; every recorded lookup must be a
native cache hit. No live photo resource or remote avatar loader is supplied.
Legacy `setPeer` uses actual `overrideLetters`; V2, bubble resize and
`setCustomLetters` execute the owner's AF-01…04 backends. Forum comparisons are
the output of real `peerAvatarCompleteImage`, displayed as UIImageViews without
harness clipping; their photo/fallback alpha, unrounded output and caller fonts
are checked from the actual decoded/composited images.

**ASC01:** two `ValuePipe` emissions occur **after ImageNode.setSignal returns**,
so the old bitmap already occupies an active native crossfade layer. A
CADisplayLink captures the presented old bitmap, resets to Q on the **second
display callback**, and captures the new letters after two further callbacks.
Reset must occur before 0.2s and while the old bitmap/animation is still installed.
An unrelated owned empty layer survives; the old layer loses bitmap/animations
and attachment. After new cached V2 green arrives, the old completion is invoked
and may affect only its retired layer. All of this happens in the recorded live
view in both palettes. PNG writes happen after reset, outside the two-frame gate.

**Composer:** actual ChatTextInputPanelNode → RichTextEditorChatInputNode →
RichTextEngineEditorView, with the production media and paste factories. Its host
only supplies scene layout and the normal state echo/undo funnel. Selection uses
the live UITextInput's own text, positions and selectedTextRange, including the
table cell's off-flat-axis range after an emoji. The production Format Date
UIAction captures `beginNativeDateEditing`; the fixture answers that native picker
completion with a finite timestamp or zero. Mention uses the same
`beginSelectionMention` completion as the peer picker. The picker presentation
itself is not covered by these fixed answers. No alternate editor, flat draft
reconstruction, network lookup, account stand-in or replacement media view is used.

The finite draft is heading + underlined body word/struck tail + authored quote +
two-cell table + **96pt actual local PNG with caption** + a literal code block.
Every operation compares the whole native ChatInputContent; undo also compares
the actual Document identity. Date add/remove preserves structure and underline;
Mention touches only the first cell; code paste keeps the entire URL including
`utm_source`, with zero calls to the genuine wrapped markdown parser. Context and
interaction services outside these paths trap by name. No blanket reuse of the
12 native editing fixtures' contexts or id-only placeholder media is involved.

### Expected frames — specified before recording

No acceptance frames have been captured here. Target active time is Avatar
~9–14s and Composer ~8–14s, within the existing 30s total process ceiling. Ordinary
state steps hold 0.15–0.35s, navigation 0.65s, keyboard focus 0.5s plus readiness.
Actual timing comes from the recorded variable-rate PTS, not these estimates.

| Probes (both Avatar palettes) | Expected frames / settling |
|---|---|
| `avatar-{light,dark}-legacy` → `v2-pending` → `v2` | Same native node: square A raster, then a deliberately held 150ms image-only empty state, then red round V2. No old square corner, queued green child bitmap or resurrected parent raster after the font/round reset. The final red image is a native cache hit. |
| `bubble-60`, `bubble-38`, `bubble-100` | The native bubble tail and image resize together at each discrete geometry update; radius is zero and the same named native mask is resized. These are immediate clip changes, **no spring/morph or overshoot is intended**. No leftover circular edge, old-size mask or missing tail. |
| `letters`, `blank`, `override` | B, blank initials and actual overrideLetters Q replace the image at the same view identity. No old child/unrounded bitmap over the letters, and no delayed old photo returns. Native glyph/background draw is used throughout. |
| `active-fade-reset` (`events`: `fade-installed`, `active-frame-1`, `active-frame-2`, `reset-to-letters`, `letters-presented`) | Real red→green ImageNode crossfade starts with its usual 0.2s ease-in/out, **interrupted after two displayed frames**, never allowed to finish before reset. The old presented bitmap disappears with semantic reset; Q is visible on the following frames, without a residual red/green veil. No overshoot. Native before/after captures support inspection; every corresponding MP4 frame must be read. |
| `v2-return` | New V2 green replaces Q, stays green across the delayed old completion/publications, with no ghost letters or old crossfade layer. |
| `forum-{0,14,28}-{native,unified}` | Four primary samples: regular photo/letters and forum photo/letters. Each photo/placeholder pair has the same contour. Native forum differs from regular at 14/28; singleRadius unifies them; 0 is square. The second row shows unrounded photo/letters and forum fonts 9/20: no corner clipping in `.none`, visible font difference with the same outer contour. |
| Every dark Avatar step | Native dark surrounding palette/labels, caller-theme legacy letters and unchanged owned red/green photo bytes. No pale flash outside an explicitly replaced native image. |
| `avatar-cleanup` | Avatar and previews removed; all ten held cache/child subscriptions have one start/one cancellation; the home is the sole root. |

| Composer probe | Expected frames / settling |
|---|---|
| `composer-rich-light`, `composer-date-selected` | Production heading, authored quote, two-cell table, captioned local photo and code block; body word `date` selected after 😀, with the real software keyboard. Selection/caret and panel remain clear of the keyboard and navigation bar. No dummy media rectangle. |
| `composer-date-added`, `composer-date-add-undone` | Only selected `date` gains the native date marker; one undo restores the exact draft/document. Heading style, quote author, table geometry, media width/caption and code remain intact. No flat-text rewrite, duplicate block or relayout flash. |
| `composer-date-removed`, `composer-date-remove-undone` | Removing the marker retains authored underline; undo restores the marker once. Surrounding native blocks stay stable. |
| `composer-cell-selected`, `composer-cell-mentioned`, `composer-cell-undone` | Highlight stays inside the first table cell, despite its zero-length composer-flat projection. Mention affects only `cell`; the adjacent `other` cell and all outside blocks stay unchanged. Undo returns the real Document, without jumping the selection into body text. |
| `composer-code-pasted`, `composer-code-undone` | Literal `https://example.test/?utm_source=code&keep=1` appears in the native code block unchanged; wrapping/scroll reveal follow the native editor. No cleaner strips query bytes or promotes a web preview. Undo restores the previous rich document. |
| `composer-rich-dark` | Same production editor and full draft, localized cell selection and dark input palette/keyboard. No bright editor flash, content reset or change to unaffected media/quote/table geometry. |
| `composer-cleanup` | Real keyboard/panel dismissed; no first responder, retained media view or additional navigation controller. |

Display navigation keeps the existing critically damped, zero-overshoot contract.
Keyboard/panel changes follow the **observed Display container layout**, including
real input height; keyboard motion is not synthesized. Root ChatController height/
inset composition, Date/peer-picker presentation, live media, and the remaining
native regression permutations still require their own evidence.

### Indexed evidence and review handles

Each added scenario retains the standard `recording.mp4`, `ffprobe.json`,
`frames/sheet-NN.png`, `frames/frames/NNNNN.png`, `frames/frames.tsv`,
`state.json` (semantic probes + trace), `timing.json` and actual source manifest.
It also retains declared, SHA-256/size/IHDR-checked **`native/*.png`** captures of
the real views; only those handles are copied from the app, not its account data.

`frame-handles.json` records **every ffprobe PTS in decoder order, duplicates
included**, with its unique zero-based frame path, sheet/tile and semantic JSON
pointer. Probe and ASC01 event wall times give a recording-start **bracket** plus
candidate indices on either side. They do not manufacture exact sub-frame sync.
Use that bracket to open the full transition, then report the actual `#index /
t=PTS` range after viewing it. Crop Avatar by `semantic.windowFrame`, Composer by
`panelWindowFrame` / `editorWindowFrame`, using points and the recorded screen
scale. Enlarge the small avatar crop to judge tails, corners and the ASC01 veil.

Review every flagged gap/jump and neighboring frame; all before/after frames of
the active reset are mandatory. The summary remains
`recorded-awaiting-visual-review` until that separate evaluation. These two final
families address the additional AGENTS recording requirement; they do not establish
an all-feature visual pass from source checks or unit-level opacity assertions.

Final-visual source checks on this Windows host: **18 Python driver-contract tests
passed** (7 baseline + 5 domain + 6 final-visual), including ASC01 active-vs-finished
fade rejection, localized cell edits, literal URL bytes, duplicate/variable PTS
handles and bounded PNG exports. The current native interaction constructor's
**132 ordered slots** match the explicit harness adapter. All **36 mandatory new
source paths** were checked: the sole absent source is the handed-off 24-line
factory, whose patch passes `git apply --check`. Python AST checks passed for the
three drivers/two tools; UTF-8/whitespace checks passed for 27 harness Swift files.
These checks do not typecheck UIKit. The factory and declared BUILD/resource edges
must be joined before native execution; recordings and visual review remain pending.
