# Player / lyrics native handoff

Source implementation for the **33 original player AppearanceConfig IDs** is in
this worktree. Native build, XCTest execution, frame review and the fresh
independent review are **pending**. The coordinator's reported Core baseline
`4b3f7064` (122 + 89 + 16 green tests) predates this cohort; it is not evidence for
these additions. All parity records remain `ported: false`.

## Integration for coordinator

Apply `docs/wave-2/player-integration-hunks.patch` to
`TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`:

1. Register `PlayerFeatures.definitions` with the other domains, before UI creation.
2. Retain `ExteralessPlayerIntegration`; call `update(context:)` on the main actor
   after selecting the active account and `clearContext()` during account teardown.

The existing `chats.player` settings action still constructs
`ExteralessPlayerController(context:)`, so it needs no replacement action or
duplicate ChatFeatures key. The modern music entry is already wired at
`OverlayAudioPlayerControllerNode.updateExteralessPlayer()`. The classic native
queue is selected with `forceClassic: true`, not by toggling a persisted setting.

`player-gallery-hunks.patch` is a **separate unapplied coordinator hunk** because
Tools owns simultaneous subtitle edits in `UniversalVideoGalleryItem.swift`.
Apply its Gallery and registry parts together. Until then,
`PlayerFeatures.galleryDefinitions` is deliberately outside `definitions` and
`chats.swipeToPip` has no registered inert toggle. Gallery already imports
ExteralessCore in this worktree; the hunk calls the existing native PiP controller,
checks real possibility/active/suspended state, centrality, the stock kill switch,
secret media and animation/live-photo exclusions. It adds opt-in **downward** PiP;
the stock upward gesture retains its native policy.

**Parity ownership transfer:** `chat-parity.json` currently has older `player` and
`nowplaying` module records. Remove those two transferred records from that input
when merging `player-parity.json`; the merger intentionally rejects conflicting
independent module records. Keep the Chat feature records for playback rates,
pause-on-minimize, proximity and autoplay-next-voice. Their definitions are reused.

### Build dependencies

- Core files are covered by the existing ExteralessCore SwiftPM/Bazel source globs.
- New native files live under `TelegramUI/Sources/ExteralessClient/Player/`, covered
  by TelegramUI's recursive source glob. Existing dependencies include
  ExteralessCore, AccountContext, Display, TelegramCore, TelegramUIPreferences,
  PhotoResources, InstantPageUI and SwiftSignalKit. UIKit, AVFoundation and
  UniformTypeIdentifiers are system frameworks.
- `MediaPlaybackHeaderPanelComponent` now reads `PlayerMiniPresentation`; its
  current BUILD already declares `//third-party/exteraless:ExteralessCore`.
- No Postbox importer/access exception is required. New consumers use the Engine
  data/resources APIs. The pre-existing cloud upload path in the classic player
  retains its existing allowed boundary.

## Original sources and exact keys

Original roots: `third_party/exteraless-android/TMessagesProj/src/main/`.
The field declarations are in
`kotlin/app/exteraless/appearance/AppearanceConfig.kt:256-365,392-399`.
Behavior was checked in `java/app/exteraless/player/` (PlayerStyle, Md3Player,
PlayerSheet, PlayerMiniView, PlayerQueueSheet, PlayerActions, OnlineLyrics,
Lyrics/LyricsView, ControlsRow, PlayerColors and SeekableFragmentsExtractorsFactory)
and `java/app/exteraless/nowplaying/NowPlayingController.java`.

All 33 keys are **`appearance.<originalField>`**, not a second `chats.*` copy.
The defaults below match the original declarations. “Adapted” denotes real native
behavior with UIKit geometry/color/animation rather than Android widget identity.

