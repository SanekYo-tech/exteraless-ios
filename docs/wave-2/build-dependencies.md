# Wave 2 — build/dependencies integration contract

**Native build prerequisite:** include the canonical mtproto-engine outer patch,
metadata and common preparation hooks in the joined commit. The nested gitlink
alone remains the original upstream base. See “Nested Rust gitlink delivery” below.

## Frozen production full-app handoff

The current production delivery is [production-build-freeze.md](production-build-freeze.md),
with exact paths, raw hashes and receipts under
`build/wave-2-dependencies/production-app-freeze-2bac089c/`.
It is ready for the supported `//Telegram:Telegram` unsigned full build with
`--continueOnError` on the published UI `2bac089c` plus local CorePath `96bff39e`.

Production audit: **5,113 Swift files / 27,515 project imports / 0 missing imports /
0 unresolved published owners**. Fresh offline staging: **414 source pins, 3,267
files, 547 Python assets, 12 distributions, 55 frameworks per slice**. The production
Make resource validator now seals and checks Fonts/Monet alongside the existing
AdGuard, Python and frozen Rust provenance. The exact invocation and completed
checks are in the handoff above.

## Native BUILD handoff checkpoint

Source publication: `4476f853`; Core `d8cbdaca`, SDK `46393e31`, Layout `19c1a96a`,
renderers `b06f959b` and Font `2bac089c`. BUILD/resource/workflow joins are ready for coordinator
selection; no commit, dispatch, Apple build or native execution was performed here.

- Applied Performance's two direct Core edges, Monet's PData test/resources hunks,
  Chat Swipe, CMC05 schedule, final Forward and Feed terminal/direct-save bindings.
- Joined all thirteen final-visual filegroups and eight harness imports. Added the
  `//Telegram:ClientUIHarness` alias required by the frozen visual contract.
- Recording is one full build, NativeIntegrationTests, then explicit **3+3+2**
  serial batches from the retained IPA. The third batch has the same 600s outer /
  30s per-process bounds. Its evidence is uploaded with the existing trees.
- Font/Monet bundle roots have an executable size/SHA/placement check after build,
  including Share/Content and NativeTestHost. NativeDisplay sources and registrations
  were not rewritten.

### Actual audit results

| Check | Result |
| --- | --- |
| Registered-module import/ownership scan after handback | 6887 Swift paths, 1595 imports, 471 targets; no missing declared edge or unresolved owner |
| Native libraries and harness direct imports | All actual non-system imports resolved; the invalid `MediaPlayer:MediaPlayer` label is corrected to `:UniversalMediaPlayer` |
| Native test map | 36 targets / 88 classes / 410 methods; the earlier 395 and 401 method metrics remain historical checkpoints |
| Final-visual/root manifest | 13 new filegroups; 627 canonical declared inputs, including root/provider and Font/Monet bytes |
| Fresh offline runtime staging | 405 source pins, 3267 staged files, 547 Python assets, 12 pure distributions |
| CPython slice headers | Device 215 / simulator 216; 90 private compatibility headers per slice, outside app resources |
| Framework inventory | 55 per slice: Python plus 54 stdlib extensions; native candidate admission remains closed |
| BUILD/MODULE syntax | 98 delivery BUILD/MODULE files parsed; the earlier 94-file checkpoint is retained |
| Final component sparse closure | 988 source inputs, no missing cone coverage; compiler inputs are derived from the actual runner declarations |
| Frozen Rust | `9ca7ac71a7540ec3a2ef52b2fda5318580f1f5fe4a97611e53a29c7372b315fd`; bytes and mtimes unchanged |

The Core ownership route is TelegramCoreFramework → TelegramCore → the stable
ExteralessCore label. TelegramUIFramework depends on that framework. PluginHost
has no Core edge; Core has no PasscodeCore/CallsUI/UI dependency. Existing unsigned,
six-extension, dynamic Python, TLS/checksum and C219 legacy/admission checks remain.

Artifacts and the per-path frozen delivery manifest are under
`build/wave-2-dependencies/final-native-join/post-font-handback/`; the exact paths
are in `frozen-build-paths.txt` with matching JSON/SHA receipts. `native-tests.md` contains the full
current label map. Local tests were targeted to the new batch/resource/runner
contracts and new visual-driver contract; the prior 74+44+48 suites were not repeated.

### Source-owner findings and receipt boundary

`ChatMediaRemediationNativeTests.swift:4` needs the source owner's
`import UniversalMediaPlayer` correction; `final-native-source-fixes.patch` is a
checked, un-applied handoff. The actual `MediaPlayerStatus` type is declared in
that module. No Swift fixture/source was edited by this build slice.

Review observations after `4476` remain in `source-base-deltas.json`. The published
Font/Layout/renderer handbacks have a separate source receipt under
`post-font-handback/`, with the full native map and canonical source fingerprint.
These do not replace earlier source metrics. The original 946-input component receipt was
incomplete for TL compiler inputs; its correction is preserved, not relabelled
as a complete pass.

The valid full staging checkpoint is retained with its 55-framework slices and
header inventories. Six later Core Darwin/AI source repairs changed its source
pins; `post-font-handback/current-staging-source-inventory.json` records their
current hashes and names. The normal full-build prepare step regenerates staging
from the agreed source snapshot; the older staging receipt is not relabelled as
covering those subsequent changes.

Coordinator-reported first Mac run `43723262961` passed foundational UI/TL/Java7
and Host/Hooks execution; Core's two async waits were fixed in `4aac68b3`.
Those component results do not constitute native UIKit, IPA or recorded-frame acceptance.

Coordinator-reported retry `43728873627` / `46393e31` compiled Core and ran 663
tests with 42 failures; Tools is diagnosing Darwin storage-path aliases and the
AI UTF-16 correction is `230cb7c0`. This is a component source issue, not a reason
to alter native label selection. HNS23 / CPython SDK3 / C219 execution remains
blocked behind Core in that workflow.

## Historical coordination contract and delivery notes

- `//third-party/exteraless:ExteralessCore` resolves to
  `@exteraless//swift/ExteralessCore:ExteralessCore`, Swift module `ExteralessCore`.
  TelegramCore and TelegramUI depend on it. The module has no project dependencies;
  one static copy belongs to TelegramCoreFramework and its existing export-list
  scan covers the UI clients. All domain `Sources/ExteralessCore/**/*.swift` enter
  the staged module. Additional domain BUILD dependencies follow ready handoffs.
