# Normal Telegram first-launch smoke

## Baseline and expected frames (defined before recording)

The baseline is production commit `79fedf4f4324bc5f8f65b573370bd03fda3daa57`.
The coordinator's later AppDelegate/app-group error-presentation fix must **not**
enter this baseline snapshot. The user report concerns a black screen in build 41
on a physical iOS 27.0.1 device with an unchanged BundleID.

Expected: within 20 seconds the **normal Telegram** first launch displays its
onboarding/login UI, or a visible explicit startup error. A settled black/empty
window, crash, or failed launch fails this smoke. An explicit error is useful
diagnostic evidence, not proof of a healthy onboarding path. A nonblank image or
surviving process alone cannot establish semantic success.

Normal `AppDelegate.swift` obtains `group.<BundleID>` before account setup. The
baseline missing-app-group guard attempts `Error 2` and returns early; the
coordinator is investigating scene attachment and signed capabilities. A black
frame alone does **not** prove the app-group URL is nil. This driver adds no
instrumentation and claims that condition only if actual diagnostics expose it.

## Execution boundary

`.github/workflows/telegram-launch-smoke.yml` uses the existing `xcode-27` runner,
the `versions.json` Xcode 27.1 pin and existing iPhone 17/runtime selection helper,
restricted to an available compatible generic iOS 27 runtime. It creates a fresh
device; it never clones, selects a preexisting UUID, or installs on a user device.
The created UUID, name, type and runtime are checked again before cleanup.

The source workspace is `/Users/Shared/exteraless-launch-smoke`, with the existing
workspace helper's sentinel, generation and lock. Its required children remain
`telegram-ios` and `bazel-user-root`. No output-base reset or broad cleanup runs.
The main-branch launch phase checks4 GiB actual free space without deletion: it
does not invent a completed native-test receipt to call post-native reclamation.
The already-dispatched baseline snapshot retains its historical helper call.
Frame dependencies are checksum/hash-pinned and installed
before the full build consumes disk. Resources are staged by the existing lock-
verifying preparer, including `.runtime` inputs, archives and application assets.

`tools/runtime/telegram_launch_smoke.py --phase build` reuses
`client_ui_harness_build.build` with its production unsigned/runtime aquery
preflight and jobs=2 cached full graph. Although that helper also compiles the
harness target, **only `//Telegram:Telegram` is installed and launched here**.
There is no native 434-test or 20-scene prerequisite. The current graph's exact
`bazel-bin/Telegram/Telegram.ipa` is verified and retained immediately; the stale
archive-root directory is never used. All six extensions remain intact and no
codesign command or bundle rewrite is applied.

API credentials follow the normal iOS workflow's Actions secret injection;
values are not printed. Full private aquery contents are deleted, never uploaded.
Known API hash values are removed from retained text logs/reports, including
failure logs. Reports publish only the startup-relevant Info.plist key allowlist.

Launch uses `simctl launch <created UUID> <actual normal BundleID>` with stdout/
stderr capture and **zero app arguments**. In particular it does not use
`--ui-test`, fake Account data, harness runtime, deep links, plugin injection,
login/phone entry, or send actions. The normal app accesses only its genuinely
fresh simulator app group and may use its built-in Telegram network transport.

## Evidence and verdict

* `telegram-build.json`: current Git SHA, declared production base SHA, driver
  SHA-256, actual main IPA SHA-256, current Bazel output path, safe plist/scene
  metadata, unchanged BundleID and preserved extension identities.
* `expected-before.json`: the above frame criteria, written before device creation.
* `owned-device.json`, `launch-*-command.json`/streams, app stdout/stderr: created
  UUID and actual launch PID/error. Each command retains separate streams.
* `screen-02s.png`, `screen-10s.png`, `screen-20s.png`: actual simctl screenshots.
  `launch-result.json` records requested offset plus actual monotonic start/end
  relative to the launch command (a slow launch can make the first capture late).
* Per-offset launchctl evidence retains only the exact bundle rows and checks the
  original returned PID; device snapshots come from `simctl list` and retain only
  the owned simulator. Crash evidence is **paths/metadata only**, bounded to new
  matching Telegram reports with the own bundle and PID/device match.
* `first-launch.mp4`, `ffprobe.json`, `frames/frames.tsv`, `frames/sheet-*.png`:
  passive H.264 recording starts before launch. Frame times are actual ffprobe
  PTS, never inferred from frame index/fps. Sheets use the existing animation
  tool at the iPhone 17's 3x scale. Partial genuine videos survive failures.

The driver catches black/uniform central content at the endpoint, excluding the
status/home bars. This is a rejection heuristic, **not** a semantic recognizer.
A complete recording's status remains `recorded-awaiting-visual-review` with
`visualPassed: false`; a reviewer must inspect onboarding/error and cite frames.
Failed installation/launch preserves the real logs and any genuine video. It
never fabricates a substitute screenshot. The owned simulator is terminated,
shut down and deleted before frame analysis.

The job has a 215-minute cap, a 112-minute full-build envelope and a 5-minute
launch/analysis envelope. Both full failure diagnostics and launch evidence are
uploaded, plus the exact retained main simulator IPA if built. This test cannot
confirm behavior, entitlements, saved user data or frame pacing on physical iOS.

## Isolated one-run verification

For the initial pre-merge verification, create one immutable commit-tree snapshot
from the exact baseline using a separate `GIT_INDEX_FILE`. Include only this new
driver/workflow/test/document and replace the *existing* dispatchable
`.github/workflows/client-ui-harness.yml` **in that verification branch only**
with the new workflow bytes. Leave main HEAD, index, checkout and production
sources untouched. Dispatch that known workflow path once against the explicit
branch/SHA, then watch only the returned owned run. Do not dispatch blind retries.

Local contract check:

```text
python -B -m unittest tools.runtime.tests.test_telegram_launch_smoke -v
```

### Baseline verification dispatched 2026-11-17

* Run: [44110646483](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/44110646483).
* Immutable snapshot: `5b16fb66218f3171895319f97a4566290dfc727b`.
* Branch: `verify/telegram-launch-79fed-20261117-150706`.
* Production base: `79fedf4f4324bc5f8f65b573370bd03fda3daa57`; diff contains only
  the four new smoke files plus the branch-only dispatch workflow replacement.
* Main HEAD and index were unchanged. Six local contract tests passed.
* Expected evidence: `telegram-launch-evidence-44110646483-1`; expected retained
  IPA artifact: `telegram-launch-ipa-44110646483-1` (only after a successful build).

At dispatch time the run was `in_progress`. A single background watcher is scoped
to this exact run/SHA and downloads its evidence artifact after completion.
Actual build/launch outcome and frame review remain pending; these artifact names
are expectations, not a claim that uploads or screenshots already exist.

The main-branch workflow records `github.sha` as its production source identity.
Only the immutable baseline verification snapshot overrides this to79fedf4f:
its other files are tooling additions and its production source was checked
against that baseline. Later launches must not retain the historical base label.
