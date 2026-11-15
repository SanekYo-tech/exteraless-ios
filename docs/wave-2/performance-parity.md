# nagram.performanceClass — native presentation policy

Current status: **PNP-02/03 renderer source remediation and real native fixtures
supplied; Apple execution pending**. The coordinator published native baseline
`4476f853`; the independent portable review confirms applied Root/energy/per-target
and ChatController joins. Their former staged descriptions below are historical,
not new gaps. The coordinator reports green Core performance tests on `d8cbdaca`;
exact CI counts remain coordinator evidence, not a result of this renderer patch.

Original integration postimages and the full-file preservation check are recorded in
`performance-native-postimages.json`. Reversing only the applied hunks restores
each exact preimage hash, including all existing PFR/CMC source outside those hunks.

The coordinator-reported **0ceafb7b / green CI** is the accepted TBF-01–04 baseline,
not verification of this new performance cohort. Backup code and its source pins
are frozen. This work uses distinct `ToolsPerformancePolicy.swift` and
`ToolsPerformancePolicyTests.swift`; it does not modify `ToolsFeatures.swift`.

## Original behavior, read before choosing the native mapping

Paths here are under `third_party/exteraless-android/TMessagesProj/src/main/`:

| Original source | Actual decision |
|---|---|
| `kotlin/xyz/nextalone/nagram/NaConfig.kt:1080–1085` | `PerformanceClass`, integer default 0. |
| `java/org/telegram/messenger/SharedConfig.java:1817–1849` | User values 0 measure, 1 high, 2 average, 3 low. These differ from internal LOW=0/AVERAGE=1/HIGH=2 constants. The selected class is cached; the separate native override takes precedence. |
| `SharedConfig.java:1852–1920` | Automatic Android version/SoC/CPU/sysfs-frequency/memory measurement. None of these identities is synthesized on iOS. |
| `java/org/telegram/messenger/LiteMode.java:52–86,206–214` | Default animation/autoplay/effect masks depend on class; stored per-feature flags and power saving remain separate. Low still permits GIFs and some premium emoji/particle work in this Android preset. |
| `java/org/telegram/ui/Components/AnimatedEmojiDrawable.java:608–640,671–681` | Low-class static tab previews, Lottie precache/thumbnail choices, plus independent LiteMode keyboard/reaction gates. |
| `java/org/telegram/messenger/ImageLoader.java:967–978,1072–1074` | Real Lottie size/fps/cache decisions; non-high implies precache unless `nolimit`. |
| `java/org/telegram/ui/Components/DrawingInBackgroundThreadDrawable.java:231–256` | High skips one heavy-operation pause layer; lower classes pause/resume background Canvas work. |
| `java/org/telegram/ui/Components/ThanosEffect.java:1114–1135` | 120k/60k/30k particle ceilings, with other native clamps. |

These are workload decisions, not a value to forward into an iOS network handshake.
The iOS implementation uses its existing energy flags and client animation clocks;
it does not emulate Android's Canvas scheduler, Lottie disk-cache choice, premium
mask split, particle shader, CPU count or codec support.

## Defined iOS rungs

Every row is intersected with the **unprojected native preferences** and the live
environment below. `Native` means retain that flag, including false. A stored false
is never interpreted as an absent/default flag just because it matches a heuristic.

| User value | Cached renderer clock | Video/GIF autoplay | Sticker/emoji loops | Translucency / dependent effects | Extended/background download work |
|---|---|---|---|---|---|
| 0 Automatic | Existing measured 30/60-fps heuristic | Native | Native | Native | Native |
| 1 High | Up to 60 fps, within actual renderer/display ceiling | Native | Native | Native | Native |
| 2 Average | At most 30 fps | Native | Native | Disabled | Disabled |
| 3 Low | Paused; existing first-frame APIs still work | Disabled | Disabled | Disabled | Disabled |

- `EnergyUsageSettings.default` remains the source of `hw.ncpu`-based default
  loopEmoji/fullTranslucency (`MediaAutoDownloadSettings.swift:264–362`). Automatic
  retains that result and the existing DCT/Subcodec processor-count clock heuristic.
- High can request 60 instead of automatic 30 on a low-count CPU. This is a manual
  **work budget**, not an assertion that the CPU/GPU/device became a higher class.
  It cannot exceed the renderer's 60-fps design ceiling or the actual display ceiling.
  Native energy flags, including hardware-derived false defaults, still win.
