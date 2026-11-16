# Native gate / SDK finite followup — tooling handoff

## Current Map addition: twenty recorded scenes

The accepted 40-path packet now has a separate implemented Map delta:
[`map-attribution-native-handoff.md`](map-attribution-native-handoff.md).
`map-attribution` explicitly invokes `LocationUI.ExteralessMapAttributionFixture`
against an ordinary MKMapView and the production provider/UIButton, with six
light/dark standard/satellite/failure states, 13 native PNGs and ffprobe PTS handles.
The injected OSM loader uses only the owned 256px PNG or an actual error;
standard public Apple/GeoServices map requests are permitted and labelled as such.

The gate now selects **20 scenes**: base8 + Reset10 + secondary-trust1 + Map1,
with nine distinct serial recording simulators, one retained IPA and 30s/process.
The XCTest map remains **37 labels / 89 mandatory sources / 92 classes / 430 methods**.
Map uses two 3.8s palette segments, a 9s interaction cap and a 150s command envelope.
Supplemental envelopes total990s; the job remains215m. The new source/input and
tooling-delta receipts live in `build/wave-2-dependencies/native-gate-map-followup/`.

Coordinator-applied Composer math and all six Pill observer calls are present;
source preflight is clean. Native compilation, execution and frame acceptance
remain coordinator-run. The earlier 40-path ZIP and its receipts are preserved.

The subsequent [FD platform contract](native-fd-platform-handoff.md) makes
`darwin_family_fd_paths` mandatory in the first Mac SDK child. UIKit uses the
distinct `clientUIFixture` path; its authorized coordinator packet is now **applied**,
with the full shared helper and separate post-cleanup `actual_ios_fd_paths`
observations. The new application/source receipts are in
`build/wave-2-dependencies/native-ui-ios-fd-join/`. The current four children remain bounded;
the developer owner's fifth child awaits its driver hunk. Map stays the twentieth
scene. `sealed/` preserves the earlier Map receipt; the final FD-inclusive delta
is captured separately under `native-gate-map-followup/`.

## Accepted 40-path snapshot: Reset and secondary permissions (historical)

Current receipt directory:
`build/wave-2-dependencies/native-gate-sdk-followup-590ce05b/complete-handoff/`.
Its readonly pre/post capture covers **1,381 source inputs**, SHA-256
`730e9332fe7cb3eab5256e42a6cf9f198ea250a0db0ca1b12a4dce2cc257329d`.
The manifest records working source, not an assistant-published commit. The older
`sealed/` and `witness-cohort/` files remain separate checkpoints.
`source-handoff.json` / `.sha256` and `source-change-after-capture.json` retain the
subsequent readonly delivery-time check: the descriptor/file-authority owner
edited two Host files after the earlier capture. That earlier fingerprint is
not relabelled as current. Production source approval and Root pin regeneration
remain coordinator-owned.

The latest computed XCTest map is **37 labels / 89 mandatory source files /
92 classes / 430 methods**. It preserves the 410 baseline and adds Manager12,
TrustUI2, Elyx protocol3 and TL secondary permissions3. The latter two source-list
joins remain in the existing TL target. The Reset navigation and secondary-UI
helpers are recorded scenarios, not additional XCTest methods.

**Applied:** all five RSR BUILD hunks in their actual fields: Exteraless exports,
Harness library sources, DomainFingerprintInputs, Core Tools/Privacy fingerprint
inputs, and Display's four real navigation sources. The dispatcher recognizes
the ten exact Reset IDs and calls the given-context fixture. Unknown cases throw
instead of falling through to Core. The 22-source ready/probe contract and the
real lifecycle/authority/plan/provider counters are validated. The provided
19-method CoreReset source stays under SwiftPM's existing auto discovery.
The current SwiftPM followup ledger totals70 source-declared methods, including
those19 reset methods and the two platform-scoped PluginResourcePath tests.

**Applied:** `PLUGIN_TRUST_SECONDARY_UI_FIXTURE` is enabled on TelegramUI only
for the existing debug configuration. A distinct helper explicitly awaits
`PluginTrustSecondaryUIFixture.run(context:presenter:)`, observes the real alert
and two distinct UIActivityViewControllers, captures native images, and requires
the fixture to return cleanly. Its canned Host worker/callback transport is
labelled; actual UI consumers run, while external URLs/network/Python do not.

There are now **18 scenes for base + Reset**, and **19 including the separately
requested secondary-trust witness**. The original eight keep their three batch
names and `evidence/batches.json`. Every supplement uses the same retained IPA,
staging/harness fingerprint and native-test result:

| Directory under `evidence/supplements/` | Exact cases | Palette |
| --- | --- | --- |
| `reset-1` | `reset-ready-cancelled`, `reset-prepare-before-return`, `reset-prepare-after-return` | light, dark, light |
| `reset-2` | `reset-reply-before-return`, `reset-reply-after-return`, `reset-prepare-actual-pop` | dark, light, dark |
| `reset-3` | `reset-reply-actual-pop`, `reset-retired-ready`, `reset-retired-prepare` | light, dark, light |
| `reset-4` | `reset-retired-reply` | dark |
| `trust-secondary` | `trust-secondary-permissions` | native current palette |

