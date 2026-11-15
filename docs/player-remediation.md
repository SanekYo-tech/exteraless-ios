# Player remediation — FPP-03 / FPP-06 / FPP-07 / FPP-08

## CMC-14 P2: stale action-at-end after a playlist handoff

Input: `docs/wave-2/reviews/chat-media-composer.md`, CMC-14. **Addressed in source;
eight bounded native fixture methods are authored, not executed here.**

`SharedMediaPlayer.swift` now registers completion with an immutable native
playback-object identity and generation through `ExteralessPlayerEndActionGate`.
The gate checks its lock-protected token on the decoder/worker before enqueue,
again after the main-queue hop, and immediately before the selected effects.
Neither playlist policy nor player state is read from the worker.

- Replacement retires the previous registration before pausing/removing its
  object. Changed playlist item IDs also rearm the callback when the native
  backend object is reused for identical media data.
- Next/actual Previous navigation invalidates before scheduling/playlist control,
  covering the interval before asynchronous replacement completes. Explicit
  playback/seek commands retire queued old completions and rearm the current
  object (pause rearms after pausing). Stop and teardown invalidate as well.
- Loop-item keeps seek-to-zero → play semantics, with an intervening generation
  check so synchronous replacement during seek cannot replay the retired item.
- Advance consumes the registration before effect delivery; duplicate queued
  callbacks cannot advance a loading playlist again. Stop retains a live
  registration so a native overlay's direct replay of the same item still works.
  Voice-stop policy retains its music exclusion and loop-item precedence.
- Native effect closures additionally resolve only the captured object identity;
  they do not blindly pause/play whichever item happens to be current later.

`TelegramUI/Tests/Player/PlayerEndActionGateTests.swift` uses the shipping gate,
plain fake players, a controlled decoder-worker step and a controlled main FIFO
with a one-second worker wait and an eight-step drain cap. Cases: end A → Next/B → drain under both voice-stop
values; A while its replacement is still loading; already-retired A at the worker
boundary; reused-object/ABA generation;
live loop/stop/advance including direct same-item replay; duplicate advance completions; replacement during loop
seek; replacement while reading policy before any effect. B remains playing with
zero stale pause/next/seek/play effects. No Account, audio session/units, MediaPlayer
or remote resource is constructed.

**BUILD needs:** production `Sources/**/*.swift` includes the new Foundation-only
gate under `ExteralessClient/Player/`. Existing `ExteralessPlayerNativeTestsLib`
uses `Tests/Player/*.swift`, so the new fixture is included there without an extra
dependency; any curated cohort list must include `PlayerEndActionGateTests.swift`.
Run the compiled fixture suite with a 30-second bound. No root/PiP/Gallery or
Chat round-send producer changes are part of CMC-14.

Local source checks passed: official Postbox importer/access guard, scoped
`git diff --check`, UTF-8/NUL/delimiter sanity. These are not Swift/native test
execution; this Windows session has not run CI or audio playback.

---

## Focused follow-up: FPP-FU-04

`docs/wave-2/reviews/feed-player-pills-followup.md` closes FPP-03/06/07 in source
and identifies the remaining FPP-08 Surface-sequence bug. **FU-04 is now addressed
in source; its three new native UIKit regressions and recorded frames are pending.**
The reported `43700711108` / `f99909b5` Core player/budget pass is retained evidence
for the Core slice. This follow-up changes UIKit only and makes no new Core/CI claim.

The shipping `ExteralessPlayerSurface.render` captures one playback sample and
makes one follow decision for both `updateLyricsPresentation` and its trailing
`tick`. An unchanged paused track/position/duration is appearance work, even after
the manual-follow deadline expires. A subsequent separate same-position tick
uses the same rule. Advancing playback and actual position/track changes can
follow; the five-second manual-scroll suspension remains in the actual LyricsView.
Artwork palette callbacks explicitly perform presentation-only updates.
`LyricsView.updatePosition` now requires explicit follow permission, so no caller
can silently reintroduce the old default-true second step.