- Low is deliberately stricter than Android's premium/GIF exceptions: iOS has shared
  energy fields and shared cached renderers, not the same per-surface LiteMode mask.
  Regular message stickers keep the stock `.once` fallback when looping is disabled;
  this is distinct from pausing the cached emoji/keyboard renderer.
- Fair thermal state caps to 30 fps and disables heavy translucent/effect work.
  Serious/critical/unknown thermal states stop visual and optional background work.
- OS Low Power Mode or the **existing native battery-threshold result** stops visual
  and optional background work in every mode, including High. Unknown battery level
  and the 4/96 threshold endpoints retain `automaticEnergyUsageShouldBeOnNow` semantics.
- Background/Reduce Motion pauses visual work; Reduce Transparency additionally
  vetoes translucency. Foreground recovery and reset recompute from current native
  preferences, not from a previously reduced boolean image.
- Per-target emoji/sticker/effect vetoes are separate from caller-owned
  `shouldBeAnimating`. High cannot resume an opted-out emoji just because a sticker
  keeps the shared clock running. Visibility/playback requests are not overwritten.

## Exact Core API

All declarations are in
`swift/ExteralessCore/Sources/ExteralessCore/ToolsPerformancePolicy.swift`.

```swift
ToolsPerformancePolicy.key == "tools.performanceClass"
ToolsPerformancePolicy.definition: ClientSettingDefinition // declaration; applied Root owns registration
ToolsPerformancePolicy.definitions: [ClientSettingDefinition] == [definition]
ToolsPerformancePolicy.Mode: Int64 // automatic=0, high=1, average=2, low=3

ToolsPerformancePolicy.Selection.init(snapshot: ClientSettingsSnapshot)
ToolsPerformancePolicy.Selection.init(mode: Mode, isStoredOverride: Bool = false)
// Selection exposes mode and isStoredOverride; reset differs from stored zero.

ToolsPerformancePolicy.Energy.init(
    autoplayVideo: Bool, autoplayGif: Bool, loopStickers: Bool, loopEmoji: Bool,
    fullTranslucency: Bool, extendBackgroundWork: Bool, autodownloadInBackground: Bool)
ToolsPerformancePolicy.Environment.init(
    isInForeground: Bool, lowPowerMode: Bool, batterySaving: Bool, thermal: Thermal,
    reduceMotion: Bool = false, reduceTransparency: Bool = false)
// Thermal: nominal / fair / serious / critical / unknown
ToolsPerformancePolicy.Input.init(
    selection: Selection, nativeEnergy: Energy, environment: Environment,
    automaticFramesPerSecond: Int, maximumFramesPerSecond: Int)
ToolsPerformancePolicy.resolve(_ input: Input) -> Budget
// Budget.energy, Budget.animationFramesPerSecond (0 means paused)
Budget.allowsAnimation(_ kind: AnimationKind) -> Bool // emoji / sticker / effect
ToolsPerformancePolicy.advanceFrames(
    frameCount: Int, frameIndex: Int, remainingDuration: Double,
    durations: [Double], elapsed: Double) -> FrameAdvance
// FrameAdvance: frames: Int, index: Int, remainingDuration: Double, didLoop: Bool

ToolsPerformancePolicyStore.init(notifications: NotificationCenter = .default)
ToolsPerformancePolicyStore.shared
ToolsPerformancePolicyStore.didChange: Notification.Name
ToolsPerformancePolicyStore.snapshot() -> ToolsPerformancePublication?
ToolsPerformancePolicyStore.publish(_ input: Input) -> ToolsPerformancePublication
// Publication: revision: UInt64, input: Input, budget: Budget
ToolsPerformancePublicationCursor.init()
ToolsPerformancePublicationCursor.accept(_ publication: ToolsPerformancePublication) -> Budget?
```

Publication revisions are process-local, not fabricated ClientSettings disk
revisions. Identical inputs do not notify. Any selection/presence/native-energy/
environment change publishes a complete immutable result before notification.
Notifications carry invalidation only; subscribers read the latest snapshot.
Callbacks run outside the store lock. A cursor rejects stale/repeated revisions.

## Native helpers and actual decision-chain hunks