Each invocation creates/deletes its own simulator; each case has a fresh app
process and the unchanged **30s** process limit. Reset keeps the fixture's 18s
interaction deadline and 6s reply gates. The added hard command envelopes are
180+180+180+120+150+30 = **840 seconds**, including final verification. The job cap
is **215 minutes**. There is one build, not one build per case.

`complete-gate.json` independently requires all five supplemental batches,
all nineteen scenes, eight distinct invocation simulator IDs, exact source and
native-result identity, real probe hierarchy/images, and full Reset lifecycle
witnesses. It cannot relabel the base eight as coverage of the new flows.
ffprobe PTS, native PNGs and frame-handle sheets remain required for review.

**At that snapshot:** the Composer/Pill coordinator patch and a Map entry were
pending. The coordinator has since applied the control calls, and the approved
Map transport boundary and native entry are implemented in the delta above.
The earlier source/count snapshots below are preserved SDK checkpoints; the
final delivery receipt contains the new computed map and readonly pre/post hashes.

## Initial SDK-only checkpoint

## Current computed map

The new map contains **37 executable XCTest labels / 88 required source files /
91 classes / 427 methods**. The historical 410-method receipts remain intact.
The additions are Trust UI **2**, Manager Custom/Alias **12** (the initial five
plus seven MCA-F01/F02 regressions), and Elyx developer protocol **3** in the
existing `//submodules/TelegramUI:ExteralessTLModelTests` target.

`//Tests/ManagerCustomAlias:ManagerCustomAliasTests` uses the existing Runner and
resource-bearing NativeTestHost. Its source group retains the six coordinator
additions: EventFIFO, SettingsUpdate, Lifecycle, ReleaseQueue, MenuModel and
Navigation. The applied TL tests source-list line is preserved. The Foundation
UI compiler list and native filegroup also include SettingsUpdate.

SwiftPM's existing unfiltered discovery includes these **49** followup methods:

| Package / source | Methods |
| --- | ---: |
| Host / PluginSendHookPriorityTests | 8 |
| Host / PluginSettingsPageLeaseTests | 4 |
| Host / PluginTrustHostTests | 4 |
| Host / PluginTrustLevelTests | 9 |
| Host / PluginElyxDeveloperTests | 7 |
| Core / ClientSettingsSearchTests | 16 |
| Core / ToolsArchiveIDCodecTests | 1 |

These are declaration counts. Coordinator-reported Core704/Mac20 results are
historical execution evidence, not results for this new source cohort.

## Exact tooling / input delivery

New receipts live in
`build/wave-2-dependencies/native-gate-sdk-followup-590ce05b/sealed/`:

- `native-test-plan.json`, `native-target-map.json`, `swiftpm-followup-tests.json`:
  complete selected methods and automatic-package bindings.
- `source-inputs.json` / `.sha256`, `readonly-source-stability.json`: **1,366**
  consumed source inputs with readonly pre/post hashes; captured working source
  payload SHA-256
  `008b8286daef85531c22119d53ff518e7ff8fceb539058d4fbfe2f0bdbc5d98d`.
- `sdk-followup-sparse.json`, `dynamic-python-asset-copy.json`: exact finite
  sparse coverage and verified automatic copying of the current Python helpers.
- `archive-api-contract.json`, `owned-archive-fixtures/`: inspected current
  public Host signatures, FD-hook declaration status and the real EMIT inputs.
- `delivery-paths.txt` / `.sha256`, `checks.json`, `receipt-manifest.sha256`:
  final plumbing paths, checks and hashes.

The source payload is a working/private-source receipt, **not a published
production freeze**. Root registration/config pin regeneration remains with the
coordinator. No Runtime/Host/Python-adapter implementation was changed by this
tooling slice. The existing Swift fixture main receives only a fourth dispatch
branch; its first three branches, IDs, flags and Root/SDK calls are preserved.

`compiler-input-correction.json` preserves the initial draft inventory and records
the two TL codec inputs it omitted. The sealed inventory consumes the driver's
actual `SDK_TL_CODEC_SOURCES`, including TLTransformCodec and TLUpdatePolicy.

## Python Framework workflow

The finite pytest step names the five requested SDK modules explicitly, plus
the supplied P1 and native-Elyx protocol regressions. It uses the already sealed
`python/vendor` PyYAML, owned temporary directories and JUnit evidence. Collection
currently resolves **64 cases** including the two dedicated Darwin tests;
collection is not an execution pass. Optional C-extension variants require their
matching existing ABI inputs, and the Python 3.14 OWN_GIL-only case remains
platform/version-gated under the Python 3.12 component job.

The actual developer listener has a dedicated **120s compile / 10s run** step;
its five compiler inputs are derived from the test's source declaration, including
`fixtures/sdk_developer/NativeDeveloperServerProbe.swift`. Native candidate ZIP
validation has its own **120s compile / 10s run** step and the supplied local
`fixtures/native_elyx` Swift package. Process-group teardown remains in the
existing bounded native test driver. There is no external corpus selection.