| Original field = default | Native effect / consumer |
|---|---|
| `md3Player=true` | Adapted: `OverlayAudioPlayerControllerNode` selects `ExteralessPlayerSurface`; off selects classic native controls. Settings entry makes the same initial style choice. |
| `md3MiniPlayer=true` | Adapted: `ExteralessPlayerIntegration` mounts the active-account mini overlay on main tabs. The main-list accessory yields only after mounting; chat accessories remain native, as the Android main-tabs-only routing does. |
| `profileMusicCard=true` | Adapted: `PeerInfoHeaderNode.profileMusic` gates the native music strip and its layout. My Profile is included; the native saved-music library stays accessible from the new My Profile Music action. Android off uses its old music row; iOS off hides the header strip. |
| `lrclibAllowed=false` | Native URLSession opt-in; metadata goes only to the pinned LRCLIB/LRCMUX endpoints. Embedded/imported/cached lyrics can work offline. |
| `playerCoverStyle=0` | `ExteralessPlayerSurface` / artwork view: card, wide, full backdrop, disc. |
| `playerCoverSize=100` | Artwork geometry scales 60–100%. |
| `playerCoverRadius=28` | Actual image layer corner radius, 0–48 points, capped to half the rendered side. |
| `playerDiscSpin=true` | Disc rotates while playing/visible; pause freezes its angle, Reduce Motion disables rotation, teardown removes animation. |
| `playerCoverSwipe=true` | Framed artwork horizontal swipe calls native previous/next with the originating playback identity. Card/disc only, matching PlayerStyle. |
| `playerTitleAlign=0` | Leading/centered title and artist, with symmetric center alignment around the like button. |
| `playerTitleSize=1` | Three real font metrics, Dynamic Type, wrapping, scrollable full layout. |
| `playerTitleAbove=false` | Changes title/artwork order for card/disc, matching the original style restriction. |
| `playerOrder=""` | Progress/controls/actions order, six UI permutations; policy deduplicates and appends missing known block IDs. |
| `playerShowActions=true` | Hides the actions row and its height; lyrics/queue/rate stay available in the native action menu. |
| `playerShowModes=true` | Shuffle/order and repeat control visibility/layout. |
| `playerShowLike=true` | Permission-aware save/remove-from-profile button; actual `savedMusicIds`, native revalidating add/remove calls. |
| `playerShowSource=true` | Shows the real message/profile source action when that source is available. |
| `playerWavy=true` | Native UISlider with a drawn animated progress wave and native accessibility/gesture handling. |
| `playerControlsSize=1` | Original scale factors 0.84 / 1 / 1.14 affect the primary control and icon geometry; hit targets stay usable. |
| `playerActionsStyle=0` | Separate rounded controls versus one joined island. |
| `playerColors=0` | Artwork-derived contrast-aware palette versus Telegram theme roles. Native color sampling replaces Android Celebi/HCT/Monet, not a claim of identical colors. |
| `playerBackground=0` | Solid / tonal gradient / native blurred artwork. |
| `playerCoverExtend=true` | Extends artwork backdrop/blur over the full surface; off limits its extent to the artwork region. |
| `playerMiniCover=0` | Rounded / circular / hidden artwork; text reclaiming the removed width. |
| `playerMiniShape=0` | Rounded (20), pill, soft-square (10), with matching progress outline. |
| `playerMiniProgress=0` | Play-button ring / bottom line / hidden / card border, driven by actual media position. |
| `playerMiniColors=1` | Native theme / artwork palette, independently of full-player colors. |
| `playerMiniCompact=false` | 64/52-point panel and 44/36-point artwork, matching the original sizes, plus real compact text metrics. |
| `playerMiniArtist=true` | Artist visibility and title centering. |
| `playerMiniPrevious=false` | Native previous button plus its reclaimed width. |
| `playerMiniNext=true` | Native next button plus its reclaimed width. |
| `playerMiniClose=true` | Native stop/clear-playlist control plus its reclaimed width. |
| `playerMiniTop=false` | Main-tab overlay docks below the actual navigation bar or above the actual horizontal tab item frame; side-tab/safe-inset and keyboard paths are handled. |

### Native queue, actions and retained playback paths

- `ExteralessPlayerSession` observes the active account and the real global player
  together; a paused player is not lost if account publication arrives later.
  Every command checks account validity and a player/item/resource/duration lease.
  Minimize, reopen and account teardown issue **no play command**.
- Continuous scrub and lyric-line taps both use `ChatPlaybackSeekLease`. A new
  item/duration cancels the lease; native seek receives the clamped real timestamp.
- `ExteralessPlayerActions` uses native ShareController for forward, external file
  share and Save to Saved Messages. Real messages are fetched through Engine and
  passed intact (`.messages`), retaining attributes/entities and paid-send checks.
  A missing message is not replaced by a fabricated file-only forward. Saved-music
  files retain their `FileMediaReference`. Save to Files uses `saveMediaToFiles`.