### Energy projection

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/ExteralessToolsPerformanceEnergy.swift`:

```swift
@MainActor final class ExteralessToolsPerformanceEnergy
init(settings: MediaAutoDownloadSettings, isInForeground: Bool,
     updated: @escaping (MediaAutoDownloadSettings, ToolsPerformancePublication) -> Void)
func update(settings: MediaAutoDownloadSettings)
func update(isInForeground: Bool)
func dispose()
```

One instance belongs to the existing process-wide `SharedAccountContextImpl`.
It observes the registered public settings cache and native power/thermal/battery/
accessibility notifications; it performs no settings I/O or hardware benchmark.
The applied SharedAccountContext integration separates its native source promise from its effective
consumer promise. `currentAutomaticMediaDownloadSettings` remains the user's raw
settings for editors. The effective `energyUsageSettings` getter is set **before**
the derived download-settings signal is delivered. There is no persisted writeback.
Unrelated native connection/preset changes are also forwarded even if the policy
revision/budget remains equal. The foreground subscription and helper are disposed
with their SharedAccountContext owner.

### Renderer

`telegram-ios/submodules/TelegramUI/Components/MultiAnimationRenderer/Sources/ToolsPerformanceRenderClock.swift`:

```swift
ToolsPerformanceRenderClock.init(tick: @escaping (Double) -> Void)
ToolsPerformanceRenderClock.setPlaying(_ value: Bool)
ToolsPerformanceAnimationGate.init(
    kind: ToolsPerformancePolicy.AnimationKind = .emoji,
    updated: @escaping @MainActor () -> Void)
ToolsPerformanceAnimationGate.update(kind: ToolsPerformancePolicy.AnimationKind)
ToolsPerformanceAnimationGate.allowsAnimation: Bool
ToolsPerformanceAnimationGate.allowsEffects: Bool
```

Creation, playback changes and notifications are main-thread operations. The clock
rearms real timers on a new FPS budget, cancels them when paused, and advances in
seconds rather than frame-count guesses. Resume does not replay background elapsed
time. Targets notify their existing renderer callbacks when an energy veto changes.

The applied source replaces the existing timer owners in **both** DCT and Subcodec, and AND
the target energy veto into their actual target-playing decisions. The current
`AccountContext.swift:395–396` uses DCT; Subcodec is a separate supported backend,
not claimed active by default. `MultiAnimationRenderTarget.shouldBeAnimating` retains
its original requested-state semantics. Keyboard file/reaction/pack-thumbnail/gift
targets are classified explicitly; inline text emoji uses the default emoji kind,
and the two decorative pattern targets use the effect kind.

Both backends also recheck the target veto at **frame delivery**: an allowed target
can keep a shared cache item decoding while another target for that item is opted
out. DCT's queued completion cannot animate that opted-out target or keep updating
its animated blur. First-frame/manual frame APIs retain their initial/static image
behavior. The first time-accounting implementation was incorrect at the real cache /
mux seams (PNP-02/03). The native fixes and decoder-backed fixtures are specified in
the remediation section below; the Core planner alone is not evidence for them.

### Layout, effects and prefetch

- The remaining narrow `ChatController` hunk republishes the effective download
  settings and actual `enableFullTranslucency`, and supplies `energyChanged`.
  The applied `ChatControllerNode` method then collects
  instantiated message IDs, then invokes the existing `requestMessageUpdate` path
  outside enumeration. Existing media layout readers of `energyUsageSettings`
  will recalculate autoplay without a manual message edit once the deferred caller
  hunk lands. Its default `energyChanged: false` keeps the current caller compatible.
- The real animated-sticker item receives energy invalidation, reapplies changed
  loop mode, and gates/removes automatic extra effects through fullTranslucency
  while retaining `canReadHistory` and other native permission checks. Its delayed
  premium-effect entry rechecks the gate before starting.
- `PrefetchManager` intersects optional video predownload with autoplayVideo and
  emoji warmup with loopEmoji, before its existing full-fetch/native permissions.
  Its existing context removal drains no-longer-eligible optional work. Ordinary
  manual/full-download eligibility, privacy filtering, secret-media checks and
  transport parameters keep their native decision paths. High adds no fetch grant.
  This manager's existing `#if DEBUG` early return remains: a debug build alone
  cannot verify its release prefetch body.
