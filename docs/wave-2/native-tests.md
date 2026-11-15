# Native regression execution map

## Current native/UIKit frozen snapshot

See [native-ui-freeze.md](native-ui-freeze.md) for the exact delivery after
`78e6d5d8`, the `e8484ec0` glob correction and the `e2a5684c` TL receiver fix.
The actual selection is **36 executable labels / 85 mandatory sources /
88 classes / 410 methods**. The new receipt directory is
`build/wave-2-dependencies/native-ui-freeze-78e6d5d8/final/`.
It includes full method-start/result gates, generated protocol stubs, both
resource-bearing XCTest hosts and source-bound **3+3+2** recordings.
The ChatMedia test import correction is applied in this native-only delta.
The older source seals and staging observations below remain checkpoints;
the current handoff explicitly records the concurrent unpublished Core source edit.

## Final BUILD / recording join

**Source base:** `4476f853`, SDK `46393e31`, Layout `19c1a96a`, renderers
`b06f959b`, Font consumers `2bac089c`. This is a declaration/staging handoff,
not an Apple compile or native-test result.

Final selection: **36 targets, 88 classes, 410 methods**.
The same selection before the Font consumer handoff had 33 targets / 85 classes;
the `4476f853` bodies contained 395 methods. Three additional PNP01 Layout methods
were published in `19c1a96a`, three Font consumer methods in `2bac089c`, and nine
actual renderer/decoder fixtures in `b06f959b`. The intermediate working-tree
34/86/401 metric is retained as a checkpoint, not relabelled as this final result.
`Tests/Exteraless/native-tests.json` is the mandatory source-to-label map; the
full per-class/method inventory is `build/wave-2-dependencies/final-native-join/post-font-handback/native-test-plan.json`.

| Executable label | Classes | Methods |
| --- | ---: | ---: |
| `//Tests/Exteraless:NativeUIContractsTests` | 3 | 9 |
| `//Tests/Exteraless:NativeTLContractsTests` | 1 | 3 |
| `//Tests/Exteraless:RuntimeRecoveryContinuationTests` | 1 | 2 |
| `//Tests/Exteraless:IdentityPresentationTests` | 3 | 13 |
| `//Tests/Exteraless:DialogNativePreferenceTests` | 1 | 2 |
| `//Tests/Exteraless:StickerEmojiRenderingTests` | 3 | 16 |
| `//Tests/Exteraless:PluginPillContractsTests` | 3 | 10 |
| `//submodules/TelegramCore:ExteralessPrivacyTests` | 4 | 23 |
| `//submodules/TelegramCore:ExteralessNativeCoreTests` | 21 | 122 |
| `//submodules/TelegramUI:ExteralessFeedTests` | 7 | 39 |
| `//submodules/TelegramUI:ExteralessAINativeTests` | 2 | 14 |
| `//submodules/TelegramUI:ExteralessChatMediaTests` | 7 | 34 |
| `//submodules/ChatListUI:ExteralessChatSwipeTests` | 1 | 4 |
| `//submodules/InstantPageUI:ExteralessAIVisibilityTests` | 1 | 1 |
| `//submodules/TelegramUI:ExteralessTLModelTests` | 2 | 7 |
| `//submodules/TelegramUI:ExteralessPlayerNativeTests` | 4 | 18 |
| `//submodules/TelegramUI:ExteralessAppearanceRootTests` | 1 | 2 |
| `//submodules/AvatarNode:ExteralessAppearanceAvatarTests` | 2 | 8 |
| `//submodules/Display:ExteralessFontFamilyTests` | 1 | 5 |
| `//Tests/Exteraless:FontFamilyConsumerTests` | 1 | 3 |
| `//submodules/Display:ExteralessLayoutModeTests` | 1 | 8 |
| `//submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl:ExteralessDCTTimingTests` | 1 | 5 |
| `//submodules/TelegramUI/Components/SubcodecMultiAnimationRendererImpl:ExteralessSubcodecTimingTests` | 1 | 4 |
| `//submodules/TelegramPresentationData:ExteralessAppearancePresentationTests` | 2 | 8 |
| `//submodules/TelegramStringFormatting:ExteralessAppearancePresenceTests` | 1 | 3 |
| `//submodules/TelegramUI/Components/NavigationExpansionTransition:ExteralessGlassTests` | 1 | 4 |
| `//submodules/TelegramUI/Components/SwitchComponent:ExteralessAppearanceSwitchTests` | 1 | 1 |
| `//submodules/Postbox:ExteralessRetentionMediaTests` | 1 | 2 |
| `//submodules/MTProtoRustEngine:ExteralessPassivePingTests` | 2 | 5 |
| `//submodules/TextFormat:ExteralessComposerTests` | 2 | 7 |
| `//Tests/ComposerHarness:ExteralessComposerSelectionTests` | 1 | 5 |
| `//Tests/ComposerHarness:ExteralessComposerPasteTests` | 1 | 7 |
| `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerMetadataTests` | 1 | 1 |
| `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerUIKitTests` | 1 | 3 |
| `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerMapperTests` | 1 | 7 |
| `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerInputDecTests` | 1 | 5 |