- Copy protection combines the playback source, peer/MyCopyProtection and current
  message restrictions. Secret/view-once media cannot be saved to profile through
  the new buttons. Like state is native `savedMusicIds`; add errors are shown.
  Native remove is optimistic `NoError` and is not advertised as a server ACK.
- Queue opens the **existing** native history/saved-music/rich-message queue with
  the current `playlistLocation` and actual item anchor. Its rich-message track
  references, load-more and saved-music reordering are retained. The small fallback
  queue uses actual InstantPage tracks or the actual single item, and reconstructs
  only the same InstantPage playlist with its original web page/message reference.
  Arbitrary reordering of a chat's message chronology is not exposed as a fake
  local playlist; reordering remains on the native saved-music path.
- My Profile Music opens the native own-account saved-music queue/editor, including
  its Add picker. The uploaded-file callback now passes the **returned cloud file**
  to profile save (the old callback passed its pre-upload local file). Upload and
  file-description disposables are cancelled on account invalidation.
- The classic player and fallback queue also invalidate on a primary-account
  switch; old account controls/menu actions cannot target the new global player.
- Existing `SharedMediaPlayer.swift` and `MediaManager.swift` rate/remember paths
  remain the authoritative implementations: original six-speed cycle
  `[1,1.2,1.5,1.7,2,0.5]`, `chats.musicPlaybackSpeed`, native voice preference,
  exact stored rates, 10-minute music / 5-minute voice position thresholds,
  explicit seek priority, pause-on-minimize and lock-screen base rate.

`nagram.playerDecoder` is explicitly **unsupported as an Android selector** and has
no registered key. “Native Media Decoders” explains the real AVFoundation /
VideoToolbox / FFmpeg pipelines. The original Media3 fragment-extractor API is not
pretended to exist. Native container/codec-specific seeking remains in the native
media pipeline; fragmented-audio codec coverage needs native fixtures/device CI.

## Lyrics implementation and bounds

`PlayerLyricsRequest` pins the original `OnlineLyrics.java:208-328` semantics:

- `https://lrclib.net/api/get`: artist_name, track_name, optional album_name/duration.
- `https://lrclib.net/api/search`: track_name, optional artist_name.
- `https://api.lrcmux.dev/get`: title, level=line, format=json, optional artist,
  album and duration. Its `start` values are milliseconds. A duration difference
  greater than five seconds rejects the fallback recording.
- Prefer primary synced/instrumental output; otherwise try LRCMUX, preferring a
  synced upgrade. Four-token / 90% punctuation alignment preserves the fallback
  timestamps. Search retains synced +40 and the original three-second duration
  scoring, with additional title/artist and gross-duration mismatch rejection.
  Users can explicitly choose another returned candidate or edit the query.

`PlayerLyricsDocument` handles CRLF, multiple line timestamps, decimal/colon
fractions, Android-sign `[offset:ms]`, metadata/blank-line normalization, stable
timestamp ordering, plain/instrumental lyrics and real enhanced word cues.
Malformed seconds and oversized input are rejected defensively. Inline shows
nearby lines; karaoke follows the active line and uses real word cues, or a
line-progress fill between real line timestamps and the actual track end.
Untimed text is not made seekable. User scrolling temporarily suspends following.

The UI also loads embedded lyrics/album from the locally available AVURLAsset
(three-second metadata budget), imports a user-selected LRC/text file, stores an
explicit lyric override and supports a separate −60…+60-second delay. Positive
user delay displays/seeks later; it is distinct from the LRC metadata offset.

Identity is **account + native resource ID + exact duration in milliseconds**.
Query metadata can improve later without losing the user's choice. Separate
generation tokens reject cancelled/late metadata/HTTP results. A track or account
switch cancels the URLSession task, metadata loading and interactive seek lease.

Bounds:

- 20 seconds for an entire provider lookup including retries; each request is at
  most 10 seconds. Three attempts per endpoint; original 0.7/2-second backoff and
  numeric Retry-After capped to 5 seconds, all cancellation-aware.
- Three concurrent lookups per account client; excess requests report busy.
- Streaming response cap 1 MiB; no URLSession `data(for:)` unbounded buffer.
- Lyric text 256 KiB, a line 8 KiB, 4096 lines, 32768 word cues, 40 candidates.
- Success LRU 24 records / 4 MiB; missing 128 records / 15-minute TTL; at most 64
  explicit overrides. Archive reads are bounded before decoding; writes are atomic
  and a too-large override archive reports an error rather than evicting selections.