- Native effects consumers include media-picker camera previews, spoiler dust,
  placeholders and reveal animations through the existing fullTranslucency field.
  This does not claim that all already-running Core Animation transitions are
  forcibly cancelled or that Android's particle counts were ported numerically.

## Original integration staging requirements (historical)

The original `performance-native-hunks.patch` and these four split artifacts record
the earlier staged integration. Do not reapply them to the published native baseline:

| Patch | Remaining scope |
|---|---|
| `performance-build-hunks.patch` | Core dependency edges for MultiAnimationRenderer and SubcodecMultiAnimationRendererImpl only. |
| `performance-chat-controller-hunk.patch` | The existing energy/download-settings callback only; Chat lead/coordinator applies after CMC scheduler work. |
| `performance-registration-hunk.patch` | Root adds `+ ToolsPerformancePolicy.definitions`; the same artifact contains the exact SDK parser join described below. Held while SDK owner diagnoses Linux manifest drift. |
| `performance-receipt-hunk.patch` | Only the matching performance receipt row; held until the remaining integration is actually applied. |

The Core implementation/tests and the two native helpers use existing source globs.
Before native compilation, the BUILD owner adds
`//third-party/exteraless:ExteralessCore` to both specified renderer targets. DCT
already depends on MultiAnimationRenderer and needs no direct Core import.
TelegramUI already has Core, Display, TelegramUIPreferences and
TelegramPresentationData dependencies. No BUILD file was changed in this apply.

No Root/SDK source, generated manifest, receipt, or ChatController source was changed
in this apply. After the SDK freeze clears, the coordinator joins the remaining
Root/SDK group and regenerates through the SDK owner's existing workflow. The
generic settings screen renders `snapshot.definitions`; it needs no second selector
or ToolsFeatures mutation. This does not claim frozen legacy archive-name migration.
Receipt activation keeps `ported:false` and native execution/frames pending.

### Exact Root / SDK registration join

The public group now exists in Core:

```swift
public static let definitions: [ClientSettingDefinition] = [definition]
```

`performance-registration-hunk.patch` replaces the earlier staged scalar-array
addition with **`+ ToolsPerformancePolicy.definitions`**. This matters because
`tools/compat/sdk_config_manifest.py:root_registration` consumes `.definitions` /
`.galleryDefinitions` groups, and
`tools/runtime/check_swift_plugin_embedding.py:361–368` generates the actual SDK
Root fixture with `result.append(contentsOf: <group>)`. The earlier
`+[ToolsPerformancePolicy.definition]` would have registered the app key while
omitting it from that consumed fixture. The staged Root and consumed fixture now
reference the identical public group.

The **second file section** of the same Root patch is the exact deferred SDK change
to `tools/compat/sdk_config_manifest.py`:

1. Add `ToolsPerformancePolicy.swift` to `HELPERS`.
2. Restrict `REGISTERED_MEMBERS` to the referenced `definition`, not every static
   constructor in the file.
3. Enable the existing literal-constant key resolver for this file (`key: key`).
4. Require `ToolsPerformancePolicy.definitions` in actual parsed Root groups, and
   require the group's complete initializer to be exactly `[definition]`. Root is
   a `static var` body, so it is checked with `root_registration`, not the
   `selected_declarations(..., ("definitions",))` static-let child-owner path.
5. Record Root source registration evidence for the discovered public integer key
   and `NaConfig.performanceClass` symbol.

This SDK section has **not** been applied. A bounded, read-only prospective probe
executed the real parser functions against the staged strings. It found one typed
`tools.performanceClass` definition and the same consumed group. It rejected the
current unregistered Root, the old inline scalar-array form, an empty group and an
appended unreviewed group expression. It generated no manifest and compiled no
native SDK fixture.

Root/SDK sources received parallel font-family/layout/ChatSwipe owner changes during
the final check. The remaining patch still dry-applies on that fresh source and
the prospective parser retains those additions. Their current source fingerprints
are recorded separately from the earlier preimages in
`performance-native-postimages.json`; neither Root nor SDK source was edited by
this performance apply.

## Bounded fixtures and evidence