PFR's 7-method and 3-method classes remain independent executions. ASC01's active
fade fixture is included in Avatar; the new Font consumer target is separate from
the original five Font producer tests. Schedule/Forward/Feed terminal and direct-save
files are mandatory mappings. The four previously unbound `PluginTLExecutionGuardTests`
now compile in the existing TL model target with a direct PluginHost edge.
The PNP02/03 targets use the shipped decoders/caches with generated local frames,
64-frame/250ms work bounds and the same external 30-second class limit.

### Native execution and three recording batches

The full build names `//Telegram:Telegram` and `//Telegram:ClientUIHarness`; the latter
is a BUILD alias of the existing `//Tests/ExteralessHarness:ClientUIHarness` app.
The frozen driver's `buildSelection` therefore names the actual built target.
The verified harness IPA is retained once before any test build can repoint bazel-bin.

Xcode 27.1 / an available iPhone 17 iOS 27.0 runtime and unsigned `debug_sim_arm64`
remain mandatory. Compile/analysis and execution each have a 900-second envelope;
per class: 180s preparation, 30s logic, 60s finalization. The driver fits within
its 2000s total / 2100s owned-exec deadline. Run-only forbids compiler actions;
all required method starts/results and the explicit serial-runner patch are retained.

After NativeIntegrationTests, one owned-workspace invocation per row records:

| Directory | Exact ordered scenarios |
| --- | --- |
| `evidence/baseline/` | `core-light`, `core-dark`, `sdk-ui` |
| `evidence/domains/` | `feed-render`, `player-render`, `pill-render` |
| `evidence/final-visuals/` | `avatar-render`, `composer-render` |

Each invocation keeps a 600s outer budget and at most three sequential fresh
30s app processes, and deletes its fresh simulator before the next invocation.
The job cap is 200 minutes. The final verifier requires exact requested/batch/build
identities, successful native tests, complete semantic/recording lists, equal IPA /
Rust / domain fingerprints and three distinct simulator UUIDs. Native PNGs and
frame-handles remain in the final batch's evidence tree. No visual pass is inferred.

All thirteen final-visual source filegroups and eight direct harness dependencies
are joined. The same build-time manifest also includes root registration/provider
sources and the pinned Font/Monet resource bytes. Local declaration resolution
found 627 canonical inputs; the built IPA's manifest remains authoritative.

### Resource and source audit notes

`native-bundle-resources.json` pins the Roboto pair/OFL and three Monet notices.
The full build checks Telegram, Share, Notification Content and ClientUIHarness
bundle roots; native-test compilation also checks NativeTestHost. Wrong hashes,
missing/nested duplicates and additional Roboto UIAppFonts registration fail.

Audit found a source import mismatch in `ChatMediaRemediationNativeTests.swift:4`:
`MediaPlayerStatus` is in `UniversalMediaPlayer`, not Apple's `MediaPlayer` module.
The BUILD edge is corrected. The un-applied one-line source handoff is
`final-native-source-fixes.patch`; the source owner must accept it before native compile.
The earlier post-4476 observations are retained in `source-base-deltas.json`.
Published Font/Layout/renderer handbacks are captured separately under
`post-font-handback/`; source metrics are not native results.

The post-handback native source fingerprint is
`e40c47b029a38ec2a1be8ed368bbd6638c61cc1b353370e6fdcbfd358474df34`;
the declared domain/root resource fingerprint is
`2c5a3d90429e967338cd5507e694618200b440fa7cc12d8328762d30eed73922`.
Full per-file hashes and BUILD paths are in the same `post-font-handback/` directory.
The complete registered-module source scan is 6887 files / 1595 imports / 471 targets,
with no remaining missing declared dependency or unresolved source owner.

The earlier 946-input component receipt omitted three actual TL compiler inputs.
It is not complete compiler-coverage evidence. Its unchanged receipt and correction
are retained separately; schema-2 inventories consume the actual runner declarations.

