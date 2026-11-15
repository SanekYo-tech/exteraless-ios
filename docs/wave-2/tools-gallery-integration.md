# Gallery subtitles — applied integration

**A–E are installed in the ordinary native Gallery source.** The app-side factory,
player clock, measured layout, settings menu and lifecycle are connected, including
native PiP transfer/return/failure. Evidence here is **source hygiene only**; Apple
compilation, native execution and recorded-frame acceptance remain pending.

## Applied files

| File | Applied source |
|---|---|
| `telegram-ios/submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift` | A–E, measured footer callback, native PiP delegate wiring and return gates |
| `telegram-ios/submodules/GalleryUI/Sources/ExteralessGallerySubtitleBridge.swift` | Public controls and context-scoped, revocable factory |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/ExteralessToolsIntegration.swift` | Factory registration in `update(context:)`, revocation in `clearContext()` and token-guarded deinit |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/ExteralessGallerySubtitleAdapter.swift` | Native picker, sidecar tasks, timed UILabel, cancellation and disposal |

### A–E callsites

- **A — state/clock:** `toolsSubtitleIdentity`, `toolsSubtitles`,
  `toolsUpdateSubtitleStatus`. A sample uses the actual `MediaPlayerStatus.timestamp`,
  `generationTimestamp`, `duration`, `baseRate` and `.playing` state.
- **B — media binding:** `setupItem` calls `toolsSetupSubtitles(for:)` immediately
  after `self.item = item`. Replacing the content disposes the old binding and clears
  the old clock/subscription before subscribing to the new node. NativeVideoContent
  and HLSVideoContent use the base document's media ID. Secret/view-once/secret-chat
  media, animations and Live Photos do not get a persistent subtitle binding.
- **C — real status:** the existing main-queue `statusDisposable` forwards each
  status, including nil. It rejects callbacks from a replaced `UniversalVideoNode`.
  Pause/buffering freeze the cue clock; playback, rates and seeks follow that player.
- **D — layout/lifetime:** `containerLayoutUpdated` feeds safe side insets, navigation
  height and footer height. `UniversalVideoGalleryItemOverlayNode.updateLayout` also
  forwards the **already-measured** `GalleryFooterNode` insets, covering caption and
  thumbnail changes that do not relayout the item itself. Layout carries the native
  `ContainedViewLayoutTransition` through to the label.
  `centralityUpdated`, `visibilityUpdated`, ownership/placeholder updates and both
  animate-out paths recompute visibility. Node deinit disposes controls on MainActor.
- **E — actual menu:** `contextMenuMainItems(isSettings:)` adds **Choose subtitles…**
  and **Clear external subtitles**. Actions run after the real context-menu dismissal
  completion, with weak node/controls captures, current-node/current-binding checks
  and visibility checks. A revoked binding cannot open a late picker.

The overlay belongs to the existing Gallery item. Playback remains the existing
`UniversalVideoNode`; there is no additional AVPlayer or replacement Gallery screen.

## Native PiP lifecycle

The visibility condition includes two explicit gates, in addition to centrality,
visibility and content ownership: `toolsNativePictureInPictureActive` and
`toolsGalleryHiddenForPictureInPicture`. A nil `pictureInPictureNode` cannot bypass them.

| Real callback | Subtitle/lifecycle action |
|---|---|
| `pictureInPictureControllerWillStartPictureInPicture` → `willBegin` | Marks the transfer active and hides/cancels subtitle UI before Gallery's custom dismissal |
| `pictureInPictureControllerDidStartPictureInPicture` → `didBegin` | Keeps the active-transfer gate closed |
| `pictureInPictureControllerWillStopPictureInPicture` | Keeps subtitles hidden while AVKit still owns the layer |
| `pictureInPictureControllerDidStopPictureInPicture` → `didEnd` | Resets native transfer resources, releases the active gate and refreshes the real clock/visibility |
| `restoreUserInterfaceForPictureInPictureStop…` → `expand` | Uses the existing navigation window to present Gallery; releases its hidden gate only in presentation completion with a live window and matching generation; reports the real Bool result to AVKit |
| `failedToStartPictureInPictureWithError` → `failedToBegin` | Resets transfer resources and the active gate, restores Gallery if WillStart had already dismissed it |

Presentation and DidStop may complete in either order: **both gates must clear**
before subtitles return. Closing PiP without expanding keeps the dismissed Gallery
hidden. A generation token revokes the pending WillStart fade completion when a
return begins, preventing a late dismissal from removing the returned Gallery.
Callbacks that change subtitle transfer state check the actual video/content instance.

The external text overlay is not an AVKit PiP subtitle track and is not burned into
the video. Its return reloads the same scoped sidecar and uses the latest native clock.

## Public bridge API and context scope

All of these APIs are MainActor-isolated, in **GalleryUI**:

```swift
ExteralessGallerySubtitleBridge.register(
    accountId: Int64, contextIdentity: ObjectIdentifier,
    make: @escaping (String, UIView) -> ExteralessGallerySubtitleControls
) -> UUID
ExteralessGallerySubtitleBridge.isRegistered(_ token: UUID) -> Bool
ExteralessGallerySubtitleBridge.unregister(_ token: UUID)
ExteralessGallerySubtitleBridge.make(
    accountId: Int64, contextIdentity: ObjectIdentifier,
    identity: String, container: UIView
) -> ExteralessGallerySubtitleControls?
```