`ToolsPerformancePolicyTests.swift` supplies **12** tests: all four original values;
every native false flag; automatic measurement versus manual High and real FPS
ceiling; independent emoji/sticker/effect vetoes; battery/Low Power Mode; thermal
states; background/accessibility/return; actual Core set/explicit-zero/reset presence;
commit-before-notification/deduplication; stale publication rejection; equal
animation duration/loop events at 30 and 60 fps; and bounded malformed-metadata /
long-stall frame advancement.
They use small values and one disposable client-settings file, with no accounts,
HTTP, sleeps, real renderer or device energy profiling. Run the already-built test
filter under the authorized runner's **30-second fixture deadline**.

The **12 Core tests remain frozen**, at SHA-256
`cb24284049116a67f5b5e1ffa1d55cf03ff15ff2ea2438616f937dbcf8bbae98`.
The only Core change in this apply is the public `definitions = [definition]` group
and its comment. No test body or policy behavior changed.

Local evidence: the **10 actual native postimages** match the prepared authorized
hunks; inverse application recovers their exact preimage hashes. Scoped
`git diff --check`, source delimiter checks and the **four remaining patches / six
target files** in-memory dry run passed. The Root/SDK prospective parser probe passed as described
above. Swift and Apple SDK execution are unavailable locally; no new compile/test
green is claimed. BUILD, the ChatController caller, Root/SDK registration, receipt
activation and native/frame acceptance remain pending.

The integration-stage whole-tree `PostboxImportCheck.py` run returned **exit 0** after the Monet
owner's correction. This is source-boundary evidence, not a native build or runtime
result.

Before recording an authorized self-owned native fixture (at most 30 seconds), the
expected frames are: High/Average retain animation duration while cadence changes;
Low shows a stable existing/first frame, not an empty layer; opting out of emoji
does not stop opted-in stickers or resume the emoji on High; background/power-saving
stops advancement, and foreground/reset resumes only currently allowed targets;
visible media updates autoplay/effect decisions without a manual message edit.
Use the timestamped frame workflow in `telegram-ios/AGENTS.md`; no energy-saving
percentage or measured device-performance claim is made by these source fixtures.

### Original staging preimages (historical)

These are historical preimages, not current hashes for the ten applied files and
not replacements for any TBF/source-closure pin. Current applied SHA-256 values are
in `performance-native-postimages.json`. Paths below are relative to
`telegram-ios/submodules/TelegramUI/`.

```text
c28dd8599026ac9ad648d48a264dff89b5ed322234e9a406294e1eb221534a75  Components/MultiAnimationRenderer/BUILD
fe7f508f8cf6c39d4ffcae8b1ed7ffbbebd43f61aeda5f3b5c7480c67d72a293  Components/SubcodecMultiAnimationRendererImpl/BUILD
d75f38eb2565677ea42fac96c3a9140f0378f9e5b0d9c600fda53f83c9081a10  Sources/SharedAccountContext.swift
60e4564a28a1f6291b683845180bf3f0f017581922ff4db9b64b467d5062b084  Components/DCTMultiAnimationRendererImpl/Sources/DCTMultiAnimationRendererImpl.swift
4e91e4b051d0524940c6520079fabce3e578bb1788d59ef2bb4fd538499b1dee  Components/SubcodecMultiAnimationRendererImpl/Sources/SubcodecMultiAnimationRendererImpl.swift
48fb18a7cc28682762fac7b43afbfcb398b68141aa0204c80181c8e4af54d760  Sources/ChatController.swift
f4649c1f14e5b516d3c96c678b3adc7e30bfc549786455a90dce2878f83daec2  Sources/ChatControllerNode.swift
8a03e6db39d8fea17a0cd7f73b65a72ca0ee18ad1380ed7e0e9d069197551a7d  Components/Chat/ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift
39b2ead30476571b9e6aa7cf0346d49a10657b6298ef1881bca05bb0364627a7  Sources/PrefetchManager.swift
d4ff240bfb64f944788c0165b73548e2a6b4e137c1c7842ba2a9a0f85eecda3c  Components/MultiAnimationRenderer/Sources/MultiAnimationRenderer.swift
b13b9daa7da785359e623f3beef9c456137e5c1ae06be5bc58dc3d0df24ca1e6  Components/EntityKeyboard/Sources/EmojiKeyboardItemLayer.swift
83be7675da009954e289c8fd4d1468fb49a44426abbf3240160099b6e76dfb83  Components/Chat/MessageInlineBlockBackgroundView/Sources/MessageInlineBlockBackgroundView.swift
465391fa87997d69627966788d95c03e56badd904b50b3cda63a92bd4e1e2a51  Components/PeerInfo/PeerInfoCoverComponent/Sources/PeerInfoCoverComponent.swift
079c928225f64db1c25b77eac650bd057af77f01dc1fa936a14bdaa89f56c473  Sources/ExteralessClient/ExteralessClientRuntime.swift
```