## Fourth real Swift / C / CPython archive child

`check_swift_plugin_embedding.py` builds the existing executable with the new
`tools/runtime/fixtures/swift_sdk_archive_probe.swift`, then dispatches
`--archive-lifecycle` as a **fourth isolated process, maximum 30s**. It reuses
`SDKTLObservedEngine`, the real CPythonXCFrameworkEngine, NativeBridgeBinding,
PluginHost and PluginServiceStorage. The extra observer is
`tools/runtime/fixtures/native_archive_probe.py`; it does not replace a backend,
loader, ZIP implementation or path authorization.

The input archives come directly from
`test_ios_elyx_archives.py --emit-fixtures`: `owned.elyx`, `owned-next.elyx`,
`literal.eaf`, `requires.elyx` and the small source-format control. Each is bounded
to 32 KiB by the native driver. The archive child performs:

1. Public Host metadata preview and disabled installation of `7_archive`.
   Host re-inspects its staged archive before committing explicit isolated/native
   consent. Both inspectors must execute zero plugin entries.
2. Actual enable, SDK settings read and public Host setting update.
3. Host reload with a fresh native owner and retired extraction cleanup.
4. Native replacement by the next archive: changed module and the same wheel
   filename must both expose **`later`**, retaining settings and a new C epoch.
5. Actual `_archive` / EAF installation and enable, followed by owner-local
   uninstall. Another live archive and unrelated cache marker must survive the
   appropriate earlier cleanup.
6. `requires` rejection before entry, neighbor import or HTTP, then complete
   Host shutdown and bridge removal.

The expected operation trace is eight metadata inspectors and five owner
interpreters, with exactly **one process initialize/finalize**. All observations
must show real built-in C/backend identity, OWN_GIL, destroyed interpreters and
zero retained SDK handles. Network/neighbor attempts are observed, not simulated
as successful calls. The result declares its Foundation/provider boundary and
never claims UIKit/network execution. Runtime API/file hashes are checked before
and after the four-child run.

`_archives.py`, `_audit_paths.py`, `_elyx_helpers.py`, `_elyx_developer.py` and the
original SDK archive/namespace/loader files are explicit required production
inputs. The automatic Python copy path retains their current bytes. No stale
source helper, legacy cache-path loader or Host adaptation was introduced.

### Developer FD publication boundary

The inspected Host exposes `elyxDeveloperTargets`,
`inspectElyxDeveloperDescriptor(_:format:shouldExecute:)` and
`elyxDeveloper(_:targets:account:files:deadline:shouldExecute:)`. The descriptor
lease is retained through `onExecutionFinished`. The source owner must finish
and hand back the native file authority and the three archive seams:

- `ArchiveAdapter.developer_manifest(expected_source_digest=...)`
- `_archives.inspect_developer_descriptor(descriptor)`
- `_archives.verified_developer_load(platform, path, descriptor)`

Their exact declaration status is recorded in `archive-api-contract.json`.
The seven Host developer fixtures use an explicitly labelled file-authority
contract recorder; the candidate fixture proves real ZIP transformation. Neither
is relabelled as real FD publication. The fourth archive child covers the public
standard Host lifecycle; it does not pretend these pending developer capabilities
exist or supply a fake file authority to make publication pass.

## UIKit frame handoff

Search export/source groups and the existing **13 core probes** are present.
The exported-file label and `Tests/Exteraless/` canonical manifest prefix are
supported by the tooling. New Manager/Trust/developer UI source inputs, including
the supplied guarded `PluginTrustUIFixture`, enter the explicit followup group.

The eight scenarios remain **3+3+2**, 30s per fresh app process. The new isolated
configuration-control helper is selected by the existing harness source glob.
The coordinator has applied `configured-controls-harness-coordinator.patch` to
the Composer/Pill scenario sources. Source preflight checks the actual calls. The
expected frames, geometry, source provenance and ffprobe-PTS review are specified
before recording in `ui-harness.md`; no 45s process extension exists.

Map attribution now has its own twentieth scene. `map-attribution-owned-route.json`
records the implemented entry and approved public MapKit traffic boundary;
`map-attribution-native-handoff.md` defines its source pins, budgets and frame review.

## Local checks and execution boundary

- Five focused emitter/input/command/control-evidence checks passed.
- Two compiler-input/immutable-receipt checks passed.
- Ten native-map/batch identity checks passed.
- Twenty-six existing driver/workspace/visual-contract checks passed.
- At the historical SDK capture, the coordinator Composer/Pill patch passed
  `git apply --check`; the current calls have since been applied by the coordinator.
- Readonly source pre/post payload hashes matched during the sealed capture.

No Apple compilation, UIKit execution, CI query/dispatch, commit or push was
performed here. Native execution and recorded-frame acceptance remain with the
coordinator after source handbacks and Root/config pin regeneration.