- PluginHost does not currently import ExteralessCore. The client-setting bridge
  can live in a UI-side PluginBridgeExtension; add a Host dependency only if the
  coordinator actually introduces an `import ExteralessCore` there.
- TL/services owns `python/runtime/tl-schema.json`; packaging copies its exact
  bytes to **`App.app/python/tl-schema.json`**, next to compat-manifest.json.
- Python dependency manifest remains schema 1, generator
  `exteraless-pure-python-dependencies-v1`, same `packages`, `files`,
  `lock_sha256`, `bundle_sha256`. Every installed file is sealed before app
  staging; staging copies that inventory verbatim.
- The pure bundle expands from 8 to **12 distributions**. SDK agent must extend
  its provided-distribution allowlist/import roots, without changing SDK sources:
  `beautifulsoup4 -> [bs4]`, `soupsieve -> [soupsieve]`,
  `pyyaml -> [yaml, _yaml]`, `debugpy -> [debugpy]`. Existing eight roots stay the
  same. `dist_info` retains normalized wheel spelling, e.g. `pyyaml-6.0.3.dist-info`.
  New optional build provenance fields are `artifact_kind: sdist-python` and
  `projection` for the two reviewed source-only installations. Their `sha256`
  identifies the pinned upstream sdist, not a fictitious upstream universal wheel.
- Native candidates do not enter the provided-distribution inventory until their
  **actual iOS CPython 3.12.16 OWN_GIL imports** pass with
  `check_multi_interp_extensions=1`. Known unsupported candidates stay explicit
  constraints, not installed/compatible claims. Python/engine flags are not relaxed.
- Native package files will use a separate fixed import root
  **`App.app/python/native-vendor`** and manifest
  **`App.app/python/native-dependencies.json`**, keeping the pure vendor seal intact.
  SDK's fixed-path gate may admit only manifest-listed `.fwork` files under that
  root and their manifest-listed binaries under the main app's Frameworks directory.
  No arbitrary plugin `.so` / `.fwork` is admitted. No new path is needed when
  `admitted_packages` is empty (the current pinned native candidates are blocked).
  Framework names use a module-derived `exl_..._<sha-prefix>` namespace, so dotted
  names and stdlib names cannot collide. `.origin` points back to the marker.

## Original dependency surface

`third_party/exteraless-android/TMessagesProj/build.gradle:145–152` installs
beautifulsoup4, debugpy, lxml, packaging, pillow, requests, PyYAML under Python 3.11.
The iOS runtime is CPython **3.12.16**; Android wheels are not reused.

The original `python/sdk/dev_server.py:198–204` uses **debugpy.listen**, not
connect. Upstream `debugpy/server/api.py` spawns an adapter subprocess by default;
that operation is unavailable on iOS. `connect` uses an external adapter and
`listen(in_process_debug_adapter=True)` is a different API/protocol path. Neither
has been validated for the SDK/OWN_GIL lifecycle. Shipping/importing debugpy's real
Python sources is not a claim of a working iOS debugger. `stop_listening` is also
absent in this upstream version; the SDK already reports that explicitly.

## Selected source versions (pins are in the lock files)

| Package | Version | Delivery / execution status |
| --- | --- | --- |
| beautifulsoup4 | 4.15.0 | PyPI py3-none-any wheel; actual HTML/CSS selector operations passed in two host OWN_GIL interpreters |
| soupsieve | 4.1.1 | PyPI py3-none-any wheel; exercised through BeautifulSoup selectors in both interpreters |
| PyYAML | 6.0.3 | Pinned sdist `lib/yaml`, `lib/_yaml`; documented pure fallback; LibYAML unavailable |
| debugpy | 1.8.22 | Pinned sdist Python sources; no native acceleration/PID attach; debugger session unverified |
| Pillow | 11.0.0 | BeeWare cp312 iOS arm64/device+simulator wheel candidates; `_imaging` is single-phase, OWN_GIL unsupported |
| lxml | 6.1.3 | No cp312 iOS wheel found on PyPI/BeeWare; native host XML/XPath passed, OWN_GIL import rejected; iOS source recipe prepared |

Native investigation: PyPI Pillow 13.0.0 offers iOS wheels for cp313/314/315,
not cp312. Its `_imaging.c` has `Py_mod_exec`/`Py_mod_gil`, but no
`Py_mod_multiple_interpreters = Py_MOD_PER_INTERPRETER_GIL_SUPPORTED`; free-threaded
support is not per-interpreter-GIL support. BeeWare's latest published cp312 iOS
candidate is 11.0.0. Mobile-forge recipe revision:
`1c6a989fc91eadeda2d40d12cc6659affcb9b5e1` (Pillow 11, libjpeg 1.5.3, freetype 2.9.1).

## Exact new delivery pins

The existing eight pins are unchanged in `python/runtime/dependency-lock.json`.
The new package records use the same exact fields (`name`, `version`, `filename`,
`url`, `sha256`, `size`, Python/dependency metadata and `import_roots`).

| Package/artifact | URL | SHA-256 |
| --- | --- | --- |
| bs4 4.15.0 wheel | https://files.pythonhosted.org/packages/88/c6/92fcd42f1ba33e1184263f25bfabf3d27c383410470f169e4b8163bf9c17/beautifulsoup4-4.15.0-py3-none-any.whl | `d6f88de62e1d4e38ecb1077eb9724cd0eff29d2a08ca16a401e9b9e93f117cf9` |
| soupsieve 4.1.1 wheel | https://files.pythonhosted.org/packages/cd/65/7fae69a095696195334a934eab23aeb12e2715e6c3f08025d2f91942750e/soupsieve-4.1.1-py3-none-any.whl | `8ff3422dab0b720fb667ee79864d80531a0e57994a13eb701697719ffcb751f6` |
| PyYAML 6.0.3 sdist | https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz | `d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f` |
| debugpy 1.8.22 sdist | https://files.pythonhosted.org/packages/44/9d/3cb6693342acf96802dba89934a5b8da43c201d764ebd1f2c0514a3d42bd/debugpy-1.8.22.tar.gz | `e489c7268e1c7b41e13b438d9c533d2a7af73fb59bf8cd30fead8286c1c39c4e` |

Native pins are **candidate** inputs in `python/runtime/new-native-dependency-lock.json`:

| Artifact key | Version / URL | SHA-256 |
| --- | --- | --- |
| `pillow-device` | https://pypi.anaconda.org/beeware/simple/pillow/11.0.0/pillow-11.0.0-cp312-cp312-ios_13_0_arm64_iphoneos.whl | `2ba930f4606f9ec9551ffadbf38c02aeb61a9846d03f0e59c450707962123849` |
| `pillow-simulator` | https://pypi.anaconda.org/beeware/simple/pillow/11.0.0/pillow-11.0.0-cp312-cp312-ios_13_0_arm64_iphonesimulator.whl | `bcbd744a31102e97baf1f4462e54bd87709160b6872afd7d79852fa88a5fe450` |
| `lxml-source` | https://files.pythonhosted.org/packages/23/ad/28ecd7cb894d172f3c9c80a075eeeb2017ac62e3632cee05a5f9493547eb/lxml-6.1.3.tar.gz | `45222d94ddd511536f3b2f7d9deae3b2339b4ce0f075f1ca25703b07cad9dd21` |
| `libxml2-source` | https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz | `98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821` |
| `libxslt-source` | https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.45.tar.xz | `9acfe68419c4d06a45c550321b3212762d92f41465062ca4ea19e632ee5d216e` |

Anaconda release metadata supplies the iOS wheel hashes/sizes; PyPI release JSON
supplies distribution metadata; GNOME `.sha256sum` supplies native-library pins.
All new pure artifacts, Pillow **device** wheel, lxml source, both host probe
wheels, libxml2 and libxslt were downloaded with bounded streams and checked.
The Pillow simulator URL/size/hash was confirmed in Anaconda metadata, but local
downloads hit TLS record/decryption failures after the object-store redirect
(urllib 3.12/3.14 and system curl). TLS verification was retained. This artifact's
local content check remains pending; the manual component fetch verifies it before use.

## Native pipeline and admission

`tools/runtime/build_native_dependencies.py` and the manual-only
`.github/workflows/native-dependencies.yml` provide:

1. `--phase build`: verified support archive (same 3.12.16 headers/binary), Pillow
   cp312 wheels, lxml generated C plus static libxml2 2.15.4/libxslt 1.1.45.
   Native library/header/config-script Make targets avoid running target iOS
   programs on the Mac. C modules compile serially; native libraries use `make -j2`.
2. Five real Pillow device extensions were already converted into unsigned
   frameworks locally (data-only): `_imaging`, `_imagingft`, `_imagingmath`,
   `_imagingmorph`, `_imagingtk`. Every Mach-O is device arm64 and links only
   Python.framework and OS dylibs. Example:
   `exl_PIL__imaging_6fa6fe7c0e.framework`, marker under `python/native-vendor/PIL`.
3. Build-only `native-candidates.tar.gz` / `native-inputs.json` are input artifacts,
   never edits to a finished Telegram IPA. Cache keys include source/pin/Xcode
   identity; every reused candidate file is rehashed.
4. `--phase probe`: a separately ad-hoc-signed simulator copy, explicit iPhone 17
   selection and `simctl spawn --standalone`. Four fresh native processes (two
   packages × main/OWN_GIL), **20 s per process**, two isolated interpreters per
   OWN_GIL probe. It runs real image/XML operations and writes success only after
   interpreter/process finalization. Package-specific expected ImportError is a
   verified constraint, not a passing package-compatibility result.
5. Admission requires reviewed `production_eligible=true`, `own_gil=supported`,
   completed **iOS** 3.12.16 execution, all module imports/operations in both OWN_GIL
   interpreters, unchanged checks and evidence bound to both platforms' framework
   byte hashes. `--native-bundle` rejects the current empty admission set.

The current **production admission set is empty**. lxml's pinned generated
`etree.c` defaults `CYTHON_USE_MODULE_STATE=0`, and even the module-state branch
declares `Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED` (around line 279373); it
also has the single-interpreter guard (around 279484). Neither this nor Pillow's
global static types are repaired by setting a slot or disabling a CPython check.

Component commands for the coordinator (Mac; not run by this agent):

```sh
python -B tools/runtime/build_native_dependencies.py --phase build \
  --cache build/native-dependency-cache --output build/native-component
python -B tools/runtime/build_native_dependencies.py --phase probe \
  --cache build/native-dependency-cache --output build/native-component \
  --simulator-device 'iPhone 17'
```

No workflow was dispatched. This component's iOS compile/execution is pending;
the earlier green CPython/bridge gate is not evidence for Pillow/lxml.

## Actual local evidence (2026-11-15)

```powershell
python -B tools/runtime/vendor_dependencies.py --cache build/dependency-downloads `
  --output build/wave-2-dependencies/vendor --report build/wave-2-dependencies/pure-packages.json
python -B tools/runtime/probe_dependency_imports.py `
  --python C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe `
  --cache build/wave-2-dependencies/downloads --output build/wave-2-dependencies/host-probes `
  --vendor build/wave-2-dependencies/vendor --native
```

- Pure delivery: 12 packages, 2,683,316 download bytes, 8,351,187 installed bytes,
  479 sealed files; bundle hash
  `d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`.
- Host **CPython 3.12.10 / Windows**, not iOS: BeautifulSoup/soupsieve selectors,
  YAML parse/dump with `__with_libyaml__=False`, requests preparation, debugpy
  import/version and the other pure distributions passed in two OWN_GIL
  interpreters. No debugger connection/session or external network operation ran.
- Pillow 11 main interpreter performed PNG encode/decode/pixel checks; lxml 6.1.3
  performed real XML/XPath/serialization. Separate fresh OWN_GIL processes rejected
  `_imaging` and `lxml.etree` with `does not support loading in subinterpreters`.
  Exact wheel provenance is in `host-probes/import-probes.json` and the native lock.
- Full source staging succeeded for both iOS targets: **3095 recorded inputs**,
  **38 Core source files** in that snapshot, byte-identical TL schema, **540 shared
  Python assets**, 857 target resources, 54 stdlib extensions + Python.framework.
  The production native policy has no admitted packages/frameworks. Each staged
  input hash was checked. Counts may grow as domain agents add source; globs are
  recursive and the coordinator must prepare again after final stitching.
- Checks passed: **43 unittest runtime/packaging cases**, **35 pytest dependency
  cases**, **25 unsigned build/IPA plumbing cases**; `git diff --check`; Buildifier
  parsed **29 changed/new BUILD files**. A static import-to-target check covered
  26 direct ExteralessCore consumers; the three late Camera/link-edit/open-URL
  edges found by it were added. No Swift/Apple toolchain was executed locally.

## Bazel / CI edge summary