Frozen pre-existing Core Tools corpus: **43 files**, aggregate SHA-256
`c4d4fe4ab0f228be5d0cc531ff60bad7e487eab507f1c2b30af670c59c6aeb47`
(sorted repository path + NUL + raw bytes + NUL, excluding new Performance files).
`ToolsFeatures.swift` SHA-256 remains
`b5cca254c1770cfc6504af9db541a2bd4b6f4c87dfe98531321765be6fd4f7de`.
No commit, push or CI dispatch was performed for this performance work.

## PNP-02/03 native renderer remediation

The independent report `reviews/portable-navigation-performance.md` is retained
unchanged. PNP-01 belongs to the navigation owner. This patch changes only the two
renderer implementations and adds their native fixture sources; Core policy / its
12 tests, the energy/Root/target gates, common cache/decoder/mux libraries, and
earlier TBF fixes are not rewritten.

### PNP-02 — DCT elapsed debt and actual cache advances

Actual contract read: `DCTAnimationCacheImpl.swift:692–769` implements `.frames(n)`
as n real `loadNextFrame()` calls. Its `.duration(seconds)` has its own hidden
remaining-duration state and an unbounded loop; `AdvanceResult.frame.duration` is
the full frame duration, not that hidden remainder. Dividing by the renderer's
shrinking remainder therefore cannot compute a source-frame count.

`ItemAnimationContext` now:

- Accumulates main-queue elapsed debt, including ticks received while a decode or
  its completion is pending. The outstanding debt is capped at **250 ms**.
- Consumes a sub-frame interval directly from the displayed frame's remaining
  duration. Once a boundary is reached, the worker advances the real cache one
  `.frames(1)` at a time and subtracts each actual returned frame duration.
- Performs at most **64 actual source-frame reads** per worker request. It drops
  overflow at the bound, rather than carrying unlimited stalled time into retries.
- Reserves elapsed without removing newer pending time. A completion subtracts
  only its reservation; a pause/reset epoch prevents an old completion from
  subtracting newly resumed elapsed. Cached accessor generations also prevent a
  queued pre-seek decode from advancing a newly reset accessor.
- Aggregates the real `AdvanceResult.didLoop` values and preserves the per-target
  delivery/effects veto. Float32 cache-duration rounding receives a 100-ns boundary
  tolerance, rather than a quotient-to-integer heuristic.

The tiny `15 ms + 18 1/3 ms` sequence now requests two actual source frames after a
primed 60-fps frame, rather than `.frames(11)`. Internal visibility of
`ItemAnimationContext` / `LoadFrameGroupTask` permits `@testable` native fixtures to
control the production worker/completion seam; no alternate timing implementation
is installed for tests.

### PNP-03 — real mux rounds and complete decoder dependencies

Actual contracts read:

- `SCMuxSurface.mm:116–139` / `mux_surface.cpp:407–470`: marking a sprite sets one
  boolean. Each successful emit encodes its current source frame and then advances
  that sprite. A newly added sprite starts with an un-emitted frame-0 introduction.
- `SCVideoToolboxDecoder.mm:187–303`: `decodeStream` creates and destroys a fresh
  VideoToolbox session per call. It requires SPS/PPS in the first packet and the
  IDR/P-frame dependency chain. Passing isolated later P-frames loses that contract.
- `MuxSurface.resize` accepts the current capacity, emits new SPS/PPS plus an
  I_PCM checkpoint, preserves the native next-source indices, and compacts active
  slots in old-slot order.

`SurfaceGroup` now schedules **one mark → emit round per required source step**.
Provisional Swift indices/remaining durations are committed only after the real
VideoToolbox decode returns the expected complete frame set. Introductions are
tracked separately from already displayed source frames. Loop flags come from
the frames actually emitted, and only the final decoded image for the tick is
delivered to each allowed target.