## Historical handoff checkpoints

The sections below preserve earlier source/count checkpoints. The final selection
and three-batch contract above supersede their aggregate counts and two-batch text.

## Font/Layout native BUILD join after the component handoff

The separately published `font-family-build.patch` and
`layout-mode-native-tests.patch` are integrated as BUILD/resource declarations:

- `//submodules/Display:ExteralessFontFamilyTests` selects the five methods in
  `ExteralessFontFamilyTests.swift`.
- `//submodules/Display:ExteralessLayoutModeTests` selects the five methods in
  `AppearanceLayoutModeTests.swift`, with Display/Core/AsyncDisplayKit/SwiftSignalKit.

Both labels enter IntegrationTests and the required-source map, use the existing
Runner/NativeTestHost, and retain one 30-second class execution each. The older
hostless Display test library excludes the resource-dependent Font test source;
its Layout imports have the handed-off direct dependencies.

`//submodules/Display:ExteralessFontResources` contains the pinned Roboto 3.015
regular/italic pair and unmodified OFL. Each of Telegram, ShareExtension,
NotificationContentExtension, NativeTestHost and ClientUIHarness has one flat
`resources` edge, placing the files in its process-main-bundle root. Roboto is not
added to UIAppFonts. The three sizes/SHA-256/Git-blob pins and five resource edges
were checked; compiled bundle inspection and native execution are pending.

The separate declaration inventory is
`build/wave-2-dependencies/native-font-layout/resource-inventory.json`.
This is a later native-cohort join, not evidence from component receipts 946/947.
The imminent Mac handoff remains the three compiler-input tooling files recorded
in `component-preflight/component-delta-218f7327.json`. SDK Config registration,
manifest regeneration and the whole native graph audit follow their owner joins.

## Post-checkpoint cohort additions (final map awaits source freeze)

The accepted 19-target checkpoint below is retained as history. These published
source edges have been added directly; no new aggregate map/count is claimed while
AF/FU/IDS and the remaining author cohorts are being finalized.

| Ready handoff | Executable suite binding |
| --- | --- |
| `shared-PR02.patch:50–70`: `ExteralessPrivacyAdmissionTests.swift` and `ExteralessPrivacyHistoryLifetimeTests.swift` (17 supplied methods) | `//submodules/TelegramCore:ExteralessPrivacyTests`; explicit Core + MtProtoKit deps, each once |
| `retention-review-tests-hdo.patch`: `RetentionReviewRemediationTests.swift` (11) | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `FinalAppNotificationAdmissionTests.swift` (4) | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| CA04 `NetworkCredentialLogTests.swift` (4) | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| CA04 `RustCredentialLogTests.swift` (2) | `//submodules/MTProtoRustEngine:ExteralessPassivePingTests`; explicit MtProtoKit dependency |
| `IdentityRemediationTests.swift` (7, two XCTest classes) | Existing `//Tests/Exteraless:IdentityPresentationTests`; LocalizedPeerData, PresentationData, UIPreferences and SwiftSignalKit deps |
| `ExteralessTLReviewTests.swift` (8) | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `TelegramUI/Tests/PluginTLEditModelTests.swift` (3) | `//submodules/TelegramUI:ExteralessTLModelTests` |
| CMC-12 `BrowserGestureContractsTests.swift` (2) | Existing `//Tests/Exteraless:NativeUIContractsTests`; shipping Browser gesture filegroup with Display/Core/SwiftSignalKit |
| `ExteralessStickerReviewTests.swift` (two native classes) | `//submodules/TelegramCore:ExteralessNativeCoreTests`; updated Emoji tests retain their existing selected source |
| Player CMC-14 `PlayerEndActionGateTests.swift` and FU-04 `PlayerSurfaceFollowingTests.swift` | Existing `//submodules/TelegramUI:ExteralessPlayerNativeTests`; current test glob and explicit required-source entries |
| AI AF follow-up `ExteralessAIFollowupNativeTests.swift` | Existing `//submodules/TelegramUI:ExteralessAINativeTests`, with the six handed-off direct dependencies |
| `InstantPageUI/Tests/InstantPageAIVisibilityTests.swift` | `//submodules/InstantPageUI:ExteralessAIVisibilityTests`; one-file cohort selection alongside the existing general InstantPage test target |
| `SwitchComponent/Tests/AppearanceSwitchTests.swift` | `//submodules/TelegramUI/Components/SwitchComponent:ExteralessAppearanceSwitchTests` |
| `TelegramCore/Tests/ExteralessDialogReviewTests.swift` (9) | Existing `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| SDK05 `Tests/Exteraless/PluginManagerAuthorityTests.swift` (3) | Existing `//Tests/Exteraless:NativeUIContractsTests`, with shipping preferences/model/recovery helpers |
| CMC `HarnessComposerSelectionActionTests` / `HarnessComposerPlainPasteTests` | `//Tests/ComposerHarness:ExteralessComposerSelectionTests` / `:ExteralessComposerPasteTests`; one named class per target, actual `ComposerHarness` test host |
| `TextFormat/Tests/ExteralessComposerProducerTests.swift` | Existing `//submodules/TextFormat:ExteralessComposerTests`; explicit source alongside policy tests |
| `DocumentSelectionMediaMetadataTests` | `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerMetadataTests` |
| `CanvasPlainPasteLiteralTests` | `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerUIKitTests`; its existing nested `CanvasClipboardTests.FakePasteboard` compiles as support |
| `AttributedStringMapperLinkTests` | `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerMapperTests` |
| InputDec `Host/Tests/Engine/ChatLinkIngressTests.swift` | `//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerInputDecTests` |
| ChatMedia `ChatMediaRemediationNativeTests.swift` (8) | `//submodules/TelegramUI:ExteralessChatMediaTests`, with the full `ChatMediaNativeFixture.swift` and the packet's real native deps |
| Runtime recovery `RuntimeRecoveryContinuationTests.swift` (2) | `//Tests/Exteraless:RuntimeRecoveryContinuationTests`; explicit one-file library linking TelegramUI, ExteralessCore and PluginHost |
| PFR `PFRAppIntegrationTests.swift`: `PFRAppIntegrationTests` (7), `PFRNativeAccountStartupTests` (3) | Existing `//submodules/TelegramCore:ExteralessNativeCoreTests`; both classes independently selected and bounded |
| `TelegramUI/Tests/Chats/{ChatAdmissionProducerTests,ChatSoundProducerTests,ChatCallProducerTests,ChatEditProducerTests}.swift` | Existing `//submodules/TelegramUI:ExteralessChatMediaTests`, with its actual AccountContext/Core/Postbox/SwiftSignalKit dependencies |
| `TelegramCore/Tests/EnqueueAdmissionTests.swift` | Existing `//submodules/TelegramCore:ExteralessNativeCoreTests` |