ExteralessCore dependencies were added to the current direct-importing Swift
targets: TelegramCore, TelegramUI, NotificationServiceExtensionLib, AvatarNode,
Camera/CameraLegacy/CameraNeo, CameraScreen, VideoMessageCameraScreen, ChatListUI,
ChatPresentationInterfaceState, GalleryUI, Display, MediaPickerUI, TabBarUI,
TelegramPresentationData, TextFormat, TelegramStringFormatting, TabBarComponent,
ChatMessageBubbleItemNode, ChatChannelSubscriberInputPanelNode,
ChatMessagePollBubbleContentNode, ChatMessageDateAndStatusNode, ChatTextInputPanelNode,
ChatTextLinkEditUI, OpenUserGeneratedUrl. `Svg:Svg` is now explicit for appearance
image decoding. Foundation/Apple SDK imports (Security/Speech/AVFoundation/
Compression/ImageIO/MetricKit) use the existing Swift autolinking path.

Appearance's final handoff requires no new artwork bundle: it uses SF Symbols and
the already-bundled app-icon PNGs/plist; the existing resource graph covers those.
All new client Swift files remain in their actual package's recursive Sources glob.

Linux Compat Tests run the complete Core SwiftPM suite; the macOS Python component
uses the bounded build/test driver described below. Sparse checkout and Swift
cache inputs include Core. iOS download cache keys include both dependency locks
and support-lock. Framework counts come from manifests; only the **54 stdlib**
count is fixed. Existing unsigned preflight, six extensions, root embedding and
shared framework rpaths remain in the real Bazel graph.

The native/core/package changes are source/packaging-checked locally, not an iOS
Bazel compilation of wave 2. Baseline app run 43635233046 and runtime gate
43633853229 remain the coordinator-provided baseline evidence.

## Joined-source integration slice: owner epochs, resources and XCTest

### C bridge gate

`validate_runtime.py::validate_bridge_report` now follows the actual P2 JSON in
`native-owner-token-remediation.md`: **219 callbacks**, **213 previous-suite
callbacks**, **6 bulk-clear callbacks**, **169 baseline callbacks**, and
**41 owner-bound callbacks**. The old bound subset is still **35** (`41 - 6`);
the new JSON field must not be rewritten to 35. Two native workers and two OWN_GIL
interpreters are mandatory. All previous transport/rollback/realm/counted-buffer
booleans remain required, plus every published owner-token field:
`owner_token_authoritative`, `unbound_owner_token_removed`, `immutable_owner_token`,
`canonical_owner_token`, `owner_token_validation`, `isolated_owner_tokens`,
`parent_owner_isolated`, `owner_bound_seven_ops`.

P2 additionally requires `bulk_clear_reentrant_registration`,
`bulk_clear_nested_once`, `bulk_clear_realm_registry_swaps`,
`bulk_clear_monotonic_ids`, `terminal_owned_refs_released`, exactly **27 terminal
admission checks**, and **2 payloads created / 2 freed**. The separate terminal-case
counters accept only `(rejected, before_clear) = (1, 1)` or `(2, 0)`, as published:
GC can run the real-End finalizer before module clear, while forced-dead admission
is rejected. These counters count two cases, not the 27 API paths. Missing fields,
false/non-Boolean checks, string/float/Boolean counters, and old 169/213-call reports
fail. The bridge process deadline remains **30 seconds**.

`tools/runtime/tests/fixtures/native-bridge-p2.json` is the published native report,
compared locally to `remediation-report.json`. Regression tests use this independent
fixture, rather than generating success fields from the validator's own checklist;
removing any old or new required Boolean therefore fails the tests. This validates
the report contract, not a new execution of the integrated native sources.

The runtime artifact fingerprint now includes SDK/adapter Python files, all native
fixture `.plugin`/`.py`/`.swift` files, Host tests (including maintenance/effect-budget
cases), Core and Hooks source/tests, package/BUILD manifests, C shim module maps,
and shipping UI/TL Foundation fixtures/drivers. This
requires freshly compiled matching artifacts; an earlier green report cannot be
relabelled for new source. The SDK probe driver's own implementation remains with
its owner and is invoked through its existing CLI.

### AdGuard main-bundle resource

Vendored untouched from the exact requested pin:
`telegram-ios/submodules/TelegramUI/Resources/Exteraless/Links/adguard_url_tracking.txt`.
Version **2.0.14.84**, **184303 bytes**, SHA-256
`06098fad1d9ee93ce294223206d9cb4b4c180df7a356eb563fa64e775e36cdfc`.
The embedded upstream header is intact. The companion GPL-3.0 license is pinned
to upstream commit `04e0f73b214ddc9d9c59ded9a5934878059d9f39`, 35149 bytes, SHA-256
`3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
`.gitattributes` disables line-ending conversion for both verbatim data files.

`//submodules/TelegramUI:ExteralessLinkResources` is attached directly to
`//Telegram:Telegram.resources`, with the same files excluded from the generic
resource group. Its flat bundle filename is **`adguard_url_tracking.txt`**, exactly
what `Bundle.main.url(forResource:withExtension:)` requests. No network fetch or
rule execution is needed to build an IPA. `build-system/exteraless/runtime-assets.json`
records source/bundle paths and pins. Preparation verifies them, Make rechecks the
staged provenance, and the IPA verifier requires one byte-identical copy at the
main bundle root (including the license). A future moving-URL change needs a real
pin update; checksum verification is not bypassed.

### Current graph and focused tests

`tools/runtime/check_bazel_imports.py` audits bounded Swift import headers against
the **actual owning BUILD/srcs declarations** and explicit public module labels.
It does not guess labels from filenames or claim Bazel analysis. Tests cover
recursive globs, excluded sources, `@testable` imports and distinct test ownership.
The first integration scan covered 6642 Swift files / 203 imports / 43 targets.
The P2/ready-handoff scan covered **6749 Swift files, 318 checked imports, 60 owning
targets**, with **zero missing edges and zero unresolved owners**. That scan preceded
the harness handoff and excluded its separately owned subtree; the completed
harness-specific declaration check is recorded below. These are
declaration checks on an unfrozen source snapshot, not Bazel analysis.

New direct edges include ActivityIndicator, GlassBackgroundComponent,
ContextControllerImpl, ChatTitleView, ChatListHeaderComponent,
ChatAvatarNavigationNode, PeerInfoScreen, TranslateUI, TextSelectionNode,
TranslateHeaderPanelComponent, ChatMessageTextBubbleContentNode,
ChatMessageRichDataBubbleContentNode, ChatMessageReplyInfoNode, ChatMessageItemImpl,
ChatMessageInteractiveFileNode, AccountContext and MediaPlaybackHeaderPanelComponent.
ChatPresentationInterfaceState also directly depends on LocalizedPeerData.
AppBundle's existing Objective-C source/header globs already cover its provider
changes; no CPython/Core dependency was invented there.

