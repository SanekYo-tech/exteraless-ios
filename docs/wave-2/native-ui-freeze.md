# Native XCTest + Client UIKit Acceptance frozen handoff

Base BUILD publication: `78e6d5d8`. Required published followups:
**`e8484ec0`** (optional-language fingerprint glob) and **`e2a5684c`** (TL
constructor's positional-only receiver). Production archive/947-path receipts
remain the original publication.

## Exact selection and delivery

Receipt directory: `build/wave-2-dependencies/native-ui-freeze-78e6d5d8/final/`.

- `frozen-delivery-paths.txt` / `.sha256` / `.json`: exact native BUILD/tooling
  delivery, including its unchanged prerequisite declarations.
- `pending-delivery-paths.txt`: the remaining working-tree delta.
- `native-test-plan.json`, `native-target-map.json`, `native-method-map.tsv`:
  **36 executable labels, 85 mandatory source files, 88 classes, 410 methods**.
  The TSV has one row per selected method with its label, host, class and source.
- `harness-inputs.json`: physical inputs, declaration/command hashes, generated
  protocol stub and the actual build-time domain resource.
- `source-inputs.json` / `.sha256`: joined physical native/harness/runtime pins.
- `native-commands.json`, `workflow-commands.json`: commands derived from the
  existing Make argument generator and the final workflow.
- `runtime-staging.json`, `runtime-source-delta.json`, `runtime-prepare.json`,
  `staged-input-proof.json`: fresh runtime preparation and relocated source proof.
- `checks.json`, `receipt-manifest.sha256`: scoped checks and receipt hashes.

The original Font producer target retains five tests; the separate
`//Tests/Exteraless:FontFamilyConsumerTests` has three actual header/archive/contact
fixtures. PNP02/03 use `ExteralessDCTTimingTests` (5) and
`ExteralessSubcodecTimingTests` (4), with generated local decoder/pixel data and
the published 64-frame/250ms work bounds. PNP01 remains eight methods in the
existing Layout target. The two Composer classes retain their explicit
ComposerHarness host and class-filtered labels.

`ChatMediaRemediationNativeTests.swift` now imports `UniversalMediaPlayer`, the
actual owner of its `MediaPlayerStatus` type; this is the one-line test-source
correction previously handed off as `final-native-source-fixes.patch`.

## Build and resource binding

The DEBUG `makeExteralessComposerPanel` factory is present in the published
TelegramUI source glob and in the fingerprint. The actual Core/TelegramUI Swift
compile actions must contain DEBUG. All thirteen final-visual source groups and
the eight harness dependencies remain joined.

`DomainFingerprintInputs` additionally includes the harness BUILD, Info.plist,
fixture plugin and **the actual generated ContextStubs output**. Its generator
and current AccountContext protocol are pinned. The generated 76,716-byte Swift
stub has SHA-256
`37bf1ddb47fff79cbebed383f86812d3deefc341cce669d3a881e55c98910e07`.
After compilation, the IPA's domain resource must equal the declaration-derived
manifest, including that generated output.

Both NativeTestHost and ComposerHarness carry Fonts/OFL, Monet notices, actual
localization data and Assets.car. The native driver verifies both host archives
after compilation through `native_test_resources.py`. ClientUIHarness keeps its
native assets, fonts/notices, plugin and full Python resource/framework graph.
The shared production Make/resource contracts are consumed as published.

### Bazel 9 loading correction

`e8484ec0` sets `allow_empty=True` only on
`RichTextEditor:ClientHarnessFinalVisualFingerprintSources`. Its cross-product
contains legitimately absent language variants, including
`Sources/RichTextEditorCore/**/*.m`. The new source resolver checks **each include
pattern**, enforces exclusions and excludes subpackages. Tests reproduce the
reported loading failure and its explicit optional-pattern correction. Required
visual source paths remain mandatory in the resulting manifest.

## Execution/evidence contract

Actual Xcode 27.1 and available iPhone 17 / iOS 27.0 are required for XCTest.
Compile/analysis and execution retain separate 900s envelopes; each class has
180s preparation, **30s logic**, 60s finalization, within the 2000s driver / 2100s
owned-exec boundary. The runner remains serial, with cached test results and
retries disabled. Run-only uses `--check_up_to_date --nocheck_tests_up_to_date`.

Native success requires every selected class and every method's start **and**
pass observation, the exact source/label/host mapping and valid phase durations.
A `passed` flag, zero methods, omitted classes, duplicate results or changed
identity cannot pass the final gate.

One debug simulator build produces Telegram and ClientUIHarness. The harness IPA
is verified and retained before native-test builds can repoint `bazel-bin`.
`acceptanceIdentity` binds the native plan, harness inputs, staged runtime source
inventory and that IPA. All native tests and recordings must match it.

The frozen recording driver is invoked through `record_client_ui_batch.py`,
which verifies the complete native result and source identity before/after each
invocation and writes a separate `batch-identity.json`. The workflow keeps:

| Evidence directory | Exact ordered scenarios |
| --- | --- |
| `baseline/` | `core-light`, `core-dark`, `sdk-ui` |
| `domains/` | `feed-render`, `player-render`, `pill-render` |
| `final-visuals/` | `avatar-render`, `composer-render` |

Each invocation has one fresh simulator, at most three sequential fresh app
processes, 30s per process and its existing 600s outer envelope. Three distinct
simulator UUIDs and exact semantic/recording lists are required. Native PNGs,
frame handles, ffprobe timestamps, MP4s and semantic evidence remain uploaded.
The job limit is 200 minutes. Recorded-frame acceptance remains coordinator-run.

## Published runtime boundary and checks

Fresh offline preparation contains **414 source inputs, 3,267 staged files,
547 Python assets, 12 distributions and 55 frameworks per slice**. Relative to
the original production inventory, its only runtime source delta is
`python/exteraless_runtime/_tl.py`:

- Previous: `6108bc28915113b7927696a11588f55fd4783c35f2238b108f6584d050801ba7`
- `e2a5684c`: `38421d438a8efedd32ce62cfa9946c5b31545d792e86ac8e7ad3c20e611773cf`
- New runtime source seal: `a6300da129001d0933d38bbdaf06bda99fefad5e2db1b18ac9ed2b3112601a8c`

During preparation, an unpublished `ClientSettings.swift` edit appeared in the
live checkout. The prepared copy retains the published `e2a5684c` bytes
(`60f695dd...`); `runtime-prepare.json` records the differing worktree SHA explicitly.
The frozen packet uses that published runtime boundary. It does not describe the
concurrently edited checkout as zero-drift. Later Core handbacks need their own
source receipt when joined.

| Scoped check | Result |
| --- | --- |
| Native map, phase/command, glob and evidence fixtures | 22 passed |
| Frozen driver, generated protocol, visual and workspace contracts | 26 passed |
| Native/harness direct imports, including generated stubs | 40 libraries, 340 Swift compiler inputs, 1,241 project imports; 0 missing |
| Component sparse declarations | 997 inputs covered, no missing cones; receipt outside `final/` |
| Native plan through relocated source inputs | Same selected map and fingerprint |
| Runtime/root-resource/Rust preparation | Fresh published source snapshot verified; historical receipts preserved |

Native plan: `e3d8aeb88a78d49eb6a2c72481d28d03a237b51531478db0bbf42b124b211a20`.
Harness inputs: `4451e4283462f7b2a63e8b4f602f09e0e9924201b02a44a17afcd9fd359470d9`.
Domain resource: `2c3419879db39d226d787c4a3bc376950057b512c25511be9411e2838cc1657c`
(631 canonical entries, including the generated stub).

These are raw-byte source/declaration receipts, not Apple compilation or native
execution results. The coordinator owns dispatch, compilation and frame review.