All referenced native labels already belong to IntegrationTests; these files are not left
only in the unrelated broad test globs. `native-tests.json` records the required
new source edges. Siri's IntentsExtensionLib and NotificationContentExtensionLib
also directly depend on ExteralessCore for the applied app-composition imports.
BrowserUI also has its direct Core dependency, and ShareExtensionContext directly
depends on TextFormat. CMC-12 executes UIKit view/settings logic, not WebKit page
construction. The planner associates methods with each XCTest class body;
Identity/Sticker multi-class files remain independently bounded at 30s per class.

The later AI handoff adds TelegramUI's real RichDataBubble dependency and the
AccountContext/ComponentFlow/Postbox/SwiftSignalKit/transcription-button/round-video
dependencies to the existing AI test library. Appearance's Switch/Slider/NavBar/
ChatListFilterTab targets and Tools' MediaEditor/TelegramCallsUI have direct Core
edges. ManagedAudioRecorder and NetworkEngine already belong to Core-dependent
TelegramUI/TelegramCore targets. Neither private Core dependency direction nor
Postbox allowlists was expanded.

NativeUI contracts now include the current Foundation driver's recovery,
maintenance and release-queue sources. This supplies the new
`PluginRuntimeRecoverySnapshot` used by the preferences writer. The versioned
owned test/build fixtures have no stale manual NativeConfig type stub; the applied
runtime writer was inspected forwarding `authority.isCurrent` at actual write time.
No production authority forwarding or author regression body was rewritten here.

RichComposer's two handed-off direct dependencies are in `ComposerHarnessTestsLib`.
Its shared helper chain reaches `HarnessEditedContent` and the existing fuzz support,
so the library compiles once under the separate compiler budget. Each new wrapper's
BUILD `test_filter` names exactly one remediation class. The planner respects that
filter, requires a matching class and records all compiled inputs; the runtime does
not union it with a broader filter. UIKit's Canvas helper class is handled the same
way. The Core, mapper and InputDec targets have explicit fixture files and use the
shipping Bazel modules with the package/Host project's Swift 5 language mode.
The iOS transition plus mandatory native method results prevents a
`#if canImport(UIKit)` macOS zero-test pass. These cohorts execute displayMode
preservation, revision/ABA, Date, paste/undo and authored-underline checks.