This slice adds direct Core edges to EntityKeyboard, ChatEntityKeyboardInputNode,
ChatScheduleTimeController, StickerPickerScreen, ChatMessageSelectionInputPanelNode,
ChatSendMessageActionUI, Emoji, LocationResources, LocationUI, OpenInExternalAppUI,
PasscodeUI and TelegramCoreTestsLib. The latter also needs PluginHooks for the new
outgoing-chat tests, and sqlcipher for the retention fixtures. Additional concrete
handoff edges are AccountContext → ComponentFlow; EntityKeyboard → Emoji;
TelegramUI → Weather, ChatMessageItemImpl, ChatMessageItemView and
QuickReactionSetupController; MtProtoKit → system `libdns_sd`. The known-module
audit covered 270 selected source files / 37 imports without a missing edge.
Other new Cloud/API/Dialog/Network/Player/Pill/Privacy/Tools source files are covered
by their existing package globs and SDK autolinking.

Dedicated `Make.py test --target` labels:

- `//Tests/Exteraless:NativeUIContractsTests` — real model/lease source files;
  counted handles, actual appearance, stale revisions/account generations and leases.
- `//Tests/Exteraless:NativeTLContractsTests` — real codec/schema/registry sources;
  pre-engine binary golden, truncation/type checks and owner-bound terminal tickets.
- `//submodules/TelegramCore:ExteralessPrivacyTests` — owner's existing
  ExteralessPrivacySignalTests / ExteralessProxyNameTests, normal Core/Postbox/API deps.
- `//Tests/Exteraless:IdentityPresentationTests` — native peer projection values.
- `//Tests/Exteraless:DialogNativePreferenceTests` — actual archive preference leases.
- `//Tests/Exteraless:StickerEmojiRenderingTests` — actual UIKit/CoreText rendering
  API with the owner's generated font fixture and native favorite-sticker projections.
- `//Tests/Exteraless:PluginPillContractsTests` — shipping identity archive and wire
  DTO sources, with Core/Host dependencies and no interpreter startup.
- `//submodules/TelegramCore:ExteralessNativeCoreTests` — authored Cloud/API,
  outgoing-chat, AI/Postbox, fake-resolver and disposable encrypted-retention fixtures.
- `//submodules/TelegramUI:ExteralessFeedTests` — four finite page/window fixtures
  against testable TelegramUI's shipping registry/timeline.
- `//submodules/TelegramUI:ExteralessAINativeTests` — eight authored UIKit/mapper/
  scoped-transport/speech fixtures against testable TelegramUI.
- `//Tests/Exteraless:IntegrationTests` — these ten targets, independent of the
  dangling `//Tests/AllTests` suite.

UI/TL contract tests compile shipping Foundation sources in test-only modules.
The UI source filegroup now follows all nine files selected by the current owner
driver, including PluginUIStyleModel, PluginManagerPreferences and
PluginDeveloperProtocol. Core's exported `EmojiFontFixture.swift` is explicitly
included by the runtime source preparer, so its external label exists in the
relocated `@exteraless` repository. It is a compile input, not an app resource.
Privacy/NativeCore tests stay in TelegramCore's package for its visibility boundaries.
The runner matches the documented iPhone 17/iOS 26.5 configuration. Existing
bounded Foundation fixture drivers are now wired into Python Framework macOS CI,
with their actual source/resource paths included in sparse checkout. Host/Hooks
and the full FoundationCore package tests remain enabled. The app export lists
already inspect Core's transitive archive and every shipping UI/extension consumer,
so the new dependencies retain one ExteralessCore copy in TelegramCoreFramework.

### Bounded native component preparation

`python-framework.yml` invokes `tools/runtime/check_swift_components.py` for all
three SwiftPM packages. Each invocation builds **all** package tests with two jobs
and a **240-second compile deadline**, then runs an **unfiltered** `swift test
--skip-build` with a separate **30-second process-group deadline**. A compile
failure cannot fall through to cached tests. Source edits during build/execution
invalidate the report; failures and successes retain source hashes, compiler/test
logs and launcher commands/PIDs in the uploaded component artifact. Existing Swift
cache inputs include every package's Sources/Tests/Package.swift.

The source-only inventory at this check had Core **136 source / 54 test files**,
Host **29 / 15**, Hooks **6 / 3**. SwiftPM discovers the full actor/policy surface,
including Host maintenance/mailbox/native-effect suites and the newly authored
Feed/Pill/Player/Privacy/Tools/Appearance/Cloud/Network tests. These are file counts,
not executed test counts. The direct native adapter driver also uses recursive
Host source discovery.

The SDK owner's current native driver remains the published CLI, now invoked with
an explicit matching Python executable and sealed Python root. Its shipping probe
uses `onOwnedCallback`'s captured wire-token comparison/admission Bool and mandatory
`PluginNativeCallLease.check()` before platform effects. Native compilation covers
the current Host implementation and `swift_sdk_fixture.swift`; the child keeps its
30-second deadline. Mac execution awaits the coordinator's Host/SDK-ready snapshot.

### Completed harness BUILD handoff

Applied the published `ui-harness.md:145–200` integration in existing BUILD files:

- `//submodules/AccountContext:ClientHarnessProtocolSource` exports exactly
  `Sources/AccountContext.swift` to the harness package.
- `//Tests/ComposerHarness:DisposableAccountSources` exports only
  `AppContext/HarnessAccount.swift` and `AppContext/HarnessProcessRetainer.swift`.
- `//Telegram:MtProtoKitFramework`, `:SwiftSignalKitFramework`, `:PostboxFramework`
  and `:TelegramUIFramework` now allow `//Tests/ExteralessHarness:__pkg__`.
  TelegramCoreFramework retains its existing public visibility.

Both framework export selectors retain `:debug: []` and their existing release
symbol lists/clients. This matches the harness's **debug_sim_arm64-only** contract.
All three owning BUILDs parsed; source paths, exact visibility and export selectors
were checked. The read-only harness import audit covered **8 Swift files / 6 Core
or Host imports**, with no missing dependency or unresolved source owner.

The app/harness toolchain is the existing **xcode-27 runner / Xcode 27.1** from
`ios-build.yml` and `versions.json`. **26.6 belongs to Foundation runtime CI**.
The harness owner/coordinator owns the new workflow's runner, canonical-source
staging and concurrency corrections. Its BUILD/workflow/helpers and production
Display/settings seams were not edited by this build slice.