`TelegramUI/Tests/Player/PlayerSurfaceFollowingTests.swift` traverses the **actual
Surface instance and sequence**, using a <1 KiB, 30-line local document:

- Inline → Karaoke → manual scroll far from the active line → injected clock
  past the resume deadline → palette render + another same-position tick: offset
  retained, no seek; a slider lease begun before restyling still returns the same
  track and expected timestamp on explicit completion.
- Playing samples still respect the manual deadline, then call the real table
  following path after expiry and move back to the active line.
- Font restyling's restored anchor survives the full Surface render/tick sequence.

### Exact accountless UIKit API for the native harness owner

Production sources expose the following safe presentation/control seam in
`TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerVisualSurface.swift`.
It constructs the shipping Surface/LyricsView, artwork/mini views and current
occlusion publisher. The harness owns its scenario, window, controls and recording.

```swift
import AccountContext
import ExteralessCore
import TelegramUI
import UIKit

let colors = ExteralessPlayerPalette(
    surface: .black, elevated: .darkGray, primary: .cyan,
    text: .white, secondary: .lightGray
)
var input = ExteralessPlayerVisualInput(
    title: "Fixture", artist: "Fixture",
    style: PlayerStylePolicy(), palette: colors, dark: true,
    artwork: nil, // A local UIImage may be supplied for artwork/disc frames.
    track: track, lyrics: document, offset: 0,
    position: 13, duration: 120, advancing: false
)
let player = ExteralessPlayerVisualSurface(
    input: input,
    now: { fixtureClock },
    animateFollowing: true,
    seek: { track, timestamp in /* record intent / update local fixture input */ }
)
hostView.addSubview(player.view)
player.view.frame = hostView.bounds
player.setInsets(hostView.safeAreaInsets)
player.setLyricsVisible(true) // false shows the same full-player artwork layout
player.setKaraoke(true)
player.scrollLyrics(to: CGPoint(x: 0, y: 650)) // actual manual-follow callback
player.update(input) // actual full render -> presentation -> tick sequence
player.tick()        // actual subsequent playback tick at the supplied sample
let offset = player.lyricsContentOffset
let activeLine = player.activeLyricsIndex

let registry = ExteralessContentOcclusions()
let mini = ExteralessMiniPlayerVisualSurface(input: input, registry: registry,
    open: { /* host reveals the retained player.view */ })
hostView.addSubview(mini.view)
mini.view.frame = miniFrame // parent owns placement; use mini.preferredHeight
mini.update(input, visible: true)
mini.beginGeometryTransition(duration: 0.3) // before an animated frame change
// ... normal UIKit layout/animation supplied by the harness ...
mini.update(input, visible: false)
mini.stop() // terminal owner retirement, current native publisher clears its UUID
player.stop()
```

`track` is a synthetic `PlayerLyricsTrack`; `document` is a small local
`PlayerLyricsDocument.parse(...)` result. Retain both handles while their views
are mounted, and call `stop()` at teardown. A mini input with a different account
retires that handle; create a new handle for a different synthetic account.
The views use the supplied snapshots/clock and do not construct AccountContext,
lyrics clients, media managers or playback engines. Native-engine-only buttons
are disabled on this explicit visual path; seek reports intent to the supplied
closure. The fixture host advances `input.position` / `input.advancing` and calls
`update`/`tick`; it owns any timer. Production still uses the native session and
unchanged playback clocks. Use `animateFollowing: false` only for deterministic
unit assertions; recorded scenarios should use the default true value.

The factory is a UIKit data/control seam, not a second painted player or a new
harness. The existing `Tests/Player/*.swift` test glob picks up the regression
file; production source globs pick up the factory. No root/PiP routing changes
or Core lyrics budget edits are part of FU-04.