The ChatMedia packet was generated/checked using
`chat_media_shared_patch.py --part tests --verify` and its three BUILD/manifest
hunks applied. Fixtures import full AccountContext/Gallery/MediaPlayer/Core scope
APIs. Gallery/Forward production integration remains the published owners' work.

The Runtime recovery patch's remaining BUILD segment (336–374) is applied, with
the mandatory source mapping. Its named class exercises the shipping public
`ExteralessToolsHostMaintenance` adapter, actual Core journal reconciliation and
`PluginRuntimeStartupContinuation` with a fixture engine. It uses the common
Runner/NativeTestHost and the existing 30-second class logic budget. The new Host
helper and six SwiftPM tests enter the existing source/test targets automatically.
The coordinator reports the Runtime source hunk applied; composition, observer and
native execution stability remain unverified by these declaration checks.

After the component preflight, the published PFR and Chat-review source bindings
were added to the existing executable targets. PFR's two XCTest class bodies stay
separate (7 + 3 methods), with the same 30-second class clock. Its `@testable
ExteralessCore` hook uses the existing `debug_sim_arm64` / `-c dbg` configuration:
the pinned Swift rules enable `swift.enable_testing` in dbg and emit `-enable-testing`.
This is verified configuration wiring, not an Apple compile result.

The Chat handoff's 18 new methods are 14 across its four new UI classes, three in
`EnqueueAdmissionTests`, and the already-selected
`testWholeBotCommandIncludingStyledArgumentsBypassesPangu` in outgoing-text tests.
Required source mappings pin each new file; the component sparse checkout also
contains `TelegramUI/Tests/Chats` for the planner's own unit tests. Native execution
and fixture/scenario acceptance remain coordinator gates.

The PluginUI remediation cohort is a separate **Foundation executable**:
`PluginUI/Tests/PluginUIRemediationFixture.swift` plus ten shipping helpers and the
real Core/Host packages, with a fixture engine. Its single Python Framework
invocation follows successful Core/Host component reports/cache preparation.
`run_remediation_fixture.py` provides **480s compilation / at most 30s execution**,
two compiler jobs, its own SwiftPM scratch cache, source/component fingerprints,
compiler/runtime logs and the current 23-scenario completion marker. The selected
sources contain no UIKit import; this is neither pixel evidence nor real-CPython
execution. Native UIKit/domain scenarios stay with the harness owner.

### Java-value Foundation TL control

Python Framework now invokes `tools/runtime/check_java_tl_codec.py` once. It compiles
the actual `TLCodec.swift`, `TLSchemaGenerated.swift` and
`tools/compat/tests/fixtures/java_values/native_codec.swift`, then supplies the fresh
executable through `EXTERALESS_JAVA_TL_CODEC` to exactly
`test_java_value_regressions.py::test_java_bytes_through_native_tl_codec`.
Compilation has **240 seconds**; the codec process has **20 seconds**, its isolated
Python child **30 seconds**, and the entire pytest process group **30 seconds**.
The component requires actual Xcode 26.6 and the macOS Foundation SDK.

The seven cases consume Python adapter output and validate native
`sourceSHA256/nativeLayoutHash`, normalized round trips and bytes rejection.
Raw input hashes, executable SHA, compiler/runtime logs and one passing, unskipped
JUnit result are retained in `swift-components/JavaTLCodec/`. Changed inputs or
binary, compile failure, timeout, skipped/empty/partial test evidence fail admission.
This additional codec process is independent of the existing three SDK children.
The optional Java C-extension test requires a matching platform extension/receipt;
the author's Windows C results are not Mac C-extension evidence.

Coordinator-reported component checkpoint: **`43711634580` / `9c409eb8` —
595 Core / 174 Host / 30 Hooks green**. The new UIKit cohorts and this Java Foundation
codec invocation remain native-execution pending. Local results cover scoped
declarations, command/evidence gates and patch application only.

### Component-only preflight before the manual Mac gate

`check_component_inputs.py` inventories the current runtime/unit-test inputs,
three SDK children's Java receipt/root Config sources, 23-scenario UI postimage,
Foundation Java codec inputs, public relocated-runtime filegroups/exports and native
planner fixtures, including TBF05. Each source has its raw SHA, consumers and actual
cone coverage recorded. Root Config and ClientSettingsBridgeExtension are confirmed
ancestor-cone files. The workflow supplies narrow test/source cones and explicitly
prepares the pinned `rules_apple` gitlink's plumbing directories.