### PrivacyExtras and late fixture declaration follow-up

Applied the sole extra edge requested by `privacy-extras-integration.md`:
`//Telegram:ShareExtensionLib` directly depends on
`//third-party/exteraless:ExteralessCore` for `Share/ShareRootController.swift`'s
new import. Both TelegramCore and ExteralessCore retain no PasscodeCore dependency.
ShareExtensionLib is already a client of the Core framework's symbol-export rule.

The next import audit also found and closed the published ChatEmptyNode and
TextFormatTestsLib Core edges. Applied `stickers-integration-build-hunks.patch`
to the existing StickerEmojiRenderingTestsLib: the new favorites fixture and its
TelegramCore dependency. The current `ai-native-remediation.md` requests
`//submodules/TelegramUI:ExteralessAINativeTests`; that target is now declared,
and the owner's nine Core AI fixtures are also selected by NativeCoreTestsLib.
The owner's Swift helper/remediation implementations remain source-owner work.

Current full declaration scan, now including the handed-off harness: **6773 Swift
files / 337 checked imports / 65 owning targets**, **zero missing dependencies or
unresolved source owners**. All six BUILD files changed in this follow-up parsed.
This is source/declaration evidence; the newly selected XCTest methods remain
uncompiled/unexecuted locally.

Coordinator source facts: snapshot **2a03061** commits the 41-class Core addition;
the NetworkResolverHTTP exclusivity failure was corrected with a read-before-write
local under the lock. The subsequent CI is still coordinator-run work. PrivacyExtras
helper fixes A–D retain their author's remediation ownership.

### Nested Rust gitlink delivery — native build prerequisite

Confirmed outer mode **160000**, pinned/detached nested HEAD
**da4b2170210aab0430c4ff18c032991f3030cf45**. The Network/Maps author's resolver,
session_runtime and worker edits were dirty files inside that nested repository;
an ordinary outer commit cannot deliver them. The canonical delivery is now:

- `telegram-ios/build-system/exteraless-patches/mtproto-engine-native-dns.patch`
- `telegram-ios/build-system/exteraless-patches/manifest.json` and `.gitattributes`
- `telegram-ios/build-system/Make/ClientSourcePatches.py` — the common applicator
- `tools/runtime/apply_telegram_client_patches.py` — preparation/proof/Rust-test CLI

The **15922-byte** patch exactly matches the nested `git diff --binary --full-index
--no-ext-diff --unified=0`, SHA-256
`f1bbe44f47990d0f97df34d4a897abc3306b181de793875eae7410d562828cce`.
Neither the gitlink, `docs/submodule-pins.json`, nor an upstream remote was repinned.

| Rust source | Raw preimage SHA-256 | Raw postimage SHA-256 |
| --- | --- | --- |
| resolver.rs | `f0ab8bbfc1814b8c2b46805c78b5fb414c47817b6a48501d7b774523c3500330` | `bfc08ab5618867ceaccf41a08c8aeabaa4b02b9986b9cfed6dfdb33379fe7074` |
| session_runtime.rs | `2f63e664433ed9d523b2fe47c5f389b5cd2b06b9d32c43f4ce410ed4bd67a3aa` | `90c2f28f69ef2eed29b01d2f6864c4a955270b26312c914714cddf09e2b9b91e` |
| worker.rs | `32bc15d7c46b8f1a2bdd0ed035af8742f92407af07356e84823a4d13961485e2` | `2eeeaac5589410c676488c6a23f96f696f8214aae023127f306f8642c4d25d51` |

Preimages are raw LF Git blobs. The author's exact postimages contain mixed CRLF/LF;
explicit, pinned line-ending ranges reproduce them after applying the LF diff.
The SHA checks remain raw-byte checks, matching `network-maps-native-pins.json`.
An all-preimage set is prepared; an exact all-postimage set is only validated.
Third states, partial sets, wrong Git HEAD, altered patch bytes or changed provenance
fail. All output hashes are checked before publishing any replacement file.

Prepared integration paths:

1. `ios-build.yml`: real clean-base replay proof and preparation **before** the
   canonical source rsync. The copy continues to exclude Git metadata. Proof is
   included with artifacts and failure diagnostics.
2. Harness staging CLI: a narrow common-helper callback under its existing owned
   workspace lock, before rsync; sentinel/generation/concurrency rules are retained.
   Harness build uses Make's gate, and its IPA report checks/carries the same stamp.
3. Local Make build/test share `BazelCommandLine` preparation. Remote/VM Make
   entrypoints also prepare before their source copy; full app output rechecks
   staging after compilation.
4. `prepare_telegram_runtime.py`: checks source and relocated contracts before a
   support download, prepares both, and adds patch/metadata/helper and all three
   raw postimage hashes to `source_files` and `client_source_patches`.
5. Runtime preflight/IPA manifests and harness packaging report preserve this
   fingerprint. Stale/missing patch provenance is rejected. Bazel already declares
   every Rust file through its source glob, so changed raw inputs change action keys.
6. `apply_telegram_client_patches.py --rust-tests --report <path>` is the prepared
   host-Rust fixture entrypoint: locked Cargo build (300s), the two `app_resolver_*`
   tests (30s process-group bound), and matching source/executable hashes. This
   command was prepared, **not executed here**.

Local clean-base proof used exactly three temporary files obtained by `git show`
from the pinned commit. Application produced the published postimages, a second
pass preserved modification times, tampering each file was rejected without writes,
and mixed pre/post states were rejected. It copied only those blobs and the tracked
contract/helper, with no Git metadata, credentials or user configuration. Report:
`build/wave-2-dependencies/client-patch-proof.json`.
Its current source fingerprint is
`9ca7ac71a7540ec3a2ef52b2fda5318580f1f5fe4a97611e53a29c7372b315fd`.
The proof also compared the live nested bytes and modification times before/after
validation and recorded `working_postimages_untouched: true`.

The current working nested source was recognized as the exact postimage and was
not reset or re-applied. The outer patch/preparation changes still need to join the
coordinator's source commit before native CI. CPython support and native-framework
packaging remain independent of fetching/compiling this Rust checkout. No final
whole-cohort staging, native Rust/Apple execution, CI dispatch, commit or push was
performed by this build slice.

### Component-only sparse preflight