- Account-local archive: `<basePath>/exteraless-player/<account-id>/lyrics-v1.json`.
  The client has no credential setting. No Android preferences/keys are imported;
  URLSession has no cookies, credential storage, additional auth headers or redirects.

## Changed files

Core (`swift/ExteralessCore/Sources/ExteralessCore/`):
`PlayerFeatures.swift`, `PlayerStylePolicy.swift`, `PlayerLyrics.swift`,
`PlayerLyricsHTTP.swift`, `PlayerLyricsClient.swift`, `PlayerMiniPresentation.swift`.

Native (`TelegramUI/Sources/ExteralessClient/Player/`):
`ExteralessPlayerSession.swift`, `ExteralessPlayerSurface.swift`,
`ExteralessPlayerArtworkView.swift`, `ExteralessPlayerProgressView.swift`,
`ExteralessPlayerLyricsView.swift`, `ExteralessLyricsSelectionController.swift`,
`ExteralessPlayerActions.swift`, `ExteralessPlayerQueueController.swift`,
`ExteralessMiniPlayerView.swift`, `ExteralessPlayerIntegration.swift`.

Existing native seams: `Chats/ExteralessPlayerController.swift`,
`OverlayAudioPlayerController.swift`, `OverlayAudioPlayerControllerNode.swift`,
`MediaPlaybackHeaderPanelComponent.swift` (account replacement + mounted-player
suppression), and the single music gate in `PeerInfoHeaderNode.profileMusic`.
Preserve other agents' changes around those latter shared components.

## Checks and next review

- **Passed locally:** official `PostboxImportCheck.py telegram-ios`, without any
  allowlist changes; UTF-8/NUL/delimiter/whitespace sanity for 18 new and four
  existing owned Swift files; owned `git diff --check`. Both coordinator patches
  pass read-only `git apply --check`. These are source checks, not Swift compilation.
- **Parity validation passed:** real `merge_parity` accepts 35 feature records
  (33 Appearance + PiP + decoder) and two modules; all 90 file/line references are
  within source bounds. It preserves all 567 inventory features and produces zero
  player verified/ported claims. Chat + Player also merge after the documented
  removal of the two transferred older Chat module records. States: 36 partial,
  one unsupported.
- **Written, not run:** 23 XCTest methods in `PlayerPolicyTests.swift` and
  `PlayerLyricsClientTests.swift`. They cover original defaults/ranges, timestamp
  parsing/alignment, actual rate interpolation, identity/seek cancellation,
  provider ordering/scoring, fallback duration rejection, offline consent,
  persistent overrides, LRU/missing behavior, retries, real URLSession cancellation,
  streaming/header limits and deadlines.
- All HTTP tests install a catch-all URLProtocol with canned provider-schema
  responses and synthetic track metadata. They cannot fall through to real DNS or
  HTTP. Test timeouts are short; run the owned suite with a **30-second bound**.
- `player-parity.json` uses original inventory IDs and source-only evidence.
  Main registration/Gallery application and real CI remain outstanding. No visual
  or runtime verification is claimed from the coordinator's older green cohort.

Fresh independent reviewers should compare the original player/nowplaying sources
with these paths, first read-only: (1) all 33 effects/routing and account teardown;
(2) provider/error/cache/cancellation and reference/paid-send semantics;
(3) UIKit layout/gestures/lifetimes. The coordinator then runs the native build and
the owned fixtures before promoting any parity status.

### Required visual evidence (currently pending)

Before recording, expect: the full sheet moves as one surface (~0.3 s native
transition), no blank artwork or duplicate mini during entry/exit; disc rotation
freezes on pause and never resumes playback itself; the wave advances smoothly
only during playback; line following respects manual scrolling and tapping seeks
the correct current track; the mini remains above the actual tab bar or below the
header, clears side/keyboard insets, and disappears across account switches.

Record full/mini open/close, card/wide/full/disc, pause/buffer, artwork swipe, slider
cancel and automatic next, inline/karaoke with plain/synced/word/instrumental/error,
candidate/offset changes, light/dark, large Dynamic Type, compact landscape and Duo
side-strip layouts. Include first/last list rows under the floating mini to check
occlusion. Use `simctl io recordVideo` and labelled timestamped frame sheets per
AGENTS.md. XcodeBuildMCP/device tools are unavailable in this Windows session.