The component filesystem projection was checked against `git sparse-checkout
check-rules`, then tested on Python 3.12 with a freshly staged, checksum-verified
12-distribution vendor bundle. Results: **74 runtime unittests passed**, the existing
Git-only Rust clean-base proof skipped in this component checkout, **44 unsigned/native
plumbing tests passed**, and **48 SDK/dependency pytest cases passed**. No owned SDK
checks were removed. The masked-string XCTest scanner now uses horizontal leading
whitespace to avoid repeated whole-suffix scans. UI driver unit checks load the new
postimage helper and retain its actual source validation and 23-case completion.

Local inventory/logs: `build/wave-2-dependencies/component-preflight/`.
CI retains `swift-components/input-preflight.json`; the workflow uses
`PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`. These are component input/plumbing results;
Apple compilation, 23-scenario/native-child execution and the joined IPA freeze
remain later gates. The avatar follow-up's three direct dependencies are in the
existing Avatar test library; all four raw source pins were checked.

## Accepted native-test checkpoint

Source/declaration handoff. **No new XCTest, simulator or CI execution is claimed.**
The current mapped snapshot has **19 ios_unit_test targets, 36 XCTest classes,
139 methods**. `telegram-ios/Tests/Exteraless/native-tests.json` names mandatory
source → target edges; `tools/runtime/native_test_plan.py` resolves the actual
BUILD/srcs/filegroup/glob declarations and derives every current XCTest method.
An omitted required source, duplicate owner, empty class or missing runner fails
before native compilation. Additional methods in these files are picked up from
the joined source snapshot rather than relabelled as an older green result.

## Required native files and labels

All labels below belong to `//Tests/Exteraless:IntegrationTests`.

| Source / obligation | Native label |
| --- | --- |
| `TelegramCore/Tests/PlayerSavedMusicTests.swift` — FPP-06 | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `TelegramUI/Tests/Player/{PlayerOcclusionPublisherTests,PlayerLyricsAppearanceTests}.swift` — FPP-03/08 | `//submodules/TelegramUI:ExteralessPlayerNativeTests` |
| `TelegramCore/Tests/ExteralessPrivacyExtrasRemediationTests.swift` — A–D and durability binding | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `TelegramUI/Tests/Appearance/AppearanceRootTabsTests.swift` — AP-02/root composition | `//submodules/TelegramUI:ExteralessAppearanceRootTests` |
| `AvatarNode/Tests/AppearanceAvatarRenderingTests.swift` — AP-04/05/06 | `//submodules/AvatarNode:ExteralessAppearanceAvatarTests` |
| `NavigationExpansionTransition/Tests/GlassShapeKeyframesTests.swift` — AP-08, including previous real Glass cases | `//submodules/TelegramUI/Components/NavigationExpansionTransition:ExteralessGlassTests` |
| `TelegramPresentationData/Tests/AppearancePresentationRevisionTests.swift` — AP-09 | `//submodules/TelegramPresentationData:ExteralessAppearancePresentationTests` |
| `TelegramStringFormatting/Tests/AppearancePresenceTests.swift` — AP-10/11 | `//submodules/TelegramStringFormatting:ExteralessAppearancePresenceTests` |
| `TelegramUI/Tests/FeedTests/{FeedNativeOrchestrationTests,FeedRemediationNativeTests}.swift`, with `FeedNativeFixtures.swift` | `//submodules/TelegramUI:ExteralessFeedTests` |
| `Tests/Exteraless/{PluginPillContractsTests,PillSettingsEntryContractsTests,PillPassivePingContractsTests}.swift` — wire, FPP-09, passive reading admission | `//Tests/Exteraless:PluginPillContractsTests` |
| `TelegramCore/Tests/ExteralessPassivePingForwardingTests.swift` | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `MTProtoRustEngine/Tests/MTProtoRustEngineTests/RustPassivePingEventTests.swift` — actual FFI layout/projection, no live engine | `//submodules/MTProtoRustEngine:ExteralessPassivePingTests` |
| `TelegramCore/Tests/{ExteralessRetentionTests,RetentionNativeIntegrationTests}.swift` | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `Postbox/Tests/MediaBoxRetentionKeepTests.swift` | `//submodules/Postbox:ExteralessRetentionMediaTests` |
| `Tests/Exteraless/{StickerEmojiRenderingTests,StickerFavoritesIntegrationTests,ToolsFavoriteStorageNativeTests}.swift` | `//Tests/Exteraless:StickerEmojiRenderingTests` |
| `TelegramUI/Tests/AI/ExteralessAINativeUITests.swift` | Existing `//submodules/TelegramUI:ExteralessAINativeTests` (one target) |
| `TelegramCore/Tests/{ClientAPIRequestMetadataTests,CloudTransportTests,CloudLegacyTransportTests,ExteralessAINativeTests,ExteralessOutgoingChatTextTests,ExteralessResolverConnectionTests}.swift` | `//submodules/TelegramCore:ExteralessNativeCoreTests` |
| `TelegramCore/Tests/{ExteralessPrivacySignalTests,ExteralessProxyNameTests}.swift` | `//submodules/TelegramCore:ExteralessPrivacyTests` |
| `TextFormat/Tests/ExteralessComposerPolicyTests.swift` | `//submodules/TextFormat:ExteralessComposerTests` |
| Existing UI/TL Foundation contracts, Identity presentation and Dialog preference fixtures under `Tests/Exteraless` | `:NativeUIContractsTests`, `:NativeTLContractsTests`, `:IdentityPresentationTests`, `:DialogNativePreferenceTests` |