**Later, separate native Font/Layout BUILD slice:** the two published Display
targets are in IntegrationTests/required-source mappings (five Font methods and
five Layout methods, individually bounded). Roboto 3.015's two fonts and OFL have
flat resource edges into all five handed-off process bundles: main, Share,
Notification Content, NativeTestHost and ClientUIHarness. The extension libraries
have direct Display dependencies. Byte counts, SHA-256/Git-blob pins, resource
ownership, class selection and the absence of additional Roboto UIAppFonts entries
were checked. Inventory: `build/wave-2-dependencies/native-font-layout/resource-inventory.json`.
This slice carries no component 946/947, Apple compilation or visual pass claim.
The compiler-input tooling delta was handed off first in
`component-preflight/component-delta-218f7327.json`; SDK Config/root registration
and the full native graph audit await their separate joins.

Python Framework's sparse checkout now includes the actual Java receipt document,
23-scenario UI postimage/Runtime/harness inputs and the source fixtures used by the
runtime and native-runner plumbing unittests. Its pinned `rules_apple` gitlink is
prepared explicitly, with only `apple/internal` and `apple/testing/default_runner`
selected in that nested checkout. Root registration and its compiled Config provider
are verified ancestor-cone inputs. Public relocated-runtime filegroups/exports and
the TBF05 native source binding are included in `check_component_inputs.py`'s inventory.

A component-only filesystem projection matched Git's own cone matcher and passed
Python 3.12 checks: 74 runtime tests, 44 unsigned/native-planner tests and 48
SDK/dependency pytest cases. The existing Git-only Rust proof is skipped when that
separate repository is absent; full app preparation still requires it. The projection
uses fresh offline staging from the current 12-distribution lock; audit-path tests
require this generated vendor input before execution. Source inventory and logs live
under `build/wave-2-dependencies/component-preflight/` and the CI input report is
retained in `swift-components/input-preflight.json`.

The UI fixture unittest loader was updated for its new postimage module, real source
validation and 23-scenario completion. Native class discovery was made linear over
masked blank lines. `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` is set at the component job.
The coordinator's external-corpus execution exclusions remain in the Core workflow.
No native/Apple execution, workflow dispatch, commit or global IPA source freeze is
attributed to this preflight.

Appearance's final avatar test imports now have AsyncDisplayKit, SwiftSignalKit and
TelegramCore direct dependencies on the existing test library. Its four frozen
source SHA pins and the four added method declarations were checked.

Following that component preflight, the PFR file (two independent 7/3-method classes)
and `EnqueueAdmissionTests.swift` enter the existing native Core target. The four
`TelegramUI/Tests/Chats` producer files enter the existing ChatMedia native target;
its direct dependencies already cover their actual imports. Required-source mappings
and the corresponding component test-source cone are added. The 18 Chat additions
include the already-bound outgoing whole-command regression. PFR's internal Core
hook is served by the current dbg-mode Swift testability feature; Apple typecheck
and all new native class executions are still pending. Fixture and production bodies
were not edited in this binding slice.

### RichComposer, ChatMedia and Java codec handoffs

The subsequent Runtime recovery BUILD handoff (the final segment of
`runtime-recovery-shared.patch`) adds
`//Tests/Exteraless:RuntimeRecoveryContinuationTests`, its one-file library and the
IntegrationTests/required-source mapping. Two methods link the shipping TelegramUI
Tools adapter, Core journal recovery and Host continuation with the existing
Runner/NativeTestHost, bounded at 30 seconds of class logic. Host's new helper and
six SwiftPM tests are already covered by its source/test discovery. The coordinator
applied the Runtime source segment; these build declarations make no source-observer,
Runtime stability or native-execution claim.

Applied the RichComposer BUILD handoff: Core/ChatRichTextEditorComposer dependencies
on `ComposerHarnessTestsLib`, explicit TextFormat producer source, two named-class
Composer test wrappers using the real scene-based `ComposerHarness`, and separate
Core metadata / UIKit Canvas / mapper / InputDec native labels. The planner supports
one exact BUILD class filter and per-target host identity. Shared helper sources
compile under the compiler budget; runtime selects only the handed-off classes.
The Composer host receives the same flat AdGuard resources. UIKit guards cannot
turn a macOS empty suite into accepted evidence: all labels use the iOS simulator
transition, Xcode 27.1 / available iOS 27.0 and mandatory per-method results.

Applied the read-only ChatMedia emitter's `--part tests` packet after its exact
`git apply --check` succeeded: real AccountContext/Gallery/MediaPlayer/Postbox/Core
dependencies, the dedicated test library/target and required source mapping. Its
eight native methods remain execution pending; Gallery/Forward hunks belong to
the source owners.

Native execution stays serial on one owned simulator. A MODULE patch on the
already selected `xctestrunner` version `0.2.16-20260212-4c6f493` adds the actual
`-parallel-testing-enabled NO` argument. The upstream archive was fetched with
verified TLS and matched SHA-256
`4567932c7309b29092ec45c5a0deac75d68af987a3b1112cfdd790b4cffaded4`.
The exact temporary pre/postimage application proof is
`build/wave-2-dependencies/xctestrunner-serial-proof.json`; the patch and its BUILD
are fingerprinted native-plan inputs. Frozen Rust delivery files are separate.

Python Framework additionally invokes `check_java_tl_codec.py`: actual Foundation
TLCodec + TLSchemaGenerated + the Java author's native codec fixture, followed by
the single named pytest with `EXTERALESS_JAVA_TL_CODEC` set to the fresh executable.
Budgets are 240s compilation / 20s codec / 30s isolated child and outer pytest group.
Source/binary hashes, schema identity, unskipped named JUnit completion and logs are
retained in the existing always-uploaded `swift-components/JavaTLCodec/` directory.
The runtime artifact fingerprint also includes the Java fixture, schema and pytest source.
This is the additional seven-case codec process; the existing three SDK child
invocations retain their own evidence. No Windows C binary is selected for Mac;
the optional Java C test requires its own matching extension/receipt.

Scoped declaration/driver checks and seven Starlark parses passed. One old Identity
declaration check had an obsolete method total after author additions; it now pins
the original mandatory method membership in the two classes. No aggregate native
map/source inventory was regenerated. Coordinator-reported Core CI
`43711634580` / `9c409eb8` is green at 595 Core / 174 Host / 30 Hooks; the new native
UIKit/Java codec executions and recordings await coordinator execution.

### Verification limits for the preceding slices

