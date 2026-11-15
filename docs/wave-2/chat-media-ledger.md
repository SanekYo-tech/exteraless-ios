# Chat media/browser/alias ledger — 13 + 6 original IDs

Source receipts for `docs/parity/wave-2-reconciliation.md:87–111`.
All 19 IDs belong in Chat's fragment. Playback's 33 Appearance-field transfer did
not transfer the six baseline IDs below. Native compilation/runtime/frames pending.

## Thirteen previously missing records

| Original ID | Source behavior and native disposition |
|---|---|
| `chats.hdrPhotos` | Android `PhotoViewer.updateWindowHdrColorMode`: API 34+, gainmap photo, HDR display. Native gallery decodes the original resource with `UIImageReader.Configuration.prefersHighDynamicRange`, caps at 4096 px and presents HDR in `UIImageView` on iOS 17+. The original zoom/capture-protection parent owns that view; off/SDR uses the normal raster. |
| `chats.translateInSheet` | Android `ChatActivity.showTranslateSheet`: excludes poll, voice and already translated message; rich pages stay rich. Native helper opens `makeTextProcessingScreen` with a `ComposedRichMessage.rich` or entities-bearing `.plain`, current source capability and account lease. Double-tap is connected; ordinary AI-message entry has the narrow hunk in `chat-media-shared.patch`. Provider selection stays with AI. |
| `chats.unmuteWithVolumeButtons` | **Android hardware-KeyEvent disposition.** `LaunchActivity:8871–8897` consumes a non-repeated volume up/down ACTION_DOWN outside VoIP/PhotoViewer/sheets, then tries the visible chat video. iOS has no public general-chat equivalent that consumes those hardware volume events instead of changing volume. `outputVolume` observation cannot identify/consume that event. No native toggle or substitute behavior is registered. |
| `nagram.defaultHlsVideoQuality` | **Only value 1 is migrated** by `ChatsConfig:403–405` to `preferOriginalQuality=true`, resetting this integer to 0. Values 2–5 remain live in `VideoPlayer.getDefaultSavedQuality:511–534`. Native gallery implements those same descending quality bands/fallbacks; the original-quality toggle wins, and explicit viewer selection cancels the pending default. Native highest-available is the adaptation for Android's separate original rendition. |
| `nagram.disableChannelMuteButton` | Source migration bridges `DisableChannelMuteButton=true` to `OEChatsBottomButton=0`, and mirrors hidden bottom action back to the legacy flag. Native consumer is the existing `chats.bottomButton` channel panel. No independent legacy switch. |
| `nagram.disableInAppBrowserGestures` | Android `ArticleViewer.handleTouchEvent` returns false. Native Browser disables WebKit back/forward gestures live and its enclosing interactive navigation/dismiss gesture; buttons and page scrolling remain native. |
| `nagram.disablePreviewVideoSoundShortcut` | **Source-storage-only disposition, not a hardware alias.** Exact Java/Kotlin search finds the `NaConfig` declaration (default true) and `NekoChatSettingsActivity` row, but no operational getter/field consumer. No native control is claimed. The distinct `unmuteWithVolumeButtons` behavior is recorded separately above. |
| `nagram.hideReactions` | Source true fans out to the three chat-kind flags and resets the old flag to false. Native reaction consumers already use those three canonical flags. No fourth independent switch. |
| `nagram.messageColoredBackground` | Source false writes `replyBackground=false` and resets the old flag to true. Native reply background consumer uses the canonical preference. No inverse duplicate toggle. |
| `nagram.sendMp4DocumentAsVideo` | Source default true enters the video sender for MP4 file selection. Native asset/file-picker paths add a Video attribute only for valid playable MP4 metadata, preserve resource/caption/entities/spoiler/paid/group data, and keep original-quality file bytes. Files metadata load is cancellable with a 5 s fallback to document. Mixed document/video kinds follow native homogeneous-album rules. |
| `nagram.showSmallGIF` | Source single GIF preview is 120 dp. Native standalone constrained GIF layout uses 120 pt; album/mosaic, paid-preview and secret geometry remain on native paths. Media/message attributes are not projected through JSON or rewritten. |
| `neko.autoPauseVideo` | Source pauses video/PiP on background and resumes only its own paused video. Native gallery listens to foreground + active account, uses a paused-item identity, and rejects resume after item/account change or a pre-existing user pause. Disabling leaves platform playback policy in control. |
| `neko.takeGIFasVideo` | Source enables normal video controls for GIFs. Native gallery enables scrubber, playback/settings and eligible PiP controls while preserving the GIF media flag and looping behavior. |

## Source-defined alias import handoff

`ChatLegacyPreferenceMigration.apply(to:)` exactly projects a **source nkmrcfg
dictionary**, including source precedence over conflicting OE values. It does not
migrate an invented native schema or add legacy controls. Pure bounded tests cover
predicates, fan-out, reverse bottom-button mirroring, unrelated data and idempotence.

`chat-media-shared.patch` gives the Cloud owner the importer insertion and typed
rules. Apply it before making an imported-alias runtime claim. The existing public
batch applies the projected canonical values atomically. Cloud's dependency on
`ChatDoubleTapAction` is retained; this handoff is independent of the committed-slice
failure. The ordinary translation-menu hunk is in the same packet for the AI owner.
The packet also explicitly excludes `nagram.showTextTranslate` from AI's fragment,
whose consumer evidence is aggregated in Chat's record. This is required by the
strict duplicate check in `merge_parity`; fragment ordering cannot resolve it.

## Six restored baseline receipts

| Original ID | Actual consumer |
|---|---|
| `chats.doubleTapSeekDuration` | `GalleryUI/.../UniversalVideoGalleryItem.swift`: double-tap seek uses the original `[5,10,15,30]` table in `ChatPlaybackPolicy`; boundary-clamped native seek. |
| `chats.pauseOnMinimizeRound` | `TelegramUI/Sources/SharedMediaPlayer.swift`: foreground callback and new playlist-item construction consult `shouldPauseInBackground(.instantVideo)`. |
| `chats.pauseOnMinimizeVoice` | Same native foreground/new-item path for `.voice`. |
| `chats.preferOriginalQuality` | Gallery's first available native quality state selects the highest available, with explicit-choice precedence. |
| `nagram.dontAutoPlayNextVoice` | `SharedMediaPlayer.swift`: playback-completed branch pauses non-music instead of advancing; manual Next remains native. |
| `neko.disableProximityEvents` | `MediaManager.swift`: conjunctive gate on new voice-player proximity control, alongside native Raise to Listen. |

Each receipt has current source anchors and source-test evidence. Restored defaults
are also exercised by the real registration/write/reopen test; those are not runtime
playback, hardware, provider or visual test results.

## Build edges / verification handoff

Build owner: new direct `ExteralessCore` imports in `BrowserUI`, `LegacyMediaPickerUI`,
`ChatMessageInteractiveMediaNode`, and the previously reported `AdminUserActionsSheet`.
`GalleryUI` and TelegramUI already declare Core. `ShareExtensionContext → TextFormat`
remains required by the shared import hunk. New helper files use their normal source globs.

Frames: compare HDR on/off on a gainmap-capable device; toggle browser swipes in an
existing page; record compact GIF beside an unchanged album; open GIF controls and
seek without an item jump; background/resume A, switch to B, and verify no A replay;
open a rich translation sheet and verify tables/media/links retain their structure.
No recorded frames or Apple build were available in this session.
