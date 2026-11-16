# UIKit initial graph remediation — 43785534046 / d717af9e

**Actual failure identified and source fix applied.** The completed run failed
during `aquery deps(set(//Telegram:Telegram //Telegram:ClientUIHarness))`, before
compilation. A real post-fix Apple aquery/build remains coordinator-run.

## Downloaded evidence

The requested artifact was downloaded once with `gh run download --name` into
`build/artifacts/client-ui-43785534046/`. Authentication came from the origin URI
without printing credentials. Only this completed artifact was queried/downloaded.

- Run: `43785534046`, commit `d717af9ef3020c8b4d7bca9e828affed868c57e6`.
- Artifact: `client-ui-evidence-43785534046-1`, ID `14190640277`,386245 bytes.
- GitHub metadata digest:
  `sha256:b1e3fdb79dfa67a392230bfd7b658d0672f574938b15dd82a594c03bf89dfb1e`.
- `build/build.log`:6312 bytes; locally verified SHA-256
  `9b56d295b86fb53ab5b27b118bea6a2ae73327d5f021245ccb586881d85258ce`.

`download-receipt.json` records all five extracted file hashes and the metadata.
The CLI extracted the ZIP; its advertised ZIP digest is recorded as metadata,
not misrepresented as an independently rehashed local ZIP.

## Exact stderr and root cause

`build/artifacts/client-ui-43785534046/build/build.log:56–62`:

```text
ERROR: /Users/Shared/exteraless-client-ui-harness/telegram-ios/Tests/ExteralessHarness/BUILD:8:14: in swift_library rule //Tests/ExteralessHarness:ClientHarnessAccount: Visibility error:
target '//submodules/Postbox:Postbox' is not visible from
target '//Tests/ExteralessHarness:ClientHarnessAccount'
Recommendation: modify the visibility declaration if you think the dependency is legitimate. For more info see https://bazel.build/concepts/visibility
ERROR: /Users/Shared/exteraless-client-ui-harness/telegram-ios/Tests/ExteralessHarness/BUILD:8:14: Analysis of target '//Tests/ExteralessHarness:ClientHarnessAccount' (config: 38721a4) failed
Analyzing: 2 targets (1329 packages loaded, 76558 targets configured, 207 aspect applications)
ERROR: Analysis of target '//Telegram:ClientUIHarness' failed; build aborted: Analysis failed
```

The log reports63.873s and **0 processes**. The outer console's empty error body
was caused by `stderr=log`: `Popen.communicate()` returns no stderr string when
the actual diagnostics go to a file.

Postbox exposes its library through the `clients` and `test_clients` package
groups. The latter already included ComposerHarness, but omitted ExteralessHarness.
The public `//Telegram:ClientUIHarness` alias does not change the package of
`ClientHarnessAccount` or confer Telegram's dependency visibility.

## Applied correction

- `telegram-ios/submodules/Postbox/BUILD`: add the exact
  `//Tests/ExteralessHarness` package to **`test_clients`**. This deliberate
  test-fixture exception covers the three existing direct Postbox consumers:
  `ClientHarnessAccount`, `ClientHarnessAppContext` and `ClientUIHarnessLib`.
  The production-client list and Postbox's restricted visibility stay scoped.
- `tools/runtime/client_ui_harness_build.py`: source preflight now verifies that
  exact test-client group and the library's reference to it. The full normal app
  plus Harness graph, same debug/simulator flags, caches, two-job/memory limits,
  unsigned/runtime/domain-debug validators and retained fresh-IPA path are used.
  No build-target reduction or visibility-check bypass was introduced.
- Aquery and build failures use `logged_build_command`. It flushes the log,
  reads at most **16 KiB** of its tail, and writes `build-failure.json` with the
  actual phase/command/error and diagnostic **byte offset, byte count, file size
  and SHA-256**. The same diagnostic text reaches the exception/console.
  Private action-graph stdout is not read as a diagnostic; it retains its existing
  cleanup path. A failure never creates a successful `build-result.json`.
- `.github/workflows/client-ui-harness.yml`: upload `build/build-failure.json`
  alongside the existing `build.log` evidence.

The audit of other literal direct Harness dependency/resource edges found the
existing framework/resource visibility grants sufficient. The actual failed
command already selected `-c dbg` and `--ios_multi_cpus=sim_arm64`; the existing
action validator continues requiring `DEBUG` for TelegramCore/TelegramUI and
`EXTERALESS_MAP_ATTRIBUTION_FIXTURE` for LocationUI.

## Verification and input delta

**13 affected tooling tests passed** in0.266s: three new graph/diagnostic tests,
seven driver contracts, two Xcode-selection checks and the actual-compiler-debug
definition contract. The redirected-stderr test runs a real short Python child
which exits1, verifies the diagnostic SHA/byte range and confirms that private
stdout does not become captured diagnostic output. No Apple process runs locally.
Source preflight, BUILD parsing and scoped whitespace checks passed.

Relative to the downloaded input manifests:

- Native plan: **369 inputs**,37 labels /89 required sources /92 classes /
  **434 methods**; the Postbox BUILD hash changes with the visibility fix.
- Harness: **743 inputs**; only the build driver and upload workflow hashes change.
- Domain manifest: **694 inputs**, unchanged digest
  `235419fb3bac4b31bd7b23991ed43f8ebac79c10ad3ed167b2d984bf84873e8d`.
- The local native plan also observes CRLF in the existing rules_apple runner
  template. Its LF-normalized SHA exactly matches the artifact
  (`770b0ce52417f0a120bdcfa1dc91b0e9b9bb933c2618ae77ec878b75410429c7`);
  that file was not edited. Raw artifact/current hashes are recorded separately.

New receipts/delta:
`build/wave-2-dependencies/uikit-initial-graph-d717af9e/`.
The original downloaded files and historical handoff snapshots remain intact.
The five SDK children, twenty UIKit scenes,434 XCTest methods and30s app limits
remain the cohort contract. No CI launch/cancel, commit/push, Rust change or
Root/SDK pin regeneration was performed. Coordinator can publish this scoped
fix and dispatch the full UIKit gate on the same owned queue.

## Coordinator integration

All five delivered postimages and the ZIP digest matched. The coordinator also
enabled Bazel `--keep_going` for the actual full app/Harness build, so one compile
failure does not hide independent target diagnostics. Aquery still must succeed
before validation or compilation; failed builds cannot enter frame acceptance.