The next received scoped BUILD handoffs are applied: AI's RichDataBubble edge and
six direct AI-test dependencies; Appearance Switch/Slider/NavigationBar/filter-tab
Core imports and the one-file Switch XCTest target; Dialogs' nine Postbox regression
methods in NativeCore; SDK05's three manager-authority methods in NativeUI. The
InstantPage visibility regression has a dedicated one-file cohort target so it
executes without expanding the whole renderer test suite. Tools' MediaEditor and
TelegramCallsUI receive the standalone Core edge; ManagedAudioRecorder/NetworkEngine
already have it through their actual owning targets. No Core → TelegramCallsUI /
PasscodeCore edge or Postbox allowlist change was introduced.

The native UI filegroup was synchronized with the current Foundation fixture driver's
recovery/maintenance/release sources, including the preferences writer's new recovery
snapshot type. Current runtime authority forwarding was inspected; no stale owned
manual NativeConfig fixture required a production-source edit. Ten scoped BUILD files
parsed and the specified source/import/suite edges checked. No native test process,
whole graph audit or final aggregate target map was run for this delta.

Latest scoped handoffs add Identity's two-class remediation file (7 methods),
native TL review/model files (8 + 3), CMC-12 Browser gestures (2), frozen Sticker
review and Player CMC-14/FU-04 sources to actual executable cohort labels. Browser
gesture tests compile the shipping source with Display/Core/SwiftSignalKit; they
construct no WebKit process. BrowserUI → Core and ShareExtensionContext → TextFormat
are declared. The XCTest planner now resolves multiple class bodies in one file;
the final aggregate audit remains reserved for the completed source freeze.

The SDK owner's unchanged CLI now builds six Swift SDK probe/fixture files and runs
three bounded native children. Python Framework keeps all three success reports
(`swift-plugin-smoke.json`, `swift-sdk-tl-smoke.json`, `swift-sdk-hns-smoke.json`),
their build/console logs and build-input identities. Its existing sparse source
paths already cover every supplied SDK/codec/Host input.

The ready domain build handoff is also joined: direct DCT context dependencies,
all requested `ClientHarnessDomainFingerprintSources` groups, and the generated
`client-ui-domain-sources.json` main-bundle resource. Core/UI DEBUG compile actions
are required by the build helper. It retains the verified IPA before later Bazel
test commands can move `bazel-bin`; both recording invocations use that same file.
Baseline core-light/core-dark/sdk-ui and domain feed/player/pill run serially in
separate evidence subdirectories, under the same owned workspace/generation.
Each driver still permits at most three fresh 30-second app processes. The new
batch verifier checks the shared IPA/source fingerprints and preserves both sets
in `evidence/batches.json`; the outer UIKit job cap is 190 minutes. No renderer,
harness scene/domain implementation or process deadline was changed here.

The latest checks were eight focused class/batch/DEBUG checks, 13 BUILD syntax
checks and the handed-off source/dependency/workflow edges. These are declaration
and helper-contract results, not executed native/visual evidence. Rust's frozen
patch/manifest/helper/postimages still match the recorded fingerprint.

Ready post-checkpoint graph deltas are recorded at the top of
[`native-tests.md`](native-tests.md): PR02/04 (17 supplied methods), RetPR (11),
FinalApp notifications (4), and both CA04 classes (4 + 2) now enter their existing
executed cohort labels. Siri/NotificationContent have their actual direct Core
edges. Core/MtProtoKit dependencies were added without duplicates; no private
Core → PasscodeCore edge was introduced.

Python Framework now has one HNS remediation fixture invocation after package
compile/cache preparation. The driver separates **480 seconds to compile the two
local packages and executable** from **30 seconds to execute 13 scenarios**. It
does not assume independent Core/Host package caches contain this executable's
objects: a separate source-keyed scratch cache is restored/saved. The overall
component job is capped at 40 minutes, with a 10-minute HNS step. Successful current
Core/Host source reports are required in CI; input changes, compilation failures or
a missing completion marker fail the fixture. Existing sparse checkout and runtime
source-fingerprint paths already include every selected helper, driver and Core/Host
input. Evidence is retained under `swift-components/PluginUIRemediation/`.

Only three new driver-contract checks and scoped declaration/workflow checks ran
for these additions. No Swift/HNS executable, native UIKit test or CI run is claimed.
The final whole-cohort source inventory/map is reserved for the joined source freeze;
the frozen Rust patch fingerprint and harness domain sources/driver were not edited.

The subsequent remediation/native-test execution handoff is
[`native-tests.md`](native-tests.md): **19 focused native labels / 36 XCTest classes /
139 source-derived methods**, Player/PrivacyExtras/AP/FPP/Retention source coverage,
the resource-bearing XCTest host, unsigned Make test phases, and a bounded manual
UIKit workflow step between full-sim compile and recording. Only its new declaration/
workflow checks ran locally; the existing Rust delivery fingerprint is frozen.

- **68 runtime/packaging unittest cases**, **26 unsigned plumbing cases**, and
  **15 harness driver/workspace cases passed** after the nested-patch integration.
  The preceding dependency/SDK slice passed 47 pytest cases. Checks cover the P2 report gate,
  source-fingerprint invalidation, compiler-failure/timeout handling, exported test
  input coverage, AdGuard pins and main-root resource placement. Import audits,
  Postbox import check, owned workflow YAML and **60 changed/new BUILD** syntax
  checks passed. The earlier 50/56-case runtime results are superseded by this run.
- New UIKit/TL XCTest wrappers and Mac Foundation drivers are **compile/execution
  pending**. Full UIKit compilation and recorded-frame acceptance belong to the
  coordinator/device stage. No allowlist was widened and no CI was dispatched.
- Coordinator-reported `4b3f7064` / `43653040458` (122 Core / 89 Host / 16 Hooks)
  remains earlier green baseline evidence. The newer coordinator-pushed
  `9222140b` / `43691591367` includes C219 and a larger Core snapshot; its reported
  ToolsReleaseTransfer/NSObject `hash` compile failure was fixed by the coordinator
  with `contentHash`. That failed run is not a pass for this integration. Current
  Host/TL and Settings/AI stitching stays with its source owners.
- Pillow simulator download was retried with an explicit native-root TLS context
  (`CERT_REQUIRED`, hostname checking, 36 trust roots; TLS 1.2). The redirect still
  reset the connection. No verification-off/IP/cookie/private-header workaround
  was introduced, no Mac CI was spent on the download, and native admission is
  still empty. Only previously verified artifact metadata/content is reported.
- Final whole-input staging review waits for **all source commits and the completed
  joined cohort**. The checks here only inspected source inventories; no new final
  staging, Apple build, CI dispatch, commit or push was performed. The new harness
  BUILD/workflow/helpers remain owned by their separately assigned agent.