Controls expose `update(_:)`, `visible(_:)`,
`layout(_:_:_: ContainedViewLayoutTransition)`, `select(_:)`, `clear(_:)`,
`dispose()` and `isDisposed`. Their initializer accepts the six implementation
closures. Disposal is idempotent, releases the closures and makes further calls inert.

- `ExteralessToolsIntegration.updateGallerySubtitles(context:)` captures the actual
  `context.sharedContext.basePath` and `ObjectIdentifier(context)`, plus the actual
  account record ID. Repeated updates of that context reuse the registration.
- Sidecars live below `<basePath>/exteraless/gallery-subtitles`. The store receives
  `account:<recordId>:media:<namespace>:<id>` and hashes it for the filename. The
  integration reuses its store actor for the same root across context switches.
- Factory creation checks **both** context identity and record ID. The factory
  captures only the store, not AccountContext or a presenter.
- `clearContext()` revokes the token and every still-live control, including pickers
  on retained nodes. The registry retains controls weakly. Old teardown/deinit cannot
  unregister a newer token. These calls are already inside ToolsIntegration.

## Picker, cancellation and rendering

One owned `UIDocumentPickerViewController` selects one `.srt` or `.vtt` file. Its
controller identity and operation generation are checked before accepting a callback;
cancel is implemented. Loss of Gallery eligibility or disposal cancels work, clears
the delegate and dismisses only the adapter's own picker/error alert.

Reads run on a worker through `exteralessToolsReadPickedFile`, with the existing byte
bound, file coordination and balanced security-scoped access. Cancellation reaches
the reader task; after reading, the current generation is checked **before** calling
the sidecar store. Load/save/clear results and errors are checked again on return.
An atomic store operation already executing can finish for its original immutable
identity; a late completion cannot attach it to another item or context.

The label uses Dynamic Type, up to three complete lines, truncation for longer cues,
16-point side/bottom spacing and the native layout transition. Insufficient space
hides the label instead of drawing a clipped partial line. Its accessibility ID is
`exteraless.gallery.subtitles`. The 100-ms common-runloop timer runs only for active,
visible, attached, playing content with a track. Paused/buffering statuses render
once; app inactivity and window detachment stop the timer. Dispose removes observers
and the label as well as cancelling work.

## Dependencies and preservation

- Bridge imports: **Display, ExteralessCore, Foundation, UIKit**. GalleryUI's existing
  source glob includes the new file; its current dependency list already includes
  Display and ExteralessCore.
- ToolsIntegration adds **GalleryUI**, an existing TelegramUI dependency. The adapter
  adds **Display**; UIKit/UniformTypeIdentifiers/Core were already used. The direction
  is TelegramUI → GalleryUI → Display/Core, with no GalleryUI → TelegramUI library edge.
- New bridge/adapter/registration code adds no Postbox import/access. The official
  repository Postbox boundary check passed. BUILD changes remain with the build owner.
- Preservation check matched the pre-edit SHA-256 of all four protected regions:
  coordinator `canBeginPictureInPicture`, `maybePerformActionForSwipeDownDismiss`,
  chat `contentDoubleTapAction`, and the `chats.preferOriginalQuality` subscription.
  Existing safe-mode/backup binding code in ToolsIntegration is preserved.
- ToolsCore/Pill/batch APIs and Root/App/CachedSchemaRuntime are outside this patch.

## Checks and native acceptance

Completed locally, each command bounded to at most 30 seconds:

1. `tools-gallery-source-check.py` in the approved OpenCode temporary directory:
   four Swift files passed delimiter/string/comment, NUL/conflict-marker and owned
   formatting checks; four protected source regions matched; zero new Postbox access.
2. `python -B build-system/Make/PostboxImportCheck.py` from `telegram-ios`: **exit 0**.
3. Targeted `git diff --check`: **exit 0**; untracked Swift files are also checked by #1.
4. Read-only parity merge, source-path/range and document hygiene: **pass**,
   111 source references, zero added verified-feature claims.

These checks are not Swift typechecking or UI/runtime evidence. This Windows session
has no Apple SDK/simulator/XcodeBuildMCP. No native test, network/account fixture, commit,
push or CI was run. Earlier coordinator Core CI results are dependency evidence only.

### Expected frames, recorded before the pending native run

Use the real ordinary Native/HLS Gallery with offline fixtures; each recording/fixture
is bounded to 30 seconds. Follow `telegram-ios/AGENTS.md` for passive `simctl recordVideo`
and ffprobe-timestamped frame sheets. Retain indexed/timestamped frames for:

| Path | Expected visible result |
|---|---|
| SRT/VTT import, 0.5/1/2×, pause, buffering, seek | One text overlay follows the actual cue clock; pause/buffer do not advance text; seek replaces the cue immediately on status delivery |
| Controls show/hide, expanded caption, album strip | Text clears the measured footer and follows the same supplied transition; no overlap with footer controls |
| Portrait/landscape, asymmetric Duo insets, large text | Label stays within the safe content band with complete lines; long cues truncate and insufficient space hides it |
| Album swipe, replaced node, clear/reopen, picker cancel | No previous item's cue or late picker on the next item; cancellation leaves the sidecar unchanged; successful clear stays cleared on reopen |
| Native PiP entry, return, close, failed start | Text disappears before transfer and stays hidden through stopping; return restores one current cue only after layer and Gallery are back; failed start cannot leave Gallery invisible |
| Account switch/clear while picker or reader is pending | Old UI closes and cannot publish into the new context; the same media ID in a different account remains isolated |

Native compilation, file-provider/AVKit callback ordering, transition timing and these
frame observations remain **pending**. `tools-parity.json` records applied source with
no promotion to verified.