The AP-01/03/07 `AppearanceRemediationTests`, FPP-01 context lease,
FPP-07 lyrics-budget and FPP-10 registry tests are Foundation Core package fixtures.
Their source/test globs remain part of the existing complete ExteralessCore
component run; the native table above identifies the app-layer proof obligations.
Foundation or XCTest results do not substitute for the authors' required frames.

## Runner and resources

Every selected target uses `//Tests/Exteraless:Runner` (**iPhone 17 / iOS 27.0**).
The default host is the minimal `//Tests/Exteraless:NativeTestHost`. The execution helper checks
**actual Xcode 27.1**, iOS SDK 27 and an available matching generic iOS 27.0 runtime
from `simctl`. Missing runtime/type is a blocked gate; there is no 26.6/26.5 fallback.

The resource-only host has unique Objective-C delegate/scene names, an empty
UIKit root and the existing strings, PresentationStrings.data, image/legacy assets
and exact AdGuard resources. This is required because shipping presentation APIs
force-read `Bundle.main`. The acceptance harness's scene, scenarios and driver are
not repurposed as a test host. Postbox tests remain in their owning packages;
Postbox visibility/import allowlists and Core → PasscodeCore edges are not expanded.

The two Composer targets instead declare `//Tests/ComposerHarness:ComposerHarness`
in `native-tests.json:target_hosts`: their real fixture helper reads the app's
`AppDelegate.harnessRootViewController`. The planner checks the BUILD bundle id and
fingerprints the actual app/context sources and `Tests/Common/Main/main.m`; the
driver uninstalls that exact host before each class. Its existing resource list now
includes the flat AdGuard resources with package-specific visibility.

The existing pinned `xctestrunner` receives
`build-system/exteraless-testing/xctestrunner-serial.patch` through MODULE's
`single_version_override`. It adds `-parallel-testing-enabled NO` to the actual
`xcodebuild test-without-building` command. The driver's explicit owned simulator
destination remains in use, and an additional booted simulator blocks execution.
The patch was verified against the checksum-matched upstream archive, including
exact LF pre/postimages with Git autocrlf disabled only for the temporary proof.

## Native execution in the manual UIKit workflow

`client-ui-harness.yml` runs the native-test helper **after** the full unsigned
`debug_sim_arm64` app/harness build and **before** installing frame tools/recording.
It runs through the existing claimed `client_ui_harness_workspace.py exec`, with
the same sentinel, ready generation, Bazel user root and content-addressed disk
cache. The helper validates those identities and the completed full-sim build report.

- **Compilation/analysis:** separate 900-second budget, two Bazel jobs and the
  preceding build's JVM/CPU/memory limits. The joined manifest's concrete labels are compiled.
  Unsigned aquery includes the full app plus the tests, retaining the normal app /
  six-extension and runtime checks.
- **Simulator preparation:** one newly created `EXL-NativeTests-<uuid>` simulator;
  explicit type/runtime, 30-second boot command and 150-second boot readiness bound.
- **Execution:** serial XCTest classes, never parallel simulator fleets. Each class
  has up to 180 seconds for runner preparation, **30 seconds from the first native
  XCTest suite-start event**, and 60 seconds for finalization. A 900-second whole