FU-04 local checks passed: official Postbox importer/access guard, owned diff
whitespace checks, and UTF-8/delimiter/native-boundary sanity for 15 Player UI/test
files. Core lyrics/budget paths have no working-tree delta in this follow-up.
The three Surface regression methods are authored, not executed in this Windows
session. Native fixture execution and the harness owner's recorded frames remain
the verification boundary.

---

## Initial remediation record

Review input: `docs/wave-2/reviews/feed-player-pills.md`. Worktree HEAD observed
while preparing this handoff: `dcc13004`; the changes here are source changes,
not a CI result. **All four assigned fixes are implemented in source; native
build/XCTest execution and recorded-frame verification remain pending.**

Native short filenames below are under
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/`; Core lyric
filenames are under `swift/ExteralessCore/Sources/ExteralessCore/`.

| Finding | Source status | Regression evidence |
|---|---|---|
| FPP-03 P1 | Player publisher implemented against Feed's account/window/UUID registry contract. | Three accountless UIKit publisher/real-mini fixtures; native Feed admission/inset consumer belongs to Feed owner. End-to-end frames pending. |
| FPP-06 P2 | IDs-only cache updated after confirmed RPC, independent of profile-list cache; failure semantics corrected. | Four real in-memory Postbox fixtures with canned request acknowledgements; no Account/Network. Not run here. |
| FPP-07 P2 | Expanded document, word-text and aggregate candidate/cache budgets checked before output admission/encoding. | Six small Core budget fixtures plus two URLProtocol candidate-budget/fallback cases. Not run here. |
| FPP-08 P2 | New palette precedes lyric update; visible cells reapply colors/fonts without replacing document or seek identity. | Four actual UITableView-cell fixtures for paused plain/inline/karaoke and font changes. Native frames pending. |

## FPP-03: rendered mini-player occlusion

`ExteralessPlayerOcclusionPublisher.swift` publishes to
`AccountContext.ExteralessContentOcclusions` using the contract in
`docs/wave-2/feed-occlusion.md`:

- One immutable owning account ID and one UUID per overlay publisher.
- Rectangles come from `mini.convert(mini.bounds, to: mini.window)`, not a guessed
  bar height or root-controller coordinate system. Visible presentation-layer
  geometry is included only when it belongs to that window's presentation tree.
- Animated layouts retain old/new rectangles and sample while geometry is
  unsettled. Steady publications return to the current rectangle. Registry
  deduplication suppresses unchanged publications.
- `ExteralessMiniPlayerView.geometryChanged` covers attachment, layout, hide and
  detachment. The controller updates publication before/after animated frame
  changes and when top/bottom, 64/52 height, keyboard or orientation layout changes.
  Window hide/show notifications also reconcile the publication.
- A retired controller/publisher rejects subsequent callbacks. Hide/detachment
  clears only its UUID once per live publication; repeated stop/retire cannot clear
  another overlay or revive a retired account. Windows are weakly held.

Production wiring is in `ExteralessPlayerIntegration.swift`'s existing mini
controller (construction, `containerLayoutUpdated`, `stop`). This is a geometry
lease: it calls no media control, read-receipt or account RPC. Existing full-player
30 FPS and mini-progress 15 FPS settings are retained; the separate geometry clock
exists only for unsettled transitions.

Fixtures: `telegram-ios/submodules/TelegramUI/Tests/Player/PlayerOcclusionPublisherTests.swift`.
They cover actual window-coordinate conversion, 64/52 frames, window replacement,
account isolation, owner-only/once clearing, retired callbacks and the real mini
view's attach/layout/hide/detach callbacks. Synthetic windows/views only.

Android counterpart read: `java/app/exteraless/feed/ui/FeedActivity.java:225-246,254-265`
under `third_party/exteraless-android/TMessagesProj/src/main/`: `miniPlayerPadding`
is included in both normal and ignoring-visibility inset paths. Feed owns the
native receipt/inset subtraction; this patch supplies its actual overlay geometry.

## FPP-06: native saved-music state and acknowledgements

`telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/SavedMusic.swift`:

- `_internal_commitSavedMusicUpdate` accepts one true acknowledgement before
  starting the mutation transaction. RPC errors, `false` and a completed request
  with no response are failures, not successful completion.
- `SavedMusicIdsList` is updated independently of `CachedProfileSavedMusic`.
  Known IDs are preserved/deduplicated; an entirely unknown IDs list remains
  unknown rather than being fabricated from one mutation.
- Profile-list and cached profile-header changes also follow successful RPC
  completion. `ProfileSavedMusicContext` applies its local projection before
  downstream successful completion, not before starting the request.
- The real RPC remains `account.saveMusic` with native file references and
  `revalidatedMusic`. The accountless acknowledgement seam is used only by tests.
- Existing `NoError` removal signatures remain compatible, but do not mutate
  caches on failure. Outcome-reporting player consumers use the checked
  `updateSavedMusic(engine:file:isSaved:)` / `ProfileSavedMusicContext.updateMusic`
  APIs and receive `AddSavedMusicError` for either add or remove failure.

`ExteralessPlayerSession.toggleProfileSave` uses those checked operations, keeps
the native IDs subscription authoritative, and reports both add/remove errors.
The classic overlay now shows its Added/Removed bulletin only after confirmed
success; failed operations show an error instead. Its pending request is cancelled
on account invalidation. Removal's existing last-playing-item stop behavior is
guarded by the original item identity so a later track is not stopped.

Fixtures: `telegram-ios/submodules/TelegramCore/Tests/PlayerSavedMusicTests.swift`.
They create only disposable in-memory Postboxes, seed the IDs preference without
a profile page, and observe the actual `_internal_savedMusicIds` signal. Coverage:
save → Remove next action, remove → Save next action; failed/false/missing replies;
pending/cancelled replies; idempotent save; unknown-list preservation. Each wait
is capped at one second. No Account, Network, profile context or resource fetch is
constructed; production request construction remains with the engine owner.

Android source read: `java/app/exteraless/player/PlayerActions.java:279-324`:
file-reference retry, error callback, then independent saved IDs update at line 308
before the optional UserFull/profile cache branch.

## FPP-07: logical expansion bounds

`PlayerLyricsContentBudget` charges a repeated batch before the `for time in times`
append loop. Logical bytes include both line text and its enhanced word-text copy.
It also checks expanded word-cue and row counts atomically before admission.

The exact review case remains supported syntax:

| Source | Source bytes | Expanded line text | Result |
|---|---:|---:|---|
| 64 timestamps + 4096 ASCII characters | 4544 | 262144 | Valid: all 64 timestamps/order preserved |
| 64 timestamps + 4097 ASCII characters | 4545 | 262208 | `responseTooLarge` before adding the repeated rows |

`PlayerLyricsCandidateBudget` independently caps aggregate returned candidates:
40 records, 512 KiB logical line/word text, 65536 cues, 8192 rows, and a bounded
worst-case encoded footprint. Remaining capacity is passed into the next parser.
The fallback keeps its original synced preference: it is parsed under its own
document cap, then admitted with priority while optional search candidates are
trimmed to the aggregate budget before adding the fallback to the collection.
Raw LRCLIB array decoding constructs only the same first 40 records that were
previously selected, rather than decoding an unbounded typed array first.

Documents from provider parsing, embedded data, overrides and disk cache use the
same checked footprint. Punctuation alignment also admits output before appending
lines. Cache trimming and override admission compute conservative JSON-escape/key/
timestamp costs **before JSONEncoder**; the 4 MiB archive is never first encoded
large and then trimmed. Final encoded-size checks remain as a backstop.

Fixtures:
- `swift/ExteralessCore/Tests/ExteralessCoreTests/PlayerLyricsBudgetTests.swift`:
  exact 4545/4544 boundaries, enhanced-word duplication, UTF-8 charging, atomic
  batch rejection, unchecked override rejection before a cache file is created,
  and escaped Unicode within the pre-encoding upper bound.
- Added `testTinySearchReplyCannotMultiplyPastAggregateCandidateBudget` to
  `PlayerLyricsClientTests.swift`: a <16 KB canned HTTP reply, two boundary
  candidates accepted and the third rejected. Catch-all URLProtocol; no live query.
  A second small case verifies that a full 40-candidate collection does not block
  a valid synced LRCMUX upgrade.

Android source read: `java/app/exteraless/player/Lyrics.java:91-120`, particularly
the one-line/multiple-timestamp loop at 104-107. Multiple timestamps were retained.

## FPP-08: paused lyrics appearance

`ExteralessPlayerSurface.render` calculates/applies the new palette before calling
`updateLyricsPresentation`. Artwork palette callbacks use that same order.

`ExteralessPlayerLyricsView.applyAppearance` resolves all lyric colors and fonts
against its actual traits. A changed appearance reconfigures every visible cell,
including plain, previous and future lines at an unchanged active index. Color
changes do not reload rows or move the scroll offset. Font changes remeasure while
preserving the visible anchor and clamping the restored position to scroll bounds.
Trait changes use the same path. The lyric document, track identity, offset,
gesture/seek callback and following state are not replaced for a styling change.

Fixtures: `telegram-ios/submodules/TelegramUI/Tests/Player/PlayerLyricsAppearanceTests.swift`.
Actual visible UITableViewCells are examined through light → dark → light at a
fixed paused document/position. They assert cell identity, attributed colors,
scroll preservation, no seek callback during styling, intact track/time on a later
tap, and font-trait reapplication. Results use the real Core client's offline
embedded-document path; no AccountContext or player backend is instantiated.

Android comparison remains the original `PlayerColors`/`PlayerSheet.applyColors`
and `LyricsView` color updates described in `docs/wave-2/player.md`. UIKit palette
adaptation is retained; this fix concerns propagation/lifecycle rather than a new
visual style.

## Verification and build handoff

Passed locally: official `PostboxImportCheck.py telegram-ios` without exceptions;
owned `git diff --check`; UTF-8/NUL/delimiter/native-boundary source sanity; bounded
arithmetic confirmation of the 4544/4545-byte fixtures. These are **source checks**.
Swift/Xcode is unavailable in this Windows session; none of the **19 new regression
methods** has been executed here. No CI, account/paid actions or external provider
queries were run.

Build-owner additions needed (no root routing changes):

- Core SPM/Bazel globs already include `PlayerLyricsBudget.swift` and its Core tests.
- General `TelegramCoreTestsLib`'s recursive test glob includes
  `Tests/PlayerSavedMusicTests.swift`. Add that same file to the cohort's explicit
  `ExteralessNativeCoreTestsLib.srcs` list.
- Wire `TelegramUI/Tests/Player/*.swift` into a native UIKit test target, with
  `TelegramUI`, `AccountContext` and `ExteralessCore` dependencies, the existing
  Exteraless simulator runner, iOS 15+ and `timeout = "short"`. Run each compiled
  owned suite with a 30-second process bound.

Suggested target names are `ExteralessPlayerNativeTestsLib` /
`ExteralessPlayerNativeTests`, following the adjacent Feed/AI target pattern;
no generated sources or new module dependencies are needed by production code.

Recorded-frame follow-up: mini top/bottom and 64/52 docking on phone/Duo, keyboard
hide/restore, rotation, window/account replacement and old-owner callbacks; paused
plain/inline/karaoke light/dark/artwork palette changes with manual scroll position.
Frames must show no covered Feed post admitted before uncovering, no stale overlay
after retirement, and all visible lyric cells changing appearance together. Native
CI and those frames, then independent re-review, are required for verified status.