The existing bulk VideoToolbox decoder is reused unchanged. The renderer retains a
complete dependency window of at most **8 composite frames**, also limited by
**32 MiB encoded bytes / 64 MiB decoded planes**. When full, the existing mux resize
API establishes a same-capacity I_PCM checkpoint. This is bounded dependency replay,
not a new general decoder or an increase in the profile's FPS. Replay and checkpoint
frames count toward **64 actual decoder frames per tick**, as do at most 64
elapsed-driven emit rounds; elapsed catch-up remains **250 ms**. No throughput or
energy-saving claim is made for this correctness-first bulk-decoder adaptation.

Because checkpointing compacts slots, context objects retain identity while their
regions update in the native old-slot order. Removal callbacks use each context's
current slot. Paused sprite pixels and native next-frame positions survive the
checkpoint. Failed/partial decode stops the group instead of publishing a Swift
counter which is ahead of the decoder. The caller's `shouldBeAnimating` is retained.

### Native fixture map / BUILD-owner handoff

Machine-readable map: **`performance-native-fixtures.json`**.
Remediation postimages and preserved-source hashes: **`performance-pnp-postimages.json`**.
Exact unapplied target/dependency/suite/map hunks:
**`performance-renderer-fixtures-build.patch`**. The build owner owns application
to the final graph, including `Tests/Exteraless/native-tests.json`.

| Actual fixture source | Native target | Checks |
|---|---|---|
| `telegram-ios/submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl/Tests/ToolsDCTRendererTimingTests.swift` | `//submodules/TelegramUI/Components/DCTMultiAnimationRendererImpl:ExteralessDCTTimingTests` | 5 authored cases: real DCT cache writer/accessor, distinguishable 16×16 frames, 15+18⅓ ms, jittered 30/60 Hz, variable durations, held decode/completion, loops, work bounds and delivery veto. |
| `telegram-ios/submodules/TelegramUI/Components/SubcodecMultiAnimationRendererImpl/Tests/ToolsSubcodecRendererTimingTests.swift` | `//submodules/TelegramUI/Components/SubcodecMultiAnimationRendererImpl:ExteralessSubcodecTimingTests` | 4 authored cases: real SCSprite extraction, SurfaceGroup→SCMuxSurface→VideoToolbox pixels, independent OpenH264 reference, 30/60 Hz/loop, one final delivery, per-target veto, checkpoint compaction and paused pixels, real decode-work bound. |

Direct dependencies are listed in the map and BUILD hunk. Both tests use the existing
`//Tests/Exteraless:Runner` and `:NativeTestHost`, minimum iOS 15, and a **30-second
logic deadline** per fixture. DCT cache readiness waits are 3 seconds. All media are
small locally generated grayscale/YUV/alpha buffers; no account, network, real
media file, simulator interaction or energy profiling is used by the fixtures.
The renderer modules need `swift.enable_testing` in the test configuration for
`@testable`; the repository's rules_swift enables it for dbg/fastbuild (see
`feature_names.bzl:148–152`). No production decoder/cache source is duplicated in
the fixture target.

### Verification boundary

Source delimiter checks passed for both renderer and both fixture files. The
four-file BUILD/suite/native-map handoff dry-applied in memory with unique contexts
and valid JSON; it was not written into the build owner's files. Scoped
`git diff --check` passed. These are source checks, **not native compilation or
executed pixel assertions**. Apple execution is still required for PNP-02/03 closure.
The earlier green Core planner tests do not substitute for these actual-path cases.

Preserved common-source fingerprints:

```text
cb24284049116a67f5b5e1ffa1d55cf03ff15ff2ea2438616f937dbcf8bbae98  swift/ExteralessCore/Tests/ExteralessCoreTests/ToolsPerformancePolicyTests.swift
844a1231151fc4d6c2ee38b14a5512354655479bc7dabaa7815f5ded5edfd024  telegram-ios/submodules/TelegramUI/Components/DCTAnimationCacheImpl/Sources/DCTAnimationCacheImpl.swift
7896d657299ee021b9ce25f6918302fb1be6cbd51b2e506716146c32ead341fd  telegram-ios/third-party/subcodec/Sources/SubcodecObjC/SCVideoToolboxDecoder.mm
b7756bdb74bc364000cf3f674952ae5fad52581eba92704264f295f725d84dec  telegram-ios/third-party/subcodec/src/mux_surface.cpp
```