execution envelope bounds the class loop. Native stdout is unbuffered and logs
  are bounded. Deadline cancellation interrupts the owned Bazel request and shuts
  down only the newly created/identity-checked test simulator.
- **No compilation during the execution phase:** Bazel 9.2's `--check_up_to_date`
  forbids build actions while `--nocheck_tests_up_to_date` still permits
  `TestRunnerAction`. Results caching/retries are disabled. See Bazel 9.2
  `src/main/java/com/google/devtools/build/lib/exec/CheckUpToDateFilter.java`.
- **Result admission:** every source-derived test method must start and pass in its
  selected class. Zero tests, partial results, skips, failures, retries or a logic
  duration over 30 seconds fail. The previous test-host installation is removed
  from the owned simulator before each class; cleanup checks its UUID/name/type/runtime.

The helper's 2000-second overall deadline reserves 150 seconds for cancellation /
identity-checked cleanup before the owned wrapper's hard stop; slow earlier phases
reduce the remaining class-loop allowance. The workflow step is capped at 36 minutes
(owned execution: 2100 seconds); the job
has a 190-minute outer cap including the existing full build and recording stages.
An unsuccessful native step blocks recording. No new package/toolchain installation
or native execution was performed locally while preparing these declarations.

## Serial domain recording join

The later `Tests/ExteralessHarness/Integration/domain-build-handoff.md` is applied
to BUILD/resource edges. Real DCT cache/renderer imports have direct dependencies.
Domain filegroups cover bootstrap/Core policies, Feed/Player/Pills, the four
separate message-component packages and PhotoResources. The protocol-generator
filegroup still contains exactly `AccountContext.swift`. A build-action genrule
embeds `client-ui-domain-sources.json`; actual Core/UI Swift compile actions must
contain DEBUG, and the build helper validates the resource in the produced IPA.

The verified IPA is retained once as `$CLIENT_UI_RUN_DIR/build/ClientUIHarness.ipa`
before NativeIntegrationTests can repoint `bazel-bin`. After that one full-sim build
and the native tests, two sequential owned-workspace driver invocations record:

1. `--scenario core-light --scenario core-dark --scenario sdk-ui`
   into `evidence/baseline/`.
2. `--scenario feed-render --scenario player-render --scenario pill-render`
   into `evidence/domains/`.

Each invocation retains its 600-second outer budget and at most three fresh
30-second app processes. The first driver deletes its owned simulator before the
second starts; no matrix or simultaneous simulator pool is introduced. The job's
outer limit is now 190 minutes. `verify_client_ui_batches.py` checks both complete
scenario/recording lists, cleanup, process caps, passing NativeIntegrationTests,
the single IPA/Rust identity and the build-time domain source manifest. It writes
`evidence/batches.json` and the summary; visual review remains pending. Both evidence
subdirectories and the build's domain fingerprint report are uploaded without overwrite.

Checks for this join were scoped: four multi-class source checks, four serial-batch/
DEBUG checks, 13 changed BUILD parses and declared fingerprint/source edges. No
whole-cohort inventory/map was regenerated, and no native process or CI was launched.

## Make.py compatibility and artifacts

`Make.py test` now accepts the same `--unsigned` configuration path as the app.
It also provides `--buildOnly`, `--runOnly`, `--testFilter`, `--testArgument`,
`--testEnvironment`, `--testTimeout`, `--streamTestOutput` and `--buildNumber`.
The native execution helper reuses its actual command builders/configuration,
with no codesigning secrets. `--testTimeout` is the outer launcher envelope;
the helper's observed XCTest clock supplies the separate 30-second logic bound.
Use the focused labels above, not `Tests/AllTests`.

Artifacts under `$CLIENT_UI_RUN_DIR/native-tests/` include the complete source
plan, hashes, copied declared sources/BUILDs, tool hashes, commit/generation,
Xcode/SDK, frozen client-patch stamp, compilation/analysis logs, command lines,
per-class native console/test.log/test.xml/runner outputs, observed method results
and owned simulator cleanup. Raw aquery/config content lives in a temporary sibling
outside the uploaded tree, including on hard interruption.

Local checks for this slice: five new declaration/command/deadline checks passed;
ten changed BUILD files parsed; workflow ordering, owned exec/cache/artifact paths,
Python syntax and the test-host plist checked. The prior 68/26/15 suites were not
repeated. Frozen Rust patch/manifest/helper/postimages still match
`9ca7ac71a7540ec3a2ef52b2fda5318580f1f5fe4a97611e53a29c7372b315fd`.
Whole-cohort staging and native compile/execution await the joined source commit.
